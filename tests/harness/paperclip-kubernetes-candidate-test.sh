#!/usr/bin/env bash
set -euo pipefail

candidate="k8s/applications/ai/paperclip/poc/kubernetes-execution/instance-candidate.yaml"
lock="k8s/applications/ai/paperclip/poc/kubernetes-execution/version-lock.yaml"
production="k8s/applications/ai/paperclip/kustomization.yaml"

test -f "$candidate"
test -f "$lock"
! grep -F 'name: "@paperclipai/plugin-kubernetes"' "$candidate" >/dev/null
grep -F 'bundled local-plugin path' "$candidate" >/dev/null
grep -F 'npmVersion: "0.1.0"' "$lock" >/dev/null
grep -F 'npmDistIntegrity: "sha512-' "$lock" >/dev/null
! grep -F 'npmDistIntegrity: NOT_OBSERVED' "$lock" >/dev/null
grep -F 'npmSelectionStatus: "not-selected-operator-does-not-install-spec.plugins"' "$lock" >/dev/null
grep -F 'source: "Paperclip image local bundle"' "$lock" >/dev/null
grep -F 'autoInstallKey: "kubernetes"' "$lock" >/dev/null
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
grep -F 'PAPERCLIP_K8S_INTERNAL_SERVICES' "$candidate" >/dev/null
grep -F 'PAPERCLIP_K8S_SERVER_ENDPOINT_LABELS' "$candidate" >/dev/null
grep -F 'name: paperclip-agent-litellm' "$candidate" >/dev/null
grep -F 'key: LITELLM_API_KEY' "$candidate" >/dev/null
grep -F 'io.cilium.k8s.namespace.labels.paperclip.io/managed-by: paperclip-k8s-plugin' k8s/applications/ai/paperclip/networkpolicy.yaml >/dev/null
grep -F 'paperclip.io/role: agent' k8s/applications/ai/paperclip/networkpolicy.yaml >/dev/null
grep -A2 -F 'port: "3100"' k8s/applications/ai/paperclip/networkpolicy.yaml | grep -F 'protocol: TCP' >/dev/null
grep -F 'ghcr.io/paperclipai/agent-runtime-opencode@sha256:349fc68e609998f1d9fc77f94208d50263368b49631f746a51f819917d9b0d2d' "$candidate" >/dev/null
adapter_registry_json="$(yq -r '.spec.env[] | select(.name == "PAPERCLIP_ADAPTERS") | .value' "$candidate")"
jq -e '
  length == 1 and
  .[0].adapterType == "opencode_local" and
  .[0].enabled == true and
  .[0].runtimeImage == "ghcr.io/paperclipai/agent-runtime-opencode@sha256:349fc68e609998f1d9fc77f94208d50263368b49631f746a51f819917d9b0d2d" and
  .[0].envKeys == ["LITELLM_API_KEY"] and
  .[0].probeCommand == ["opencode", "--version"] and
  (["github.com", "api.github.com"] - .[0].allowFqdns | length) == 0 and
  (.[0].allowFqdns | index("litellm.litellm.svc.cluster.local") | not) and
  (.[0].defaultEnv.OPENCODE_CONFIG_CONTENT | contains("http://litellm.litellm.svc.cluster.local:80/v1")) and
  (.[0].defaultEnv.OPENCODE_CONFIG_CONTENT | contains("{env:LITELLM_API_KEY}"))
' <<<"$adapter_registry_json" >/dev/null
test "$(yq -r '.spec.env[] | select(.name == "PAPERCLIP_K8S_INTERNAL_SERVICES") | .value' "$candidate")" = '[{"name":"litellm","namespace":"litellm","port":80}]'
test "$(yq -r '.spec.env[] | select(.name == "PAPERCLIP_K8S_SERVER_ENDPOINT_LABELS") | .value' "$candidate")" = '{"app.kubernetes.io/name":"paperclip","app.kubernetes.io/component":"server"}'
! grep -F 'LITELLM_MASTER_KEY' "$candidate" >/dev/null
! grep -F 'egressAllowFqdns:' "$candidate" >/dev/null
! grep -E '^        (inCluster|adapterType|podActivityDeadlineSec|jobTtlSecondsAfterFinished):' "$candidate" >/dev/null
! grep -F 'poc/kubernetes-execution' "$production" >/dev/null
! grep -F 'instance-candidate.yaml' "$production" >/dev/null
grep -F 'serviceAccountToken: false' docs/factory/H3_AGENT_IMAGE_MANIFEST_2026-10-09.yaml >/dev/null
grep -F 'PAPERCLIP_SERVER_RBAC_NOT_GRANTED' docs/factory/H3_AGENT_IMAGE_MANIFEST_2026-10-09.yaml >/dev/null
grep -F 'IMMUTABLE_IMAGE_RUNTIME_NOT_OBSERVED' docs/factory/H3_AGENT_IMAGE_MANIFEST_2026-10-09.yaml >/dev/null

kustomize build k8s/applications/ai/paperclip/poc/kubernetes-execution >/dev/null

printf '%s\n' 'PAPERCLIP_KUBERNETES_CANDIDATE_CONTRACT_TEST=PASS'
