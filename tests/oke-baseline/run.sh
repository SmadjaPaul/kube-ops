#!/usr/bin/env bash
# Tests statiques de la baseline reseau d'OKE (PLT-384), sans cluster ni secret :
# rendu kustomize de cilium/, baseline/ et argocd-root/, kubeconform (kinds natifs ; les kinds cilium.io
# n'ont pas de schema ici), valeurs de chaining attendues, quotas rendus == expected-quotas.tsv.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cluster="$root/k8s/clusters/oracle-a1"
for t in kustomize kubeconform yq; do command -v "$t" >/dev/null || { echo "FAIL: $t requis" >&2; exit 2; }; done
out="$(mktemp -d)"
trap 'rm -rf "$out" "$cluster/cilium/charts"' EXIT

kustomize build --enable-helm "$cluster/cilium" >"$out/cilium.yaml"
kustomize build "$cluster/baseline" >"$out/baseline.yaml"
kustomize build "$cluster/argocd-root" >"$out/argocd-root.yaml"
kubeconform -summary -strict -ignore-missing-schemas "$out/cilium.yaml" "$out/baseline.yaml"

bad=0
cfg() { yq ea -r "select(.kind == \"ConfigMap\" and .metadata.name == \"cilium-config\") | .data[\"$1\"]" "$out/cilium.yaml"; }
expect() { local got; got="$(cfg "$1")"; if [[ "$got" == "$2" ]]; then echo "PASS: cilium-config $1=$2"; else echo "FAIL: cilium-config $1 attendu '$2' lu '$got'"; bad=1; fi; }
expect cni-chaining-mode generic-veth
expect cni-chaining-target oci
expect cni-exclusive false
expect routing-mode native
expect enable-ipv4-masquerade false
expect kube-proxy-replacement false

for n in deny-imds allow-egress-unisolated; do
  if [[ "$(yq ea -r "select(.kind == \"CiliumClusterwideNetworkPolicy\" and .metadata.name == \"$n\") | .metadata.name" "$out/baseline.yaml")" == "$n" ]]; then echo "PASS: CCNP $n rendue"; else echo "FAIL: CCNP $n absente"; bad=1; fi
done
if [[ "$(yq ea -r 'select(.metadata.name == "deny-imds") | .spec.egressDeny[0].toCIDRSet[0].cidr' "$out/baseline.yaml")" == 169.254.169.254/32 ]]; then echo "PASS: deny-imds vise 169.254.169.254/32"; else echo "FAIL: deny-imds ne vise pas l'IMDS"; bad=1; fi

for d in cilium baseline; do
  if grep -qx "          - path: k8s/clusters/oracle-a1/$d" "$cluster/argocd-root/infrastructure-applicationset.yaml"; then echo "PASS: $d dans l'ApplicationSet infrastructure"; else echo "FAIL: $d absent de l'ApplicationSet infrastructure"; bad=1; fi
done

while IFS=$'\t' read -r ns rcpu rmem lmem pods; do
  [[ -z "$ns" || "$ns" == \#* ]] && continue
  got="$(yq ea -r "select(.kind == \"ResourceQuota\" and .metadata.namespace == \"$ns\") | .spec.hard | [.[\"requests.cpu\"], .[\"requests.memory\"], .[\"limits.memory\"], .pods] | join(\"/\")" "$out/baseline.yaml")"
  if [[ "$got" == "$rcpu/$rmem/$lmem/$pods" ]]; then echo "PASS: quota $ns $got"; else echo "FAIL: quota $ns attendu $rcpu/$rmem/$lmem/$pods lu '$got'"; bad=1; fi
done <"$root/tests/oke-baseline/expected-quotas.tsv"

[[ $bad -eq 0 ]] && echo "STATIC=PASS"
[[ $bad -eq 0 ]]
