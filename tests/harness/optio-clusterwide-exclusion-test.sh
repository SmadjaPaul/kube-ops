#!/usr/bin/env bash
# PLT-339 (MANDAT 30): the clusterwide audit baseline `clusterwide-dns-kubeapi` opens 10.0.0.0/8 and
# kube-apiserver to every endpoint it selects. Optio agent pods (namespace optio) must never inherit
# it. This test fails if the namespace optio is no longer excluded from its endpointSelector.
# Read-only, no cluster access. Self-test: a copy without the exclusion must be refused.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
policy="$root/k8s/infrastructure/network/policies/clusterwide/allow-cluster-essentials.yaml"
command -v yq >/dev/null || { echo "OPTIO_CLUSTERWIDE_EXCLUSION=BLOCKED missing yq"; exit 2; }

excluded() { # excluded FILE -> 0 when namespace optio is excluded by a NotIn expression
  yq -e '
    select(.kind == "CiliumClusterwideNetworkPolicy" and .metadata.name == "clusterwide-dns-kubeapi")
    | .spec.endpointSelector.matchExpressions[]
    | select(.key == "k8s:io.kubernetes.pod.namespace" and .operator == "NotIn")
    | .values[] | select(. == "optio")' "$1" >/dev/null 2>&1
}

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
yq 'del(.spec.endpointSelector.matchExpressions[] | select(.key == "k8s:io.kubernetes.pod.namespace"))' "$policy" > "$tmp/neg.yaml"
if excluded "$tmp/neg.yaml"; then
  echo "OPTIO_CLUSTERWIDE_EXCLUSION=FAIL self-test: a policy without the exclusion was accepted"; exit 1
fi
if ! excluded "$policy"; then
  echo "OPTIO_CLUSTERWIDE_EXCLUSION=FAIL namespace optio is not excluded from clusterwide-dns-kubeapi ($policy)"; exit 1
fi
echo "OPTIO_CLUSTERWIDE_EXCLUSION=PASS"
