#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
manifest="$repo_root/k8s/applications/platform/mastra-sandbox/resources.yaml"

# The SandboxTemplate, not the Factory API Deployment, owns sandboxd /tmp.
template='select(.kind == "SandboxTemplate" and .metadata.name == "mastra-code" and .metadata.namespace == "mastra-sandbox")'
tmp_limit="$(yq -r "${template} | .spec.podTemplate.spec.volumes[] | select(.name == \"tmp\") | .emptyDir.sizeLimit // \"\"" "$manifest")"
mount_path="$(yq -r "${template} | .spec.podTemplate.spec.containers[] | select(.name == \"sandboxd\") | .volumeMounts[] | select(.name == \"tmp\") | .mountPath" "$manifest")"
workspace_limit="$(yq -r "${template} | .spec.volumeClaimTemplates[] | select(.metadata.name == \"workspace\") | .spec.resources.requests.storage" "$manifest")"
workspace_class="$(yq -r "${template} | .spec.volumeClaimTemplates[] | select(.metadata.name == \"workspace\") | .spec.storageClassName" "$manifest")"
runtime_class="$(yq -r "${template} | .spec.podTemplate.spec.runtimeClassName" "$manifest")"
warm_pool="$(yq -r 'select(.kind == "SandboxWarmPool" and .metadata.name == "mastra-code") | .spec.replicas' "$manifest")"

[[ "$tmp_limit" == "1Gi" ]] || {
  echo "ASSERTION_FAILED sandboxd /tmp emptyDir must be 1Gi (got ${tmp_limit})" >&2
  exit 1
}
[[ "$mount_path" == "/tmp" && "$workspace_limit" == "2Gi" && "$workspace_class" == "longhorn-workspace" ]] || {
  echo "ASSERTION_FAILED sandbox mount or persistent workspace contract changed" >&2
  exit 1
}
storage_class="$repo_root/k8s/infrastructure/storage/longhorn/workspace-storageclass.yaml"
reclaim_policy="$(yq -r '.reclaimPolicy' "$storage_class")"
disk_selector="$(yq -r '.parameters.diskSelector' "$storage_class")"
replicas="$(yq -r '.parameters.numberOfReplicas' "$storage_class")"
[[ "$reclaim_policy" == "Retain" && "$disk_selector" == "bulk" && "$replicas" == "1" ]] || {
  echo "ASSERTION_FAILED sandbox storage must retain workspaces on the bulk tier with one replica" >&2
  exit 1
}
[[ "$runtime_class" == "gvisor" && "$warm_pool" == "0" ]] || {
  echo "ASSERTION_FAILED runtime isolation or warm pool contract changed" >&2
  exit 1
}
echo "MASTRA_SANDBOX_TMP_CONTRACT=PASS tmp=${tmp_limit} workspace=${workspace_limit} storage_class=${workspace_class} runtime=${runtime_class} warm_pool=${warm_pool}"
