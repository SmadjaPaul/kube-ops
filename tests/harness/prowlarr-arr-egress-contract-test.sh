#!/usr/bin/env bash
set -euo pipefail

# PLT-118 regression: policy must not admit other media pods, indexers,
# download clients, world egress, or change the incoming Arr API surface.
policy="k8s/infrastructure/network/policies/applications/media/media/allow-prowlarr-to-arr.yaml"
kustom="k8s/infrastructure/network/policies/applications/media/media/kustomization.yaml"
test -s "$policy"
test -s "$kustom"
grep -Fxq -- '- allow-prowlarr-to-arr.yaml' "$kustom"

check() {
  local expression="$1" expected="$2"
  local actual
  actual="$(yq -r "$expression" "$policy")"
  if test "$actual" != "$expected"; then
    printf 'PROWLARR_ARR_EGRESS_CONTRACT=FAIL %s expected=%s got=%s\n' "$expression" "$expected" "$actual" >&2
    exit 1
  fi
}

check '.kind' CiliumNetworkPolicy
check '.metadata.namespace' media
check '.metadata.name' prowlarr-to-arr
check '.spec.endpointSelector.matchLabels.app' prowlarr
check '.spec.egress | length' 2
check '.spec.ingress | length' 0

for spec in '0:radarr:7878' '1:sonarr:8989'; do
  IFS=: read -r idx app port <<< "$spec"
  check ".spec.egress[$idx].toEndpoints | length" 1
  check ".spec.egress[$idx].toEndpoints[0].matchLabels.app" "$app"
  check ".spec.egress[$idx].toEndpoints[0].matchLabels.\"k8s:io.kubernetes.pod.namespace\"" media
  check ".spec.egress[$idx].toPorts | length" 1
  check ".spec.egress[$idx].toPorts[0].ports | length" 1
  check ".spec.egress[$idx].toPorts[0].ports[0].port" "$port"
  check ".spec.egress[$idx].toPorts[0].ports[0].protocol" TCP
done

# No additional destinations or ports hidden in extra rule properties.
if grep -Eq '^([[:space:]]*)(toEntities|toCIDR|toCIDRSet|toFQDNs|toServices|toPortsL7|ingress):' "$policy"; then
  echo "PROWLARR_ARR_EGRESS_CONTRACT=FAIL broad selector" >&2
  exit 1
fi

echo "PROWLARR_ARR_EGRESS_CONTRACT=PASS (STATIC_ONLY)"
