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
grep -F 'path: "/spec/volumeName"' <<<"$rules" >/dev/null
if grep -F 'path: "/spec/storageClassName"' <<<"$rules" >/dev/null; then
  echo "ERROR: storage class rewriting in restore modifier" >&2
  exit 1
fi
grep -F 'source-pvcs.json' "$restore_doc" >/dev/null
grep -F 'IN("longhorn-fast", "longhorn-bulk")' "$restore_doc" >/dev/null
echo "VELERO_STORAGE_TIER_CONTRACT=PASS"
