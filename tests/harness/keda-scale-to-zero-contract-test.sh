#!/usr/bin/env bash
# PLT-564, PLT-566 : le pilote KEDA HTTP (add-on `keda-add-ons-http`) passe a zero
# searxng puis trilium (vague 2), puis sure et romm (vague 3). Contrat verifie sur
# le rendu Kustomize des applications et sur les manifests du controleur KEDA
# (namespace `keda`) :
#
#   - un InterceptorRoute par application : target = le Service de l'app, regle de
#     routage sur le hostname public, `timeouts.readiness` = 120 s (cold start),
#     `coldStart.maxPendingRequests` et une metrique de concurrence ; le Service
#     vise expose le port vise (sans backend, le proxy KEDA ne reveille rien) ;
#   - un ScaledObject `external-push` par workload ramene a zero : `minReplicaCount` 0,
#     `maxReplicaCount` 1, `cooldownPeriod` 300, cible = le Deployment du workload ;
#     (sure expose deux workloads : le web porte le trafic, le worker attend le web) ;
#   - la HTTPRoute de l'app pointe vers le proxy KEDA (namespace `keda`, port 8080)
#     et plus vers le Service de l'app ;
#   - le Deployment n'epingle pas `replicas` : KEDA est le seul proprietaire du
#     nombre de replicas (sinon Argo remet le Deployment a 1) ;
#   - la CiliumNetworkPolicy de l'app admet le proxy KEDA (namespace `keda`) sur le
#     port du conteneur : c'est lui qui relaie le trafic quand l'app est a zero ;
#   - un ReferenceGrant dans le namespace `keda` autorise la HTTPRoute de l'app a
#     referencer le proxy KEDA, et il est rendu par la kustomization du controleur ;
#   - l'appelant en cluster de searxng (gpt-researcher) passe par le proxy KEDA :
#     un appel direct au Service ne reveille pas une application a zero.
#
# Le test refuse aussi chaque variante cassee (minReplicaCount, cooldown, readiness,
# backendRef, ReferenceGrant, replicas epingles, CiliumNetworkPolicy) : un controle
# qui accepte tout ne prouve rien.
#
# Statique : rendu Kustomize local, aucun acces cluster, aucune ecriture dans le depot.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fail() {
  echo "KEDA_SCALE_TO_ZERO=FAIL $*" >&2
  exit 1
}
blocked() {
  echo "KEDA_SCALE_TO_ZERO=BLOCKED $*" >&2
  exit 2
}

command -v yq >/dev/null || blocked "missing_tool=yq"
command -v jq >/dev/null || blocked "missing_tool=jq"
command -v kustomize >/dev/null || blocked "missing_tool=kustomize"

work="$(mktemp -d "${TMPDIR:-/tmp}/keda-scale-to-zero.XXXXXX")"
trap 'rm -rf "$work"' EXIT

keda_dir="$repo_root/k8s/infrastructure/controllers/keda"
proxy_service="keda-add-ons-http-interceptor-proxy"
proxy_port=8080
scaler_address="keda-add-ons-http-external-scaler.keda:9090"

# --- helpers ------------------------------------------------------------------------------

render_repo_root() { # <racine relative du depot> -> YAML rendu sur stdout
  cat "$(bash "$repo_root/scripts/lib/render-cache.sh" render "$1")"
}

to_json() { # <yaml> -> tableau JSON (un objet par document)
  yq -o=json -I=0 '.' "$1" | jq -s '.'
}

# --- contrat d'une application -------------------------------------------------------------
# <yaml rendu> <dossier keda> <namespace> <app> <hostname> <service cible> <port cible>
# <port conteneur> <workloads ramenes a zero, espace separe>
check_app() {
  local rendered="$1" keda="$2" ns="$3" app="$4" host="$5" target="$6" target_port="$7" cport="$8"
  local workloads="$9"
  local json="$work/app.json" rg="$keda/$app-referencegrant.yaml"
  local workloads_json
  workloads_json="$(printf '%s' "$workloads" | tr ' ' '\n' | jq -R 'select(length > 0)' | jq -s '.')"

  to_json "$rendered" >"$json"

  jq -e --arg app "$app" --arg ns "$ns" --arg host "$host" --arg target "$target" \
         --argjson target_port "$target_port" --arg proxy "$proxy_service" \
         --argjson proxy_port "$proxy_port" --arg scaler "$scaler_address" --arg cport "$cport" \
         --argjson workloads "$workloads_json" '
    . as $docs |
    def ir:  [$docs[] | select(.kind == "InterceptorRoute")];
    def so:  [$docs[] | select(.kind == "ScaledObject")];
    def rt:  [$docs[] | select(.kind == "HTTPRoute")];
    def dep: [$docs[] | select(.kind == "Deployment")];
    def cnp: [$docs[] | select(.kind == "CiliumNetworkPolicy")];
    def svc: [$docs[] | select(.kind == "Service")];

    # InterceptorRoute : target, regle hostname, readiness 120 s, concurrence, cold start
    ([ir[] | select(
        .apiVersion == "http.keda.sh/v1beta1"
        and .metadata.name == $app
        and .metadata.namespace == $ns
        and .spec.target.service == $target
        and .spec.target.port == $target_port
        and ((.spec.rules | length) == 1)
        and ((.spec.rules[0].hosts | index($host)) != null)
        and (.spec.scalingMetric.concurrency.targetValue > 0)
        and (.spec.coldStart.maxPendingRequests > 0)
        and (.spec.timeouts.readiness == "120s")
      )] | length) == 1
    and
    # le Service vise par l InterceptorRoute existe et expose le port vise : sans
    # lui, le proxy KEDA n a aucun backend a reveiller et l application reste a zero
    ([svc[] | select(.metadata.name == $target and .metadata.namespace == $ns
       and any(.spec.ports[]?; .port == $target_port))] | length) == 1
    and
    # ScaledObject : un par workload ramene a zero, et pas un de plus
    ([so[] | select(.metadata.namespace == $ns)] | length) == ($workloads | length)
    and
    (all($workloads[]; . as $w |
      ([so[] | select(
          .apiVersion == "keda.sh/v1alpha1"
          and .metadata.name == $w
          and .metadata.namespace == $ns
          and .spec.scaleTargetRef.apiVersion == "apps/v1"
          and .spec.scaleTargetRef.kind == "Deployment"
          and .spec.scaleTargetRef.name == $w
          and .spec.minReplicaCount == 0
          and .spec.maxReplicaCount == 1
          and .spec.cooldownPeriod == 300
          and ([.spec.triggers[] | select(
                .type == "external-push"
                and .metadata.scalerAddress == $scaler
                and .metadata.interceptorRoute == $app)] | length) == 1
        )] | length) == 1))
    and
    # le Deployment de chaque workload existe et n epingle pas replicas : KEDA en reste
    # le proprietaire
    (all($workloads[]; . as $w |
      ([dep[] | select(.metadata.name == $w)] | length) == 1
      and ([dep[] | select(.metadata.name == $w) | select(.spec.replicas != null)] | length) == 0))
    and
    # la HTTPRoute de l app vise le proxy KEDA, et rien d autre
    ([rt[] | select(.metadata.name == $app) | .spec.rules[]?.backendRefs[]?
      | select(.name == $proxy and .namespace == "keda" and .port == $proxy_port)] | length) == 1
    and
    ([rt[] | select(.metadata.name == $app) | .spec.rules[]?.backendRefs[]?
      | select(.name != $proxy or .namespace != "keda" or .port != $proxy_port)] | length) == 0
    and
    # la HTTPRoute sert le hostname public de l app
    ([rt[] | select(.metadata.name == $app) | .spec.hostnames[]? | select(. == $host)] | length) >= 1
    and
    # la CiliumNetworkPolicy admet le proxy KEDA sur le port du conteneur
    ([cnp[] | .spec.ingress[]?
      | select(any(.fromEndpoints[]?;
          .matchLabels["k8s:io.kubernetes.pod.namespace"] == "keda"
          and .matchLabels["app.kubernetes.io/name"] == "http-add-on"
          and .matchLabels["app.kubernetes.io/component"] == "interceptor"))
      | select(any(.toPorts[]?.ports[]?; .port == $cport))] | length) >= 1
  ' "$json" >/dev/null 2>&1 || return 1

  # ReferenceGrant dans le namespace keda : la HTTPRoute de l app peut viser le proxy
  [[ -f $rg ]] || return 1
  [[ "$(yq -r '.apiVersion' "$rg")" == "gateway.networking.k8s.io/v1beta1" ]] || return 1
  [[ "$(yq -r '.kind' "$rg")" == "ReferenceGrant" ]] || return 1
  [[ "$(yq -r '.metadata.name' "$rg")" == "$app-http-route" ]] || return 1
  [[ "$(yq -r '.metadata.namespace' "$rg")" == "keda" ]] || return 1
  [[ "$(yq -r '.spec.from[] | [.group, .kind, .namespace] | map(select(. != "")) | join(" ")' "$rg")" \
     == "gateway.networking.k8s.io HTTPRoute $ns" ]] || return 1
  [[ "$(yq -r '.spec.to[] | [.group, .kind, .name] | map(select(. != "")) | join(" ")' "$rg")" \
     == "Service $proxy_service" ]] || return 1
  grep -qE "^[[:space:]]*-[[:space:]]+$app-referencegrant\.yaml[[:space:]]*$" "$keda/kustomization.yaml" || return 1
  return 0
}

# --- l appelant en cluster de searxng passe par le proxy KEDA -------------------------------
# <yaml rendu> : gpt-researcher vise le proxy KEDA et l egress autorise le namespace keda
check_internal_caller() {
  local json="$work/caller.json"
  to_json "$1" >"$json"
  jq -e --arg url "http://$proxy_service.keda.svc.cluster.local:$proxy_port/" '
    def dep: [.[] | select(.kind == "Deployment" and .metadata.name == "gpt-researcher")];
    def cnp: [.[] | select(.kind == "CiliumNetworkPolicy")];
    ([dep[] | .spec.template.spec.containers[] | select(.name == "gpt-researcher")
      | .env[] | select(.name == "SEARX_URL") | .value] == [$url])
    and
    ([cnp[] | .spec.egress[]?
      | select(any(.toEndpoints[]?;
          .matchLabels["k8s:io.kubernetes.pod.namespace"] == "keda"
          and .matchLabels["app.kubernetes.io/name"] == "http-add-on"
          and .matchLabels["app.kubernetes.io/component"] == "interceptor"))
      | select(any(.toPorts[]?.ports[]?; .port == "8080"))] | length) >= 1
  ' "$json" >/dev/null 2>&1
}

# --- les applications du perimetre ---------------------------------------------------------
searxng_root="$repo_root/k8s/applications/catalog/searxng"
trilium_root="$repo_root/k8s/applications/web/trilium"
sure_root="$repo_root/k8s/applications/catalog/sure"
romm_root="$repo_root/k8s/applications/games/romm"
gpt_root="$repo_root/k8s/applications/ai/gpt-researcher"

render_repo_root k8s/applications/catalog/searxng >"$work/searxng.yaml" || fail "rendu searxng impossible"
render_repo_root k8s/applications/web/trilium >"$work/trilium.yaml" || fail "rendu trilium impossible"
render_repo_root k8s/applications/catalog/sure >"$work/sure.yaml" || fail "rendu sure impossible"
render_repo_root k8s/applications/games/romm >"$work/romm.yaml" || fail "rendu romm impossible"
render_repo_root k8s/applications/ai/gpt-researcher >"$work/gpt-researcher.yaml" || fail "rendu gpt-researcher impossible"

check_app "$work/searxng.yaml" "$keda_dir" searxng searxng search.smadja.dev searxng 80 8080 "searxng" ||
  fail "searxng : le pilote KEDA (InterceptorRoute, ScaledObject, HTTPRoute, ReferenceGrant, CiliumNetworkPolicy) n est pas conforme"
check_app "$work/trilium.yaml" "$keda_dir" trilium trilium trilium.smadja.dev trilium 8080 8080 "trilium" ||
  fail "trilium : le pilote KEDA (InterceptorRoute, ScaledObject, HTTPRoute, ReferenceGrant, CiliumNetworkPolicy) n est pas conforme"
# sure : le web porte le trafic, le worker attend le web (il ne peut pas rester seul) ;
# les deux sont ramenes a zero et reveilles par la meme route.
check_app "$work/sure.yaml" "$keda_dir" sure sure sure.smadja.dev sure 80 3000 "sure-web sure-worker" ||
  fail "sure : le pilote KEDA (InterceptorRoute, ScaledObject, HTTPRoute, ReferenceGrant, CiliumNetworkPolicy) n est pas conforme"
check_app "$work/romm.yaml" "$keda_dir" romm romm romm.smadja.dev romm 8080 8080 "romm" ||
  fail "romm : le pilote KEDA (InterceptorRoute, ScaledObject, HTTPRoute, ReferenceGrant, CiliumNetworkPolicy) n est pas conforme"
check_internal_caller "$work/gpt-researcher.yaml" ||
  fail "gpt-researcher : l appel en cluster a searxng ne passe pas par le proxy KEDA (une requete a froid echouerait)"

# --- variantes cassee : chacune doit etre refusee --------------------------------------------
# break_app <nom> <racine> <namespace> <app> <hostname> <service> <port cible> <port conteneur>
#            <workloads> <mutation> <cible> <kind> <expression>
# La mutation recoit la copie de l app, la copie du controleur KEDA, la cible a
# muter (un fichier de l app, ou le nom de l app pour le ReferenceGrant), le kind
# attendu et l expression yq.
break_app() {
  local name="$1" root="$2" ns="$3" app="$4" host="$5" target="$6" tport="$7" cport="$8" workloads="$9"
  local mutation="${10}" cible="${11}" kind="${12}" expression="${13}"
  local copy="$work/$name" keda_copy="$work/$name-keda" rendered="$work/$name.render.yaml"
  rm -rf "$copy" "$keda_copy"
  cp -r "$root" "$copy"
  cp -r "$keda_dir" "$keda_copy"
  "$mutation" "$copy" "$keda_copy" "$cible" "$kind" "$expression"
  # une variante qui ne rend pas ne prouve rien : le refus doit venir du contrat
  if ! kustomize build --enable-helm "$copy" >"$rendered" 2>/dev/null; then
    fail "variante cassee non rendue : $name"
  fi
  if check_app "$rendered" "$keda_copy" "$ns" "$app" "$host" "$target" "$tport" "$cport" "$workloads"; then
    fail "variante cassee non refusee : $name"
  fi
}

mutate() { # <copie> <keda copie> <fichier> <kind> <expression yq>
  yq -i "if .kind == \"$4\" then $5 else . end" "$1/$3"
}
mutate_no_grant() { # <copie> <keda copie> <nom de l app> : le ReferenceGrant disparait
  rm -f "$2/$3-referencegrant.yaml"
}

break_app bad-min-replicas "$searxng_root" searxng searxng search.smadja.dev searxng 80 8080 "searxng" \
  mutate interceptorroute.yaml ScaledObject '.spec.minReplicaCount = 1'
break_app bad-cooldown "$searxng_root" searxng searxng search.smadja.dev searxng 80 8080 "searxng" \
  mutate interceptorroute.yaml ScaledObject '.spec.cooldownPeriod = 60'
break_app bad-readiness "$trilium_root" trilium trilium trilium.smadja.dev trilium 8080 8080 "trilium" \
  mutate interceptorroute.yaml InterceptorRoute '.spec.timeouts.readiness = "60s"'
break_app bad-backend "$trilium_root" trilium trilium trilium.smadja.dev trilium 8080 8080 "trilium" \
  mutate http-route.yaml HTTPRoute '.spec.rules[0].backendRefs[0].name = "trilium"'
break_app bad-pinned-replicas "$trilium_root" trilium trilium trilium.smadja.dev trilium 8080 8080 "trilium" \
  mutate deployment.yaml Deployment '.spec.replicas = 1'
break_app bad-no-cnp "$searxng_root" searxng searxng search.smadja.dev searxng 80 8080 "searxng" \
  mutate app.yaml CiliumNetworkPolicy '.spec.ingress = []'
break_app bad-no-cnp-trilium "$trilium_root" trilium trilium trilium.smadja.dev trilium 8080 8080 "trilium" \
  mutate network-policy.yaml CiliumNetworkPolicy '.spec.ingress = []'
break_app bad-no-grant "$searxng_root" searxng searxng search.smadja.dev searxng 80 8080 "searxng" \
  mutate_no_grant searxng "" ""
break_app bad-min-replicas-romm "$romm_root" romm romm romm.smadja.dev romm 8080 8080 "romm" \
  mutate interceptorroute.yaml ScaledObject '.spec.minReplicaCount = 1'
break_app bad-backend-sure "$sure_root" sure sure sure.smadja.dev sure 80 3000 "sure-web sure-worker" \
  mutate service-route.yaml HTTPRoute '.spec.rules[0].backendRefs[0].name = "sure"'
break_app bad-pinned-replicas-sure "$sure_root" sure sure sure.smadja.dev sure 80 3000 "sure-web sure-worker" \
  mutate workloads.yaml Deployment '.spec.replicas = 1'
break_app bad-no-cnp-sure "$sure_root" sure sure sure.smadja.dev sure 80 3000 "sure-web sure-worker" \
  mutate networkpolicy.yaml CiliumNetworkPolicy '.spec.ingress = []'
break_app bad-no-grant-romm "$romm_root" romm romm romm.smadja.dev romm 8080 8080 "romm" \
  mutate_no_grant romm "" ""
break_app bad-target-service "$romm_root" romm romm romm.smadja.dev romm 8080 8080 "romm" \
  mutate service.yaml Service '.spec.ports[0].port = 9999'
break_app bad-target-service-sure "$sure_root" sure sure sure.smadja.dev sure 80 3000 "sure-web sure-worker" \
  mutate service-route.yaml Service '.spec.ports[0].port = 9999'

# --- le test est branche sur les deux portes du depot ---------------------------------------
# Le contrat est un sous-check npm (`npm run check:keda-scale-to-zero`) : le CI, qui execute
# `npm run check`, le joue. La porte locale (`just check` = `npm run check:local`) joue la
# liste bash `scripts/check-bash-tests.list` : le test y est declare, et n'est pas rejoue
# par le sous-check npm, donc une seule execution par porte.
grep -q '"check:keda-scale-to-zero": "bash tests/harness/keda-scale-to-zero-contract-test.sh"' \
  "$repo_root/package.json" ||
  fail "le test n est pas branche sur check:keda-scale-to-zero (package.json)"
[[ "$(jq -r '.scripts.check' "$repo_root/package.json")" == *"check:keda-scale-to-zero"* ]] ||
  fail "check:keda-scale-to-zero n est pas execute par npm run check (le CI ne le jouerait pas)"
grep -qx 'tests/harness/keda-scale-to-zero-contract-test.sh' "$repo_root/scripts/check-bash-tests.list" ||
  fail "le test n est pas declare dans scripts/check-bash-tests.list (just check ne le jouerait pas)"
[[ "$(jq -r '.scripts["check:local"]' "$repo_root/package.json")" != *"check:keda-scale-to-zero"* ]] ||
  fail "check:keda-scale-to-zero est joue deux fois par just check (liste bash et sous-check npm)"

echo "KEDA_SCALE_TO_ZERO=PASS"
