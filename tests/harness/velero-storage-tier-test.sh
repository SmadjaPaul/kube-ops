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
  grep -F 'velero.io/exclude-from-backup: "true"' "$file" >/dev/null
done
grep -F 'velero.io/exclude-from-backup: "true"' \
  "$repo_root/k8s/applications/ai/karakeep/meilisearch-statefulset.yaml" >/dev/null
grep -F 'velero.io/exclude-from-backup: "true"' \
  "$repo_root/k8s/applications/media/jellyfin/statefulset.yaml" >/dev/null
! grep -Fxq '  - daily-monitoring.yaml' \
  "$velero_root/schedules/kustomization.yaml"
! grep -Fxq '  - daily-executor.yaml' \
  "$velero_root/schedules/kustomization.yaml"
grep -F 'app: karakeep-web' \
  "$velero_root/schedules/daily-karakeep.yaml" >/dev/null
echo "VELERO_DURABLE_DATA_SCOPE_CONTRACT=PASS"
