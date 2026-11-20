#!/usr/bin/env bash
# Argo Application plus namespace workload/event evidence (summary|errors|full).
# Read-only, through kubectl-ro.sh.
set -euo pipefail
app=${1:?usage: diagnose-app.sh APP [summary|errors|full]}
command -v jq >/dev/null || { echo "ERROR: jq required" >&2; exit 2; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/output-mode.sh
source "$HERE/lib/output-mode.sh"
# shellcheck source=lib/kube-read.sh
source "$HERE/lib/kube-read.sh"
# shellcheck source=lib/argo-app.sh
source "$HERE/lib/argo-app.sh"
mode="$(resolve_output_mode "${2:-}")"
resolved="$(resolve_argo_app "$app")"
obj="$(kro get application.argoproj.io "$resolved" -n argocd -o json)"

# ns_listing NS: workload listing and warning events of one namespace.
ns_listing() {
  local ns=$1
  echo "=== NAMESPACE $ns ==="
  kro get pods,pvc,httproute.gateway.networking.k8s.io,externalsecret.external-secrets.io -n "$ns" -o wide 2>/dev/null || true
  kro get clusters.postgresql.cnpg.io -n "$ns" 2>/dev/null || true
  echo "--- warning events ---"
  kro get events -n "$ns" --field-selector type=Warning --sort-by=.lastTimestamp 2>/dev/null | tail -30 || true
}

if [[ "$mode" != full ]]; then
  sync="$(jq -r '.status.sync.status // "Unknown"' <<<"$obj")"
  health="$(jq -r '.status.health.status // "Unknown"' <<<"$obj")"
  rev="$(jq -r '(.status.sync.revision // "none")[0:7]' <<<"$obj")"
  evidence="$(evidence_file "diagnose-$resolved")"
  ready=0; total=0; warnings=0; last_error="$(jq -r '([.status.conditions[]? | select(.message) | .message][0]) // (if (.status.operationState.phase // "Succeeded") != "Succeeded" then .status.operationState.message else null end) // "none"' <<<"$obj" | sanitize_line)"
  errs=""
  while IFS= read -r ns; do
    [[ -z "$ns" ]] && continue
    ns_listing "$ns" >>"$evidence"
    pods_json="$(kro get pods -n "$ns" -o json 2>/dev/null || true)"
    counts="$(jq -r '[.items[] | select(.status.phase != "Succeeded")] | "\(map(select(any(.status.conditions[]?; .type=="Ready" and .status=="True"))) | length) \(length)"' <<<"$pods_json" 2>/dev/null || echo "0 0")"
    ready=$((ready + ${counts%% *})); total=$((total + ${counts##* }))
    bad="$(jq -r '.items[] | select(.status.phase != "Succeeded" and (any(.status.conditions[]?; .type=="Ready" and .status=="True") | not)) | "pod/\(.metadata.name) \(.status.phase)"' <<<"$pods_json" 2>/dev/null || true)"
    [[ -n "$bad" ]] && errs+="$ns: $bad"$'\n'
    ev="$(kro get events -n "$ns" --field-selector type=Warning --sort-by=.lastTimestamp 2>/dev/null | tail -5 || true)"
    if [[ "$(wc -l <<<"$ev")" -gt 1 ]]; then
      warnings=$((warnings + 1))
      [[ "$last_error" == none ]] && last_error="$(tail -1 <<<"$ev" | sanitize_line)"
      errs+="--- $ns warning events ---"$'\n'"$ev"$'\n'
    fi
  done < <(jq -r '[.status.resources[]?.namespace // empty] | unique | .[]' <<<"$obj")
  if [[ "$mode" == errors ]]; then
    jq '{name:.metadata.name,sync:.status.sync.status,health:.status.health.status,conditions:(.status.conditions//[])}' <<<"$obj" | sanitize_line_block 2>/dev/null || true
    printf '%s' "$errs" | sanitize_line_block 2>/dev/null || true
    echo "EVIDENCE=$evidence"
    exit 0
  fi
  verify=FAIL
  [[ "$sync" == Synced && "$health" == Healthy && "$ready" -eq "$total" && "$warnings" -eq 0 ]] && verify=PASS
  echo "ARGO=$sync/$health"
  echo "REVISION=$rev"
  echo "PODS=$ready/$total"
  echo "LAST_ERROR=$last_error"
  echo "VERIFY=$verify"
  echo "EVIDENCE=$evidence"
  exit 0
fi

echo "=== ARGO ==="
jq '{name:.metadata.name,sync:.status.sync.status,health:.status.health.status,targetRevision:.spec.source.targetRevision,operationRevision:.status.operationState.operation.sync.revision,operationPhase:.status.operationState.phase,operationMessage:.status.operationState.message,conditions:(.status.conditions//[])}' <<<"$obj"

while IFS= read -r ns; do
  [[ -z "$ns" ]] && continue
  ns_listing "$ns"
done < <(jq -r '.status.resources[]?.namespace // empty' <<<"$obj" | sort -u)
