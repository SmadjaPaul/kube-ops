#!/usr/bin/env bash
# Pourquoi l'egress d'un pod échoue-t-il ? Résumé pré-agrégé, en lecture seule,
# pour agents et opérateurs (runbook docs/runbooks/egress-why.md).
#
# Usage: bash scripts/egress-why.sh <namespace> <container> [--since 30m] [--end RFC3339]
#   container  nom du conteneur applicatif dans Loki (souvent le nom de l'app)
#   --since    fenêtre (s|m|h, défaut 30m, max 24h)
#   --end      fin de fenêtre en UTC (défaut : maintenant)
#
# Sources : Prometheus et Loki du cluster homelab via `kubectl-ro.sh get --raw`
# (aucun port-forward, aucun jeton Grafana). Sortie : une ligne par signal, au
# plus EGRESS_WHY_MAX lignes (défaut 8) par question, puis un verdict heuristique.
# Limites connues : les métriques hubble_* n'ont pas de label de pod (drops et
# DNS sont globaux au nœud) ; seuls les logs cilium-agent "Name lock" portent un
# dnsName. Une preuve par flux exige `hubble observe` (skill cilium-hubble).
# Sortie : 0 ok, 2 usage/outil absent, 1 au moins une requête en échec.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
KRO=${KUBECTL_RO_SCRIPT:-$HERE/kubectl-ro.sh}
MAX=${EGRESS_WHY_MAX:-8}
SVC=/api/v1/namespaces/monitoring/services
PROM=$SVC/kube-prometheus-stack-prometheus:9090/proxy/api/v1
LOKI=$SVC/loki-gateway:80/proxy/loki/api/v1
APP_ERR='ETIMEDOUT|ECONNREFUSED|ECONNRESET|ENOTFOUND|EAI_AGAIN|fetch failed|UND_ERR_CONNECT_TIMEOUT'

die() {
  echo "egress-why: $*" >&2
  exit 2
}
usage="usage: egress-why.sh <namespace> <container> [--since 30m] [--end RFC3339]"

[ "$#" -ge 2 ] || die "$usage"
ns=$1 ctr=$2
shift 2
since=30m end=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --since) since=${2:-}; shift 2 || die "$usage" ;;
    --end) end=${2:-}; shift 2 || die "$usage" ;;
    *) die "$usage" ;;
  esac
done
dns_label='^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$'
[[ $ns =~ $dns_label ]] || die "namespace must be a DNS label"
[[ $ctr =~ $dns_label ]] || die "container must be a DNS label"
[[ $since =~ ^([0-9]+)([smh])$ ]] || die "--since must look like 30m, 2h or 90s"
case "${BASH_REMATCH[2]}" in s) win=${BASH_REMATCH[1]} ;; m) win=$((BASH_REMATCH[1] * 60)) ;; h) win=$((BASH_REMATCH[1] * 3600)) ;; esac
[ "$win" -ge 60 ] && [ "$win" -le 86400 ] || die "--since must be between 1m and 24h"
for t in jq date; do command -v "$t" >/dev/null || die "$t required"; done

if [ -z "$end" ]; then
  end_s=$(date -u +%s)
elif [[ $end =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
  # GNU date puis BSD date (macOS).
  end_s=$(date -u -d "$end" +%s 2>/dev/null || date -j -u -f %Y-%m-%dT%H:%M:%SZ "$end" +%s 2>/dev/null) ||
    die "--end not parsable"
else
  die "--end must be RFC3339 UTC (2026-11-21T23:00:00Z)"
fi
start_s=$((end_s - win))
rng="${win}s"
failed=0

urlenc() { jq -rn --arg v "$1" '$v|@uri'; }
raw() { bash "$KRO" get --raw "$1"; }
# prom LABEL PROMQL JQ : requête instantanée à end_s, une ligne par série.
prom() {
  local out
  if ! out=$(raw "$PROM/query?query=$(urlenc "$2")&time=$end_s" 2>/dev/null); then
    echo "ERR $1 (Prometheus local injoignable)"
    failed=1
    return
  fi
  jq -r --arg l "$1" --argjson max "$MAX" '
    [(.data.result // [])[] | {k: (.metric | del(.__name__) | to_entries | map(.value) | join(" ")), v: (.value[1] | tonumber | round)} | select(.v > 0)]
    | sort_by(-.v) as $r
    | if ($r | length) == 0 then "\($l): 0" else "\($l):", ($r[:$max][] | "  \(.v) \(.k)") end' <<<"$out"
}
# loki LABEL LOGQL : requête métrique instantanée à end_s.
loki() {
  local out
  if ! out=$(raw "$LOKI/query?query=$(urlenc "$2")&time=${end_s}000000000" 2>/dev/null); then
    echo "ERR $1 (Loki local injoignable)"
    failed=1
    return
  fi
  jq -r --arg l "$1" --argjson max "$MAX" '
    [(.data.result // [])[] | {k: (.metric | to_entries | map(.value) | join(" ")), v: (.value[1] | tonumber | round)}]
    | sort_by(-.v) as $r
    | if ($r | length) == 0 then "\($l): 0" else "\($l):", ($r[:$max][] | "  \(.v) \(.k)") end' <<<"$out"
}
# bursts : minutes avec au moins 3 erreurs applicatives (horodatage UTC).
bursts() {
  local q out
  q="sum(count_over_time({namespace=\"$ns\",container=\"$ctr\"} |~ \"$APP_ERR\" [1m]))"
  if ! out=$(raw "$LOKI/query_range?query=$(urlenc "$q")&start=${start_s}000000000&end=${end_s}000000000&step=60" 2>/dev/null); then
    echo "ERR bursts (Loki local injoignable)"
    failed=1
    return
  fi
  jq -r --argjson max "$MAX" '
    [(.data.result // [])[0].values // [] | .[] | select((.[1] | tonumber) >= 3)]
    | sort_by(-(.[1] | tonumber)) as $b
    | "bursts (>=3 erreurs/min): \($b | length)", ($b[:$max][] | "  \(.[0] | tonumber | todate) \(.[1])")' <<<"$out"
}

echo "egress-why $ns/$ctr $(date -u -r "$start_s" +%FT%TZ 2>/dev/null || date -u -d "@$start_s" +%FT%TZ) +$since"
cil='{namespace="kube-system",container="cilium-agent"}'
loki "app errors by kind" "sum by (kind) (count_over_time({namespace=\"$ns\",container=\"$ctr\"} |~ \"$APP_ERR\" | regexp \"(?P<kind>$APP_ERR)\" [$rng]))"
bursts
loki "cilium fqdn datapath timeouts" "sum(count_over_time($cil |= \"Timed out waiting for datapath updates\" [$rng]))"
loki "cilium dns name-lock waits by dnsName" "sum by (dnsName) (count_over_time($cil |= \"Name lock acquisition\" | logfmt [$rng]))"
prom "hubble drops by reason (node-wide)" "sum by (reason, protocol) (increase(hubble_drop_total[$rng]))"
prom "cilium egress drops (node-wide)" "sum by (reason) (increase(cilium_drop_count_total{direction=\"EGRESS\"}[$rng]))"
prom "dns errors by rcode (node-wide)" "sum by (rcode) (increase(hubble_dns_responses_total{rcode!=\"No Error\",rcode!=\"Non-Existent Domain\"}[$rng]))"
prom "fqdn proxy answers waiting >1s for datapath" "sum(increase(cilium_proxy_upstream_reply_seconds_bucket{scope=\"dataplaneTime\",le=\"+Inf\"}[$rng])) - sum(increase(cilium_proxy_upstream_reply_seconds_bucket{scope=\"dataplaneTime\",le=\"1.0\"}[$rng]))"
prom "hubble lost events" "sum by (source) (increase(hubble_lost_events_total[$rng]))"
echo "hint: a name in 'name-lock waits' that the app calls, at the minute of a burst, means the DNS answer"
echo "      left the proxy before toFQDNs allowed its IP: first SYNs dropped, ETIMEDOUT/fetch failed."
echo "      Per-flow proof: bash .agents/skills/cilium-hubble/scripts/hubble-check.sh $ns"
exit "$failed"
