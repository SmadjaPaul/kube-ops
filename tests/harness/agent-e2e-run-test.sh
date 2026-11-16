#!/usr/bin/env bash
# agent-e2e-run.sh hands CMD the agent-e2e token only, and never prints it.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
# Fake doppler: `doppler run -p P -c C -- CMD` exports a fixture and runs CMD.
cat > "$TMP/doppler" <<'F'
#!/usr/bin/env bash
[ "$1" = run ] || exit 1
shift; while [ "$1" != -- ]; do shift; done; shift
[ "${FAKE_NO_TOKEN:-}" = 1 ] || export APP_AGENT_E2E_TOKEN=fixture-token-0123456789
export APP_OTHER_SECRET=other-secret-0123456789
exec "$@"
F
chmod +x "$TMP/doppler"
fail() { echo "FAIL: $*" >&2; exit 1; }
out=$(DOPPLER_SAFE_BIN="$TMP/doppler" bash "$ROOT/scripts/agent-e2e-run.sh" -- bash -c \
  'echo "has_token=${AGENT_E2E_TOKEN:+yes}"; echo "other=${APP_OTHER_SECRET:-none}"; echo "raw_app=${APP_AGENT_E2E_TOKEN:-none}"; echo "$AGENT_E2E_TOKEN"' 2>&1) || fail "run exit"
grep -q '^has_token=yes$' <<<"$out" || fail "token missing in child"
grep -q '^other=none$' <<<"$out" || fail "other secret leaked to child"
grep -q '^raw_app=none$' <<<"$out" || fail "APP_ token name leaked to child"
grep -q 'fixture-token' <<<"$out" && fail "token value printed"
grep -q 'MASQUÉ' <<<"$out" || fail "token not masked"
FAKE_NO_TOKEN=1 DOPPLER_SAFE_BIN="$TMP/doppler" bash "$ROOT/scripts/agent-e2e-run.sh" -- true >/dev/null 2>&1 && fail "missing token must fail"
bash "$ROOT/scripts/agent-e2e-run.sh" 2>/dev/null && fail "no command must fail"
echo "agent-e2e-run-test: PASS"
