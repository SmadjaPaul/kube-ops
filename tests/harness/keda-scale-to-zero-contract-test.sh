#!/usr/bin/env bash
# PLT-564 : le pilote KEDA HTTP (add-on `keda-add-ons-http`) passe a zero searxng
# puis trilium. Contrat verifie sur le rendu Kustomize des applications et sur les
# manifests du controleur KEDA (namespace `keda`) :
#
#   - un InterceptorRoute par application : target = le Service de l'app, regle de
#     routage sur le hostname public, `timeouts.readiness` = 120 s (cold start),
#     `coldStart.maxPendingRequests` et une metrique de concurrence ;
#   - un ScaledObject `external-push` : `minReplicaCount` 0, `maxReplicaCount` 1,
#     `cooldownPeriod` 300, cible = le Deployment de l'app ;
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
# <yaml rendu> <dossier keda> <namespace> <app> <hostname> <service cible> <port cible> <port conteneur>
check_app() {
  local rendered="$1" keda="$2" ns="$3" app="$4" host="$5" target="$6" target_port="$7" cport="$8"
  local json="$work/app.json" rg="$keda/$app-referencegrant.yaml"

  to_json "$rendered" >"$json"

  jq -e --arg app "$app" --arg ns "$ns" --arg host "$host" --arg target "$target" \
         --argjson target_port "$target_port" --arg proxy "$proxy_service" \
         --argjson proxy_port "$proxy_port" --arg scaler "$scaler_address" --arg cport "$cport" '
    def ir:  [.[] | select(.kind == "InterceptorRoute")];
    def so:  [.[] | select(.kind == "ScaledObject")];
    def rt:  [.[] | select(.kind == "HTTPRoute")];
    def dep: [.[] | select(.kind == "Deployment")];
    def cnp: [.[] | select(.kind == "CiliumNetworkPolicy")];

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
    # ScaledObject : zero au repos, cooldown 300 s, cible le Deployment de l app
    ([so[] | select(
        .apiVersion == "keda.sh/v1alpha1"
        and .metadata.name == $app
        and .metadata.namespace == $ns
        and .spec.scaleTargetRef.apiVersion == "apps/v1"
        and .spec.scaleTargetRef.kind == "Deployment"
        and .spec.scaleTargetRef.name == $app
        and .spec.minReplicaCount == 0
        and .spec.maxReplicaCount == 1
        and .spec.cooldownPeriod == 300
        and ([.spec.triggers[] | select(
              .type == "external-push"
              and .metadata.scalerAddress == $scaler
              and .metadata.interceptorRoute == $app)] | length) == 1
      )] | length) == 1
    and
    # la HTTPRoute de l app vise le proxy KEDA, et rien d autre
    ([rt[] | select(.metadata.name == $app) | .spec.rules[]?.backendRefs[]?
      | select(.name == $proxy and .namespace == "keda" and .port == $proxy_port)] | length) == 1
    and
    ([rt[] | select(.metadata.name == $app) | .spec.rules[]?.backendRefs[]?
      | select(.name != $proxy or .namespace != "keda" or .port != $proxy_port)] | length) == 0
    and
    # le Deployment n epingle pas replicas : KEDA en reste le proprietaire
    ([dep[] | select(.metadata.name == $app) | select(.spec.replicas != null)] | length) == 0
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
gpt_root="$repo_root/k8s/applications/ai/gpt-researcher"

render_repo_root k8s/applications/catalog/searxng >"$work/searxng.yaml" || fail "rendu searxng impossible"
render_repo_root k8s/applications/web/trilium >"$work/trilium.yaml" || fail "rendu trilium impossible"
render_repo_root k8s/applications/ai/gpt-researcher >"$work/gpt-researcher.yaml" || fail "rendu gpt-researcher impossible"

check_app "$work/searxng.yaml" "$keda_dir" searxng searxng search.smadja.dev searxng 80 8080 ||
  fail "searxng : le pilote KEDA (InterceptorRoute, ScaledObject, HTTPRoute, ReferenceGrant, CiliumNetworkPolicy) n est pas conforme"
check_app "$work/trilium.yaml" "$keda_dir" trilium trilium trilium.smadja.dev trilium 8080 8080 ||
  fail "trilium : le pilote KEDA (InterceptorRoute, ScaledObject, HTTPRoute, ReferenceGrant, CiliumNetworkPolicy) n est pas conforme"
check_internal_caller "$work/gpt-researcher.yaml" ||
  fail "gpt-researcher : l appel en cluster a searxng ne passe pas par le proxy KEDA (une requete a froid echouerait)"

# --- variantes cassee : chacune doit etre refusee --------------------------------------------
# break_app <nom> <racine> <namespace> <app> <hostname> <service> <port cible> <port conteneur> <mutation> <expression>
break_app() {
  local name="$1" root="$2" ns="$3" app="$4" host="$5" target="$6" tport="$7" cport="$8"
  local mutation="$9" expression="${10}"
  local copy="$work/$name" keda_copy="$work/$name-keda" rendered="$work/$name.render.yaml"
  rm -rf "$copy" "$keda_copy"
  cp -r "$root" "$copy"
  cp -r "$keda_dir" "$keda_copy"
  "$mutation" "$copy" "$keda_copy" "$expression"
  kustomize build --enable-helm "$copy" >"$rendered" 2>/dev/null || true
  if check_app "$rendered" "$keda_copy" "$ns" "$app" "$host" "$target" "$tport" "$cport"; then
    fail "variante cassee non refusee : $name"
  fi
}

mutate_scaledobject() { # <copie> <keda copie> <expression yq>
  yq -i "if .kind == \"ScaledObject\" then $3 else . end" "$1/interceptorroute.yaml"
}
mutate_interceptorroute() { # <copie> <keda copie> <expression yq>
  yq -i "if .kind == \"InterceptorRoute\" then $3 else . end" "$1/interceptorroute.yaml"
}
mutate_httproute() { # <copie> <keda copie> <expression yq>
  yq -i "if .kind == \"HTTPRoute\" then $3 else . end" "$1/http-route.yaml"
}
mutate_deployment() { # <copie> <keda copie> <expression yq>
  yq -i "if .kind == \"Deployment\" then $3 else . end" "$1/deployment.yaml"
}
mutate_cnp() { # <copie> <keda copie> <expression yq>
  yq -i "if .kind == \"CiliumNetworkPolicy\" then $3 else . end" "$1/app.yaml"
}
mutate_cnp_trilium() { # <copie> <keda copie> <expression yq>
  yq -i "if .kind == \"CiliumNetworkPolicy\" then $3 else . end" "$1/network-policy.yaml"
}
mutate_no_grant() { # <copie> <keda copie> <nom de l app> : le ReferenceGrant disparait
  rm -f "$2/$3-referencegrant.yaml"
}

break_app bad-min-replicas "$searxng_root" searxng searxng search.smadja.dev searxng 80 8080 \
  mutate_scaledobject '.spec.minReplicaCount = 1'
break_app bad-cooldown "$searxng_root" searxng searxng search.smadja.dev searxng 80 8080 \
  mutate_scaledobject '.spec.cooldownPeriod = 60'
break_app bad-readiness "$trilium_root" trilium trilium trilium.smadja.dev trilium 8080 8080 \
  mutate_interceptorroute '.spec.timeouts.readiness = "60s"'
break_app bad-backend "$trilium_root" trilium trilium trilium.smadja.dev trilium 8080 8080 \
  mutate_httproute '.spec.rules[0].backendRefs[0].name = "trilium"'
break_app bad-pinned-replicas "$trilium_root" trilium trilium trilium.smadja.dev trilium 8080 8080 \
  mutate_deployment '.spec.replicas = 1'
break_app bad-no-cnp "$searxng_root" searxng searxng search.smadja.dev searxng 80 8080 \
  mutate_cnp '.spec.ingress = []'
break_app bad-no-cnp-trilium "$trilium_root" trilium trilium trilium.smadja.dev trilium 8080 8080 \
  mutate_cnp_trilium '.spec.ingress = []'
break_app bad-no-grant "$searxng_root" searxng searxng search.smadja.dev searxng 80 8080 \
  mutate_no_grant 'searxng'

# --- le test est declare dans la liste des tests bash ---------------------------------------
grep -qx 'tests/harness/keda-scale-to-zero-contract-test.sh' "$repo_root/scripts/check-bash-tests.list" ||
  fail "le test n est pas declare dans scripts/check-bash-tests.list"

echo "KEDA_SCALE_TO_ZERO=PASS"
