#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
modifier="$repo_root/k8s/infrastructure/controllers/velero/restore-pvc-isolation.yaml"

rules="$(yq -r '.data["resource-modifier.yaml"]' "$modifier")"
patch="$(yq -o=json '.resourceModifierRules[0].mergePatches[0].patchData | fromjson' <<<"$rules")"
jq -e '. == {spec:{volumeName:null}}' <<<"$patch" >/dev/null
if yq -e '.resourceModifierRules[0].patches' <<<"$rules" >/dev/null 2>&1; then
  echo 'ASSERTION_FAILED non-idempotent patches rule is still present' >&2
  exit 1
fi

# Model the JSON Merge Patch deletion for both source shapes. The first input
# represents a PVC copied with a stale PV identity; the second is the shape
# produced when volumeName is already absent. Both must converge to the same
# PVC spec without touching storageClassName.
for pvc in \
  '{"spec":{"volumeName":"pvc-source","storageClassName":"longhorn-fast"}}' \
  '{"spec":{"storageClassName":"longhorn-bulk"}}'; do
  jq -e --argjson patch "$patch" '
    . as $pvc |
    if ($patch.spec.volumeName == null) then del(.spec.volumeName) else . end |
    (.spec.storageClassName == ($pvc.spec.storageClassName)) and
    ((.spec | has("volumeName")) | not)
  ' <<<"$pvc" >/dev/null
done

echo 'VELERO_RESOURCE_MODIFIER_IDEMPOTENCE=PASS'
