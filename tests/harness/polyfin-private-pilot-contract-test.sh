#!/usr/bin/env bash
# Static gate for a NOT-ADMITTED Polyfin family pilot.
set -euo pipefail
root=k8s/applications/media/polyfin
global=k8s/infrastructure/network/policies/applications/media/media/allow-media-access.yaml

# Activation requires a separate reviewed PR.
if grep -Eq '^[[:space:]]*-[[:space:]]+polyfin[[:space:]]*$' k8s/applications/media/kustomization.yaml; then
  echo 'POLYFIN_STATIC=FAIL unexpected activation' >&2; exit 1
fi

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
eq '.spec.template.spec.containers[0].image' "$root/deployment.yaml" 'ghcr.io/moodiness/polyfin:0.50.0@sha256:b544e75ae8f028214d6dd1ea7fd55094b75211c081a41d7c6afe0917637cc719'
! grep -Eq '^[[:space:]]*-[[:space:]]+name:[[:space:]]+external[[:space:]]*$' "$root/http-route.yaml"
! grep -Eq '^[[:space:]]*toEntities:|^[[:space:]]*matchPattern:|^[[:space:]]*toCIDR:|0\.0\.0\.0/0|^[[:space:]]*-[[:space:]]+world' "$root/networkpolicy.yaml"
echo 'POLYFIN_STATIC=PASS; RUNTIME=NOT_EXECUTED; OCI_SECURITY=NOT_EXECUTED'
