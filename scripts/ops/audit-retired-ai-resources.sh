#!/usr/bin/env bash
# Read-only post-cutover inventory; never print Secret values and never delete.
set -euo pipefail
command -v kubectl >/dev/null || { echo 'kubectl not installed' >&2; exit 2; }
echo '== Workloads/Services/PVC/Secrets/Routes matching retired services =='
kubectl get deployments,statefulsets,daemonsets,services,persistentvolumeclaims,secrets,configmaps,httproutes.gateway.networking.k8s.io -A --ignore-not-found -o custom-columns='KIND:.kind,NAMESPACE:.metadata.namespace,NAME:.metadata.name,AGE:.metadata.creationTimestamp' --no-headers |
  grep -Ei 'openclaw|open-webui|openwebui|litellm|qdrant|mcp-proxy|open-terminal' || true
echo '== PVs with old claim names (volume retention does not follow Git revert) =='
kubectl get pv --ignore-not-found -o custom-columns='PV:.metadata.name,PHASE:.status.phase,NAMESPACE:.spec.claimRef.namespace,CLAIM:.spec.claimRef.name' --no-headers |
  grep -Ei 'openclaw|open-webui|openwebui|litellm|qdrant' || true
echo '== CNPG clusters, including those from retired services =='
kubectl get clusters.postgresql.cnpg.io -A --ignore-not-found || true
echo '== Argo apps potentially still reconciling retired trees =='
kubectl get applications.argoproj.io -A --ignore-not-found -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status' --no-headers |
  grep -Ei 'openclaw|open-webui|openwebui|litellm|qdrant' || true
echo '== Retained backup schedules and Velero references =='
kubectl get schedules.velero.io -A --ignore-not-found -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,PHASE:.status.phase' --no-headers |
  grep -Ei 'openclaw|open-webui|openwebui|litellm|qdrant' || true
echo 'Read-only completed. Manually classify each match as active dependency, retained for rollback, or stale before cleanup.'
