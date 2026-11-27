#!/usr/bin/env bash
# PLT-567 : contrat du scale-to-zero KEDA de l'application opencode (statique, aucun cluster).
#
# opencode est servi par le reverse proxy du http-add-on KEDA (namespace keda) :
#   - la HTTPRoute pointe le proxy (port 8080) au lieu du Service de l'application ;
#   - l'InterceptorRoute declare la cible (Service opencode-web-service, port 5003),
#     l'hote et le budget de demarrage a froid (readiness 120 s) ;
#   - le ScaledObject possede le nombre de replicas (min 0, max 1, cooldown 300 s) ;
#   - le Deployment ne fige plus `replicas` : KEDA ecrit ce champ, Argo ne doit pas le contrdire ;
#   - le ReferenceGrant qui autorise la reference inter-namespace vit dans le namespace keda
#     (le projet Argo `apps` interdit ReferenceGrant dans une application) ;
#   - la CiliumNetworkPolicy de l'application laisse le proxy keda joindre le port 5003.
#
# Lecture seule : aucun appel reseau, aucun acces cluster, aucune ecriture dans le depot
# (mktemp pour le rendu).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

app=k8s/applications/ai/opencode
keda=k8s/infrastructure/controllers/keda
bash_list=scripts/check-bash-tests.list

fail() {
  echo "OPENCODE_KEDA_SCALE_TO_ZERO=FAIL $*" >&2
  exit 1
}

command -v yq >/dev/null || fail "reason=yq_required"
command -v kustomize >/dev/null || fail "reason=kustomize_required"
command -v jq >/dev/null || fail "reason=jq_required"

# Le test doit tourner dans la porte locale canonique.
grep -qx 'tests/harness/opencode-keda-scale-to-zero-contract-test.sh' "$bash_list" ||
  fail "reason=not_listed file=$bash_list"

# one <kind> <expression> <file> : la valeur doit etre unique dans le fichier.
one() {
  local kind=$1 expr=$2 file=$3 value
  value="$(yq eval-all --no-doc "select(.kind == '$kind') | $expr" "$file")"
  [[ "$(printf '%s\n' "$value" | grep -c . || true)" == 1 ]] || fail "reason=expected_one_$kind file=$file"
  printf '%s\n' "$value"
}

# ------------------------------------------------------------------ 1. InterceptorRoute + ScaledObject
[[ -f $app/interceptorroute.yaml ]] || fail "reason=missing_interceptorroute path=$app/interceptorroute.yaml"
grep -Eq '^[[:space:]]*-[[:space:]]*interceptorroute\.yaml[[:space:]]*$' "$app/kustomization.yaml" ||
  fail "reason=interceptorroute_not_rendered file=$app/kustomization.yaml"

ir_service="$(one InterceptorRoute '.spec.target.service' "$app/interceptorroute.yaml")"
[[ "$ir_service" == opencode-web-service ]] || fail "reason=interceptor_target_service value=$ir_service"
ir_port="$(one InterceptorRoute '.spec.target.port' "$app/interceptorroute.yaml")"
[[ "$ir_port" == 5003 ]] || fail "reason=interceptor_target_port value=$ir_port"
ir_host="$(one InterceptorRoute '.spec.rules[0].hosts[0]' "$app/interceptorroute.yaml")"
[[ "$ir_host" == opencode.smadja.dev ]] || fail "reason=interceptor_host value=$ir_host"
ir_readiness="$(one InterceptorRoute '.spec.timeouts.readiness' "$app/interceptorroute.yaml")"
[[ "$ir_readiness" == 120s ]] || fail "reason=interceptor_readiness value=$ir_readiness"

so_target="$(one ScaledObject '.spec.scaleTargetRef.kind + "/" + .spec.scaleTargetRef.name' "$app/interceptorroute.yaml")"
[[ "$so_target" == Deployment/opencode-web ]] || fail "reason=scaledobject_target value=$so_target"
so_min="$(one ScaledObject '.spec.minReplicaCount' "$app/interceptorroute.yaml")"
[[ "$so_min" == 0 ]] || fail "reason=scaledobject_min_replicas value=$so_min"
so_max="$(one ScaledObject '.spec.maxReplicaCount' "$app/interceptorroute.yaml")"
[[ "$so_max" == 1 ]] || fail "reason=scaledobject_max_replicas value=$so_max"
so_cooldown="$(one ScaledObject '.spec.cooldownPeriod' "$app/interceptorroute.yaml")"
[[ "$so_cooldown" == 300 ]] || fail "reason=scaledobject_cooldown value=$so_cooldown"
so_type="$(one ScaledObject '.spec.triggers[0].type' "$app/interceptorroute.yaml")"
[[ "$so_type" == external-push ]] || fail "reason=scaledobject_trigger_type value=$so_type"
so_scaler="$(one ScaledObject '.spec.triggers[0].metadata.scalerAddress' "$app/interceptorroute.yaml")"
[[ "$so_scaler" == keda-add-ons-http-external-scaler.keda:9090 ]] || fail "reason=scaledobject_scaler value=$so_scaler"
so_route="$(one ScaledObject '.spec.triggers[0].metadata.interceptorRoute' "$app/interceptorroute.yaml")"
[[ "$so_route" == opencode ]] || fail "reason=scaledobject_interceptor_route value=$so_route"

# ------------------------------------------------------------------ 2. le Deployment ne fige plus les replicas
replicas="$(yq '.spec.replicas' "$app/deployment.yaml")"
[[ "$replicas" == "null" || -z "$replicas" ]] || fail "reason=deployment_pins_replicas value=$replicas"

# ------------------------------------------------------------------ 3. la HTTPRoute pointe le proxy KEDA (toutes les regles)
rules="$(one HTTPRoute '.spec.rules | length' "$app/http-route.yaml")"
[[ "$rules" -gt 0 ]] || fail "reason=httproute_without_rule"
backends="$(yq eval-all --no-doc 'select(.kind == "HTTPRoute") | .spec.rules[].backendRefs[] | .name + "/" + (.namespace // "") + ":" + (.port | tostring)' "$app/http-route.yaml" | sort -u)"
[[ "$backends" == keda-add-ons-http-interceptor-proxy/keda:8080 ]] || fail "reason=httproute_backend value=$backends"

# ------------------------------------------------------------------ 4. le ReferenceGrant vit dans le namespace keda
[[ -f $keda/opencode-referencegrant.yaml ]] || fail "reason=missing_referencegrant path=$keda/opencode-referencegrant.yaml"
grep -Eq '^[[:space:]]*-[[:space:]]*opencode-referencegrant\.yaml[[:space:]]*$' "$keda/kustomization.yaml" ||
  fail "reason=referencegrant_not_rendered file=$keda/kustomization.yaml"
rg_from="$(one ReferenceGrant '.spec.from[0].kind + "/" + .spec.from[0].namespace' "$keda/opencode-referencegrant.yaml")"
[[ "$rg_from" == HTTPRoute/opencode ]] || fail "reason=referencegrant_from value=$rg_from"
rg_to="$(one ReferenceGrant '.spec.to[0].kind + "/" + .spec.to[0].name' "$keda/opencode-referencegrant.yaml")"
[[ "$rg_to" == Service/keda-add-ons-http-interceptor-proxy ]] || fail "reason=referencegrant_to value=$rg_to"

# Le projet Argo `apps` interdit ReferenceGrant : l'application ne doit pas en porter un.
if grep -l '^kind: ReferenceGrant$' "$app"/*.yaml >/dev/null 2>&1; then
  fail "reason=referencegrant_in_app"
fi

# ------------------------------------------------------------------ 5. le proxy keda doit pouvoir joindre le port 5003
yq -o=json '.' "$app/networkpolicy.yaml" | jq -e '[.spec.ingress[]? | select(any(.fromEndpoints[]?; .matchLabels["k8s:io.kubernetes.pod.namespace"] == "keda"))
  | .toPorts[]?.ports[]? | select((.port | tostring) == "5003")] | length > 0' >/dev/null ||
  fail "reason=proxy_keda_not_allowed_on_5003 file=$app/networkpolicy.yaml"

# ------------------------------------------------------------------ 6. le rendu de l'application (preuve, sans helm)
tmp="$(mktemp -d "${TMPDIR:-/tmp}/opencode-keda.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
kustomize build --enable-helm "$app" >"$tmp/render.yaml" 2>"$tmp/render.err" ||
  { cat "$tmp/render.err" >&2; fail "reason=render_failed root=$app"; }

rendered_min="$(yq eval-all --no-doc 'select(.kind == "ScaledObject") | .spec.minReplicaCount' "$tmp/render.yaml")"
[[ "$rendered_min" == 0 ]] || fail "reason=rendered_min_replicas value=$rendered_min"
rendered_cooldown="$(yq eval-all --no-doc 'select(.kind == "ScaledObject") | .spec.cooldownPeriod' "$tmp/render.yaml")"
[[ "$rendered_cooldown" == 300 ]] || fail "reason=rendered_cooldown value=$rendered_cooldown"
rendered_readiness="$(yq eval-all --no-doc 'select(.kind == "InterceptorRoute") | .spec.timeouts.readiness' "$tmp/render.yaml")"
[[ "$rendered_readiness" == 120s ]] || fail "reason=rendered_readiness value=$rendered_readiness"
rendered_replicas="$(yq eval-all --no-doc 'select(.kind == "Deployment") | .spec.replicas' "$tmp/render.yaml")"
[[ "$rendered_replicas" == "null" || -z "$rendered_replicas" ]] || fail "reason=rendered_pins_replicas value=$rendered_replicas"

echo "OPENCODE_KEDA_SCALE_TO_ZERO=PASS"
