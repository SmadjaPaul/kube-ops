#!/usr/bin/env bash
# Post-merge verification of one application on one cluster, from Grafana Cloud
# (read-only, no cluster access). Works from a cloud session.
#
# Usage: bash scripts/verify-delivery.sh CLUSTER APP [--since EPOCH] [--timeout SEC] [--interval SEC]
#   CLUSTER  homelab | oracle-a1 (label `cluster` of the exported metrics)
#   APP      Argo Application name, or its short name (apps-APP and infra-APP are tried)
#   --since  merge time (epoch s). No verdict before since+SETTLE_SECONDS (default 300):
#            Argo refresh (<=180 s) + scrape (60 s) must have run once.
#   --timeout  keep polling up to SEC seconds (default 0 = single check). With a
#            timeout, PASS needs two consecutive passing checks.
# Exit: 0 PASS, 1 FAIL, 2 BLOCKED (usage, token, Grafana unreachable).
# Evidence level: RUNTIME for the observed signal only. The Argo metric carries no
# revision, so RECONCILED at the merge commit is NOT_PROVEN by this script.
set -euo pipefail

usage() { echo "usage: verify-delivery.sh CLUSTER APP [--since EPOCH] [--timeout SEC] [--interval SEC]" >&2; exit 2; }
blocked() { echo "VERIFY=BLOCKED"; echo "LAST_ERROR=$1"; exit 2; }

orig_args=("$@")
cluster=${1:-}; app=${2:-}
[[ -n $cluster && -n $app ]] || usage
shift 2
since=0; timeout=0; interval=30
while [[ $# -gt 0 ]]; do
  case "$1" in
    --since) since=${2:?}; shift 2 ;;
    --timeout) timeout=${2:?}; shift 2 ;;
    --interval) interval=${2:?}; shift 2 ;;
    *) usage ;;
  esac
done
case "$cluster" in homelab|oracle-a1) ;; *) echo "ERROR: CLUSTER must be homelab or oracle-a1" >&2; exit 2 ;; esac
# The values go into PromQL: restrict them.
[[ $app =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || { echo "ERROR: APP must be a DNS-1123 name" >&2; exit 2; }
for n in "$since" "$timeout" "$interval"; do [[ $n =~ ^[0-9]+$ ]] || usage; done
command -v jq >/dev/null && command -v curl >/dev/null || { echo "ERROR: jq and curl required" >&2; exit 2; }

if [[ -z ${GRAFANA_AGENT_READ_TOKEN:-} ]]; then
  [[ -z ${VERIFY_DELIVERY_INNER:-} ]] || blocked "GRAFANA_AGENT_READ_TOKEN missing after Doppler injection"
  here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  rc=0
  out=$(VERIFY_DELIVERY_INNER=1 bash "$here/doppler-safe.sh" run -- bash "${BASH_SOURCE[0]}" "${orig_args[@]}" 2>&1) || rc=$?
  # The inner run always prints a VERIFY= line. Without it, Doppler failed before launching it.
  if (( rc <= 2 )) && grep -q '^VERIFY=' <<<"$out"; then printf '%s\n' "$out"; exit "$rc"; fi
  blocked "Doppler token injection failed before verification (exit $rc); authenticate Doppler"
fi

base=${GRAFANA_URL:-https://smadja.grafana.net}
uid=${GRAFANA_PROM_UID:-grafanacloud-prom}
settle=${SETTLE_SECONDS:-300}
max_age=${MAX_SAMPLE_AGE_SECONDS:-300}

prom() {
  printf 'Authorization: Bearer %s\n' "$GRAFANA_AGENT_READ_TOKEN" | curl -fsS -G -H @- --max-time 30 \
    "$base/api/datasources/proxy/uid/$uid/api/v1/query" --data-urlencode "query=$1" \
    | jq -ce 'select(.status=="success")' || return 1
}

# Sets verdict, reason and the report fields.
check_once() {
  verdict=FAIL; reason=none; argo="none"; pods="n/a"; age="n/a"
  local now; now=$(date +%s)
  if (( since > 0 && now < since + settle )); then
    reason="settling until $((since + settle)) (Argo refresh and scrape)"; return
  fi
  local sel="cluster=\"$cluster\",name=~\"($app|apps-$app|infra-$app)\""
  local a
  a=$(prom "time() - timestamp(argocd_app_info{$sel})") || blocked "Grafana query failed (argocd_app_info)"
  local n; n=$(jq -r '.data.result|length' <<<"$a")
  if (( n == 0 )); then reason="no argocd_app_info series for $app on $cluster (absent app or collection gap)"; return; fi
  if (( n > 1 )); then reason="ambiguous: $n Applications match $app"; return; fi
  local name sync health ns
  name=$(jq -r '.data.result[0].metric.name' <<<"$a")
  sync=$(jq -r '.data.result[0].metric.sync_status' <<<"$a")
  health=$(jq -r '.data.result[0].metric.health_status' <<<"$a")
  ns=$(jq -r '.data.result[0].metric.dest_namespace // ""' <<<"$a")
  age=$(jq -r '.data.result[0].value[1]|tonumber|floor' <<<"$a")
  app_resolved=$name; argo="$sync/$health"
  if [[ $sync != Synced || $health != Healthy ]]; then reason="Argo $argo"; return; fi
  if (( age > max_age )); then reason="stale sample (${age}s old): collection gap, NOT_PROVEN"; return; fi
  if [[ -n $ns && $ns =~ ^[a-z0-9-]+$ ]]; then
    local p total ready
    p=$(prom "kube_pod_status_ready{cluster=\"$cluster\",namespace=\"$ns\",condition=\"true\"} unless on(cluster,namespace,pod) (kube_pod_status_phase{cluster=\"$cluster\",namespace=\"$ns\",phase=\"Succeeded\"} == 1)") \
      || blocked "Grafana query failed (kube_pod_status_ready)"
    total=$(jq -r '.data.result|length' <<<"$p")
    ready=$(jq -r '[.data.result[]|select(.value[1]=="1")]|length' <<<"$p")
    pods="$ready/$total"
    if (( total == 0 )); then
      # No pod series: a namespace without pods, or kube-state-metrics missing. Tell them apart.
      local any
      any=$(prom "count(kube_pod_status_ready{cluster=\"$cluster\",condition=\"true\"})") || blocked "Grafana query failed (kube_pod_status_ready count)"
      if (( $(jq -r '.data.result|length' <<<"$any") == 0 )); then
        reason="no kube_pod_status_ready series on $cluster: pod telemetry gap, NOT_PROVEN"; return
      fi
    fi
    if (( ready != total )); then
      reason="pods not Ready: $(jq -r '[.data.result[]|select(.value[1]!="1")|.metric.pod]|.[0:5]|join(",")' <<<"$p")"; return
    fi
  else
    pods="n/a (destination namespace not single)"
  fi
  verdict=PASS
}

app_resolved=$app
deadline=$(( $(date +%s) + timeout )); need=1; (( timeout > 0 )) && need=2
streak=0
while :; do
  check_once
  if [[ $verdict == PASS ]]; then streak=$((streak + 1)); else streak=0; fi
  (( streak >= need )) && break
  (( $(date +%s) + interval > deadline )) && break
  sleep "$interval"
done
[[ $verdict == PASS && $streak -ge $need ]] || verdict=FAIL

echo "CLUSTER=$cluster"
echo "APP=$app_resolved"
echo "ARGO=$argo"
echo "PODS=$pods"
echo "SAMPLE_AGE_S=$age"
echo "EVIDENCE_LEVEL=RUNTIME"
echo "EVIDENCE_SCOPE=argo-app-sync-health+pods-ready (not routes, DNS, TLS, user path)"
echo "REVISION=NOT_PROVEN"
echo "LAST_ERROR=$reason"
echo "VERIFY=$verdict"
[[ $verdict == PASS ]]
