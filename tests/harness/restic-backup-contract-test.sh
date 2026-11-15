#!/usr/bin/env bash
# PLT-286: contract of the restic CronJobs (Immich, Paperless).
# Static: rendered manifests (read-only sources, memory-only scratch, order,
# tags, secrets from ESO only). Behaviour: the scripts against a stub restic
# (no network, no secret, synthetic files).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
component="$repo_root/k8s/components/restic-backup"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/restic-backup-harness.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

fail() {
  printf 'ASSERTION_FAILED %s\n' "$1" >&2
  exit 1
}

# --- Static contract on the rendered manifests ------------------------------
for spec in immich:media/immich paperless:catalog/paperless; do
  app="${spec%%:*}"
  out="$tmp/$app.yaml"
  kustomize build "$repo_root/k8s/applications/${spec#*:}/restic-backup" >"$out"

  [[ "$(yq -N 'select(.kind == "Secret") | .metadata.name' "$out")" == "" ]] || fail "$app: Secret committed in Git"
  [[ "$(yq -N 'select(.kind == "ExternalSecret") | .spec.secretStoreRef.name' "$out")" == doppler-cluster ]] || fail "$app: ExternalSecret store"
  for key in RESTIC_BACKUP_PASSWORD R2_RESTIC_WRITER_ACCESS_KEY_ID R2_RESTIC_WRITER_SECRET_ACCESS_KEY R2_S3_ENDPOINT; do
    yq -e -N "select(.kind == \"ExternalSecret\") | .spec.data[] | select(.remoteRef.key == \"$key\")" "$out" >/dev/null || fail "$app: missing Doppler key $key"
  done
  [[ "$(yq -N 'select(.kind == "ExternalSecret") | .spec.target.template.data.RESTIC_REPOSITORY' "$out")" == *"/homelab-backup-restic/$app" ]] || fail "$app: repository must be homelab-backup-restic/$app"

  for cj in "$app-restic-backup" "$app-restic-maintenance"; do
    doc="$tmp/$cj.yaml"
    yq -N "select(.kind == \"CronJob\" and .metadata.name == \"$cj\")" "$out" >"$doc"
    [[ -s "$doc" ]] || fail "$app: missing CronJob $cj"
    [[ "$(yq '.spec.concurrencyPolicy' "$doc")" == Forbid ]] || fail "$cj: concurrencyPolicy"
    pod='.spec.jobTemplate.spec.template.spec'
    containers="$pod | [(.initContainers // [])[], .containers[]]"
    # Every PVC volume and every mount of it is read-only.
    [[ "$(yq "[$pod.volumes[] | select(.persistentVolumeClaim != null and .persistentVolumeClaim.readOnly != true)] | length" "$doc")" == 0 ]] || fail "$cj: PVC volume not read-only"
    for vol in $(yq "$pod.volumes[] | select(.persistentVolumeClaim != null) | .name" "$doc"); do
      [[ "$(yq "[$containers | .[].volumeMounts[] | select(.name == \"$vol\" and .readOnly != true)] | length" "$doc")" == 0 ]] || fail "$cj: mount of $vol not read-only"
    done
    # No disk write: every emptyDir is memory-backed and bounded.
    [[ "$(yq "[$pod.volumes[] | select(.emptyDir != null and (.emptyDir.medium != \"Memory\" or .emptyDir.sizeLimit == null))] | length" "$doc")" == 0 ]] || fail "$cj: emptyDir must be Memory with sizeLimit"
    [[ "$(yq "[$containers | .[] | select(.securityContext.readOnlyRootFilesystem != true or .resources.limits.memory == null)] | length" "$doc")" == 0 ]] || fail "$cj: container hardening or limits"
    [[ "$(yq "$pod.automountServiceAccountToken" "$doc")" == false ]] || fail "$cj: service account token mounted"
  done

  doc="$tmp/$app-restic-backup.yaml"
  pod='.spec.jobTemplate.spec.template.spec'
  [[ "$(yq "[$pod.initContainers[].name] | join(\",\")" "$doc")" == "restic-binary,postgres-dump" ]] || fail "$app: dump must run as the last init container"
  [[ "$(yq "[$pod.containers[].name] | join(\",\")" "$doc")" == files ]] || fail "$app: files must run after the dump"
  [[ "$(yq "$pod.initContainers[1].command | join(\" \")" "$doc")" == "/bin/bash /scripts/backup-db.sh" ]] || fail "$app: dump command"
  [[ "$(yq "$pod.containers[0].command | join(\" \")" "$doc")" == "/bin/sh /scripts/backup-files.sh" ]] || fail "$app: files command"
  [[ "$(yq "[$pod.initContainers[1].env[], $pod.containers[0].env[]] | [.[] | select(.name == \"APP\") | .value] | unique | join(\",\")" "$doc")" == "$app" ]] || fail "$app: APP drives the tags $app-postgres and $app-files"
  [[ "$(yq -N 'select(.kind == "CiliumNetworkPolicy") | .spec.endpointSelector.matchLabels."app.kubernetes.io/name"' "$out")" == restic-backup ]] || fail "$app: network policy selector"
done

grep -q -- '--stdin-from-command' "$component/backup-db.sh" || fail "dump must use --stdin-from-command"
if grep -En '^[^#]*pg_dump[^#]*\|' "$component"/*.sh | grep -q .; then
  fail "pg_dump piped into restic is forbidden"
fi
# shellcheck disable=SC2016 # literal pattern
if grep -En '^[^#]*(set -x|\benv\b *$|printenv|echo .*\$(RESTIC_PASSWORD|AWS_SECRET))' "$component"/*.sh | grep -q .; then
  fail "a script could print a secret"
fi

# --- Behaviour against a stub restic ----------------------------------------
bin="$tmp/bin"
mkdir -p "$bin"
# macOS developer machines: use GNU tools when the system ones differ.
for tool in stat sha256sum shuf; do
  if command -v "g$tool" >/dev/null 2>&1; then ln -s "$(command -v "g$tool")" "$bin/$tool"; fi
done
cat >"$bin/restic" <<'STUB'
#!/usr/bin/env bash
# Stub restic: snapshots are directories under $STUB_REPO/snap/<n>.
set -euo pipefail
repo="$STUB_REPO"
printf '%s\n' "$*" >>"$repo/calls.log"
sub="$1"; shift
latest() { # latest snapshot dir with the tag
  local tag="$1" d best=""
  for d in "$repo"/snap/*; do [ -f "$d/tags" ] && grep -qx "$tag" "$d/tags" && best="$d"; done
  [ -n "$best" ] && printf '%s\n' "$best"
}
case "$sub" in
  cat) [ -f "$repo/config" ] && exit 0; [ -n "${STUB_WRONG_PASSWORD:-}" ] && exit 12; exit 10 ;;
  init) [ -f "$repo/config" ] && exit 1; mkdir -p "$repo/snap"; touch "$repo/config" ;;
  backup)
    tag="" stdin_name="" cmd=() paths=()
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --tag) tag="$2"; shift 2 ;;
        --stdin-filename) stdin_name="$2"; shift 2 ;;
        --host | --retry-lock | --read-concurrency | --exclude) shift 2 ;;
        --stdin-from-command) shift ;;
        --) shift; cmd=("$@"); break ;;
        *) paths+=("$1"); shift ;;
      esac
    done
    n="$(find "$repo/snap" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"
    snap="$repo/snap/$((n + 1))"
    mkdir -p "$snap/root"
    if [ "${#cmd[@]}" -gt 0 ]; then
      if ! "${cmd[@]}" >"$snap/root/$stdin_name"; then rm -rf "$snap"; exit 1; fi
    else
      for p in "${paths[@]}"; do mkdir -p "$snap/root$(dirname "$p")"; cp -R "$p" "$snap/root$p"; done
    fi
    printf '%s\n' "$tag" >"$snap/tags"
    ;;
  dump)
    tag=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --tag) tag="$2"; shift 2 ;;
        --host) shift 2 ;;
        latest) path="$2"; break ;;
        *) shift ;;
      esac
    done
    snap="$(latest "$tag")" || exit 1
    cat "$snap/root$path"
    ;;
  forget | prune | check) : ;;
  *) exit 2 ;;
esac
STUB
cat >"$bin/pg_dump" <<'STUB'
#!/usr/bin/env sh
[ -n "${STUB_PG_FAIL:-}" ] && { echo 'pg_dump: synthetic failure' >&2; exit 1; }
printf 'PGDMP synthetic custom dump\n'
STUB
cat >"$bin/pg_restore" <<'STUB'
#!/usr/bin/env sh
grep -q '^PGDMP' || exit 1
STUB
chmod +x "$bin"/restic "$bin"/pg_dump "$bin"/pg_restore

export PATH="$bin:$PATH" SCRIPTS_DIR="$component" APP=immich RESTIC_HOST=immich-restic
export STUB_REPO="$tmp/repo" SOURCE_ROOT="$tmp/root" MANIFEST_DIR="$tmp/manifest" WORK_DIR="$tmp/work"
mkdir -p "$STUB_REPO" "$SOURCE_ROOT/source/immich/library/2026" "$SOURCE_ROOT/source/immich/thumbs"
export SOURCES="$SOURCE_ROOT/source/immich" EXCLUDES="$SOURCE_ROOT/source/immich/thumbs"
printf 'photo one\n' >"$SOURCE_ROOT/source/immich/library/2026/a.jpg"
printf 'photo two\n' >"$SOURCE_ROOT/source/immich/library/2026/b c.jpg"
printf 'thumb\n' >"$SOURCE_ROOT/source/immich/thumbs/a.webp"

# Wrong password: no init, the job fails.
if STUB_WRONG_PASSWORD=1 bash "$component/backup-db.sh" >/dev/null 2>&1; then fail "wrong password must fail"; fi
[[ ! -f "$STUB_REPO/config" ]] || fail "wrong password must not initialise"

# Failed dump: repository initialised, no snapshot.
if STUB_PG_FAIL=1 bash "$component/backup-db.sh" >/dev/null 2>&1; then fail "failed dump must fail the step"; fi
[[ "$(find "$STUB_REPO/snap" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" == 0 ]] || fail "failed dump created a snapshot"

# Full cycle.
bash "$component/backup-db.sh" >/dev/null
sh "$component/backup-files.sh" >"$tmp/files1.log"
grep -q 'files=2 hashed=2' "$tmp/files1.log" || fail "first manifest must hash the 2 non-excluded files"
(cd "$SOURCE_ROOT" && sha256sum -c --status "$MANIFEST_DIR/SHA256SUMS") || fail "manifest does not verify"
grep -q 'thumbs' "$MANIFEST_DIR/SHA256SUMS" && fail "excluded path in manifest"
grep -q -- '--exclude '"$SOURCE_ROOT"'/source/immich/thumbs' "$STUB_REPO/calls.log" || fail "exclude not passed to restic"

# Incremental: only the changed file is hashed again.
sleep 1
printf 'photo one, edited\n' >"$SOURCE_ROOT/source/immich/library/2026/a.jpg"
sh "$component/backup-files.sh" >"$tmp/files2.log"
grep -q 'files=2 hashed=1' "$tmp/files2.log" || fail "incremental manifest must hash only the changed file"
(cd "$SOURCE_ROOT" && sha256sum -c --status "$MANIFEST_DIR/SHA256SUMS") || fail "incremental manifest does not verify"

# Maintenance: retention, check, dry restore.
bash "$component/maintenance.sh" >"$tmp/maint.log"
grep -q 'tag=immich-postgres PASS' "$tmp/maint.log" || fail "dump dry restore"
grep -q 'tag=immich-files PASS sampled=2 total=2' "$tmp/maint.log" || fail "files dry restore"
grep -q '^forget .*--group-by host,tags --keep-daily 7 --keep-weekly 5 --keep-monthly 12' "$STUB_REPO/calls.log" || fail "retention policy"
grep -q '^check --read-data-subset 5%' "$STUB_REPO/calls.log" || fail "check subset"

# Tampered snapshot: the dry restore fails.
last="$(find "$STUB_REPO/snap" -mindepth 1 -maxdepth 1 -exec basename {} \; | sort -n | tail -1)"
printf 'tampered\n' >"$STUB_REPO/snap/$last/root$SOURCE_ROOT/source/immich/library/2026/b c.jpg"
if bash "$component/maintenance.sh" >/dev/null 2>&1; then fail "tampered file must fail the dry restore"; fi

printf '%s\n' 'RESTIC_BACKUP_CONTRACT_TEST=PASS'
