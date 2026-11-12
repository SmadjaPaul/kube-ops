#!/usr/bin/env bash
# Bounded operator recovery: terminate an Argo CD sync operation that is stuck
# waiting on hooks/health, after proving that resuming reconciliation cannot
# prune protected data. Idempotent; never prints kubeconfig or secret values.
#
# Usage: argo-terminate-stuck-sync.sh APP [MIN_AGE_SECONDS] [--dry-run]
# Exit codes: 0 terminated or nothing to do, 2 access blocked,
#             3 precondition refused, 4 data-protection refusal, 5 verify failed.
set -euo pipefail

APP="${1:?usage: argo-terminate-stuck-sync.sh APP [MIN_AGE_SECONDS] [--dry-run]}"
MIN_AGE="${2:-600}"
DRY_RUN=no
for a in "$@"; do [[ "$a" == --dry-run ]] && DRY_RUN=yes; done
[[ "$MIN_AGE" =~ ^[0-9]+$ ]] || MIN_AGE=600
NS=argocd
K=(kubectl --request-timeout=20s)

cd "$(dirname "$0")/.."
# shellcheck source=lib/kube-preflight.sh
source scripts/lib/kube-preflight.sh
trap kube_access_cleanup EXIT
require_kube_access >/dev/null || exit 2

out() { printf '%s=%s\n' "$1" "$2"; }

# 1. Identity: the Application must exist in the Argo namespace of this cluster.
app_json="$("${K[@]}" -n "$NS" get application "$APP" -o json 2>/dev/null)" || {
  out RESULT REFUSED; out REASON application_not_found; exit 3; }
out APP "$APP"
out DESTINATION "$(jq -r '.spec.destination.server // .spec.destination.name' <<<"$app_json")"

# 2. Precondition: an operation is Running, and has been for at least MIN_AGE.
phase="$(jq -r '.status.operationState.phase // "None"' <<<"$app_json")"
started="$(jq -r '.status.operationState.startedAt // empty' <<<"$app_json")"
message="$(jq -r '.status.operationState.message // ""' <<<"$app_json")"
out OPERATION_PHASE "$phase"
if [[ "$phase" != Running ]]; then
  out RESULT NOTHING_TO_TERMINATE; exit 0
fi
age=$(( $(date -u +%s) - $(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$started" +%s 2>/dev/null || date -u -d "$started" +%s) ))
out OPERATION_AGE_SECONDS "$age"
out OPERATION_MESSAGE "$message"
if (( age < MIN_AGE )); then
  out RESULT REFUSED; out REASON operation_younger_than_min_age; exit 3
fi
if [[ "$message" != *waiting* ]]; then
  out RESULT REFUSED; out REASON operation_not_waiting_on_hooks_or_health; exit 3
fi

# 3. Data protection: once terminated, automated sync resumes and may prune.
#    Refuse if any resource Argo would prune is data-bearing and unprotected.
# CNPG Backup/ScheduledBackup CRs are metadata: deleting them never removes the
# object-store data, so they are not data-bearing here.
data_kinds='^(PersistentVolumeClaim|PersistentVolume|Cluster|ObjectStore|VolumeSnapshot|VolumeSnapshotContent|Namespace)$'
refusals=0
while IFS='|' read -r kind group ns name; do
  [[ -z "$kind" ]] && continue
  [[ "$kind" =~ $data_kinds ]] || continue
  ref="$kind${group:+.$group}/$name"
  nsflag=(); [[ -n "$ns" ]] && nsflag=(-n "$ns")
  opts="$("${K[@]}" "${nsflag[@]}" get "$ref" -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/sync-options}' 2>/dev/null || true)"
  if [[ "$opts" == *Prune=false* ]]; then
    out PRUNE_PROTECTED "$ref"; continue
  fi
  if [[ "$kind" == Namespace ]]; then
    pvcs="$("${K[@]}" -n "$name" get pvc -o name 2>/dev/null | wc -l | tr -d ' ')"
    cnpg="$("${K[@]}" -n "$name" get clusters.postgresql.cnpg.io -o name 2>/dev/null | wc -l | tr -d ' ')"
    if [[ "$pvcs" == 0 && "$cnpg" == 0 ]]; then
      out PRUNE_ALLOWED_EMPTY_NAMESPACE "$name"; continue
    fi
  fi
  out PRUNE_REFUSED "$ref${ns:+ ns=$ns}"
  refusals=$((refusals + 1))
done < <(jq -r '.status.resources[]? | select(.requiresPruning == true) | [.kind, (.group // ""), (.namespace // ""), .name] | join("|")' <<<"$app_json")
if (( refusals > 0 )); then
  out RESULT REFUSED; out REASON unprotected_data_resource_would_be_pruned; exit 4
fi

if [[ "$DRY_RUN" == yes ]]; then
  out RESULT DRY_RUN_WOULD_TERMINATE; exit 0
fi

# 4. Terminate via the official CLI (core mode, canonical kubeconfig), with the
#    equivalent status patch as fallback when the CLI is unavailable.
if command -v argocd >/dev/null 2>&1; then
  kubectl config set-context --current --namespace="$NS" >/dev/null
  argocd app terminate-op "$APP" --core >/dev/null
  out METHOD argocd_terminate_op_core
else
  "${K[@]}" -n "$NS" patch application "$APP" --type merge \
    -p '{"status":{"operationState":{"phase":"Terminating"}}}' >/dev/null
  out METHOD status_patch_terminating
fi

# 5. Verify: the stuck operation must leave Running/Terminating.
for _ in $(seq 1 30); do
  p="$("${K[@]}" -n "$NS" get application "$APP" -o jsonpath='{.status.operationState.phase}|{.status.operationState.startedAt}' 2>/dev/null || true)"
  if [[ "${p%%|*}" != Running && "${p%%|*}" != Terminating ]] || [[ "${p#*|}" != "$started" ]]; then
    break
  fi
  sleep 5
done
final="$("${K[@]}" -n "$NS" get application "$APP" -o json)"
out FINAL_OPERATION_PHASE "$(jq -r '.status.operationState.phase // "None"' <<<"$final")"
out FINAL_OPERATION_STARTED "$(jq -r '.status.operationState.startedAt // ""' <<<"$final")"
out SYNC_STATUS "$(jq -r '.status.sync.status' <<<"$final")"
out SYNC_REVISION "$(jq -r '.status.sync.revision' <<<"$final")"
out HEALTH "$(jq -r '.status.health.status' <<<"$final")"
if [[ "$(jq -r '.status.operationState.startedAt // ""' <<<"$final")" == "$started" && \
      "$(jq -r '.status.operationState.phase' <<<"$final")" =~ ^(Running|Terminating)$ ]]; then
  out RESULT VERIFY_FAILED; exit 5
fi
out RESULT TERMINATED
