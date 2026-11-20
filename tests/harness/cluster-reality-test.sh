#!/usr/bin/env bash
# cluster-reality.sh reads only through kubectl-ro.sh (fake injected, no cluster).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cluster-reality-harness.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

cat >"$tmp/bin/kubectl" <<'SH'
#!/usr/bin/env bash
echo "DIRECT_KUBECTL $*" >&2
exit 99
SH
cat >"$tmp/kubectl-ro.sh" <<'SH'
#!/usr/bin/env bash
echo "$*" >>"${FAKE_LOG:?}"
case "$1 $2" in
  "version -o") echo '{"clientVersion":{"gitVersion":"v1.36.0"},"serverVersion":{"gitVersion":"v1.36.3"}}' ;;
  "get --raw") echo '{"data":{"result":[]}}' ;;
  "get externalsecret") exit 1 ;;
  *) echo '{"items":[]}' ;;
esac
SH
chmod +x "$tmp/bin/kubectl" "$tmp/kubectl-ro.sh"
: >"$tmp/ro.log"

PATH="$tmp/bin:$PATH" KUBECTL_RO_SCRIPT="$tmp/kubectl-ro.sh" FAKE_LOG="$tmp/ro.log" \
  bash "$repo_root/scripts/cluster-reality.sh" "$tmp/out.md" >/dev/null

grep -q 'v1.36.3' "$tmp/out.md" || { echo "server version missing from the report" >&2; exit 1; }
if grep -q DIRECT_KUBECTL "$tmp/ro.log"; then exit 1; fi
# every read is a whitelisted verb; no Secret read
awk '$1 != "get" && $1 != "version" {bad=1} END {exit bad}' "$tmp/ro.log"
if grep -Eiq '(^|[ ,/])secrets?([ ,/.]|$)' "$tmp/ro.log"; then exit 1; fi
[[ "$(grep -c '^get --raw ' "$tmp/ro.log")" -eq 5 ]]

echo "CLUSTER_REALITY_KRO_TEST=PASS"
