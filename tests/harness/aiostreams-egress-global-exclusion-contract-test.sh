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
check '.spec.endpointSelector.matchExpressions[0].values | length' "$global" 1
check '.spec.endpointSelector.matchExpressions[0].values[0]' "$global" aiostreams
check '.spec.template.metadata.labels."app.kubernetes.io/name"' "$deployment" aiostreams
check '.spec.endpointSelector.matchLabels."app.kubernetes.io/name"' "$specific" aiostreams
check '.spec.egress | length' "$specific" 2
check '.spec.egress[1].toFQDNs[0].matchName' "$specific" auth.smadja.dev
check '.spec.egress[1].toPorts[0].ports[0].port' "$specific" 443
! grep -Eq '^[[:space:]]*(-[[:space:]]*world([[:space:]]|$)|toEntities:|toCIDR:)' "$specific"
echo 'AIOSTREAMS_EGRESS_STATIC=PASS; RUNTIME_DENY=NOT_EXECUTED'
