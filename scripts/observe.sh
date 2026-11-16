#!/usr/bin/env bash
# Compact, read-only cluster state for agents (PLT-312, .agents/skills/observability).
#
# Usage: bash scripts/observe.sh [--local] [summary|alerts|backups|app <name>]
#   summary  targets, firing alerts, nodes, pods, Argo, series budget (default)
#   alerts   firing alerts by cluster / alertname / severity
#   backups  CNPG, Velero, Longhorn, PVC, certificates
#   app X    one app: Argo state, pods, restarts, error logs (namespace X)
#
# Default source: Grafana Cloud (both clusters, label `cluster`), through
# GRAFANA_AGENT_READ_TOKEN (Doppler infrastructure/prd, injected by
# scripts/doppler-safe.sh, never printed: the header goes through curl stdin).
# --local: Prometheus/Loki inside each cluster via `kubectl-ro.sh get --raw`
# (homelab only: oracle-a1 has no local Prometheus/Loki); needs no Grafana token.
# Read-only: GET queries only, no silence, no write. Output: one short line per
# result, at most OBSERVE_MAX rows (default 12) per question.
# Exit: 0 ok, 2 token/tool absent or bad usage, 1 at least one query failed.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
GRAFANA_URL=${GRAFANA_URL:-https://smadja.grafana.net}
PROM_UID=grafanacloud-prom
LOKI_UID=grafanacloud-logs
MAX=${OBSERVE_MAX:-12}
RAW_SVC=/api/v1/namespaces/monitoring/services
# oracle-a1 runs only Alloy and kube-state-metrics (no local Prometheus/Loki).
LOCAL_CLUSTERS=(homelab)

die() {
  echo "observe: $*" >&2
  exit 2
}

local_mode=0
if [ "${1:-}" = --local ]; then
  local_mode=1
  shift
fi
cmd=${1:-summary}
app=${2:-}
case "$cmd" in
  summary | alerts | backups) [ "$#" -le 1 ] || die "usage: observe.sh [--local] [summary|alerts|backups|app <name>]" ;;
  app)
    [ "$#" -eq 2 ] || die "app needs a name"
    [[ $app =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || die "app name must be a DNS label"
    ;;
  *) die "usage: observe.sh [--local] [summary|alerts|backups|app <name>]" ;;
esac
for t in curl jq; do command -v "$t" >/dev/null || die "$t required"; done

# Token: present in the environment, or injected by re-executing under doppler-safe.
if [ "$local_mode" -eq 0 ] && [ -z "${GRAFANA_AGENT_READ_TOKEN:-}" ]; then
  [ -z "${OBSERVE_INNER:-}" ] || die "GRAFANA_AGENT_READ_TOKEN absent from the injected environment (use --local)"
  if ! bash "$HERE/doppler-safe.sh" has GRAFANA_AGENT_READ_TOKEN >/dev/null 2>&1; then
    die "GRAFANA_AGENT_READ_TOKEN absent or Doppler unreachable; nothing queried (retry with --local for in-cluster Prometheus)"
  fi
  export OBSERVE_INNER=1
  exec bash "$HERE/doppler-safe.sh" run --only GRAFANA_AGENT_READ_TOKEN -- bash "$HERE/observe.sh" "$@"
fi

failed=0

urlenc() { jq -rn --arg v "$1" '$v|@uri'; }

# raw_get CLUSTER PATH: Grafana ignores CLUSTER; local goes through kubectl-ro.
grafana_get() { # $1 = datasource uid, $2 = api path, rest = curl -G data args
  local uid=$1 path=$2
  shift 2
  printf 'Authorization: Bearer %s\n' "$GRAFANA_AGENT_READ_TOKEN" |
    curl -fsS --max-time 30 -G -H @- "$GRAFANA_URL/api/datasources/proxy/uid/$uid/$path" "$@"
}
local_get() { # $1 = cluster, $2 = service proxy path incl. encoded query
  bash "$HERE/kubectl-ro.sh" --cluster "$1" get --raw "$2"
}

# fmt_rows CLUSTER_DEFAULT: Prometheus vector JSON on stdin -> short lines.
fmt_rows() {
  jq -r --arg c "$1" --argjson max "$MAX" '
    (.data.result // []) as $r
    | ($r | length) as $n
    | $r[:$max][]
    | "  \(.metric.cluster // $c) \(.metric | del(.cluster, .__name__, .instance, .container, .endpoint, .service) | to_entries | map("\(.key)=\(.value)") | join(" ")) => \(.value[1] | tonumber | . * 100 | round / 100)"
    , (if $n > $max then "  ... +\($n - $max) more" else empty end)' | cut -c1-150
}

# q LABEL PROMQL: one instant query on every cluster; prints a title and rows.
q() {
  local label=$1 promql=$2 out n c
  if [ "$local_mode" -eq 0 ]; then
    if ! out=$(grafana_get "$PROM_UID" api/v1/query --data-urlencode "query=$promql" 2>/dev/null); then
      echo "ERR $label (Grafana query failed)"
      failed=1
      return
    fi
    n=$(jq '.data.result | length' <<<"$out")
    echo "$label: $n"
    [ "$n" -eq 0 ] || fmt_rows x <<<"$out"
  else
    for c in "${LOCAL_CLUSTERS[@]}"; do
      if ! out=$(local_get "$c" "$RAW_SVC/kube-prometheus-stack-prometheus:9090/proxy/api/v1/query?query=$(urlenc "$promql")" 2>/dev/null); then
        echo "ERR $label [$c] (local Prometheus unreachable)"
        failed=1
        continue
      fi
      n=$(jq '.data.result | length' <<<"$out")
      echo "$label [$c]: $n"
      [ "$n" -eq 0 ] || fmt_rows "$c" <<<"$out"
    done
  fi
}

# logs NAMESPACE: warnings/errors of the last hour, 10 lines per cluster, time-less.
logs() {
  local ns=$1 sel out c now start
  now=$(date +%s)
  start=$((now - 3600))
  if [ "$local_mode" -eq 0 ]; then
    sel="{cluster=~\".+\",namespace=\"$ns\"} |~ \"(?i)level=\\\"?(error|fatal)\""
    if ! out=$(grafana_get "$LOKI_UID" loki/api/v1/query_range --data-urlencode "query=$sel" \
      --data-urlencode "limit=10" --data-urlencode "start=${start}000000000" --data-urlencode "end=${now}000000000" 2>/dev/null); then
      echo "ERR logs (Grafana Loki query failed)"
      failed=1
      return
    fi
    echo "error logs 1h:"
    jq -r '[.data.result[] | .stream.cluster as $c | .values[] | [$c, .[1]]] | .[:10][] | "  \(.[0]) \(.[1])"' <<<"$out" | cut -c1-150
  else
    sel="{namespace=\"$ns\"} |~ \"(?i)level=\\\"?(error|fatal)\""
    for c in "${LOCAL_CLUSTERS[@]}"; do
      if ! out=$(local_get "$c" "$RAW_SVC/loki-gateway:80/proxy/loki/api/v1/query_range?query=$(urlenc "$sel")&limit=10&start=${start}000000000&end=${now}000000000" 2>/dev/null); then
        echo "ERR logs [$c] (local Loki unreachable)"
        failed=1
        continue
      fi
      echo "error logs 1h [$c]:"
      jq -r --arg c "$c" '[.data.result[] | .values[] | .[1]] | .[:10][] | "  \($c) \(.)"' <<<"$out" | cut -c1-150
    done
  fi
}

# Metrics that never mean trouble: Watchdog and InfoInhibitor.
ALERTS_Q='count by (cluster, alertname, severity) (ALERTS{alertstate="firing",alertname!~"Watchdog|InfoInhibitor"})'

do_summary() {
  q "targets up by cluster" 'count by (cluster) (up == 1)'
  q "targets down" 'count by (cluster, job) (up == 0)'
  q "firing alerts (no Watchdog)" 'count by (cluster, severity) (ALERTS{alertstate="firing",alertname!~"Watchdog|InfoInhibitor"})'
  q "nodes not Ready" 'kube_node_status_condition{condition="Ready",status="true"} == 0'
  q "node pressure" 'kube_node_status_condition{condition=~".*Pressure",status="true"} == 1'
  q "pods Pending/Failed/Unknown 15m" 'sum by (cluster, namespace, pod, phase) (min_over_time(kube_pod_status_phase{phase=~"Pending|Failed|Unknown"}[15m])) > 0'
  q "waiting reasons" 'count by (cluster, namespace, reason) (kube_pod_container_status_waiting_reason)'
  q "restarts 1h" 'topk(5, increase(kube_pod_container_status_restarts_total[1h]) > 0)'
  q "Argo not Synced/Healthy" 'count by (cluster, name, sync_status, health_status) (argocd_app_info{sync_status!="Synced"} or argocd_app_info{health_status!="Healthy"})'
  q "series budget (< 8000)" 'count by (cluster) ({cluster=~"homelab|oracle-a1"})'
}

do_alerts() {
  q "firing alerts" "$ALERTS_Q"
  echo "note: oracle-a1 exports no ALERTS series; its absence is a collection gap"
}

do_backups() {
  q "CNPG last backup age h" '(time() - cnpg_collector_last_available_backup_timestamp) / 3600'
  q "CNPG WAL archive failing" 'cnpg_pg_stat_archiver_last_failed_time > cnpg_pg_stat_archiver_last_archived_time'
  q "Velero last success age h" '(time() - velero_backup_last_successful_timestamp) / 3600'
  q "Longhorn volumes not healthy" 'longhorn_volume_robustness{state!="healthy"} == 1'
  q "PVC > 90% full" 'kubelet_volume_stats_available_bytes / kubelet_volume_stats_capacity_bytes < 0.1'
  q "certificates < 14 days" '(certmanager_certificate_expiration_timestamp_seconds - time()) / 86400 < 14'
}

do_app() {
  q "Argo app $app" "argocd_app_info{name=\"$app\"}"
  q "pods not ready in $app" "sum by (cluster, namespace, pod) (kube_pod_status_ready{condition=\"true\",namespace=\"$app\"}) == 0"
  q "waiting reasons in $app" "count by (cluster, namespace, reason) (kube_pod_container_status_waiting_reason{namespace=\"$app\"})"
  q "restarts 1h in $app" "topk(5, increase(kube_pod_container_status_restarts_total{namespace=\"$app\"}[1h]) > 0)"
  logs "$app"
}

[ "$local_mode" -eq 0 ] || echo "oracle-a1: no local Prometheus/Loki, use the Grafana mode"
echo "observe $cmd ($([ "$local_mode" -eq 1 ] && echo local || echo grafana)) $(date -u +%FT%TZ)"
case "$cmd" in
  summary) do_summary ;;
  alerts) do_alerts ;;
  backups) do_backups ;;
  app) do_app ;;
esac
exit "$failed"
