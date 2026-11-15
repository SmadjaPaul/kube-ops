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
  "$repo_root/k8s/applications/ai/karakeep/meilisearch-statefulset.yaml" \
  "$repo_root/k8s/applications/media/sabnzbd/statefulset.yaml"; do
  if grep -F 'velero.io/exclude-from-backup' "$file" >/dev/null; then
    echo "VELERO_STORAGE_TIER_CONTRACT=FAIL: StatefulSet $file must not carry velero.io/exclude-from-backup" >&2
    exit 1
  fi
done
grep -F 'backup.velero.io/backup-volumes-excludes: meilisearch-data' \
  "$repo_root/k8s/applications/ai/karakeep/meilisearch-statefulset.yaml" >/dev/null
# Only mounted volume names can be excluded through pod annotations.
# The historical incomplete-downloads claim is not mounted and is retained.
test "$(yq -r '.spec.template.metadata.annotations["backup.velero.io/backup-volumes-excludes"]' \
  "$repo_root/k8s/applications/media/sabnzbd/statefulset.yaml")" = "media-share"
grep -F 'backup.velero.io/backup-volumes-excludes: logs' \
  "$repo_root/k8s/applications/ai/gpt-researcher/gpt-researcher-deployment.yaml" >/dev/null
grep -F 'backup.velero.io/backup-volumes-excludes: downloads,backups' \
  "$repo_root/k8s/applications/web/pinepods/deployment.yaml" >/dev/null
grep -F 'backup.velero.io/backup-volumes-excludes: media' \
  "$repo_root/k8s/applications/media/audiobookshelf/statefulset.yaml" >/dev/null
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
  daily-sabnzbd.yaml \
  daily-audiobookshelf.yaml \
  daily-bazarr.yaml \
  daily-karakeep.yaml; do
  grep -F 'defaultVolumesToFsBackup: true' "$velero_root/schedules/$schedule" >/dev/null
done
echo "VELERO_DURABLE_DATA_SCOPE_CONTRACT=PASS"
