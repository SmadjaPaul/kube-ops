#!/usr/bin/env bash
# Bounded cleanup (PLT-94/PLT-250): exactly five Released Longhorn PVs that Paul
# declared abandoned on 2026-11-13 (PLT-94 comment). Each PV is pinned by name AND
# UID; a recreated object with the same name is refused.
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
)

# shellcheck source=lib/kube-preflight.sh
source "$(dirname "$0")/lib/kube-preflight.sh"
require_kube_access >/dev/null
trap 'kube_access_cleanup' EXIT

bound_volumes="$(kubectl --request-timeout=30s get pvc -A -o json | jq -r '.items[].spec.volumeName // empty')"
fail=0
for t in "${TARGETS[@]}"; do
  read -r name uid claim <<<"$t"
  if ! pv="$(kubectl --request-timeout=15s get pv "$name" -o json 2>/dev/null)"; then
    echo "PV $name ABSENT (déjà supprimé)"; continue
  fi
  reasons=()
  [[ "$(jq -r .metadata.uid <<<"$pv")" == "$uid" ]] || reasons+=("uid différent")
  [[ "$(jq -r .status.phase <<<"$pv")" == Released ]] || reasons+=("phase non Released")
  [[ "$(jq -r .spec.persistentVolumeReclaimPolicy <<<"$pv")" == Retain ]] || reasons+=("reclaimPolicy non Retain")
  [[ "$(jq -r '.spec.csi.driver // ""' <<<"$pv")" == driver.longhorn.io ]] || reasons+=("driver non Longhorn")
  [[ "$(jq -r '.spec.claimRef.namespace + "/" + .spec.claimRef.name' <<<"$pv")" == "$claim" ]] || reasons+=("claimRef inattendu")
  grep -qxF "$name" <<<"$bound_volumes" && reasons+=("un PVC référence ce PV")
  lh="$(kubectl --request-timeout=15s -n longhorn-system get volumes.longhorn.io "$name" -o json 2>/dev/null || echo '{}')"
  lh_state="$(jq -r '.status.state // "absent"' <<<"$lh")"
  [[ "$lh_state" == detached || "$lh_state" == absent ]] || reasons+=("volume Longhorn $lh_state")
  if (( ${#reasons[@]} )); then
    echo "PV $name BLOCKED: ${reasons[*]}"; fail=1; continue
  fi
  echo "PV $name ELIGIBLE claim=$claim longhorn=$lh_state"
  [[ "$mode" == delete ]] || continue
  kubectl --request-timeout=30s delete pv "$name" --wait=true --timeout=120s
  if [[ "$lh_state" == detached ]]; then
    kubectl --request-timeout=30s -n longhorn-system delete volumes.longhorn.io "$name" --wait=false
  fi
  echo "PV $name DELETED"
done
if (( fail )); then echo "PV_CLEANUP=PARTIAL"; exit 3; fi
echo "PV_CLEANUP=$([[ $mode == delete ]] && echo DONE || echo INSPECT_PASS)"
