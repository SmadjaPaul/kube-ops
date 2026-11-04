#!/usr/bin/env bash
# Static gate for the explicitly admitted private Polyfin family pilot.
set -euo pipefail
root=k8s/applications/media/polyfin
overlay=k8s/optional/polyfin-v060
policy=.github/polyfin/private-pilot-admission-v060.json
global=k8s/infrastructure/network/policies/applications/media/media/allow-media-access.yaml
tmpfindings="$(mktemp /tmp/polyfin-contract-findings.XXXXXX)"
trap 'rm -f "$tmpfindings"' EXIT

grep -Eq '^[[:space:]]*-[[:space:]]+\.\./\.\./optional/polyfin-v060[[:space:]]*$' k8s/applications/media/kustomization.yaml || {
  echo 'POLYFIN_STATIC=FAIL Polyfin v0.60 overlay is not activated in the reviewed pilot branch' >&2
  exit 1
}

eq() {
  got="$(yq -r "$1" "$2" | head -n 1)"
  [[ "$got" == "$3" ]] || { echo "POLYFIN_STATIC=FAIL $2 $1 got=$got want=$3" >&2; exit 1; }
}
! grep -Eq '^[[:space:]]*-[[:space:]]+http-route\.yaml[[:space:]]*$' "$root/kustomization.yaml"
jq -e '.securityTier == "T2" and .perimeter.publicExposure == false and .perimeter.externalRoute == false' "$policy" >/dev/null
eq '.spec.template.spec.automountServiceAccountToken' "$root/deployment.yaml" false
# The existing Cilium egress permits only 10.0.20.192:443 for AIOStreams.
# Bind this hostname inside Polyfin alone; do not use public Cloudflare AAAA.
eq '.spec.template.spec.hostAliases | length' "$root/deployment.yaml" 1
eq '.spec.template.spec.hostAliases[0].ip' "$root/deployment.yaml" 10.0.20.192
eq '.spec.template.spec.hostAliases[0].hostnames | length' "$root/deployment.yaml" 1
eq '.spec.template.spec.hostAliases[0].hostnames[0]' "$root/deployment.yaml" aiostreams.smadja.dev
eq '.spec.template.spec.containers[0].readinessProbe.httpGet.path' "$root/deployment.yaml" /readyz
eq '.spec.template.spec.containers[0].livenessProbe.httpGet.path' "$root/deployment.yaml" /healthz
eq '.spec.template.spec.containers[0].resources.requests.memory' "$root/deployment.yaml" 512Mi
eq '.spec.template.spec.containers[0].resources.limits.memory' "$root/deployment.yaml" 2Gi
eq '.spec.endpointSelector.matchLabels."app.kubernetes.io/name"' "$root/networkpolicy.yaml" polyfin
eq '.spec.egress | length' "$root/networkpolicy.yaml" 4
eq '.spec.endpointSelector.matchExpressions[0].values | length' "$global" 3
eq '.spec.endpointSelector.matchExpressions[0].values[2]' "$global" polyfin
eq '.spec.data[0].remoteRef.key' "$root/external-secret.yaml" APP_POLYFIN_SECRET_KEY
eq '.spec.bootstrap.initdb.database' "$root/cluster.yaml" polyfin
eq '.spec.storage.storageClass' "$root/cluster.yaml" longhorn-fast
eq '.spec.plugins | length' "$root/cluster.yaml" 1
eq '.spec.plugins[0].name' "$root/cluster.yaml" barman-cloud.cloudnative-pg.io
eq '.spec.plugins[0].isWALArchiver' "$root/cluster.yaml" true
eq '.spec.plugins[0].parameters.barmanObjectName' "$root/cluster.yaml" polyfin-hetzner-store
eq '.spec.egress[1].toEndpoints[0].matchLabels."cnpg.io/cluster"' "$root/networkpolicy.yaml" polyfin-db
eq '.spec.egress[2].toCIDRSet[0].cidr' "$root/networkpolicy.yaml" 10.0.20.192/32
eq '.spec.egress[2].toPorts[0].ports[0].port' "$root/networkpolicy.yaml" 443
yq -r '.spec.egress[].toFQDNs[]?.matchName' "$root/networkpolicy.yaml" | grep -Fx raw.githubusercontent.com >/dev/null || {
  echo 'POLYFIN_STATIC=FAIL anime mapping dependency is not explicitly allowlisted' >&2; exit 1
}
yq -r 'select(.metadata.name == "polyfin-db-access") | .spec.endpointSelector.matchLabels."cnpg.io/cluster"' "$root/networkpolicy.yaml" | grep -Fx polyfin-db >/dev/null || {
  echo 'POLYFIN_STATIC=FAIL CNPG ingress policy target mismatch' >&2; exit 1
}
yq -r 'select(.metadata.name == "polyfin-db-access") | .spec.ingress[0].fromEndpoints[0].matchLabels."app.kubernetes.io/name"' "$root/networkpolicy.yaml" | grep -Fx polyfin >/dev/null || {
  echo 'POLYFIN_STATIC=FAIL CNPG ingress source mismatch' >&2; exit 1
}
yq -r 'select(.metadata.name == "polyfin-db-access") | .spec.ingress[0].toPorts[0].ports[0].port' "$root/networkpolicy.yaml" | grep -Fx 5432 >/dev/null || {
  echo 'POLYFIN_STATIC=FAIL CNPG ingress port mismatch' >&2; exit 1
}
yq -r 'select(.metadata.name == "polyfin-db-access") | .spec.ingress[1].fromEndpoints[0].matchLabels."app.kubernetes.io/name"' "$root/networkpolicy.yaml" | grep -Fx cloudnative-pg >/dev/null || {
  echo 'POLYFIN_STATIC=FAIL CNPG operator source mismatch' >&2; exit 1
}
yq -r 'select(.metadata.name == "polyfin-db-access") | .spec.ingress[1].toPorts[0].ports[0].port' "$root/networkpolicy.yaml" | grep -Fx 8000 >/dev/null || {
  echo 'POLYFIN_STATIC=FAIL CNPG status port mismatch' >&2; exit 1
}
overlay_image="$(kustomize build "$overlay" | yq -r 'select(.kind == "Deployment" and .metadata.name == "polyfin") | .spec.template.spec.containers[0].image')"
expected_image="$(jq -er '.image.repository + ":" + .image.tag + "@" + .image.digest' "$policy")"
[[ "$overlay_image" == "$expected_image" ]] || { echo 'POLYFIN_STATIC=FAIL overlay image mismatch' >&2; exit 1; }
! grep -Eq '^[[:space:]]*-[[:space:]]+name:[[:space:]]+external[[:space:]]*$' "$root/http-route.yaml"
! grep -Eq '^[[:space:]]*toEntities:|^[[:space:]]*matchPattern:|^[[:space:]]*toCIDR:|0\.0\.0\.0/0|^[[:space:]]*-[[:space:]]+world' "$root/networkpolicy.yaml"
jq -r '.riskRegister[] | select(.disposition != "fixed-required") | [.id, .severity] | @tsv' "$policy" | awk -F '\t' '{print "target\t" $1 "\tpkg\t1\tUNFIXED\t" $2 "\taffected"}' > "$tmpfindings"
bash scripts/polyfin-admission-check.sh \
  --image "$expected_image" \
  --findings "$tmpfindings" \
  --policy "$policy" >/dev/null
echo 'POLYFIN_STATIC=PASS; PRIVATE_PILOT_V060=T2_ADMITTED; RUNTIME=QUALIFIED_ISOLATED'
