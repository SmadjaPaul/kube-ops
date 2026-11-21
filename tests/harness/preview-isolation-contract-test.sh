#!/usr/bin/env bash
# PLT-395: contrat d'isolation des previews (statique, aucun cluster).
# Refuse : whitelist AppProject non explicite ou admettant cilium/rbac/routes autres que HTTPRoute,
# ClusterSecretStore de prod sans exclusion des namespaces preview, Kyverno en fail-open,
# Gateway external ouverte aux namespaces preview, guardrails encore dans l'Application de la PR.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
command -v yq >/dev/null || { echo "ERROR: yq is required" >&2; exit 2; }
fail=0
bad() { echo "FAIL: $*" >&2; fail=1; }

proj=k8s/bootstrap/argocd-root/previews-project.yaml
pyq() { yq eval-all --no-doc "select(.kind == \"AppProject\" and .metadata.name == \"$1\") | $2" "$proj"; }

# 1. whitelist explicite
[[ "$(pyq previews '[.spec.namespaceResourceWhitelist[] | select((.group | test("[*]")) or (.kind | test("[*]")))] | length')" == 0 ]] || bad "previews: whitelist with wildcard"
allowed="$(pyq previews '.spec.namespaceResourceWhitelist[] | .group + "/" + .kind' | sort | tr '\n' ' ')"
for k in cilium.io networking.k8s.io rbac.authorization.k8s.io kyverno.io GRPCRoute TCPRoute TLSRoute UDPRoute ReferenceGrant; do
  [[ " $allowed" == *" $k/"* || " $allowed" == *"/$k "* ]] && bad "previews: whitelist admits $k"
done
for k in apps/Deployment apps/StatefulSet batch/Job batch/CronJob /Service /ConfigMap /Secret /PersistentVolumeClaim /ServiceAccount policy/PodDisruptionBudget gateway.networking.k8s.io/HTTPRoute external-secrets.io/ExternalSecret generators.external-secrets.io/Password; do
  [[ " $allowed" == *" $k "* ]] || bad "previews: whitelist lacks $k"
done
[[ "$(pyq previews '[.spec.clusterResourceWhitelist // []] | .[0] | length')" == 0 ]] || bad "previews: cluster resources admitted"
[[ "$(pyq previews-guardrails '.spec.namespaceResourceWhitelist | length')" == 3 ]] || bad "previews-guardrails: expected exactly 3 kinds"

# 2. guardrails: separate Application from main, absent from the PR Application
set_dir=k8s/bootstrap/argocd-root
[[ "$(yq '.spec.template.spec.sources | length' $set_dir/previews-applicationset.yaml)" == 1 ]] || bad "previews appset: guardrails source still in the PR Application"
[[ "$(yq '.spec.template.spec.project' $set_dir/previews-guardrails-applicationset.yaml)" == previews-guardrails ]] || bad "guardrails appset: wrong project"
[[ "$(yq '.spec.template.spec.source.targetRevision' $set_dir/previews-guardrails-applicationset.yaml)" == main ]] || bad "guardrails appset: not read from main"

# 3. ClusterSecretStores de prod
for f in k8s/infrastructure/controllers/external-secrets/doppler-store.yaml k8s/infrastructure/controllers/external-secrets/k8s-stores.yaml; do
  while IFS= read -r n; do
    ok="$(yq eval-all --no-doc "select(.kind == \"ClusterSecretStore\" and .metadata.name == \"$n\") | .spec.conditions[0].namespaceSelector.matchExpressions[] | select(.key == \"smadja.dev/preview\" and .operator == \"NotIn\" and .values[0] == \"true\") | .key" "$f")"
    [[ -n $ok ]] || bad "ClusterSecretStore $n: no condition excluding smadja.dev/preview=true"
  done < <(yq eval-all --no-doc 'select(.kind == "ClusterSecretStore") | .metadata.name' "$f")
done

# 4. Kyverno fail-closed, borne aux namespaces preview
pol=k8s/infrastructure/previews/admission-policy.yaml
[[ "$(yq '.spec.failurePolicy' $pol)" == Fail ]] || bad "preview-namespace-guard: failurePolicy is not Fail"
[[ "$(yq '.spec.matchConstraints.namespaceSelector.matchExpressions[0] | .key + .operator + .values[0]' $pol)" == "smadja.dev/previewIntrue" ]] || bad "preview-namespace-guard: not bounded to preview namespaces"

# 5. Gateway external fermee aux namespaces preview
gw=k8s/infrastructure/network/gateway/gw-external.yaml
[[ "$(yq '[.spec.listeners[].allowedRoutes.namespaces | select(.from != "Selector" or .selector.matchExpressions[0].key != "smadja.dev/preview" or .selector.matchExpressions[0].operator != "NotIn")] | length' $gw)" == 0 ]] || bad "Gateway external: a listener admits preview namespaces"

# 6. le patch HTTPRoute de l'ApplicationSet force Gateway/internal (tant que Access n'est pas prouve)
yq '.spec.template.spec.sources[0].kustomize.patches[] | select(.target.kind == "HTTPRoute") | .patch' $set_dir/previews-applicationset.yaml | grep -q 'name: internal' || bad "previews appset: HTTPRoute parent is not internal"

exit $fail
