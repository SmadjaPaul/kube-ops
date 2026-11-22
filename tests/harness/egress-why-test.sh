#!/usr/bin/env bash
# egress-why.sh lit seulement via kubectl-ro.sh get --raw (faux injecté, pas de cluster).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/egress-why-harness.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

cat >"$tmp/kubectl-ro.sh" <<'SH'
#!/usr/bin/env bash
echo "$*" >>"${FAKE_LOG:?}"
[ "$1 $2" = "get --raw" ] || exit 9
case "$3" in
  *loki/api/v1/query_range*) echo '{"data":{"result":[{"metric":{},"values":[[1795299780,"5"],[1795299840,"1"]]}]}}' ;;
  *loki/api/v1/query*Name%20lock*) echo '{"data":{"result":[{"metric":{"dnsName":"stremthru.13377001.xyz."},"value":[0,"7"]}]}}' ;;
  *loki/api/v1/query*) echo '{"data":{"result":[{"metric":{},"value":[0,"12"]}]}}' ;;
  *prometheus*source_workload*) echo '{"data":{"result":[{"metric":{"source_workload":"aiostreams","reason":"POLICY_DENIED","destination":"mise-versions.jdx.dev"},"value":[0,"9.2"]}]}}' ;;
  *prometheus*) echo '{"data":{"result":[{"metric":{"reason":"POLICY_DENIED"},"value":[0,"42.4"]},{"metric":{"reason":"X"},"value":[0,"0"]}]}}' ;;
  *) exit 9 ;;
esac
SH
chmod +x "$tmp/kubectl-ro.sh"
: >"$tmp/ro.log"

run() { KUBECTL_RO_SCRIPT="$tmp/kubectl-ro.sh" FAKE_LOG="$tmp/ro.log" bash "$repo_root/scripts/egress-why.sh" "$@"; }

out=$(run media aiostreams --since 30m --end 2026-11-21T22:30:00Z)
grep -q '7 stremthru.13377001.xyz.' <<<"$out" || { echo "dnsName aggregate missing" >&2; exit 1; }
grep -q '42 POLICY_DENIED' <<<"$out" || { echo "drop aggregate missing" >&2; exit 1; }
grep -q '9 aiostreams POLICY_DENIED mise-versions.jdx.dev' <<<"$out" || { echo "per-workload aggregate missing" >&2; exit 1; }
grep -q 'source_namespace=\"media\"' "$tmp/ro.log" || grep -q 'source_namespace%3D%22media%22' "$tmp/ro.log" || { echo "workload query not scoped to namespace" >&2; exit 1; }
if grep -q ' 0 X$' <<<"$out"; then echo "zero series must be hidden" >&2; exit 1; fi
grep -q '2026-11-21T22:23:00Z 5' <<<"$out" || { echo "burst minute missing" >&2; exit 1; }
# Lecture seule : uniquement des `get --raw` vers le proxy Prometheus/Loki.
if grep -v '^get --raw /api/v1/namespaces/monitoring/services/' "$tmp/ro.log"; then exit 1; fi
[ "$(wc -l <"$tmp/ro.log")" -le 12 ] || { echo "too many queries" >&2; exit 1; }
# Sortie compacte : un agent doit pouvoir la lire en peu de tokens.
[ "$(wc -l <<<"$out")" -le 60 ] || { echo "output too long" >&2; exit 1; }

# Entrées invalides refusées avant toute requête.
: >"$tmp/ro.log"
for args in "media" "Media aiostreams" "media aio\$x" "media aiostreams --since 2d" "media aiostreams --end yesterday"; do
  # shellcheck disable=SC2086
  if run $args >/dev/null 2>&1; then echo "accepted bad args: $args" >&2; exit 1; fi
done
[ ! -s "$tmp/ro.log" ] || { echo "bad args reached kubectl-ro" >&2; exit 1; }

echo "EGRESS_WHY_TEST=PASS"
