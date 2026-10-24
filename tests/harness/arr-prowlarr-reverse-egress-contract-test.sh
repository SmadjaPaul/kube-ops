#!/usr/bin/env bash
set -euo pipefail

# PLT-118: Prowlarr application test can submit a temporary indexer test
# to the target Arr. The target must reach Prowlarr on the native pod
# port. Fail closed if source pods, destination or ports are broadened.
policy="k8s/infrastructure/network/policies/applications/media/media/allow-arr-to-prowlarr.yaml"
kustom="k8s/infrastructure/network/policies/applications/media/media/kustomization.yaml"
test -s "$policy"
grep -Fxq -- '- allow-arr-to-prowlarr.yaml' "$kustom"

check() {
  local expr="$1" expected="$2" actual
  actual="$(yq -r "$expr" "$policy")"
  if test "$actual" != "$expected"; then
    printf 'ARR_PROWLARR_REVERSE_EGRESS=FAIL expression=%s expected=%s actual=%s\n' "$expr" "$expected" "$actual" >&2
    exit 1
  fi
}
check '.kind' CiliumNetworkPolicy
check '.metadata.namespace' media
check '.metadata.name' arr-to-prowlarr
check '.spec.endpointSelector.matchLabels | length' 0
check '.spec.endpointSelector.matchExpressions | length' 1
check '.spec.endpointSelector.matchExpressions[0].key' app
check '.spec.endpointSelector.matchExpressions[0].operator' In
check '.spec.endpointSelector.matchExpressions[0].values | length' 2
check '.spec.endpointSelector.matchExpressions[0].values[0]' radarr
check '.spec.endpointSelector.matchExpressions[0].values[1]' sonarr
check '.spec.egress | length' 1
check '.spec.ingress | length' 0
check '.spec.egress[0].toEndpoints | length' 1
check '.spec.egress[0].toEndpoints[0].matchLabels.app' prowlarr
check '.spec.egress[0].toEndpoints[0].matchLabels."k8s:io.kubernetes.pod.namespace"' media
check '.spec.egress[0].toPorts | length' 1
check '.spec.egress[0].toPorts[0].ports | length' 1
check '.spec.egress[0].toPorts[0].ports[0].port' 9696
check '.spec.egress[0].toPorts[0].ports[0].protocol' TCP

# Reject extraneous egress selectors or ingress in this narrowly-scoped file.
for forbidden in toCIDR toCIDRSet toEntities toFQDNs toServices fromEndpoints fromEntities ingress; do
  if grep -Eq "^[[:space:]]+$forbidden:" "$policy"; then
    echo "ARR_PROWLARR_REVERSE_EGRESS=FAIL unexpected $forbidden" >&2
    exit 1
  fi
done
echo "ARR_PROWLARR_REVERSE_EGRESS=PASS (STATIC_ONLY)"
