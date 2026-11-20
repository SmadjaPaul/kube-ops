#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
velero_root="$repo_root/k8s/infrastructure/controllers/velero"
modifier="$velero_root/restore-pvc-isolation.yaml"
restore_doc="$repo_root/k8s/applications/business/invoice-ninja/RESTORE.md"

# No automatic restore-class rewriting from Longhorn NVMe/HDD into Proxmox CSI.
test ! -e "$velero_root/storage-class-mapping.yaml"
if yq -r '.resources[]?' "$velero_root/kustomization.yaml" |
  grep -Fxq 'storage-class-mapping.yaml'; then
  echo "ERROR: global storage-class migration still rendered" >&2
  exit 1
fi

# Isolated restores must discard stale PV identity but preserve the tier.
rules="$(yq -r '.data["resource-modifier.yaml"]' "$modifier")"
grep -F 'mergePatches:' <<<"$rules" >/dev/null
grep -F '"volumeName": null' <<<"$rules" >/dev/null
if grep -F 'operation: remove' <<<"$rules" >/dev/null; then
  echo "ERROR: non-idempotent JSON Patch remove remains in restore modifier" >&2
  exit 1
fi
if grep -F 'path: "/spec/storageClassName"' <<<"$rules" >/dev/null; then
  echo "ERROR: storage class rewriting in restore modifier" >&2
  exit 1
fi
grep -F 'source-pvcs.json' "$restore_doc" >/dev/null
grep -F 'IN("longhorn-fast", "longhorn-bulk")' "$restore_doc" >/dev/null
echo "VELERO_STORAGE_TIER_CONTRACT=PASS"

# PLT-56 durable-data scope: rebuildable media/index/cache/log volumes are
# explicitly excluded, while the schedule set retains application data and
# database-specific recovery policies.
for file in \
  "$repo_root/k8s/applications/media/media-share-pvc.yaml" \
  "$repo_root/k8s/applications/ai/gpt-researcher/pvc.yaml" \
  "$repo_root/k8s/applications/web/pinepods/pvc.yaml"; do
  grep -F 'labels:' "$file" >/dev/null
  grep -F 'velero.io/exclude-from-backup: "true"' "$file" >/dev/null
done

# StatefulSet volumeClaimTemplates are immutable for existing instances. The
# FSB/Kopia exclusions therefore live on Pod templates and name the exact
# mounted volumes; no template PVC is rewritten by this policy.
for file in \
  "$repo_root/k8s/applications/ai/karakeep/meilisearch-statefulset.yaml"; do
  if grep -F 'velero.io/exclude-from-backup' "$file" >/dev/null; then
    echo "VELERO_STORAGE_TIER_CONTRACT=FAIL: StatefulSet $file must not carry velero.io/exclude-from-backup" >&2
    exit 1
  fi
done
grep -F 'backup.velero.io/backup-volumes-excludes: meilisearch-data' \
  "$repo_root/k8s/applications/ai/karakeep/meilisearch-statefulset.yaml" >/dev/null
grep -F 'backup.velero.io/backup-volumes-excludes: logs' \
  "$repo_root/k8s/applications/ai/gpt-researcher/gpt-researcher-deployment.yaml" >/dev/null
grep -F 'backup.velero.io/backup-volumes-excludes: downloads,backups' \
  "$repo_root/k8s/applications/web/pinepods/deployment.yaml" >/dev/null
if grep -F 'backup.smadja.dev/strategy: rebuildable' \
  "$repo_root/k8s/infrastructure/monitoring/prometheus-stack/values.yaml" >/dev/null; then
  echo 'VELERO_STORAGE_TIER_CONTRACT=FAIL: prometheus-stack values must not be marked rebuildable' >&2
  exit 1
fi
if [[ -e "$repo_root/k8s/infrastructure/monitoring/loki/pvc-backup-policy-patch.yaml" ]]; then
  echo 'VELERO_STORAGE_TIER_CONTRACT=FAIL: loki pvc-backup-policy-patch.yaml must stay absent' >&2
  exit 1
fi
if grep -Fxq '  - daily-monitoring.yaml' \
  "$velero_root/schedules/kustomization.yaml"; then
  echo 'VELERO_STORAGE_TIER_CONTRACT=FAIL: daily-monitoring.yaml must not be scheduled' >&2
  exit 1
fi
grep -F 'app: karakeep-web' \
  "$velero_root/schedules/daily-karakeep.yaml" >/dev/null

for schedule in \
  daily-gpt-researcher.yaml \
  daily-pinepods.yaml \
  daily-jellyfin.yaml \
  daily-bazarr.yaml \
  daily-karakeep.yaml; do
  grep -F 'defaultVolumesToFsBackup: true' "$velero_root/schedules/$schedule" >/dev/null
done
echo "VELERO_DURABLE_DATA_SCOPE_CONTRACT=PASS"

# Internal-secret namespaces: `auth` and `databases` must stay covered by a
# Velero schedule (their Secrets are rebuilt from Git/Doppler today and will
# become native Secrets). `databases` is resources-only: CNPG/Barman owns the
# PostgreSQL data, Velero must never copy PG volumes.
sched_dir="$velero_root/schedules"
for ns in auth databases; do
  schedule="$sched_dir/daily-$ns.yaml"
  listed="$(yq -r '.resources[]?' "$sched_dir/kustomization.yaml")"
  if ! grep -Fxq "daily-$ns.yaml" <<<"$listed"; then
    echo "VELERO_INTERNAL_NAMESPACE_COVERAGE=FAIL: daily-$ns.yaml not listed in schedules/kustomization.yaml" >&2
    exit 1
  fi
  if ! yq -e '.spec.template.includedNamespaces | contains(["'"$ns"'"])' "$schedule" >/dev/null; then
    echo "VELERO_INTERNAL_NAMESPACE_COVERAGE=FAIL: schedule for $ns does not include namespace $ns" >&2
    exit 1
  fi
  # Secrets must not be filtered out of the backup.
  if yq -e '(.spec.template.includedResources // ["*"]) as $inc | ($inc | contains(["*"]) or contains(["secrets"])) | not' "$schedule" >/dev/null 2>&1; then
    echo "VELERO_INTERNAL_NAMESPACE_COVERAGE=FAIL: $ns schedule does not include secrets" >&2
    exit 1
  fi
  if yq -e '.spec.template.excludedResources // [] | contains(["secrets"])' "$schedule" >/dev/null 2>/dev/null; then
    echo "VELERO_INTERNAL_NAMESPACE_COVERAGE=FAIL: $ns schedule excludes secrets" >&2
    exit 1
  fi
  # CNPG-generated pods/PVCs/Secrets (cnpg.io/cluster) are never doubled.
  yq -e '.spec.template.labelSelector.matchExpressions[] | select(.key == "cnpg.io/cluster" and .operator == "DoesNotExist")' \
    "$schedule" >/dev/null
  test "$(yq -r '.spec.template.storageLocation' "$schedule")" = "r2"
  test "$(yq -r '.spec.template.ttl' "$schedule")" = "336h"
  test "$(yq -r '.metadata.labels["backup-tier"]' "$schedule")" = "daily"
  test "$(yq -r '.metadata.name' "$schedule")" = "velero-daily-$ns"
done
# auth keeps the app volumes (Authentik Redis) through fs-backup.
grep -F 'defaultVolumesToFsBackup: true' "$sched_dir/daily-auth.yaml" >/dev/null
# databases: Kubernetes resources only, no PG volume copy of any kind.
db="$sched_dir/daily-databases.yaml"
test "$(yq -r '.spec.template.defaultVolumesToFsBackup' "$db")" = "false"
test "$(yq -r '.spec.template.snapshotVolumes' "$db")" = "false"
for res in pods persistentvolumeclaims persistentvolumes; do
  yq -e '.spec.template.excludedResources | contains(["'"$res"'"])' "$db" >/dev/null
done
# Cluster / ObjectStore / ScheduledBackup definitions stay in the backup.
for res in clusters.postgresql.cnpg.io objectstores.barmancloud.cnpg.io scheduledbackups.postgresql.cnpg.io; do
  if yq -e '.spec.template.excludedResources | contains(["'"$res"'"])' "$db" >/dev/null 2>/dev/null; then
    echo "VELERO_INTERNAL_NAMESPACE_COVERAGE=FAIL: databases schedule must keep $res" >&2
    exit 1
  fi
done
echo "VELERO_INTERNAL_NAMESPACE_COVERAGE=PASS"
