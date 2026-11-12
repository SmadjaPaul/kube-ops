#!/usr/bin/env bash
set -euo pipefail
app=${1:?usage: status-app.sh APP [summary|errors|full]}
for cmd in kubectl jq; do command -v "$cmd" >/dev/null || { echo "ERROR: $cmd required" >&2; exit 2; }; done
source "$(dirname "$0")/lib/output-mode.sh"
mode="$(resolve_output_mode "${2:-}")"
source "$(dirname "$0")/lib/kube-preflight.sh"
if [[ "$mode" == full ]]; then require_kube_access; else require_kube_access >/dev/null; fi
source "$(dirname "$0")/lib/argo-app.sh"
resolved="$(resolve_argo_app "$app")"

full_json="$(kubectl -n argocd get application.argoproj.io "$resolved" -o json | jq '{
  application:.metadata.name,
  project:.spec.project,
  source:{repo:.spec.source.repoURL,revision:.spec.source.targetRevision,path:.spec.source.path},
  sync:.status.sync.status,
  health:.status.health.status,
  reconciledRevision:.status.sync.revision,
  targetRevision:.spec.source.targetRevision,
  operationRevision:.status.operationState.operation.sync.revision,
  operationPhase:.status.operationState.phase,
  operationMessage:.status.operationState.message,
  conditions:(.status.conditions // []),
  resources:[.status.resources[]? | {group,kind,namespace,name,status,health}]
}')"

if [[ "$mode" == full ]]; then
  printf '%s\n' "$full_json"
  exit 0
fi

errors_json="$(jq '{
  application,sync,health,operationPhase,operationMessage,conditions,
  resources:[.resources[] | select((.status != null and .status != "Synced") or (.health.status != null and .health.status != "Healthy"))]
}' <<<"$full_json")"

if [[ "$mode" == errors ]]; then
  printf '%s\n' "$errors_json"
  exit 0
fi

# summary
evidence="$(evidence_file "status-$resolved")"
printf '%s\n' "$full_json" >"$evidence"
sync="$(jq -r '.sync // "Unknown"' <<<"$full_json")"
health="$(jq -r '.health // "Unknown"' <<<"$full_json")"
rev="$(jq -r '(.reconciledRevision // "none")[0:7]' <<<"$full_json")"
ready=0; total=0
while IFS= read -r ns; do
  [[ -z "$ns" ]] && continue
  counts="$(kubectl get pods -n "$ns" -o json 2>/dev/null | jq -r '[.items[] | select(.status.phase != "Succeeded")] | "\(map(select(any(.status.conditions[]?; .type=="Ready" and .status=="True"))) | length) \(length)"' 2>/dev/null || echo "0 0")"
  ready=$((ready + ${counts%% *})); total=$((total + ${counts##* }))
done < <(jq -r '[.resources[].namespace // empty] | unique | .[]' <<<"$full_json")
last_error="$(jq -r '
  ([.conditions[]? | select(.message) | .message][0])
  // (if (.operationPhase // "Succeeded") != "Succeeded" then .operationMessage else null end)
  // "none"' <<<"$full_json" | sanitize_line)"
verify=FAIL
[[ "$sync" == Synced && "$health" == Healthy && "$ready" -eq "$total" ]] && verify=PASS
echo "ARGO=$sync/$health"
echo "REVISION=$rev"
echo "PODS=$ready/$total"
echo "LAST_ERROR=$last_error"
echo "VERIFY=$verify"
echo "EVIDENCE=$evidence"
