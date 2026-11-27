#!/usr/bin/env bash
# PLT-565 - pilote KEDA HTTP, vague 2 : mealie et stirling-pdf passent a zero quand ils sont inactifs.
#
# Contrat, identique pour chaque application de la vague :
#   1. un InterceptorRoute (http.keda.sh/v1beta1) : cible = Service de l'app, hote public de la
#      HTTPRoute, metrique de concurrence, coldStart, timeouts.readiness = 120s ;
#   2. un ScaledObject (keda.sh/v1alpha1) : minReplicaCount 0, cooldownPeriod 300 s,
#      maxReplicaCount >= 1, declencheur external-push vers le scaler du KEDA HTTP add-on ;
#   3. la HTTPRoute de l'app pointe le proxy d'interception KEDA (namespace keda, port 8080) ;
#   4. le ReferenceGrant qui autorise cette reference inter-namespace vit dans
#      k8s/infrastructure/controllers/keda/ : le projet Argo `apps` le refuse dans une application ;
#   5. le Deployment ne fige pas spec.replicas : le ScaledObject est l'unique proprietaire du
#      nombre de replicas, sinon Argo CD remet le Deployment a 1 et le scale-to-zero est perdu ;
#   6. la CiliumNetworkPolicy de l'app autorise l'intercepteur (namespace keda) sur le port que
#      le pod ecoute : sinon la policy bloque la requete avant meme que l'app ne demarre.
#
# Lecture seule : aucun acces cluster, aucun secret, aucune ecriture dans le depot. Le rendu passe
# par le cache partage (scripts/lib/render-cache.sh), comme les autres controles.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"

fail() {
  echo "KEDA_SCALE_TO_ZERO=FAIL $*" >&2
  exit 1
}
command -v yq >/dev/null || fail "yq requis"
command -v jq >/dev/null || fail "jq requis"
# shellcheck source=../../scripts/lib/render-cache.sh
source scripts/lib/render-cache.sh

keda_dir=k8s/infrastructure/controllers/keda
proxy_service=keda-add-ons-http-interceptor-proxy
proxy_port=8080
scaler_address=keda-add-ons-http-external-scaler.keda:9090
cooldown_period=300
min_replicas=0

# app|namespace|Service|port du Service|host public|readiness
apps=(
  "mealie|mealie|mealie|80|mealie.smadja.dev|120s"
  "stirling-pdf|stirling-pdf|stirling-pdf|80|pdf.smadja.dev|120s"
)

for entry in "${apps[@]}"; do
  IFS='|' read -r app ns service svc_port host readiness <<<"$entry"

  dir="$(find k8s/applications -mindepth 2 -maxdepth 3 -type d -name "$app" | LC_ALL=C sort | head -1)"
  [[ -n $dir ]] || fail "$app : dossier d'application introuvable sous k8s/applications"
  rendered="$(render_root "$dir")" || fail "$app : rendu kustomize impossible ($dir)"
  docs="$(yq eval-all -o=json -I=0 '.' "$rendered" | jq -s 'map(select(type=="object"))')"

  # Le port que le pod ecoute : targetPort du Service (nom ou numero), resolu sur le Deployment.
  pod_port="$(jq -r --arg ns "$ns" --arg service "$service" --argjson svc_port "$svc_port" '
    ([.[] | select(.kind=="Service" and .metadata.name==$service and .metadata.namespace==$ns)
      | .spec.ports[] | select(.port==$svc_port) | .targetPort] | .[0]) as $tp
    | if ($tp|type)=="number" then $tp
      else ([.[] | select(.kind=="Deployment" and .metadata.namespace==$ns)
             | .spec.template.spec.containers[].ports[]? | select(.name==$tp) | .containerPort] | .[0])
      end' <<<"$docs")"
  [[ $pod_port =~ ^[0-9]+$ ]] || fail "$app : port du pod introuvable (Service $service:$svc_port)"

  check() { # <json> <message> <filtre jq>
    jq -e --arg ns "$ns" --arg app "$app" --arg service "$service" --arg host "$host" \
      --arg readiness "$readiness" --arg proxy "$proxy_service" --arg scaler "$scaler_address" \
      --argjson svc_port "$svc_port" --argjson proxy_port "$proxy_port" --argjson pod_port "$pod_port" \
      --argjson cooldown "$cooldown_period" --argjson min_replicas "$min_replicas" \
      "$3" >/dev/null <<<"$1" || fail "$app : $2"
  }

  # 1. InterceptorRoute -------------------------------------------------------------------------
  check "$docs" "un InterceptorRoute est requis dans le namespace $ns" \
    '[.[] | select(.kind=="InterceptorRoute" and .metadata.namespace==$ns)] | length == 1'
  check "$docs" "l'InterceptorRoute doit viser le Service $service:$svc_port" \
    '([.[] | select(.kind=="InterceptorRoute" and .metadata.namespace==$ns)] | .[0]) as $ir
     | ($ir.spec.target.service==$service) and ($ir.spec.target.port==$svc_port)'
  check "$docs" "l'InterceptorRoute doit porter l'hote public $host" \
    '([.[] | select(.kind=="InterceptorRoute" and .metadata.namespace==$ns)] | .[0]) as $ir
     | any($ir.spec.rules[]?.hosts[]?; .==$host)'
  check "$docs" "timeouts.readiness doit valoir $readiness" \
    '([.[] | select(.kind=="InterceptorRoute" and .metadata.namespace==$ns)] | .[0]) as $ir
     | $ir.spec.timeouts.readiness==$readiness'
  check "$docs" "metrique de concurrence et coldStart doivent etre declares" \
    '([.[] | select(.kind=="InterceptorRoute" and .metadata.namespace==$ns)] | .[0]) as $ir
     | ($ir.spec.scalingMetric.concurrency.targetValue >= 1) and ($ir.spec.coldStart.maxPendingRequests >= 1)'

  # 2. ScaledObject -----------------------------------------------------------------------------
  check "$docs" "un ScaledObject est requis dans le namespace $ns" \
    '[.[] | select(.kind=="ScaledObject" and .metadata.namespace==$ns)] | length == 1'
  check "$docs" "le ScaledObject doit viser le Deployment $app" \
    '([.[] | select(.kind=="ScaledObject" and .metadata.namespace==$ns)] | .[0]) as $so
     | ($so.spec.scaleTargetRef.kind=="Deployment") and ($so.spec.scaleTargetRef.name==$app)'
  check "$docs" "minReplicaCount doit valoir $min_replicas" \
    '([.[] | select(.kind=="ScaledObject" and .metadata.namespace==$ns)] | .[0]) as $so
     | $so.spec.minReplicaCount==$min_replicas'
  check "$docs" "cooldownPeriod doit valoir $cooldown_period s" \
    '([.[] | select(.kind=="ScaledObject" and .metadata.namespace==$ns)] | .[0]) as $so
     | $so.spec.cooldownPeriod==$cooldown'
  check "$docs" "maxReplicaCount doit valoir au moins 1" \
    '([.[] | select(.kind=="ScaledObject" and .metadata.namespace==$ns)] | .[0]) as $so
     | $so.spec.maxReplicaCount >= 1'
  check "$docs" "declencheur external-push vers le scaler du KEDA HTTP add-on requis" \
    '([.[] | select(.kind=="ScaledObject" and .metadata.namespace==$ns)] | .[0]) as $so
     | any($so.spec.triggers[]?;
           .type=="external-push" and .metadata.scalerAddress==$scaler and .metadata.interceptorRoute==$app)'

  # 3. HTTPRoute --------------------------------------------------------------------------------
  check "$docs" "la HTTPRoute doit pointer le proxy d'interception KEDA (keda:$proxy_port)" \
    '([.[] | select(.kind=="HTTPRoute" and .metadata.namespace==$ns)] | .[0]) as $r
     | any($r.spec.rules[]?.backendRefs[]?;
           .name==$proxy and .namespace=="keda" and .port==$proxy_port)'
  check "$docs" "la HTTPRoute doit garder l'hote public $host" \
    '([.[] | select(.kind=="HTTPRoute" and .metadata.namespace==$ns)] | .[0]) as $r
     | any($r.spec.hostnames[]?; .==$host)'

  # 4. ReferenceGrant dans le controleur KEDA ----------------------------------------------------
  grant="$keda_dir/${app}-referencegrant.yaml"
  [[ -f $grant ]] || fail "$app : ReferenceGrant absent ($grant)"
  grant_json="$(yq eval-all -o=json -I=0 '.' "$grant" | jq -s 'map(select(type=="object"))')"
  check "$grant_json" "le ReferenceGrant doit autoriser la HTTPRoute de $ns vers le proxy KEDA" \
    '(.[0].spec.from // []) | any(.group=="gateway.networking.k8s.io" and .kind=="HTTPRoute" and .namespace==$ns)'
  check "$grant_json" "le ReferenceGrant doit viser le Service $proxy_service du namespace keda" \
    '(.[0].spec.to // []) | any(.kind=="Service" and .name==$proxy)'
  grep -qE "^[[:space:]]*-[[:space:]]*${app}-referencegrant.yaml" "$keda_dir/kustomization.yaml" \
    || fail "$app : ${app}-referencegrant.yaml absent du kustomization de $keda_dir"
  check "$docs" "l'application ne doit pas rendre de ReferenceGrant (projet Argo apps)" \
    '[.[] | select(.kind=="ReferenceGrant")] | length == 0'

  # 5. le Deployment ne fige pas le nombre de replicas -------------------------------------------
  check "$docs" "le Deployment ne doit pas figer spec.replicas (le ScaledObject en est l'unique proprietaire)" \
    '([.[] | select(.kind=="Deployment" and .metadata.namespace==$ns)] | .[0]) as $d
     | ($d.spec.replicas // null)==null'

  # 6. la CiliumNetworkPolicy ouvre l'intercepteur sur le port du pod ----------------------------
  check "$docs" "la CiliumNetworkPolicy doit autoriser l'intercepteur (namespace keda) sur le port $pod_port" \
    '([.[] | select(.kind=="CiliumNetworkPolicy" and .metadata.namespace==$ns)] | .[0]) as $c
     | any($c.spec.ingress[]?;
           any(.fromEndpoints[]?; (.matchLabels // {})["k8s:io.kubernetes.pod.namespace"]=="keda")
           and any(.toPorts[]?.ports[]?; (.port|tostring)==($pod_port|tostring)))'
done

echo "KEDA_SCALE_TO_ZERO=PASS apps=${#apps[@]} minReplicaCount=$min_replicas cooldownPeriod=$cooldown_period"
