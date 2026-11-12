#!/usr/bin/env bash
# Static gate for the explicitly admitted private Polyfin family pilot.
set -euo pipefail
root=k8s/applications/media/polyfin
global=k8s/infrastructure/network/policies/applications/media/media/allow-media-access.yaml
tmpfindings="$(mktemp /tmp/polyfin-contract-findings.XXXXXX)"
trap 'rm -f "$tmpfindings"' EXIT

grep -Eq '^[[:space:]]*-[[:space:]]+polyfin[[:space:]]*$' k8s/applications/media/kustomization.yaml || {
  echo 'POLYFIN_STATIC=FAIL Polyfin is not activated in the reviewed pilot branch' >&2
  exit 1
}

eq() {
  # Read the complete yq stream before selecting its first value. Piping to
  # head under pipefail can terminate yq with SIGPIPE (exit 141) on CI when
  # the expression emits more than one document.
  values="$(yq -r "$1" "$2")"
  got="${values%%$'\n'*}"
  [[ "$got" == "$3" ]] || { echo "POLYFIN_STATIC=FAIL $2 $1 got=$got want=$3" >&2; exit 1; }
}
if grep -Eq '^[[:space:]]*-[[:space:]]+http-route\.yaml[[:space:]]*$' "$root/kustomization.yaml"; then
  echo 'POLYFIN_STATIC=FAIL historical Polyfin http-route.yaml must stay out of the kustomization' >&2
  exit 1
fi
jq -e '.perimeter.hostname == null and .perimeter.routeStatus == "disabled"' \
  .github/polyfin/private-pilot-admission.json >/dev/null
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
eq '.spec.template.spec.containers[0].image' "$root/deployment.yaml" 'ghcr.io/moodiness/polyfin:0.61.1@sha256:1e55720ea21bca9448ddbdd80a21251622d21448ee2e31974ad18ae2a9f6c975'
[[ "$(jq -r '.image.repository + ":" + .image.tag + "@" + .image.digest' .github/polyfin/private-pilot-admission.json)" == "ghcr.io/moodiness/polyfin:0.61.1@sha256:1e55720ea21bca9448ddbdd80a21251622d21448ee2e31974ad18ae2a9f6c975" ]] || {
  echo 'POLYFIN_STATIC=FAIL admission digest mismatch' >&2; exit 1
}
[[ "$(jq -r '.approval.expiresAt' .github/polyfin/private-pilot-admission.json)" == '2026-12-05T23:59:59Z' ]] || {
  echo 'POLYFIN_STATIC=FAIL admission expiry mismatch' >&2; exit 1
}
[[ "$(jq '[.acceptedFindings[]] | length' .github/polyfin/private-pilot-admission.json)" == '25' ]] || {
  echo 'POLYFIN_STATIC=FAIL expected 25 tracked official-image findings' >&2; exit 1
}
[[ "$(jq '[.acceptedFindings[] | select(.id == "CVE-2026-6653")] | length' .github/polyfin/private-pilot-admission.json)" == '1' ]] || {
  echo 'POLYFIN_STATIC=FAIL CRITICAL CVE-2026-6653 must remain separate' >&2; exit 1
}
if grep -Eq '^[[:space:]]*-[[:space:]]+name:[[:space:]]+external[[:space:]]*$' "$root/http-route.yaml"; then
  echo 'POLYFIN_STATIC=FAIL Polyfin route must not attach to the external Gateway' >&2
  exit 1
fi
if grep -Eq '^[[:space:]]*toEntities:|^[[:space:]]*matchPattern:|^[[:space:]]*toCIDR:|0\.0\.0\.0/0|^[[:space:]]*-[[:space:]]+world' "$root/networkpolicy.yaml"; then
  echo 'POLYFIN_STATIC=FAIL Polyfin network policy must not carry world/CIDR/entity egress' >&2
  exit 1
fi
jq -r '.acceptedFindings[] | "target\t" + .id + "\tpkg\t1\t" + (if .disposition == "fixed-required" then "1.0" else "UNFIXED" end) + "\tHIGH\t" + (if .disposition == "fixed-required" then "fixed" else "affected" end)' .github/polyfin/private-pilot-admission.json > "$tmpfindings"
bash scripts/polyfin-admission-check.sh \
  --image 'ghcr.io/moodiness/polyfin:0.61.1@sha256:1e55720ea21bca9448ddbdd80a21251622d21448ee2e31974ad18ae2a9f6c975' \
  --findings "$tmpfindings" \
  --policy .github/polyfin/private-pilot-admission.json >/dev/null
echo 'POLYFIN_STATIC=PASS; PRIVATE_PILOT=ADMITTED_UNTIL_2026-12-05; RUNTIME=PENDING'
