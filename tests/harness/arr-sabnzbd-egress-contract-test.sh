#!/usr/bin/env bash
set -euo pipefail

# PLT-118: only Radarr and Sonarr may reach the SABnzbd native API port.
policy="k8s/infrastructure/network/policies/applications/media/media/allow-arr-to-sabnzbd.yaml"
kustom="k8s/infrastructure/network/policies/applications/media/media/kustomization.yaml"
test -s "$policy"
grep -Fxq -- '- allow-arr-to-sabnzbd.yaml' "$kustom"

check() {
  local expression="$1" expected="$2" actual
  actual="$(yq -r "$expression" "$policy")"
  if test "$actual" != "$expected"; then
    printf 'ARR_SABNZBD_EGRESS=FAIL expression=%s expected=%s actual=%s\n' "$expression" "$expected" "$actual" >&2
    exit 1
  fi
}

check '.kind' CiliumNetworkPolicy
check '.metadata.namespace' media
check '.metadata.name' arr-to-sabnzbd
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
check '.spec.egress[0].toEndpoints[0].matchLabels.app' sabnzbd
check '.spec.egress[0].toEndpoints[0].matchLabels."k8s:io.kubernetes.pod.namespace"' media
check '.spec.egress[0].toPorts | length' 1
check '.spec.egress[0].toPorts[0].ports | length' 1
check '.spec.egress[0].toPorts[0].ports[0].port' 8080
check '.spec.egress[0].toPorts[0].ports[0].protocol' TCP

for forbidden in toCIDR toCIDRSet toEntities toFQDNs toServices toPortsL7 fromEndpoints fromEntities ingress; do
  if grep -Eq "^[[:space:]]+$forbidden:" "$policy"; then
    echo "ARR_SABNZBD_EGRESS=FAIL unexpected $forbidden" >&2
    exit 1
  fi
done
echo "ARR_SABNZBD_EGRESS=PASS (STATIC_ONLY)"
