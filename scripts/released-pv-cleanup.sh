#!/usr/bin/env bash
# Bounded cleanup (PLT-94/PLT-250): exactly eight Longhorn PVs that Paul declared
# abandoned on 2026-11-13 (PLT-94 comment, then chat: Atlantis retired, executor
# abandoned). Each PVC/PV is pinned by name AND UID; a recreated object with the
# same name is refused. Phase 1 releases three Bound PVCs (atlantis-pilot-data,
# atlantis-apps-data, data-executor-0) when no pod mounts them; Argo may recreate
# the two retention PVCs empty, bound to new PVs. rustical-data is out of scope.
# Default read-only (inspect). Deletion requires --execute and
# ALLOW_RELEASED_PV_DELETION=yes. For each PV, at execution time:
#   - phase Released, reclaimPolicy Retain, driver driver.longhorn.io;
#   - no PVC in the cluster has spec.volumeName == this PV;
#   - Longhorn volume detached, no attachment ticket;
# then deletes the PV, waits for it to disappear, and deletes the Longhorn volume.
set -euo pipefail
mode=inspect
case "${1:-}" in
  "") ;;
  --execute) mode=delete ;;
  --help|-h) echo "Usage: ALLOW_RELEASED_PV_DELETION=yes bash scripts/released-pv-cleanup.sh --execute"; exit 0 ;;
  *) echo "PV_CLEANUP=BLOCKED invalid argument" >&2; exit 2 ;;
esac
(( $# <= 1 )) || { echo "PV_CLEANUP=BLOCKED too many arguments" >&2; exit 2; }
if [[ "$mode" == delete && "${ALLOW_RELEASED_PV_DELETION:-}" != yes ]]; then
  echo "PV_CLEANUP=BLOCKED approval guard missing" >&2
  exit 2
fi
for cmd in kubectl jq; do
  command -v "$cmd" >/dev/null || { echo "MISSING=$cmd" >&2; exit 2; }
done

# name uid former-claim
TARGETS=(
  "pvc-347aff51-c65a-4cac-a73d-c4a6d95be820 924a320e-70fe-4837-aaf2-a8164d8cb761 wellness/sparkyfitness-db-1"
  "pvc-994f98ea-4974-47e0-a83e-ba285a295e0b 8df0bdff-4b35-4e4f-bc4e-e633f92356f3 auth/authentik-postgresql-restored-1"
  "pvc-af862e58-67ba-4260-b20d-ac931c20d6cb 9a5e962f-221a-4679-ab53-493e283ac621 auth/authentik-postgresql-restored-1-wal"
  "pvc-3d1c5946-3690-4285-92fd-fb877722c03d 6ebb2888-4745-45a5-ab3f-bf7166eadfcd authentik-drill/authentik-postgresql-restore-1"
  "pvc-e51c05dd-42a7-4093-ac00-5391fcaf2b9d aad393a4-a045-4a3a-adcd-965b0affae81 vikunja-drill/vikunja-postgresql-restore-1"
  "pvc-24ed83e6-2ac2-486f-8f6a-37ea3d064731 8b1e05af-7ec5-4758-803f-f3be14c6ce3a atlantis-system/atlantis-pilot-data"
  "pvc-3a789334-6113-459f-92de-9bc541dfac55 d2a9ecac-fa82-41b2-accf-73c73708b631 atlantis-apps/atlantis-apps-data"
  "pvc-dee0d6ef-edab-493b-bb94-56a2c98c9716 11a9d2b2-5a46-43ff-acb2-600da4992557 executor/data-executor-0"
)

# Phase 1 — PVC still Bound: namespace name pvc-uid pv
RELEASE=(
  "atlantis-system atlantis-pilot-data 24ed83e6-2ac2-486f-8f6a-37ea3d064731 pvc-24ed83e6-2ac2-486f-8f6a-37ea3d064731"
  "atlantis-apps atlantis-apps-data 3a789334-6113-459f-92de-9bc541dfac55 pvc-3a789334-6113-459f-92de-9bc541dfac55"
  "executor data-executor-0 dee0d6ef-edab-493b-bb94-56a2c98c9716 pvc-dee0d6ef-edab-493b-bb94-56a2c98c9716"
)

# shellcheck source=lib/kube-preflight.sh
source "$(dirname "$0")/lib/kube-preflight.sh"
require_kube_access >/dev/null
trap 'kube_access_cleanup' EXIT

# get_json KIND NAME [ns] -> prints JSON; exit 0 found, 4 NotFound, 5 other error
get_json() {
  local out err
  err=$(mktemp)
  if out=$(kubectl --request-timeout=15s get "$@" -o json 2>"$err"); then rm -f "$err"; printf '%s' "$out"; return 0; fi
  if grep -q '(NotFound)' "$err"; then rm -f "$err"; return 4; fi
  sed 's/^/  /' "$err" >&2; rm -f "$err"; return 5
}

# lh_check NAME -> echo "detached" | "absent", or exit non-zero with a reason on stderr
lh_check() {
  local lh rc state tickets
  lh=$(get_json volumes.longhorn.io "$1" -n longhorn-system); rc=$?
  if (( rc == 4 )); then echo absent; return 0; fi
  (( rc == 0 )) || { echo "lecture volume Longhorn impossible" >&2; return 1; }
  state=$(jq -r '.status.state // ""' <<<"$lh")
  [[ "$state" == detached ]] || { echo "volume Longhorn '${state:-sans état}'" >&2; return 1; }
  va=$(get_json volumeattachments.longhorn.io "$1" -n longhorn-system); rc=$?
  if (( rc == 0 )); then
    tickets=$(jq -r '(.spec.attachmentTickets // {}) | length' <<<"$va")
    [[ "$tickets" == 0 ]] || { echo "$tickets ticket(s) d'attachement Longhorn" >&2; return 1; }
  elif (( rc != 4 )); then
    echo "lecture des tickets d'attachement impossible" >&2; return 1
  fi
  echo detached
}

# delete_with_preconditions PATH UID RESOURCE_VERSION
delete_with_preconditions() {
  local body
  body=$(mktemp)
  printf '{"kind":"DeleteOptions","apiVersion":"v1","preconditions":{"uid":"%s","resourceVersion":"%s"}}' "$2" "$3" >"$body"
  kubectl --request-timeout=30s delete --raw "$1" -f "$body" >/dev/null
  local rc=$?; rm -f "$body"; return $rc
}

# expected PV UID and former claim, from TARGETS
pv_uid() { local t n u c; for t in "${TARGETS[@]}"; do read -r n u c <<<"$t"; [[ "$n" == "$1" ]] && { echo "$u"; return; }; done; }
pv_claim() { local t n u c; for t in "${TARGETS[@]}"; do read -r n u c <<<"$t"; [[ "$n" == "$1" ]] && { echo "$c"; return; }; done; }

# pv_static_reasons PV_JSON UID CLAIM -> one reason per line (identity, Retain, driver, claimRef)
pv_static_reasons() {
  [[ "$(jq -r .metadata.uid <<<"$1")" == "$2" ]] || echo "uid différent"
  [[ "$(jq -r .spec.persistentVolumeReclaimPolicy <<<"$1")" == Retain ]] || echo "reclaimPolicy non Retain"
  [[ "$(jq -r '.spec.csi.driver // ""' <<<"$1")" == driver.longhorn.io ]] || echo "driver non Longhorn"
  [[ "$(jq -r '.spec.claimRef.namespace + "/" + .spec.claimRef.name' <<<"$1")" == "$3" ]] || echo "claimRef inattendu"
}

# pvc_refs PV -> "ns/name" of every PVC whose spec.volumeName is PV; non-zero on read error
pvc_refs() {
  local all
  all=$(kubectl --request-timeout=30s get pvc -A -o json) || return 1
  jq -r --arg pv "$1" '.items[] | select(.spec.volumeName == $pv) | .metadata.namespace + "/" + .metadata.name' <<<"$all"
}

# lh_reasons PV -> sets globals lh_state (detached|absent) and lh_why (blocking reason, empty if none)
lh_state=""
lh_why=""
lh_reasons() {
  local err rc
  err=$(mktemp)
  set +e
  lh_state=$(lh_check "$1" 2>"$err"); rc=$?
  set -e
  lh_why=""
  (( rc == 0 )) || lh_why=$(cat "$err")
  rm -f "$err"
}

fail=0
pending_release=" "
for r in "${RELEASE[@]}"; do
  read -r rns rname ruid rpv <<<"$r"
  set +e
  pvc=$(get_json pvc "$rname" -n "$rns"); rc=$?
  set -e
  if (( rc == 4 )); then echo "PVC $rns/$rname ABSENT"; continue; fi
  (( rc == 0 )) || { echo "PVC $rns/$rname BLOCKED: lecture impossible"; fail=1; continue; }
  if [[ "$(jq -r .metadata.uid <<<"$pvc")" != "$ruid" ]]; then
    # Recréé par Argo (rétention) : l'ancien PV est déjà libéré, rien à faire ici.
    echo "PVC $rns/$rname recréé (uid différent), ancien PV traité en phase 2"; continue
  fi
  reasons=()
  [[ "$(jq -r '.spec.volumeName // ""' <<<"$pvc")" == "$rpv" ]] || reasons+=("volumeName inattendu")
  if users=$(kubectl --request-timeout=30s get pods -n "$rns" -o json |
    jq -r --arg c "$rname" '[.items[] | select(any(.spec.volumes[]?; .persistentVolumeClaim.claimName == $c)) | .metadata.name] | join(",")'); then
    [[ -z "$users" ]] || reasons+=("monté par $users")
  else
    reasons+=("lecture des pods impossible")
  fi
  # Le PV doit être validé AVANT de supprimer le PVC (un PV Delete serait récupéré aussitôt).
  set +e
  pv=$(get_json pv "$rpv"); rc=$?
  set -e
  if (( rc == 0 )); then
    while IFS= read -r why; do [[ -n "$why" ]] && reasons+=("PV : $why"); done < <(pv_static_reasons "$pv" "$(pv_uid "$rpv")" "$rns/$rname")
    [[ "$(jq -r .status.phase <<<"$pv")" == Bound ]] || reasons+=("PV non Bound")
  else
    reasons+=("lecture du PV impossible")
  fi
  lh_reasons "$rpv"; why=$lh_why; [[ -z "$why" ]] || reasons+=("$why")
  if (( ${#reasons[@]} )); then echo "PVC $rns/$rname BLOCKED: ${reasons[*]}"; fail=1; continue; fi
  echo "PVC $rns/$rname ELIGIBLE (libère $rpv)"
  if [[ "$mode" != delete ]]; then pending_release+="$rpv "; continue; fi
  delete_with_preconditions "/api/v1/namespaces/$rns/persistentvolumeclaims/$rname" "$ruid" \
    "$(jq -r .metadata.resourceVersion <<<"$pvc")"
  phase=""
  for _ in $(seq 1 24); do
    phase=$(kubectl --request-timeout=15s get pv "$rpv" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    [[ "$phase" == Released ]] && break
    sleep 5
  done
  echo "PVC $rns/$rname DELETED, PV $rpv phase=${phase:-?}"
done

for t in "${TARGETS[@]}"; do
  read -r name uid claim <<<"$t"
  set +e
  pv=$(get_json pv "$name"); rc=$?
  set -e
  if (( rc == 4 )); then
    # PV déjà supprimé : reprise d'une exécution interrompue, volume Longhorn éventuel.
    lh_reasons "$name"; why=$lh_why
    if [[ -n "$why" ]]; then echo "PV $name ABSENT, volume Longhorn BLOCKED: $why"; fail=1; continue; fi
    if [[ "$lh_state" == absent ]]; then echo "PV $name ABSENT, volume Longhorn absent"; continue; fi
    if ! refs=$(pvc_refs "$name"); then echo "PV $name ABSENT, lecture des PVC impossible"; fail=1; continue; fi
    if [[ -n "$refs" ]]; then echo "PV $name ABSENT, volume Longhorn BLOCKED: référencé par $refs"; fail=1; continue; fi
    echo "PV $name ABSENT, volume Longhorn detached restant"
    if [[ "$mode" == delete ]]; then
      kubectl --request-timeout=30s -n longhorn-system delete volumes.longhorn.io "$name" --wait=false
      echo "LONGHORN $name DELETED"
    else
      fail=1
    fi
    continue
  elif (( rc != 0 )); then
    echo "PV $name BLOCKED: lecture impossible"; fail=1; continue
  fi
  reasons=()
  while IFS= read -r why; do [[ -n "$why" ]] && reasons+=("$why"); done < <(pv_static_reasons "$pv" "$uid" "$claim")
  lh_reasons "$name"; why=$lh_why; [[ -z "$why" ]] || reasons+=("$why")
  pending=0
  [[ "$pending_release" == *" $name "* ]] && pending=1
  if (( ! pending )); then
    # Phase et références PVC : différées seulement pour un PV dont le PVC sera libéré en phase 1.
    [[ "$(jq -r .status.phase <<<"$pv")" == Released ]] || reasons+=("phase non Released")
    if refs=$(pvc_refs "$name"); then
      [[ -z "$refs" ]] || reasons+=("référencé par $refs")
    else
      reasons+=("lecture des PVC impossible")
    fi
  fi
  if (( ${#reasons[@]} )); then
    echo "PV $name BLOCKED: ${reasons[*]}"; fail=1; continue
  fi
  if (( pending )); then echo "PV $name ELIGIBLE après libération du PVC (inspection)"; continue; fi
  echo "PV $name ELIGIBLE claim=$claim longhorn=$lh_state"
  [[ "$mode" == delete ]] || continue
  rv=$(jq -r .metadata.resourceVersion <<<"$pv")
  delete_with_preconditions "/api/v1/persistentvolumes/$name" "$uid" "$rv"
  if ! kubectl --request-timeout=130s wait --for=delete "pv/$name" --timeout=120s >/dev/null; then
    echo "PV $name INCOMPLETE: toujours présent après 120 s, volume Longhorn conservé"; fail=1; continue
  fi
  if [[ "$lh_state" == detached ]]; then
    lh_reasons "$name"; why=$lh_why
    if [[ -n "$why" ]]; then echo "PV $name DELETED, volume Longhorn BLOCKED: $why"; fail=1; continue; fi
    if [[ "$lh_state" == detached ]]; then
      kubectl --request-timeout=30s -n longhorn-system delete volumes.longhorn.io "$name" --wait=false
    fi
  fi
  echo "PV $name DELETED"
done
if (( fail )); then echo "PV_CLEANUP=PARTIAL"; exit 3; fi
echo "PV_CLEANUP=$([[ $mode == delete ]] && echo DONE || echo INSPECT_PASS)"
