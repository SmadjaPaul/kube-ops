#!/usr/bin/env bash
set -euo pipefail
app=${1:?usage: diagnose-app.sh APP}
for cmd in kubectl jq; do command -v "$cmd" >/dev/null || { echo "ERROR: $cmd required" >&2; exit 2; }; done
source "$(dirname "$0")/lib/kube-preflight.sh"
require_kube_access
source "$(dirname "$0")/lib/argo-app.sh"
resolved="$(resolve_argo_app "$app")"
obj="$(kubectl -n argocd get application.argoproj.io "$resolved" -o json)"

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
