#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
restore_doc="$repo_root/k8s/applications/business/invoice-ninja/RESTORE.md"
modifier="$repo_root/k8s/infrastructure/controllers/velero/restore-pvc-isolation.yaml"

grep -F -- '--restore-volumes=true' "$restore_doc" >/dev/null
if grep -F -- '--restore-volumes=false' "$restore_doc" >/dev/null; then
  echo 'ASSERTION_FAILED restore must not disable volume restoration' >&2
  exit 1
fi
grep -F -- '--include-cluster-resources=true' "$restore_doc" >/dev/null
if grep -F -- '--include-cluster-resources=false' "$restore_doc" >/dev/null; then
  echo 'ASSERTION_FAILED FSB restore requires PV metadata' >&2
  exit 1
fi
grep -F -- '--exclude-resources "customresourcedefinitions.apiextensions.k8s.io,namespaces,' "$restore_doc" >/dev/null
grep -F -- '--resource-modifier-configmap restore-pvc-isolation' "$restore_doc" >/dev/null

yq -e '
  .kind == "ConfigMap" and
  .metadata.namespace == "velero" and
  (.data["resource-modifier.yaml"] | test("groupResource: persistentvolumeclaims"))
' "$modifier" >/dev/null

modifier_rules="$(yq -r '.data["resource-modifier.yaml"]' "$modifier")"
grep -F 'groupResource: persistentvolumeclaims' <<<"$modifier_rules" >/dev/null
grep -F 'namespaces:' <<<"$modifier_rules" >/dev/null
grep -F -- '- invoice-ninja' <<<"$modifier_rules" >/dev/null
grep -F 'path: "/spec/volumeName"' <<<"$modifier_rules" >/dev/null
if if grep -F 'path: "/spec/storageClassName"' <<<"$modifier_rules"; then
  echo 'ASSERTION_FAILED restore must preserve StorageClass' >&2
  exit 1
fi; then
  echo 'ASSERTION_FAILED preserve original fast/bulk StorageClass on restore' >&2
  exit 1
fi
grep -F 'groupResource: "*.*"' <<<"$modifier_rules" >/dev/null
grep -F 'argocd.argoproj.io/tracking-id' <<<"$modifier_rules" >/dev/null
grep -F '"argocd.argoproj.io/tracking-id": null' <<<"$modifier_rules" >/dev/null

printf '%s\n' 'INVOICE_RESTORE_ISOLATION_CONTRACT_TEST=PASS'
