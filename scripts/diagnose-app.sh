#!/usr/bin/env bash
set -euo pipefail
app=${1:?usage: diagnose-app.sh APP [summary|errors|full]}
for cmd in kubectl jq; do command -v "$cmd" >/dev/null || { echo "ERROR: $cmd required" >&2; exit 2; }; done
source "$(dirname "$0")/lib/output-mode.sh"
mode="$(resolve_output_mode "${2:-}")"
source "$(dirname "$0")/lib/kube-preflight.sh"
if [[ "$mode" == full ]]; then require_kube_access; else require_kube_access >/dev/null; fi
source "$(dirname "$0")/lib/argo-app.sh"
resolved="$(resolve_argo_app "$app")"
obj="$(kubectl -n argocd get application.argoproj.io "$resolved" -o json)"

if [[ "$mode" != full ]]; then
  sync="$(jq -r '.status.sync.status // "Unknown"' <<<"$obj")"
  health="$(jq -r '.status.health.status // "Unknown"' <<<"$obj")"
  rev="$(jq -r '(.status.sync.revision // "none")[0:7]' <<<"$obj")"
  evidence="$(evidence_file "diagnose-$resolved")"
  ready=0; total=0; warnings=0; last_error="$(jq -r '([.status.conditions[]? | select(.message) | .message][0]) // (if (.status.operationState.phase // "Succeeded") != "Succeeded" then .status.operationState.message else null end) // "none"' <<<"$obj" | sanitize_line)"
  errs=""
  while IFS= read -r ns; do
    [[ -z "$ns" ]] && continue
    {
      echo "=== NAMESPACE $ns ==="
      kubectl get pods,pvc,httproute.gateway.networking.k8s.io,externalsecret.external-secrets.io -n "$ns" -o wide 2>/dev/null || true
      kubectl get clusters.postgresql.cnpg.io -n "$ns" 2>/dev/null || true
      echo "--- warning events ---"
      kubectl get events -n "$ns" --field-selector type=Warning --sort-by=.lastTimestamp 2>/dev/null | tail -30 || true
    } >>"$evidence"
    counts="$(kubectl get pods -n "$ns" -o json 2>/dev/null | jq -r '[.items[] | select(.status.phase != "Succeeded")] | "\(map(select(any(.status.conditions[]?; .type=="Ready" and .status=="True"))) | length) \(length)"' 2>/dev/null || echo "0 0")"
    ready=$((ready + ${counts%% *})); total=$((total + ${counts##* }))
    bad="$(kubectl get pods -n "$ns" -o json 2>/dev/null | jq -r '.items[] | select(.status.phase != "Succeeded" and (any(.status.conditions[]?; .type=="Ready" and .status=="True") | not)) | "pod/\(.metadata.name) \(.status.phase)"' 2>/dev/null || true)"
    [[ -n "$bad" ]] && errs+="$ns: $bad"$'\n'
    ev="$(kubectl get events -n "$ns" --field-selector type=Warning --sort-by=.lastTimestamp 2>/dev/null | tail -5 || true)"
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

mapfile -t namespaces < <(jq -r '.status.resources[]?.namespace // empty' <<<"$obj" | sort -u)
for ns in "${namespaces[@]}"; do
  [[ -z "$ns" ]] && continue
  echo "=== NAMESPACE $ns ==="
  kubectl get pods,pvc,httproute.gateway.networking.k8s.io,externalsecret.external-secrets.io -n "$ns" -o wide 2>/dev/null || true
  kubectl get clusters.postgresql.cnpg.io -n "$ns" 2>/dev/null || true
  echo "--- warning events ---"
  kubectl get events -n "$ns" --field-selector type=Warning --sort-by=.lastTimestamp 2>/dev/null | tail -30 || true
done
