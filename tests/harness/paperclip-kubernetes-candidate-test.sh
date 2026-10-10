#!/usr/bin/env bash
set -euo pipefail

candidate="k8s/applications/ai/paperclip/poc/kubernetes-execution/instance-candidate.yaml"
lock="k8s/applications/ai/paperclip/poc/kubernetes-execution/version-lock.yaml"
production="k8s/applications/ai/paperclip/kustomization.yaml"

test -f "$candidate"
test -f "$lock"
grep -F 'version: "0.1.0"' "$candidate" >/dev/null
grep -F 'npmVersion: "0.1.0"' "$lock" >/dev/null
grep -F 'npmDistIntegrity: "sha512-' "$lock" >/dev/null
! grep -F 'npmDistIntegrity: NOT_OBSERVED' "$lock" >/dev/null
grep -F 'selectedVersion: v1.0.5' "$lock" >/dev/null
grep -F 'agents.x-k8s.io/v1beta1' "$lock" >/dev/null
! grep -F 'sandboxApiExpected: "agents.x-k8s.io/v1alpha1"' "$lock" >/dev/null
grep -F 'selectedReleaseAssetSha256:' "$lock" >/dev/null
grep -F 'candidate-compatible-with-v1.0.5' "$lock" >/dev/null
grep -F 'backend: sandbox-cr' "$candidate" >/dev/null
grep -F 'egressPolicy: allowlist' "$candidate" >/dev/null
grep -F 'egressAllowFQDNs:' "$candidate" >/dev/null
grep -F 'perTenantQuota:' "$candidate" >/dev/null
grep -F 'perTenantLimitRange:' "$candidate" >/dev/null
grep -F 'PAPERCLIP_ADAPTERS' "$candidate" >/dev/null
grep -F 'ghcr.io/paperclipai/agent-runtime-opencode@sha256:349fc68e609998f1d9fc77f94208d50263368b49631f746a51f819917d9b0d2d' "$candidate" >/dev/null
adapter_registry_json="$(yq -r '.spec.env[] | select(.name == "PAPERCLIP_ADAPTERS") | .value' "$candidate")"
jq -e '
  length == 1 and
  .[0].adapterType == "opencode_local" and
  .[0].enabled == true and
  .[0].runtimeImage == "ghcr.io/paperclipai/agent-runtime-opencode@sha256:349fc68e609998f1d9fc77f94208d50263368b49631f746a51f819917d9b0d2d" and
  .[0].envKeys == [] and
  .[0].probeCommand == ["opencode", "--version"] and
  (["paperclip.paperclip.svc.cluster.local", "litellm.litellm.svc.cluster.local", "github.com", "api.github.com"] - .[0].allowFqdns | length) == 0
' <<<"$adapter_registry_json" >/dev/null
! grep -F 'egressAllowFqdns:' "$candidate" >/dev/null
! grep -E '^        (inCluster|adapterType|podActivityDeadlineSec|jobTtlSecondsAfterFinished):' "$candidate" >/dev/null
! grep -F 'poc/kubernetes-execution' "$production" >/dev/null
! grep -F 'instance-candidate.yaml' "$production" >/dev/null
grep -F 'serviceAccountToken: false' docs/factory/H3_AGENT_IMAGE_MANIFEST_2026-10-09.yaml >/dev/null
grep -F 'PAPERCLIP_SERVER_RBAC_NOT_GRANTED' docs/factory/H3_AGENT_IMAGE_MANIFEST_2026-10-09.yaml >/dev/null
grep -F 'IMMUTABLE_IMAGE_RUNTIME_NOT_OBSERVED' docs/factory/H3_AGENT_IMAGE_MANIFEST_2026-10-09.yaml >/dev/null

kustomize build k8s/applications/ai/paperclip/poc/kubernetes-execution >/dev/null

printf '%s\n' 'PAPERCLIP_KUBERNETES_CANDIDATE_CONTRACT_TEST=PASS'
