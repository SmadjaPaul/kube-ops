#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
deployment="$root/k8s/applications/platform/mastra-factory/deployment.yaml"
network_policy="$root/k8s/applications/platform/mastra-factory/networkpolicy.yaml"
policy="$root/docs/operations/mastra-factory-supervised-promotion-v1.md"
readme="$root/k8s/applications/platform/mastra-factory/README.md"
command -v yq >/dev/null || { echo 'yq required' >&2; exit 127; }
yq -e '
  (.kind == "Deployment") and
  (.metadata.name == "mastra-factory") and
  (.metadata.namespace == "mastra-factory") and
  (.spec.replicas == 1) and
  (.spec.strategy.type == "Recreate") and
  (.metadata.annotations."factory-platform.dev/source-sha" |
    test("^[0-9a-f]{40}$")) and
  (.spec.template.spec.serviceAccountName == "mastra-factory") and
  (([.spec.template.spec.containers[] | select(.name == "factory")] | length) == 1) and
  ([.spec.template.spec.containers[] | select(.name == "factory") |
    .image | test("^ghcr\\.io/smadjapaul/mastra-factory@sha256:[0-9a-f]{64}$")] | all) and
  ([.spec.template.spec.containers[] | select(.name == "factory") |
    .readinessProbe.httpGet.path == "/health"] | all)
' "$deployment" >/dev/null
yq -e '
  (.kind == "CiliumNetworkPolicy") and
  (.metadata.name == "mastra-factory") and
  (.metadata.namespace == "mastra-factory") and
  (.spec.endpointSelector.matchLabels."app.kubernetes.io/name" == "mastra-factory")
' "$network_policy" >/dev/null
test -s "$policy"
grep -Fq 'single' "$policy"
grep -Fq 'GitOps' "$policy"
grep -Fq 'mastra-factory-supervised-promotion-v1.md' "$readme"
printf 'MASTRA_FACTORY_SUPERVISED_PROMOTION_CONTRACT=PASS\n'
