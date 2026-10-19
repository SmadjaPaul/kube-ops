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
grep -F 'allowRecurringJobWhileVolumeDetached: true' "$values" >/dev/null
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

for file in \
  "$repo_root/k8s/applications/platform/agentgateway/resources.yaml" \
  "$repo_root/k8s/applications/business/retained/listmonk/storage.yaml" \
  "$repo_root/k8s/applications/business/retained/twenty/storage.yaml" \
  "$repo_root/k8s/poc/atlantis-plan-only/pvc-backup-patch.yaml"; do
  grep -F 'recurring-job.longhorn.io/source: enabled' "$file" >/dev/null
  grep -F 'recurring-job.longhorn.io/persistent-offsite-backup: enabled' "$file" >/dev/null
done

! rg -n 'storageClassName:|resources:|dataStorage:|numberOfReplicas:|defaultDataPath:' \
  "$repo_root/k8s/applications/platform/agentgateway/resources.yaml" \
  "$repo_root/k8s/applications/business/retained/listmonk/storage.yaml" \
  "$repo_root/k8s/applications/business/retained/twenty/storage.yaml" \
  "$repo_root/k8s/poc/atlantis-plan-only/pvc-backup-patch.yaml" \
  | rg 'pvc-backup-patch|agentgateway-state|listmonk-uploads|twenty-storage|atlantis-pilot-data' >/dev/null

printf '%s\n' 'LONGHORN_OFFSITE_PVC_CONTRACT=PASS'
