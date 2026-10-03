#!/usr/bin/env bash
set -euo pipefail
app=${1:?usage: status-app.sh APP}
for cmd in kubectl jq; do command -v "$cmd" >/dev/null || { echo "ERROR: $cmd required" >&2; exit 2; }; done
source "$(dirname "$0")/lib/kube-preflight.sh"
require_kube_access
source "$(dirname "$0")/lib/argo-app.sh"
resolved="$(resolve_argo_app "$app")"

kubectl -n argocd get application.argoproj.io "$resolved" -o json | jq '{
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
}'
