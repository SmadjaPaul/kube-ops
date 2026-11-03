#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
deployment="$root/k8s/applications/platform/mastra-factory/deployment.yaml"
network_policy="$root/k8s/applications/platform/mastra-factory/networkpolicy.yaml"
policy="$root/docs/operations/mastra-factory-supervised-promotion-v1.md"
readme="$root/k8s/applications/platform/mastra-factory/README.md"
command -v yq >/dev/null || { echo 'yq required' >&2; exit 127; }
test "$(shasum -a 256 "$network_policy" | awk '{print $1}')" = \
  'b3edbafc2423e0d755f5bcb7ff84e284a609b13e35da6e93a974575f2aec59ea'
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
    .readinessProbe.httpGet.path == "/health"] | all) and
  ([.spec.template.spec.containers[] | select(.name == "factory") |
    .env[] | select(.name == "DATABASE_URL") |
    (.valueFrom.secretKeyRef.name == "mastra-factory-postgresql-app" and
     .valueFrom.secretKeyRef.key == "uri")] | length == 1) and
  ([.spec.template.spec.containers[] | select(.name == "factory") |
    .env[] | select(.name == "DATABASE_URL") |
    (.valueFrom.secretKeyRef.name == "mastra-factory-postgresql-app" and
     .valueFrom.secretKeyRef.key == "uri")] | all)
' "$deployment" >/dev/null
yq -e '
  (.kind == "CiliumNetworkPolicy") and
  (.metadata.name == "mastra-factory") and
  (.metadata.namespace == "mastra-factory") and
  (.spec.endpointSelector.matchLabels."app.kubernetes.io/name" == "mastra-factory") and
  ([.spec.ingress[].fromEntities[]] | length == 3) and
  ([.spec.ingress[].fromEntities[]] | contains(["host"])) and
  ([.spec.ingress[].fromEntities[]] | contains(["remote-node"])) and
  ([.spec.ingress[].fromEntities[]] | contains(["ingress"])) and
  ([.spec.ingress[]?.toPorts[]?.ports[]? |
    select(.port == "4111" and .protocol == "TCP")] | length > 0) and
  (.spec.egress | length == 11) and
  ([.spec.egress[]?.toFQDNs[]?.matchName] | contains(["fsn1.your-objectstorage.com"])) and
  ([.spec.egress[]?.toCIDRSet[]?.cidr] | length == 0) and
  ([.spec.egress[]? |
    select(
      ([.toEndpoints[]?.matchLabels? |
        select(."k8s:io.kubernetes.pod.namespace" == "mastra-factory" and
               ."cnpg.io/cluster" == "mastra-factory-postgresql")] | length > 0) and
      ([.toPorts[]?.ports[]? |
        select(.port == "5432" and .protocol == "TCP")] | length > 0)
    )] | length > 0)
' "$network_policy" >/dev/null
 yq -e '
  [.spec.template.spec.containers[] | select(.name == "factory") |
   .env[]? | select(.name | test("^(MASTRA_RESEARCH|RESEARCH_)"))] | length == 0
' "$deployment" >/dev/null
yq -e '
  [.spec.data[]? | select(.secretKey == "RESEARCH_LLM_API_KEY")] | length == 0
' "$root/k8s/applications/platform/mastra-factory/secrets.yaml" >/dev/null
test -s "$policy"
grep -Fq 'single' "$policy"
grep -Fq 'GitOps' "$policy"
grep -Fq 'mastra-factory-supervised-promotion-v1.md' "$readme"
printf 'MASTRA_FACTORY_SUPERVISED_PROMOTION_CONTRACT=PASS\n'
