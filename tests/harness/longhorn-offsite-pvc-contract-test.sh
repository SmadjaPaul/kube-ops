#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
longhorn="$repo_root/k8s/infrastructure/storage/longhorn"

values="$longhorn/values.yaml"
credentials="$longhorn/backup-credentials.yaml"
job="$longhorn/recurring-job.yaml"
immich_job="$longhorn/immich-redis-recurring-job.yaml"
immich_pvc="$repo_root/k8s/applications/media/immich/immich-redis/redis-pvc-labels.yaml"

grep -F 'version: 1.12.1' "$longhorn/kustomization.yaml" >/dev/null
grep -F 'backupTarget: s3://smadja-dev-homelab-backups@fsn1/longhorn/' "$values" >/dev/null
grep -F 'backupTargetCredentialSecret: longhorn-hetzner-credentials' "$values" >/dev/null
grep -F 'allowRecurringJobWhileVolumeDetached: false' "$values" >/dev/null
grep -F 'key: HETZNER_S3_ACCESS_KEY_ID' "$credentials" >/dev/null
grep -F 'key: HETZNER_S3_SECRET_ACCESS_KEY' "$credentials" >/dev/null
! rg -n 'AWS_ACCESS_KEY_ID: [A-Za-z0-9+/=]{16,}|AWS_SECRET_ACCESS_KEY: [A-Za-z0-9+/=]{16,}' "$credentials" >/dev/null
grep -F 'kind: RecurringJob' "$job" >/dev/null
grep -F 'task: backup' "$job" >/dev/null
grep -F 'retain: 7' "$job" >/dev/null
grep -F 'concurrency: 1' "$job" >/dev/null
grep -F 'name: immich-redis-offsite' "$immich_job" >/dev/null
grep -F 'task: backup' "$immich_job" >/dev/null
grep -F 'retain: 7' "$immich_job" >/dev/null
grep -F 'concurrency: 1' "$immich_job" >/dev/null
grep -F 'recurring-job.longhorn.io/source: enabled' "$immich_pvc" >/dev/null
grep -F 'recurring-job.longhorn.io/immich-redis-offsite: enabled' "$immich_pvc" >/dev/null
grep -F 'redis-pvc-labels.yaml' "$repo_root/k8s/applications/media/immich/immich-redis/kustomization.yaml" >/dev/null
# Regressions: the StatefulSet volumeClaimTemplates are immutable after creation.
# Apply recurring backup labels only to the existing standalone PVC.
redis_dir="$repo_root/k8s/applications/media/immich/immich-redis"
! rg -n 'recurring-backup-patch|volumeClaimTemplates|kind: StatefulSet' "$redis_dir/kustomization.yaml" >/dev/null
test ! -e "$redis_dir/recurring-backup-patch.yaml"
grep -F 'kind: PersistentVolumeClaim' "$immich_pvc" >/dev/null
grep -F 'name: redis-data-immich-redis-master-0' "$immich_pvc" >/dev/null
grep -F 'namespace: immich' "$immich_pvc" >/dev/null
grep -F 'storageClassName: longhorn-fast' "$immich_pvc" >/dev/null
grep -F 'storageClass: longhorn-fast' "$redis_dir/values.yaml" >/dev/null
grep -F 'size: 1Gi' "$redis_dir/values.yaml" >/dev/null
grep -F 'storage: 1Gi' "$immich_pvc" >/dev/null

for file in \
  "$repo_root/k8s/applications/platform/agentgateway/resources.yaml" \
  "$repo_root/k8s/poc/atlantis-plan-only/pvc-retention.yaml" \
  "$repo_root/k8s/applications/business/invoice-ninja/storage.yaml" \
  "$repo_root/k8s/applications/catalog/sure/storage.yaml"; do
  grep -F 'recurring-job.longhorn.io/source: enabled' "$file" >/dev/null
  grep -F 'recurring-job.longhorn.io/persistent-offsite-backup: enabled' "$file" >/dev/null
done

! rg -n 'storageClassName:|resources:|dataStorage:|numberOfReplicas:|defaultDataPath:' \
  "$repo_root/k8s/applications/platform/agentgateway/resources.yaml" \
  "$repo_root/k8s/poc/atlantis-plan-only/pvc-retention.yaml" \
  | rg 'pvc-retention|agentgateway-state|atlantis-pilot-data' >/dev/null

# Retired Atlantis recovery volume (PLT-205; absorbs the former dedicated
# Atlantis retirement tests). The Argo root must keep owning the recovery PVC,
# must keep it out of prune, and must not carry any workload, route, credential
# or policy object again.
atlantis_root="$repo_root/k8s/poc/atlantis-plan-only"
grep -F -- '- path: k8s/poc/atlantis-plan-only' \
  "$repo_root/k8s/bootstrap/argocd-root/infrastructure-applicationset.yaml" >/dev/null
test "$(find "$atlantis_root" -type f -printf '%f\n' | sort | tr '\n' ' ')" = \
  'kustomization.yaml namespace.yaml pvc-retention.yaml '
atlantis_rendered="$(mktemp)"
trap 'rm -f "$atlantis_rendered"' EXIT
kustomize build "$atlantis_root" >"$atlantis_rendered"
test "$(grep -c '^kind:' "$atlantis_rendered")" = 2
grep -q '^kind: Namespace$' "$atlantis_rendered"
grep -q '^  name: atlantis-system$' "$atlantis_rendered"
grep -q '^kind: PersistentVolumeClaim$' "$atlantis_rendered"
grep -q '^  name: atlantis-pilot-data$' "$atlantis_rendered"
grep -q 'argocd.argoproj.io/sync-options: Delete=false' "$atlantis_rendered"
grep -q 'atlantis.smadja.dev/retention: recovery-only' "$atlantis_rendered"
grep -q 'atlantis.smadja.dev/server: retired' "$atlantis_rendered"
grep -q 'storageClassName: longhorn-fast' "$atlantis_rendered"
grep -q 'storage: 5Gi' "$atlantis_rendered"
! grep -Eq '^kind: (StatefulSet|Deployment|Service|HTTPRoute|ExternalSecret|Secret|ConfigMap|CiliumNetworkPolicy)$' \
  "$atlantis_rendered"
! rg -n 'atlantis-servicemonitor|atlantis-observability|atlantis-pilot' \
  "$repo_root/k8s/infrastructure/monitoring/prometheus-stack/kustomization.yaml" \
  "$repo_root/k8s/applications/media/aiostreams/networkpolicy.yaml" \
  "$repo_root/k8s/applications/media/polyfin/networkpolicy.yaml" >/dev/null

printf '%s\n' 'LONGHORN_OFFSITE_PVC_CONTRACT=PASS'
