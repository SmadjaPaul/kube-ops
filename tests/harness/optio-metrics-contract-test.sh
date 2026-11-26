#!/usr/bin/env bash
# PLT-525 contract: metriques Prometheus de l'API Optio.
#
# L'API sert /metrics sur un port separe quand OPTIO_METRICS_PORT est defini
# (apps/api/src/telemetry/prometheus.ts, amont 0.26.4). Le chart expose ce port
# par un Service dedie (optio-api-metrics) ; le scrape Prometheus est decrit par
# le ServiceMonitor du depot (servicemonitor.yaml), jamais par celui du chart :
# deux ServiceMonitor sur le meme Service doublent les series Prometheus.
#
# Contrat verifie sur le rendu de k8s/applications/platform/optio :
#   - le conteneur api porte OPTIO_METRICS_PORT=9464 et le containerPort "metrics" 9464 ;
#   - le Service optio-api-metrics expose 9464/TCP et rien d'autre ;
#   - un seul ServiceMonitor cible ce Service : label release=kube-prometheus-stack,
#     chemin /metrics, intervalle 60 s ;
#   - la CiliumNetworkPolicy optio-api admet le namespace monitoring sur 9464/TCP,
#     et aucune autre regle n'ouvre 9464.
#
# Statique : rendu Kustomize local (scripts/lib/render-cache.sh), aucun acces cluster.
# Les cas negatifs (copie cassee) doivent etre refuses.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
optio_root="k8s/applications/platform/optio"

command -v yq >/dev/null 2>&1 || { echo 'OPTIO_METRICS_CONTRACT=BLOCKED missing_tool=yq' >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo 'OPTIO_METRICS_CONTRACT=BLOCKED missing_tool=jq' >&2; exit 2; }
command -v helm >/dev/null 2>&1 || { echo 'OPTIO_METRICS_CONTRACT=BLOCKED missing_tool=helm' >&2; exit 2; }

work="$(mktemp -d "${TMPDIR:-/tmp}/optio-metrics-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

rendered="$(cd "$repo_root" && cat "$(bash scripts/lib/render-cache.sh render "$optio_root")")"
printf '%s\n' "$rendered" >"$work/render.yaml"

# JSON (tableau de documents) : les assertions sont en jq, sans la surprise de
# l'operateur `and` de yq.
json_of() { # <fichier yaml> -> tableau JSON sur stdout
  yq -o=json -I=0 '.' "$1" | jq -s '.'
}

json_of "$work/render.yaml" >"$work/render.json"

# --- assertions (un tableau JSON en entree) -----------------------------------------------

check_metrics_env() { # <json> : OPTIO_METRICS_PORT=9464 + containerPort metrics 9464
  jq -e '
    ([.[] | select(.kind == "Deployment" and .metadata.name == "optio-api")
      | .spec.template.spec.containers[] | select(.name == "api")
      | .env[] | select(.name == "OPTIO_METRICS_PORT") | .value] == ["9464"])
    and
    ([.[] | select(.kind == "Deployment" and .metadata.name == "optio-api")
      | .spec.template.spec.containers[] | select(.name == "api")
      | .ports[] | select(.name == "metrics") | .containerPort] == [9464])
  ' "$1" >/dev/null 2>&1
}

check_metrics_service() { # <json> : le Service dedie expose 9464/TCP, rien d'autre
  jq -e '
    ([.[] | select(.kind == "Service" and .metadata.name == "optio-api-metrics")] | length == 1)
    and
    ([.[] | select(.kind == "Service" and .metadata.name == "optio-api-metrics")
      | (.spec.type == "ClusterIP")
      and (.spec.selector.app == "optio-api")
      and (.metadata.labels.app == "optio-api")
      and (.metadata.labels["app.kubernetes.io/component"] == "metrics")
      and ((.spec.ports | length) == 1)
      and (.spec.ports[0].name == "metrics")
      and (.spec.ports[0].port == 9464)
      and (.spec.ports[0].targetPort == "metrics")
      and (.spec.ports[0].protocol == "TCP")] | all)
  ' "$1" >/dev/null 2>&1
}

check_servicemonitor() { # <json> : un seul ServiceMonitor sur le Service metriques
  jq -e '
    ([.[] | select(.kind == "ServiceMonitor"
      and .spec.selector.matchLabels.app == "optio-api"
      and .spec.selector.matchLabels["app.kubernetes.io/component"] == "metrics")] | length == 1)
    and
    ([.[] | select(.kind == "ServiceMonitor"
      and .spec.selector.matchLabels.app == "optio-api"
      and .spec.selector.matchLabels["app.kubernetes.io/component"] == "metrics")
      | (.metadata.namespace == "optio")
      and (.metadata.labels.release == "kube-prometheus-stack")
      and (.spec.namespaceSelector.matchNames == ["optio"])
      and (.spec.selector.matchLabels == {"app": "optio-api", "app.kubernetes.io/component": "metrics"})
      and ((.spec.endpoints | length) == 1)
      and (.spec.endpoints[0].port == "metrics")
      and (.spec.endpoints[0].path == "/metrics")
      and (.spec.endpoints[0].interval == "60s")] | all)
  ' "$1" >/dev/null 2>&1
}

check_networkpolicy() { # <json> : une seule regle ouvre 9464, depuis le namespace monitoring
  jq -e '
    ([.[] | select(.kind == "CiliumNetworkPolicy" and .metadata.name == "optio-api")
      | .spec.ingress[] | select(any(.toPorts[]?; any(.ports[]; .port == "9464")))] | length == 1)
    and
    ([.[] | select(.kind == "CiliumNetworkPolicy" and .metadata.name == "optio-api")
      | .spec.ingress[] | select(any(.toPorts[]?; any(.ports[]; .port == "9464")))
      | ((.toPorts | length) == 1)
      and ((.toPorts[0].ports | length) == 1)
      and (.toPorts[0].ports[0].port == "9464")
      and (.toPorts[0].ports[0].protocol == "TCP")
      and ((.fromEndpoints | length) == 1)
      and (.fromEndpoints[0].matchLabels["k8s:io.kubernetes.pod.namespace"] == "monitoring")
      and ((.fromEndpoints[0].matchLabels | length) == 1)] | all)
  ' "$1" >/dev/null 2>&1
}

# --- le rendu doit passer les quatre assertions ------------------------------------------

check_metrics_env "$work/render.json" ||
  { echo 'OPTIO_METRICS_CONTRACT=FAIL le conteneur api ne porte pas OPTIO_METRICS_PORT=9464 (containerPort metrics)' >&2; exit 1; }
check_metrics_service "$work/render.json" ||
  { echo 'OPTIO_METRICS_CONTRACT=FAIL le Service optio-api-metrics n expose pas 9464/TCP seul' >&2; exit 1; }
check_servicemonitor "$work/render.json" ||
  { echo 'OPTIO_METRICS_CONTRACT=FAIL le ServiceMonitor (release=kube-prometheus-stack, /metrics, 60s) est absent ou incorrect' >&2; exit 1; }
check_networkpolicy "$work/render.json" ||
  { echo 'OPTIO_METRICS_CONTRACT=FAIL la CiliumNetworkPolicy optio-api n admet pas le namespace monitoring sur 9464/TCP seul' >&2; exit 1; }

# --- cas negatifs : chaque variante cassee doit etre refusee ------------------------------

cat >"$work/bad-env.yaml" <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: optio-api
  namespace: optio
spec:
  template:
    spec:
      containers:
        - name: api
          ports:
            - name: metrics
              containerPort: 9464
EOF

cat >"$work/bad-service.yaml" <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: optio-api-metrics
  namespace: optio
  labels:
    app: optio-api
    app.kubernetes.io/component: metrics
spec:
  type: ClusterIP
  selector:
    app: optio-api
  ports:
    - name: metrics
      port: 9464
      targetPort: metrics
EOF

cat >"$work/bad-servicemonitor.yaml" <<'EOF'
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: optio-api
  namespace: optio
  labels:
    release: kube-prometheus-stack
spec:
  namespaceSelector:
    matchNames:
      - optio
  selector:
    matchLabels:
      app: optio-api
      app.kubernetes.io/component: metrics
  endpoints:
    - port: metrics
      path: /metrics
      interval: 30s
EOF

cat >"$work/bad-servicemonitor-duplicate.yaml" <<'EOF'
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: optio-api
  namespace: optio
  labels:
    release: kube-prometheus-stack
spec:
  namespaceSelector:
    matchNames:
      - optio
  selector:
    matchLabels:
      app: optio-api
      app.kubernetes.io/component: metrics
  endpoints:
    - port: metrics
      path: /metrics
      interval: 60s
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: optio-api-chart
  namespace: optio
  labels:
    release: kube-prometheus-stack
spec:
  namespaceSelector:
    matchNames:
      - optio
  selector:
    matchLabels:
      app: optio-api
      app.kubernetes.io/component: metrics
  endpoints:
    - port: metrics
      path: /metrics
      interval: 60s
EOF

cat >"$work/bad-networkpolicy.yaml" <<'EOF'
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: optio-api
  namespace: optio
spec:
  endpointSelector:
    matchLabels:
      app: optio-api
  ingress:
    - fromEntities: [world]
      toPorts:
        - ports:
            - port: "9464"
              protocol: TCP
EOF

for fixture in bad-env bad-service bad-servicemonitor bad-servicemonitor-duplicate bad-networkpolicy; do
  json_of "$work/$fixture.yaml" >"$work/$fixture.json"
done

check_metrics_env "$work/bad-env.json" &&
  { echo 'OPTIO_METRICS_CONTRACT=FAIL self-test: une API sans OPTIO_METRICS_PORT a ete acceptee' >&2; exit 1; }
check_metrics_service "$work/bad-service.json" &&
  { echo 'OPTIO_METRICS_CONTRACT=FAIL self-test: un Service metriques sans port 9464 a ete accepte' >&2; exit 1; }
check_servicemonitor "$work/bad-servicemonitor.json" &&
  { echo 'OPTIO_METRICS_CONTRACT=FAIL self-test: un ServiceMonitor a 30 s a ete accepte' >&2; exit 1; }
check_servicemonitor "$work/bad-servicemonitor-duplicate.json" &&
  { echo 'OPTIO_METRICS_CONTRACT=FAIL self-test: deux ServiceMonitor sur le Service metriques ont ete acceptes' >&2; exit 1; }
check_networkpolicy "$work/bad-networkpolicy.json" &&
  { echo 'OPTIO_METRICS_CONTRACT=FAIL self-test: une regle 9464 ouverte au monde a ete acceptee' >&2; exit 1; }

echo 'OPTIO_METRICS_CONTRACT=PASS'
