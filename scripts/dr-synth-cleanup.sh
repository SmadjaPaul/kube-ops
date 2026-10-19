#!/usr/bin/env bash
# Cleanup for one named synthetic DR drill.
#
# Safety contract:
#   * dry-run is the default;
#   * apply requires an approval token derived from the exact manifest digest;
#   * every delete is preceded by an identity and ownership re-check;
#   * an absent object is safe only when this journal proves this run deleted it;
#   * this script never force-deletes, removes finalizers, or uses wildcards.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: dr-synth-cleanup.sh [--dry-run|--apply] [--resume]
  [--manifest FILE] [--journal FILE] [--report FILE] [--metadata-dir DIR]

Default mode is --dry-run. Apply requires:
  DR_CLEANUP_APPROVAL=APPROVE:<run>:<manifest-sha256>

If CNPG/Barman objects exist in the drill, apply also requires:
  DR_CLEANUP_ALLOW_BARMAN_CR_DELETE=true
EOF
}

mode=dry-run
resume=false
manifest="${DR_CLEANUP_MANIFEST:-/tmp/dr-synth-20261019170700-cleanup-manifest.json}"
journal="${DR_CLEANUP_JOURNAL:-/tmp/dr-synth-20261019170700-cleanup.journal.jsonl}"
report="${DR_CLEANUP_REPORT:-/tmp/dr-synth-20261019170700-cleanup-report.jsonl}"
metadata_dir="${DR_CLEANUP_METADATA_DIR:-/tmp/dr-synth-20261019170700-cnpg-metadata}"
delete_timeout="${DR_CLEANUP_DELETE_TIMEOUT:-60s}"
transition_timeout="${DR_CLEANUP_TRANSITION_TIMEOUT:-300}"
poll_seconds="${DR_CLEANUP_POLL_SECONDS:-2}"
request_timeout="${DR_CLEANUP_REQUEST_TIMEOUT:-8s}"
kubectl_bin="${KUBECTL_BIN:-kubectl}"

while (($#)); do
  case "$1" in
    --dry-run) mode=dry-run ;;
    --apply) mode=apply ;;
    --resume) resume=true ;;
    --manifest) shift; manifest="${1:?missing manifest path}" ;;
    --journal) shift; journal="${1:?missing journal path}" ;;
    --report) shift; report="${1:?missing report path}" ;;
    --metadata-dir) shift; metadata_dir="${1:?missing metadata directory}" ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

die() { printf 'DR_CLEANUP=BLOCKED\nREASON=%s\n' "$*" >&2; exit 1; }
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}';
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

[[ -s "$manifest" ]] || die "manifest missing: $manifest"
command -v jq >/dev/null 2>&1 || die "jq is required"
command -v "$kubectl_bin" >/dev/null 2>&1 || die "kubectl is required: $kubectl_bin"
kube() { "$kubectl_bin" --request-timeout="$request_timeout" "$@"; }

manifest_sha="$(sha256_file "$manifest")"
run="$(jq -er '.run' "$manifest")" || die "manifest.run missing"
inventory_file="$(jq -er '.inventory.file' "$manifest")" || die "manifest.inventory.file missing"
inventory_sha="$(jq -er '.inventory.sha256' "$manifest")" || die "manifest.inventory.sha256 missing"
[[ -s "$inventory_file" ]] || die "inventory missing: $inventory_file"
[[ "$(sha256_file "$inventory_file")" == "$inventory_sha" ]] || die "inventory digest mismatch"
[[ "$(jq -r '.namespaces|length' "$manifest")" -gt 0 ]] || die "empty namespace plan"

mkdir -p "$(dirname "$journal")" "$(dirname "$report")" "$metadata_dir"
touch "$journal" "$report"

log_event() {
  local action="$1" kind="$2" namespace="$3" name="$4" uid="$5" detail="${6:-}"
  jq -cn --arg ts "$(now)" --arg run "$run" --arg action "$action" \
    --arg kind "$kind" --arg namespace "$namespace" --arg name "$name" \
    --arg uid "$uid" --arg detail "$detail" \
    '{ts:$ts,run:$run,action:$action,kind:$kind,namespace:$namespace,name:$name,uid:$uid,detail:$detail}' \
    | tee -a "$journal" >> "$report"
}

journal_has_deleted() {
  local kind="$1" namespace="$2" name="$3" uid="$4"
  jq -e -s --arg kind "$kind" --arg namespace "$namespace" --arg name "$name" --arg uid "$uid" \
    'any(.[]; .action == "deleted" and .kind == $kind and .namespace == $namespace and .name == $name and .uid == $uid)' \
    "$journal" >/dev/null
}

get_json() {
  local kind="$1" namespace="$2" name="$3"
  if [[ -n "$namespace" ]]; then
    kube -n "$namespace" get "$kind" "$name" -o json
  else
    kube get "$kind" "$name" -o json
  fi
}

get_list_json() {
  local kind="$1" namespace="$2"
  if [[ -n "$namespace" ]]; then kube -n "$namespace" get "$kind" -o json
  else kube get "$kind" -A -o json; fi
}

assert_identity() {
  local kind="$1" namespace="$2" name="$3" expected_uid="$4" json
  if ! json="$(get_json "$kind" "$namespace" "$name" 2>/dev/null)"; then
    if journal_has_deleted "$kind" "$namespace" "$name" "$expected_uid"; then
      log_event already-deleted "$kind" "$namespace" "$name" "$expected_uid" "journal-confirmed"
      return 3
    fi
    die "object absent without matching journal deletion: $kind $namespace/$name"
  fi
  [[ "$(jq -r '.metadata.uid // ""' <<<"$json")" == "$expected_uid" ]] || \
    die "UID divergence: $kind $namespace/$name"
  printf '%s' "$json"
}

assert_run_label() {
  local json="$1" kind="$2" namespace="$3" name="$4"
  [[ "$(jq -r '.metadata.labels["dr.smadja.dev/run"] // ""' <<<"$json")" == "$run" ]] || \
    die "run label mismatch: $kind $namespace/$name"
}

write_metadata_snapshot() {
  local kind="$1" namespace="$2" name="$3" json="$4" out
  out="$metadata_dir/${namespace:-cluster}__${kind//\//_}__${name}.json"
  jq 'del(.metadata.managedFields) | {apiVersion,kind,metadata:{name,namespace,uid,labels,annotations,ownerReferences,finalizers},status:{phase:(.status.phase // null),conditions:(.status.conditions // [])}}' \
    <<<"$json" >"$out"
}

preflight_namespace() {
  local row name uid json rc
  while IFS= read -r row; do
    name="$(jq -r '.name' <<<"$row")"; uid="$(jq -r '.uid' <<<"$row")"
    if json="$(assert_identity namespace '' "$name" "$uid")"; then :; else
      rc=$?; (( rc == 3 )) && continue; return "$rc"
    fi
    assert_run_label "$json" namespace '' "$name"
    log_event verified namespace '' "$name" "$uid" "run-label"
  done < <(jq -c '.namespaces[]' "$manifest")
}

preflight_configmaps() {
  local row ns name uid json rc
  while IFS= read -r row; do
    ns="$(jq -r '.namespace' <<<"$row")"; name="$(jq -r '.name' <<<"$row")"; uid="$(jq -r '.uid' <<<"$row")"
    if json="$(assert_identity configmap "$ns" "$name" "$uid")"; then :; else
      rc=$?; (( rc == 3 )) && continue; return "$rc"
    fi
    assert_run_label "$json" configmap "$ns" "$name"
    log_event verified configmap "$ns" "$name" "$uid" "run-label"
  done < <(jq -c '.configMaps[]' "$manifest")
}

preflight_storage() {
  local row pv pvuid ns pvc pvcuid handle json volume vuid volume_ns volume_pvc attachments refs rc
  while IFS= read -r row; do
    pv="$(jq -r '.name' <<<"$row")"; pvuid="$(jq -r '.uid' <<<"$row")"
    ns="$(jq -r '.claimRef.namespace' <<<"$row")"; pvc="$(jq -r '.claimRef.name' <<<"$row")"
    pvcuid="$(jq -r '.claimRef.uid' <<<"$row")"; handle="$(jq -r '.volumeHandle' <<<"$row")"
    if json="$(assert_identity pv '' "$pv" "$pvuid")"; then :; else
      rc=$?; (( rc == 3 )) && continue; return "$rc"
    fi
    [[ "$(jq -r '.spec.persistentVolumeReclaimPolicy // ""' <<<"$json")" == Retain ]] || die "PV is not Retain: $pv"
    [[ "$(jq -r '.spec.claimRef.namespace // ""' <<<"$json")" == "$ns" ]] || die "PV claim namespace mismatch: $pv"
    [[ "$(jq -r '.spec.claimRef.name // ""' <<<"$json")" == "$pvc" ]] || die "PV claim name mismatch: $pv"
    [[ "$(jq -r '.spec.claimRef.uid // ""' <<<"$json")" == "$pvcuid" ]] || die "PV claim UID mismatch: $pv"
    [[ "$(jq -r '.spec.csi.volumeHandle // ""' <<<"$json")" == "$handle" ]] || die "PV volumeHandle mismatch: $pv"
    log_event verified pv '' "$pv" "$pvuid" "claimRef=$ns/$pvc volumeHandle=$handle"

    if json="$(assert_identity pvc "$ns" "$pvc" "$pvcuid")"; then :; else
      rc=$?; (( rc == 3 )) && continue; return "$rc"
    fi
    [[ "$(jq -r '.spec.volumeName // ""' <<<"$json")" == "$pv" ]] || die "PVC volumeName mismatch: $ns/$pvc"
    log_event verified pvc "$ns" "$pvc" "$pvcuid" "volumeName=$pv"

    volume="$(jq -r '.volumeName' <<<"$row")"; vuid="$(jq -r '.volumeUid' <<<"$row")"
    volume_ns="$(jq -r '.volumeNamespace' <<<"$row")"; volume_pvc="$(jq -r '.volumePvcName' <<<"$row")"
    if json="$(assert_identity volumes.longhorn.io "$volume_ns" "$volume" "$vuid")"; then :; else
      rc=$?; (( rc == 3 )) && continue; return "$rc"
    fi
    [[ "$(jq -r '.status.kubernetesStatus.namespace // ""' <<<"$json")" == "$ns" ]] || die "Longhorn namespace mismatch: $volume"
    [[ "$(jq -r '.status.kubernetesStatus.pvcName // ""' <<<"$json")" == "$volume_pvc" ]] || die "Longhorn PVC mismatch: $volume"
    [[ "$volume_pvc" == "$pvc" ]] || die "manifest Longhorn/PVC mismatch: $volume"
    log_event verified volumes.longhorn.io "$volume_ns" "$volume" "$vuid" "exclusive=$ns/$pvc"

    attachments="$(kube get volumeattachments.storage.k8s.io -o json 2>/dev/null || printf '{"items":[]}')"
    if jq -e --arg pv "$pv" 'any(.items[]?; .spec.source.persistentVolumeName == $pv)' <<<"$attachments" >/dev/null; then
      log_event verified volumeattachment '' "$pv" "$pvuid" "attachment belongs to planned target; deletion remains blocked until detached"
    fi
    refs="$(kube get pvc -A -o json)"
    if jq -e --arg pv "$pv" --arg ns "$ns" --arg pvc "$pvc" \
      'any(.items[]; .spec.volumeName == $pv and (.metadata.namespace != $ns or .metadata.name != $pvc))' <<<"$refs" >/dev/null; then
      die "PV has another PVC reference: $pv"
    fi
  done < <(jq -c '.pvs[]' "$manifest")
}

preflight_barman() {
  local ns kind list item name uid has_barman=false
  for ns in $(jq -r '.namespaces[].name' "$manifest"); do
    case "$ns" in *-cnpg-*) ;; *) continue ;; esac
    for kind in clusters.postgresql.cnpg.io backups.postgresql.cnpg.io scheduledbackups.postgresql.cnpg.io objectstores.barmancloud.cnpg.io; do
      list="$(get_list_json "$kind" "$ns" 2>/dev/null || printf '{"items":[]}')"
      while IFS= read -r item; do
        name="$(jq -r '.metadata.name' <<<"$item")"; uid="$(jq -r '.metadata.uid' <<<"$item")"
        has_barman=true
        if [[ "$(jq -r '(.metadata.finalizers // []) | length' <<<"$item")" != 0 ]]; then
          die "CNPG/Barman object has finalizer; manual review required: $ns/$name"
        fi
        if [[ "$kind" == objectstores.barmancloud.cnpg.io && -z "$(jq -r '.spec.retentionPolicy // ""' <<<"$item")" ]]; then
          die "Barman ObjectStore has no retention policy: $ns/$name"
        fi
        if [[ "$kind" == backups.postgresql.cnpg.io && "$(jq -r '.status.phase // ""' <<<"$item")" != completed ]]; then
          die "CNPG Backup is not completed: $ns/$name"
        fi
        write_metadata_snapshot "$kind" "$ns" "$name" "$item"
        log_event preserved-metadata "$kind" "$ns" "$name" "$uid" "secret-free retention=$(jq -r '.spec.retentionPolicy // "none"' <<<"$item")"
      done < <(jq -c '.items[]?' <<<"$list")
    done
  done
  if [[ "$mode" == apply && "$has_barman" == true && "${DR_CLEANUP_ALLOW_BARMAN_CR_DELETE:-false}" != true ]]; then
    die "Barman/CNPG CR deletion requires DR_CLEANUP_ALLOW_BARMAN_CR_DELETE=true"
  fi
}

preflight_preserved() {
  local row kind ns name uid json rc
  while IFS= read -r row; do
    kind="$(jq -r '.kind' <<<"$row")"; ns="$(jq -r '.namespace // ""' <<<"$row")"; name="$(jq -r '.name' <<<"$row")"; uid="$(jq -r '.uid' <<<"$row")"
    if json="$(assert_identity "$kind" "$ns" "$name" "$uid")"; then :; else
      rc=$?; (( rc == 3 )) && continue; return "$rc"
    fi
    log_event preserved "$kind" "$ns" "$name" "$uid" "outside-delete-plan"
  done < <(jq -c '.preserve[]' "$manifest")
}

wait_for_json() {
  local kind="$1" ns="$2" name="$3" expression="$4" started now_s json
  started="$(date +%s)"
  while true; do
    if json="$(get_json "$kind" "$ns" "$name" 2>/dev/null)"; then
      if jq -e "$expression" <<<"$json" >/dev/null; then printf '%s' "$json"; return 0; fi
    else
      return 1
    fi
    now_s="$(date +%s)"
    (( now_s - started >= transition_timeout )) && return 1
    sleep "$poll_seconds"
  done
}

delete_one() {
  local kind="$1" ns="$2" name="$3" uid="$4" cascade="${5:-background}" json rc
  if json="$(assert_identity "$kind" "$ns" "$name" "$uid" 2>/dev/null)"; then :; else
    rc=$?; (( rc == 3 )) && return 0; return "$rc"
  fi
  log_event delete-intent "$kind" "$ns" "$name" "$uid" "cascade=$cascade"
  if [[ "$mode" == dry-run ]]; then
    log_event planned "$kind" "$ns" "$name" "$uid" "dry-run"
    return 0
  fi
  if [[ "$kind" == namespace ]]; then
    kube delete namespace "$name" --cascade=foreground --wait=true --timeout="$delete_timeout"
  elif [[ -n "$ns" ]]; then
    kube -n "$ns" delete "$kind" "$name" --wait=true --timeout="$delete_timeout"
  else
    kube delete "$kind" "$name" --wait=true --timeout="$delete_timeout"
  fi
  if get_json "$kind" "$ns" "$name" >/dev/null 2>&1; then
    die "delete returned success but object remains: $kind $ns/$name"
  fi
  log_event deleted "$kind" "$ns" "$name" "$uid" "verified-absent"
}

delete_plan() {
  local row kind ns name uid pv json volume vuid volume_ns volume_pvc attachments
  while IFS= read -r row; do
    delete_one configmap "$(jq -r '.namespace' <<<"$row")" "$(jq -r '.name' <<<"$row")" "$(jq -r '.uid' <<<"$row")"
  done < <(jq -c '.configMaps[]' "$manifest")

  while IFS= read -r row; do
    delete_one namespace '' "$(jq -r '.name' <<<"$row")" "$(jq -r '.uid' <<<"$row")" foreground
  done < <(jq -c '.namespaces[]' "$manifest")

  while IFS= read -r row; do
    pv="$(jq -r '.name' <<<"$row")"; uid="$(jq -r '.uid' <<<"$row")"
    if journal_has_deleted pv '' "$pv" "$uid"; then
      log_event already-deleted pv '' "$pv" "$uid" "journal-confirmed"
      continue
    fi
    json="$(wait_for_json pv '' "$pv" '.status.phase == "Released"')" || die "PV did not become Released: $pv"
    [[ "$(jq -r '.metadata.uid' <<<"$json")" == "$uid" ]] || die "PV UID changed while waiting: $pv"
    delete_one pv '' "$pv" "$uid"
  done < <(jq -c '.pvs[]' "$manifest")

  while IFS= read -r row; do
    pv="$(jq -r '.name' <<<"$row")"; volume="$(jq -r '.volumeName' <<<"$row")"; vuid="$(jq -r '.volumeUid' <<<"$row")"; volume_ns="$(jq -r '.volumeNamespace' <<<"$row")"; volume_pvc="$(jq -r '.volumePvcName' <<<"$row")"
    if journal_has_deleted volumes.longhorn.io "$volume_ns" "$volume" "$vuid"; then
      log_event already-deleted volumes.longhorn.io "$volume_ns" "$volume" "$vuid" "journal-confirmed"
      continue
    fi
    json="$(wait_for_json volumes.longhorn.io "$volume_ns" "$volume" '.status.state == "detached"')" || die "Longhorn volume did not become detached: $volume"
    [[ "$(jq -r '.metadata.uid' <<<"$json")" == "$vuid" ]] || die "Longhorn UID changed while waiting: $volume"
    [[ "$(jq -r '.status.kubernetesStatus.pvcName // ""' <<<"$json")" == "$volume_pvc" ]] || die "Longhorn claim changed while waiting: $volume"
    attachments="$(kube get volumeattachments.storage.k8s.io -o json 2>/dev/null || printf '{"items":[]}')"
    if jq -e --arg pv "$pv" 'any(.items[]?; .spec.source.persistentVolumeName == $pv)' <<<"$attachments" >/dev/null; then
      die "Longhorn volume still has a VolumeAttachment: $volume"
    fi
    delete_one volumes.longhorn.io "$volume_ns" "$volume" "$vuid"
  done < <(jq -c '.pvs[]' "$manifest")
}

[[ "$mode" == dry-run || "$mode" == apply ]] || die "invalid mode"
if [[ "$mode" == apply ]]; then
  [[ "${DR_CLEANUP_APPROVAL:-}" == "APPROVE:${run}:${manifest_sha}" ]] || die "approval token mismatch"
  if [[ -s "$journal" && "$resume" != true ]] && jq -e -s 'any(.[]; .action == "run-start")' "$journal" >/dev/null; then
    die "journal exists; use --resume after reviewing partial state"
  fi
  if [[ "$resume" == true ]] && ! jq -e -s --arg run "$run" --arg sha "$manifest_sha" \
    'any(.[]; .action == "run-start" and .run == $run and .detail == $sha)' "$journal" >/dev/null; then
    die "resume journal does not match this run and manifest"
  fi
  log_event run-start run '' '' '' "$manifest_sha"
fi

preflight_namespace
preflight_configmaps
preflight_storage
preflight_barman
preflight_preserved

if [[ "$mode" == dry-run ]]; then
  printf 'DR_CLEANUP=DRY_RUN\nRUN=%s\nMANIFEST_SHA256=%s\n' "$run" "$manifest_sha"
  exit 0
fi

delete_plan
preflight_preserved
printf 'DR_CLEANUP=PASS\nRUN=%s\n' "$run"
