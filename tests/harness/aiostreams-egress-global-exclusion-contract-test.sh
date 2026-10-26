#!/usr/bin/env bash
# PLT-121: stop broad Media policy bypassing AIOStreams' scoped egress.
# Static policy proof ONLY; negative runtime egress still required.
set -euo pipefail
global=k8s/infrastructure/network/policies/applications/media/media/allow-media-access.yaml
specific=k8s/applications/media/aiostreams/networkpolicy.yaml
deployment=k8s/applications/media/aiostreams/deployment.yaml
check() {
  actual="$(yq -r "$1" "$2")"
  if [[ "$actual" != "$3" ]]; then
    echo "AIOSTREAMS_EGRESS_STATIC=FAIL $1 expected=$3 actual=$actual" >&2
    exit 1
  fi
}
check '.spec.endpointSelector.matchExpressions | length' "$global" 1
check '.spec.endpointSelector.matchExpressions[0].key' "$global" 'app.kubernetes.io/name'
check '.spec.endpointSelector.matchExpressions[0].operator' "$global" NotIn
check '.spec.endpointSelector.matchExpressions[0].values | length' "$global" 2
check '.spec.endpointSelector.matchExpressions[0].values[0]' "$global" aiostreams
check '.spec.endpointSelector.matchExpressions[0].values[1]' "$global" rdt-client
check '.spec.template.metadata.labels."app.kubernetes.io/name"' "$deployment" aiostreams
check '.spec.endpointSelector.matchLabels."app.kubernetes.io/name"' "$specific" aiostreams
check '.spec.egress | length' "$specific" 5
check '.spec.egress[1].toFQDNs[0].matchName' "$specific" auth.smadja.dev
check '.spec.egress[1].toPorts[0].ports[0].port' "$specific" 443
check '.spec.egress[2].toCIDRSet[0].cidr' "$specific" 10.0.20.192/32
check '.spec.egress[2].toPorts[0].ports[0].port' "$specific" 443
check '.spec.egress[3].toEndpoints[0].matchLabels."k8s:io.kubernetes.pod.namespace"' "$specific" auth
check '.spec.egress[3].toEndpoints[0].matchLabels."app.kubernetes.io/name"' "$specific" authentik
check '.spec.egress[3].toEndpoints[0].matchLabels."app.kubernetes.io/component"' "$specific" server
check '.spec.egress[3].toPorts[0].ports[0].port' "$specific" 9000
# Strict native-video control-plane FQDN admission. Order and exact set
# intentionally contractual: no media CDN, wildcard FQDN or blanket world egress.
check '.spec.egress[4].toFQDNs | length' "$specific" 3
check '.spec.egress[4].toFQDNs[0].matchName' "$specific" api.torbox.app
check '.spec.egress[4].toFQDNs[1].matchName' "$specific" search-api.torbox.app
check '.spec.egress[4].toFQDNs[2].matchName' "$specific" v3-cinemeta.strem.io
check '.spec.egress[4].toPorts[0].ports | length' "$specific" 1
check '.spec.egress[4].toPorts[0].ports[0].port' "$specific" 443
check '.spec.egress[4].toPorts[0].ports[0].protocol' "$specific" TCP
# Match only active YAML fields, not explanatory comments containing "world:443".
! grep -Eq '^[[:space:]]*(-[[:space:]]+world([[:space:]]|$)|toEntities:|matchPattern:|toCIDR:|toCIDRSet:[[:space:]]*\[[^]]*0\.0\.0\.0/0)' "$specific"

! grep -Eq '^[[:space:]]*(-[[:space:]]*world([[:space:]]|$)|toEntities:|toCIDR:)' "$specific"
echo 'AIOSTREAMS_EGRESS_STATIC=PASS; RUNTIME_DENY=NOT_EXECUTED'
