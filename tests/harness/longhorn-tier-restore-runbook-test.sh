#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
doc="$repo_root/website/docs/disaster/longhorn-tier-restore-qualification.md"
modifier="$repo_root/k8s/infrastructure/controllers/velero/restore-pvc-isolation.yaml"

test -f "$doc"
test -f "$modifier"

grep -F 'longhorn-fast' "$doc" >/dev/null
grep -F 'longhorn-bulk' "$doc" >/dev/null
grep -F -- '--default-volumes-to-fs-backup=true' "$doc" >/dev/null
grep -F -- '--restore-volumes=true' "$doc" >/dev/null
grep -F -- '--include-cluster-resources=false' "$doc" >/dev/null
grep -F -- '--resource-modifier-configmap restore-pvc-isolation' "$doc" >/dev/null
grep -F 'PodVolumeBackups' "$doc" >/dev/null
grep -F 'PodVolumeRestores' "$doc" >/dev/null
grep -F 'sha256sum -c' "$doc" >/dev/null
grep -F 'claimRef.namespace == $ns' "$doc" >/dev/null

rules="$(yq -r '.data["resource-modifier.yaml"]' "$modifier")"
grep -F -- '- longhorn-tier-dr-source' <<<"$rules" >/dev/null
if grep -F 'path: "/spec/storageClassName"' <<<"$rules" >/dev/null; then
  echo 'ASSERTION_FAILED tier restore must preserve storageClassName' >&2
  exit 1
fi

grep -F 'kubectl apply -n "$SRC_NS" -f -' "$doc" >/dev/null

printf '%s\n' 'LONGHORN_TIER_RESTORE_RUNBOOK_CONTRACT_TEST=PASS'
