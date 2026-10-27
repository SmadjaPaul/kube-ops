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
  got="$(yq -r "$1" "$2")"
  [[ "$got" == "$3" ]] || { echo "POLYFIN_STATIC=FAIL $2 $1 got=$got want=$3" >&2; exit 1; }
}
eq '.spec.parentRefs | length' "$root/http-route.yaml" '1'
eq '.spec.parentRefs[0].name' "$root/http-route.yaml" internal
eq '.spec.hostnames[0]' "$root/http-route.yaml" tv.smadja.dev
eq '.spec.template.spec.automountServiceAccountToken' "$root/deployment.yaml" false
eq '.spec.template.spec.containers[0].readinessProbe.httpGet.path' "$root/deployment.yaml" /readyz
eq '.spec.template.spec.containers[0].livenessProbe.httpGet.path' "$root/deployment.yaml" /healthz
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
eq '.spec.egress[2].toCIDRSet[0].cidr' "$root/networkpolicy.yaml" 10.0.20.192/32
eq '.spec.egress[2].toPorts[0].ports[0].port' "$root/networkpolicy.yaml" 443
eq '.spec.template.spec.containers[0].image' "$root/deployment.yaml" 'ghcr.io/smadjapaul/polyfin-downstream:0.50.0-patched-01dfcfa30e78-run40564826453-attempt1@sha256:0b05483c047bb904dfcb8c4e893c528223833c7903ae8f193b4f31475ad5eaf3'
[[ "$(jq -r '.image.repository + ":" + .image.tag + "@" + .image.digest' .github/polyfin/private-pilot-admission.json)" == "ghcr.io/smadjapaul/polyfin-downstream:0.50.0-patched-01dfcfa30e78-run40564826453-attempt1@sha256:0b05483c047bb904dfcb8c4e893c528223833c7903ae8f193b4f31475ad5eaf3" ]] || {
  echo 'POLYFIN_STATIC=FAIL admission digest mismatch' >&2; exit 1
}
[[ "$(jq -r '.approval.expiresAt' .github/polyfin/private-pilot-admission.json)" == '2026-11-26T23:59:59Z' ]] || {
  echo 'POLYFIN_STATIC=FAIL admission expiry mismatch' >&2; exit 1
}
[[ "$(jq '[.acceptedFindings[]] | length' .github/polyfin/private-pilot-admission.json)" == '17' ]] || {
  echo 'POLYFIN_STATIC=FAIL expected 17 individually tracked residual CVEs' >&2; exit 1
}
[[ "$(jq '[.acceptedFindings[] | select(.id == "CVE-2026-6653")] | length' .github/polyfin/private-pilot-admission.json)" == '1' ]] || {
  echo 'POLYFIN_STATIC=FAIL CRITICAL CVE-2026-6653 must remain separate' >&2; exit 1
}
! grep -Eq '^[[:space:]]*-[[:space:]]+name:[[:space:]]+external[[:space:]]*$' "$root/http-route.yaml"
! grep -Eq '^[[:space:]]*toEntities:|^[[:space:]]*matchPattern:|^[[:space:]]*toCIDR:|0\.0\.0\.0/0|^[[:space:]]*-[[:space:]]+world' "$root/networkpolicy.yaml"
jq -r '.acceptedFindings[].id | "target\t" + . + "\tpkg\t1\tUNFIXED\tHIGH\taffected"' .github/polyfin/private-pilot-admission.json > "$tmpfindings"
bash scripts/polyfin-admission-check.sh \
  --image 'ghcr.io/smadjapaul/polyfin-downstream:0.50.0-patched-01dfcfa30e78-run40564826453-attempt1@sha256:0b05483c047bb904dfcb8c4e893c528223833c7903ae8f193b4f31475ad5eaf3' \
  --findings "$tmpfindings" \
  --policy .github/polyfin/private-pilot-admission.json >/dev/null
echo 'POLYFIN_STATIC=PASS; PRIVATE_PILOT=ADMITTED_UNTIL_2026-11-26; RUNTIME=PENDING'
