#!/usr/bin/env bash
# Generate docs/state/cluster-reality.md from the LIVE cluster (read-only).
#
# - Only `kubectl get` / `kubectl get --raw` (Argo, workloads, PVC, CNPG,
#   HTTPRoute, Prometheus and Loki through the API-server service proxy).
# - Never reads Secret values (no `get secret`; only ExternalSecret key names).
# - Idempotent: the output depends only on cluster state (+ the timestamp line).
#
# Usage: bash scripts/cluster-reality.sh [output-file]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/docs/state/cluster-reality.md}"

# shellcheck source=scripts/lib/kube-preflight.sh
source "$ROOT/scripts/lib/kube-preflight.sh"
require_kube_access >/dev/null
trap kube_access_cleanup EXIT

WORK="$(mktemp -d "${TMPDIR:-/tmp}/cluster-reality.XXXXXX")"
trap 'rm -rf "$WORK"; kube_access_cleanup' EXIT

k() { kubectl --request-timeout=60s "$@"; }

k get --raw=/version >"$WORK/version.json"
k get applications.argoproj.io -n argocd -o json >"$WORK/apps.json"
k get deploy,sts,ds,cronjob -A -o json >"$WORK/workloads.json"
k get pods -A -o json >"$WORK/pods.json"
k get pvc -A -o json >"$WORK/pvc.json"
k get clusters.postgresql.cnpg.io -A -o json >"$WORK/cnpg.json"
k get httproute -A -o json >"$WORK/routes.json"
k get externalsecret -A -o json >"$WORK/es.json" 2>/dev/null || echo '{"items":[]}' >"$WORK/es.json"
k get ns -o json >"$WORK/ns.json"

PROM=/api/v1/namespaces/monitoring/services/kube-prometheus-stack-prometheus:9090/proxy/api/v1/query
LOKI=/api/v1/namespaces/monitoring/services/loki-gateway:80/proxy/loki/api/v1/query_range

prom() { # $1 name, $2 promql
  local q
  q="$(jq -rn --arg q "$2" '$q|@uri')"
  k get --raw "$PROM?query=$q" >"$WORK/prom-$1.json" 2>/dev/null || echo '{"data":{"result":[]}}' >"$WORK/prom-$1.json"
}
CPU='sum by (namespace) (rate(container_cpu_usage_seconds_total{container!="",container!="POD"}[5m]))'
MEM='sum by (namespace) (container_memory_working_set_bytes{container!="",container!="POD"})'
prom cpu_avg "avg_over_time(($CPU)[24h:5m])"
prom cpu_max "max_over_time(($CPU)[24h:5m])"
prom mem_avg "avg_over_time(($MEM)[24h:5m])"
prom mem_max "max_over_time(($MEM)[24h:5m])"

# Gateway access logs: count Envoy HTTP access lines over 24h (0 => not measurable).
now="$(date +%s)"
lq="$(jq -rn --arg q '{namespace="kube-system",pod=~"cilium-envoy.*"} |~ "HTTP/[12]"' '$q|@uri')"
k get --raw "$LOKI?query=$lq&limit=1&start=$(((now - 86400) * 1000000000))&end=$((now * 1000000000))" \
  >"$WORK/loki.json" 2>/dev/null || echo '{"data":{"result":[]}}' >"$WORK/loki.json"

python3 -I "$ROOT/scripts/lib/cluster_reality_render.py" "$ROOT" "$WORK" "$OUT"
