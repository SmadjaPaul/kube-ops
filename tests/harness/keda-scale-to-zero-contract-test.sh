#!/usr/bin/env bash
# PLT-566 : contrat KEDA scale-to-zero (statique : aucun cluster, aucun helm).
#
# Chaque application de la vague doit :
#   - rendre un InterceptorRoute (http.keda.sh/v1beta1) vers son Service, avec le
#     hostname de la route et un timeout de readiness de 120 s ;
#   - rendre un ScaledObject (keda.sh/v1alpha1) par workload scalable : minReplicaCount 0,
#     cooldownPeriod 300, declencheur external-push vers l'interceptor de la route ;
#   - ne plus figer spec.replicas dans Git (KEDA possede le nombre de replicas) ;
#   - pointer sa HTTPRoute vers le proxy KEDA (namespace keda, port 8080) ;
#   - etre couverte par un ReferenceGrant dans keda/ : le projet Argo `apps` refuse les
#     ReferenceGrant et le namespace keda, seul porteur possible, appartient au projet
#     `infrastructure` (le controleur KEDA).
# Le proxy KEDA (namespace keda) doit aussi pouvoir joindre le pod : la CiliumNetworkPolicy
# de l'application l'admet sur le port du conteneur.
#
# Aucun acces cluster, aucun helm : les racines applicatives ne contiennent pas de chart.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

command -v yq >/dev/null || { echo "ERROR: yq is required" >&2; exit 2; }
command -v kustomize >/dev/null || { echo "ERROR: kustomize is required" >&2; exit 2; }

fail=0
bad() {
  echo "FAIL: $*" >&2
  fail=1
}

tmp="$(mktemp -d "${TMPDIR:-/tmp}/kube-ops-keda.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

keda_dir=k8s/infrastructure/controllers/keda
proxy=keda-add-ons-http-interceptor-proxy
proxy_port=8080
scaler_address=keda-add-ons-http-external-scaler.keda:9090
min_replicas=0
cooldown=300
readiness=120s

apps=(sure romm)
dirs=(k8s/applications/catalog/sure k8s/applications/games/romm)
namespaces=(sure romm)
hostnames=(sure.smadja.dev romm.smadja.dev)
services=(sure romm)
service_ports=(80 8080)
container_ports=(3000 8080)
# Workloads Ramenes a zero. sure : le web et le worker (le worker attend le web, il ne
# peut pas rester seul a 1 replica : sa sonde de readiness exige sidekiq) ; romm : un seul
# Deployment.
workloads=("sure-web sure-worker" "romm")

for i in "${!apps[@]}"; do
  app="${apps[$i]}"
  dir="${dirs[$i]}"
  ns="${namespaces[$i]}"
  hostname="${hostnames[$i]}"
  service="${services[$i]}"
  service_port="${service_ports[$i]}"
  container_port="${container_ports[$i]}"

  rendered="$tmp/$app.yaml"
  if ! kustomize build --enable-helm "$dir" >"$rendered" 2>"$tmp/$app.err"; then
    bad "$app: kustomize build $dir failed: $(head -2 "$tmp/$app.err" | tr '\n' ' ')"
    continue
  fi

  # 1. InterceptorRoute : cible, hostname, readiness
  ir_count="$(yq 'select(.kind == "InterceptorRoute") | .metadata.name' "$rendered" | grep -c . || true)"
  if [[ "$ir_count" != 1 ]]; then
    bad "$app: expected 1 InterceptorRoute, got $ir_count"
    continue
  fi
  ir_name="$(yq -r 'select(.kind == "InterceptorRoute") | .metadata.name' "$rendered")"
  ir_ns="$(yq -r 'select(.kind == "InterceptorRoute") | .metadata.namespace' "$rendered")"
  [[ "$ir_name" == "$app" ]] || bad "$app: InterceptorRoute named $ir_name"
  [[ "$ir_ns" == "$ns" ]] || bad "$app: InterceptorRoute in namespace $ir_ns (expected $ns)"
  ir_target="$(yq -r 'select(.kind == "InterceptorRoute") | .spec.target.service' "$rendered")"
  [[ "$ir_target" == "$service" ]] || bad "$app: InterceptorRoute target.service=$ir_target (expected $service)"
  ir_port="$(yq -r 'select(.kind == "InterceptorRoute") | .spec.target.port' "$rendered")"
  [[ "$ir_port" == "$service_port" ]] || bad "$app: InterceptorRoute target.port=$ir_port (expected $service_port)"
  ir_host="$(yq -r 'select(.kind == "InterceptorRoute") | .spec.rules[].hosts[]' "$rendered" | grep -Fx "$hostname" || true)"
  [[ -n "$ir_host" ]] || bad "$app: InterceptorRoute does not claim $hostname"
  ir_readiness="$(yq -r 'select(.kind == "InterceptorRoute") | .spec.timeouts.readiness' "$rendered")"
  [[ "$ir_readiness" == "$readiness" ]] || bad "$app: InterceptorRoute timeouts.readiness=$ir_readiness (expected $readiness)"
  ir_value="$(yq -r 'select(.kind == "InterceptorRoute") | .spec.scalingMetric.concurrency.targetValue' "$rendered")"
  if [[ ! "$ir_value" =~ ^[0-9]+$ ]] || ((ir_value < 1)); then
    bad "$app: InterceptorRoute scalingMetric.concurrency.targetValue=$ir_value"
  fi

  # 2. ScaledObject par workload scalable
  for workload in ${workloads[$i]}; do
    so_name="$(yq -r "select(.kind == \"ScaledObject\" and .spec.scaleTargetRef.name == \"$workload\") | .metadata.name" "$rendered")"
    if [[ -z "$so_name" ]]; then
      bad "$app: no ScaledObject scales the Deployment $workload"
      continue
    fi
    so_kind="$(yq -r "select(.kind == \"ScaledObject\" and .spec.scaleTargetRef.name == \"$workload\") | .spec.scaleTargetRef.kind" "$rendered")"
    [[ "$so_kind" == "Deployment" ]] || bad "$app/$so_name: scaleTargetRef.kind=$so_kind"
    so_min="$(yq -r "select(.kind == \"ScaledObject\" and .spec.scaleTargetRef.name == \"$workload\") | .spec.minReplicaCount" "$rendered")"
    [[ "$so_min" == "$min_replicas" ]] || bad "$app/$so_name: minReplicaCount=$so_min (expected $min_replicas)"
    so_cooldown="$(yq -r "select(.kind == \"ScaledObject\" and .spec.scaleTargetRef.name == \"$workload\") | .spec.cooldownPeriod" "$rendered")"
    [[ "$so_cooldown" == "$cooldown" ]] || bad "$app/$so_name: cooldownPeriod=$so_cooldown (expected $cooldown)"
    so_max="$(yq -r "select(.kind == \"ScaledObject\" and .spec.scaleTargetRef.name == \"$workload\") | .spec.maxReplicaCount" "$rendered")"
    if [[ ! "$so_max" =~ ^[0-9]+$ ]] || ((so_max < 1)); then
      bad "$app/$so_name: maxReplicaCount=$so_max"
    fi
    so_trigger="$(yq -r "select(.kind == \"ScaledObject\" and .spec.scaleTargetRef.name == \"$workload\") | .spec.triggers[0].type" "$rendered")"
    [[ "$so_trigger" == "external-push" ]] || bad "$app/$so_name: trigger type=$so_trigger (expected external-push)"
    so_address="$(yq -r "select(.kind == \"ScaledObject\" and .spec.scaleTargetRef.name == \"$workload\") | .spec.triggers[0].metadata.scalerAddress" "$rendered")"
    [[ "$so_address" == "$scaler_address" ]] || bad "$app/$so_name: scalerAddress=$so_address"
    so_route="$(yq -r "select(.kind == \"ScaledObject\" and .spec.scaleTargetRef.name == \"$workload\") | .spec.triggers[0].metadata.interceptorRoute" "$rendered")"
    [[ "$so_route" == "$ir_name" ]] || bad "$app/$so_name: interceptorRoute=$so_route (expected $ir_name)"
    pinned="$(yq -r "select(.kind == \"Deployment\" and .metadata.name == \"$workload\") | .spec.replicas" "$rendered")"
    [[ "$pinned" == "null" ]] || bad "$app: Deployment $workload pins spec.replicas=$pinned (KEDA owns it)"
  done

  # 3. HTTPRoute vers le proxy KEDA
  backends="$(yq 'select(.kind == "HTTPRoute") | .spec.rules[].backendRefs[] | .name + "/" + (.namespace // "") + ":" + (.port | tostring)' "$rendered" | sort -u | tr '\n' ' ')"
  [[ "$backends" == "$proxy/keda:$proxy_port " ]] || bad "$app: HTTPRoute backendRefs=$backends (expected $proxy/keda:$proxy_port)"
  route_host="$(yq -r 'select(.kind == "HTTPRoute") | .spec.hostnames[]' "$rendered" | grep -Fx "$hostname" || true)"
  [[ -n "$route_host" ]] || bad "$app: HTTPRoute does not serve $hostname"

  # 4. ReferenceGrant dans keda/ (namespace porteur : projet Argo `infrastructure`)
  grant="$keda_dir/$app-referencegrant.yaml"
  if [[ ! -f "$grant" ]]; then
    bad "$app: missing $grant"
  else
    grep -Eq "^[[:space:]]*-[[:space:]]+$app-referencegrant\.yaml$" "$keda_dir/kustomization.yaml" ||
      bad "$app: $app-referencegrant.yaml is not rendered by the keda controller"
    grant_from="$(yq -r 'select(.kind == "ReferenceGrant") | .spec.from[] | select(.kind == "HTTPRoute") | .namespace' "$grant")"
    [[ "$grant_from" == "$ns" ]] || bad "$app: ReferenceGrant from namespace=$grant_from (expected $ns)"
    grant_to="$(yq -r 'select(.kind == "ReferenceGrant") | .spec.to[] | .kind + "/" + .name' "$grant")"
    [[ "$grant_to" == "Service/$proxy" ]] || bad "$app: ReferenceGrant to=$grant_to (expected Service/$proxy)"
  fi

  # 5. Le proxy KEDA (namespace keda) atteint le pod : la politique l'admet sur le port du conteneur
  #    (port du conteneur, pas port du Service). Chaque regle d ingress devient une ligne
  #    "<namespaces>|<ports>" ; on retient les regles qui admettent le namespace keda.
  admitted=""
  while IFS= read -r rule; do
    [[ -n "$rule" && "$rule" != "null" ]] || continue
    rule_ns="${rule%%|*}"
    rule_ports="${rule#*|}"
    [[ ",$rule_ns," == *",keda,"* ]] || continue
    admitted="${admitted}${rule_ports//,/ } "
  done < <(yq -r 'select(.kind == "CiliumNetworkPolicy") | .spec.ingress[]? | ([.fromEndpoints[]? | (.matchLabels["k8s:io.kubernetes.pod.namespace"] // "")] | join(",")) + "|" + ([.toPorts[]?.ports[]? | (.port | tostring)] | join(","))' "$rendered")
  if [[ " $admitted " != *" $container_port "* ]]; then
    bad "$app: no CiliumNetworkPolicy admits the keda namespace on port $container_port (admitted: ${admitted:-none})"
  fi
done

if [[ $fail -ne 0 ]]; then
  echo "KEDA_SCALE_TO_ZERO=FAIL"
  exit 1
fi
echo "KEDA_SCALE_TO_ZERO=PASS"
