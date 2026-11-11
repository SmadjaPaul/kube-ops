#!/usr/bin/env bash
# Offline test of supervisor.sh (PLT-201): DRY_RUN + simulated clock, no network, no claude.
# Usage: bash scripts/night-relay/test_supervisor.sh
# Assertions are eval'd strings on purpose (late expansion):
# shellcheck disable=SC2016,SC2034
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SUP=$HERE/supervisor.sh
WORK=$(mktemp -d "${TMPDIR:-/tmp}/night-relay-test.XXXXXX")
trap '[ -n "${KEEP:-}" ] || rm -rf "$WORK"' EXIT  # KEEP=1 keeps the work dir
export TZ=UTC

# Sentinel: any real claude/doppler/curl call fails the test.
mkdir -p "$WORK/bin"
for tool in claude doppler curl gh; do
  printf '#!/bin/sh\necho "appel interdit : %s" >>"%s/forbidden"\nexit 99\n' "$tool" "$WORK" >"$WORK/bin/$tool"
  chmod +x "$WORK/bin/$tool"
done
export PATH="$WORK/bin:$PATH"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "ok   - $1"; }
ko() { FAIL=$((FAIL + 1)); echo "FAIL - $1"; }
check() { if (set +o pipefail; eval "$2"); then ok "$1"; else ko "$1"; fi; }

epoch() { # epoch "YYYY-MM-DD HH:MM" (UTC)
  if date --version >/dev/null 2>&1; then date -d "$1:00" +%s; else date -j -f "%Y-%m-%d %H:%M:%S" "$1:00" +%s; fi
}

run() { # run NAME START [VAR=VALUE...]
  local name=$1 start=$2; shift 2
  local dir=$WORK/$name
  mkdir -p "$dir"
  local rc=0
  env DRY_RUN=1 NIGHT_RELAY_FAKE_NOW="$(epoch "$start")" \
    NIGHT_RELAY_STATE="$dir/state" NIGHT_RELAY_HANDOFF_DIR="$dir/handoff" \
    CLAUDE_BIN="$WORK/bin/claude" "$@" bash "$SUP" >"$dir/stdout" 2>"$dir/stderr" || rc=$?
  echo "$rc" >"$dir/rc"
}

logs() { cat "$WORK/$1/state/supervisor.log.1" "$WORK/$1/state/supervisor.log" 2>/dev/null; }
size() { wc -c <"$1" | tr -d ' '; }

# --- 1. nominal night: chaining, handoff passing, quota with reset time, bounded log, report
run main "2026-11-11 22:00" DRY_RUN_QUOTA_ATTEMPTS=2 DRY_RUN_QUOTA_RESET_IN=3600
M=$WORK/main
check "main: exit 0" '[ "$(cat $M/rc)" = 0 ]'
check "main: waits for 23:00 before first cycle" \
  'logs main | grep "lancement orchestrateur" | head -1 | grep -q "^2026-11-11T23:00"'
n=$(find "$M/handoff" -name '2026-11-11-[0-9]*.md' | wc -l | tr -d ' ')
check "main: several cycles chained ($n handoffs)" '[ "$n" -ge 4 ]'
check "main: first handoff has no predecessor" 'grep -q "^precedent: aucun$" "$M/handoff/2026-11-11-1.md"'
chain=1
for i in $(seq 2 "$n"); do
  grep -q "^precedent: $M/handoff/2026-11-11-$((i - 1)).md$" "$M/handoff/2026-11-11-$i.md" || chain=0
done
check "main: each handoff N received handoff N-1" '[ "$chain" = 1 ]'
check "main: quota detected with parsed reset time" 'logs main | grep -q "limite d.usage : réinitialisation à"'
check "main: quota attempt retried as same cycle (prompt 3 is cycle 2)" \
  'grep -q "^- Cycle : 2026-11-11-2$" "$M/state/dry-run/prompt-3.txt"'
t_quota=$(logs main | grep "limite d.usage" | head -1 | cut -c1-19 || true)
t_retry=$(logs main | grep "cycle 2026-11-11-2 : lancement" | sed -n 2p | cut -c1-19 || true)
check "main: retry waits past reset ($t_quota -> $t_retry)" '[[ "$t_retry" > "2026-11-12T01:30" ]]'
check "main: no cycle launched after 08:30" \
  '! logs main | grep "lancement orchestrateur" | cut -c1-16 | awk "\$0 >= \"2026-11-12T08:30\"" | grep -q .'
check "main: report launched at/after 09:00" \
  'logs main | grep "rapport : lancement" | cut -c1-16 | awk "\$0 >= \"2026-11-12T09:00\"" | grep -q .'
check "main: report launched exactly at 09:00" \
  'logs main | grep "rapport : lancement" | head -1 | grep -q "^2026-11-12T09:00:00"'
check "main: report written" '[ -f "$M/handoff/2026-11-11-rapport.md" ]'
check "main: report prompt lists night handoffs" \
  'grep -q "$M/handoff/2026-11-11-1.md" "$M/state/runs/2026-11-11-rapport.prompt.md"'
check "main: lock released" '[ ! -d "$M/state/supervisor.lock" ]'

# --- 1b. bounded log: tiny LOG_MAX_BYTES forces rotation, one old file kept
run logbound "2026-11-11 22:00" LOG_MAX_BYTES=400
L=$WORK/logbound/state
check "logbound: log rotated" '[ -f "$L/supervisor.log.1" ]'
check "logbound: no file beyond .1" '[ ! -e "$L/supervisor.log.2" ]'
check "logbound: each log <= 400 bytes" \
  '[ "$(size $L/supervisor.log)" -le 400 ] && [ "$(size $L/supervisor.log.1)" -le 400 ]'
check "logbound: latest line kept" 'grep -q "fin du superviseur" "$L/supervisor.log"'

# --- 2. quota without reset time: bounded fallback sleep, no tight loop
run fallback "2026-11-11 23:30" DRY_RUN_QUOTA_ATTEMPTS="1,2,3" QUOTA_FALLBACK_SLEEP=1800
F=$WORK/fallback
check "fallback: unknown reset -> bounded wait logged" \
  '[ "$(logs fallback | grep -c "heure de réinitialisation inconnue")" = 3 ]'
attempts=$(find "$F/state/dry-run" -name 'prompt-*.txt' | wc -l | tr -d ' ')
check "fallback: attempts stay bounded ($attempts sessions in the night)" '[ "$attempts" -le 12 ]'
check "fallback: cycle 1 eventually done" 'grep -q "^statut: continue" "$F/handoff/2026-11-11-1.md"'

# --- 2b. "resets 3am" style message: wait until 03:00 + margin
run clock "2026-11-12 01:00" DRY_RUN_QUOTA_ATTEMPTS=1 DRY_RUN_QUOTA_MSG="You've hit your limit · resets 3am"
check "clock: parsed 03:00 reset" 'logs clock | grep -q "réinitialisation à 03:00"'
check "clock: relaunch after 03:00" \
  'logs clock | grep "lancement orchestrateur" | sed -n 2p | grep -q "^2026-11-12T03:0[2-9]"'

# --- 2c. usage limit during the report: waits then retries before the deadline
run report_quota "2026-11-12 08:00" DRY_RUN_QUOTA_ATTEMPTS=2 DRY_RUN_QUOTA_RESET_IN=1800 DRY_RUN_CYCLE_SECONDS=600
check "report_quota: report retried after limit" \
  '[ "$(logs report_quota | grep -c "rapport : lancement")" = 2 ] && logs report_quota | grep -q "rapport : terminé (code 0)"'

# --- 3. failed session: supervisor writes a stub handoff and the chain goes on
run fail "2026-11-11 23:00" DRY_RUN_QUOTA_ATTEMPTS="" DRY_RUN_FAIL_ATTEMPTS=1 FAIL_BACKOFF=60
X=$WORK/fail
check "fail: stub handoff written" 'grep -q "^statut: echec" "$X/handoff/2026-11-11-1.md"'
check "fail: next cycle receives the stub" \
  'grep -q "^precedent: $X/handoff/2026-11-11-1.md$" "$X/handoff/2026-11-11-2.md"'

# --- 4. empty queue: long pause instead of relaunching immediately
run empty "2026-11-11 23:00" DRY_RUN_QUOTA_ATTEMPTS="" DRY_RUN_EMPTY_ATTEMPTS="1,2,3,4,5,6,7,8"
check "empty: pause logged" 'logs empty | grep -q "file vide : pause"'

# --- 5. started inside the window after midnight: same night, immediate start
run late "2026-11-12 02:00" DRY_RUN_QUOTA_ATTEMPTS=""
check "late: night is 2026-11-11 and starts at 02:00" \
  'logs late | grep "lancement orchestrateur" | head -1 | grep -q "^2026-11-12T02:00.*2026-11-11-1"'

# --- 6. single instance
mkdir -p "$WORK/lock/state/supervisor.lock"
echo $$ >"$WORK/lock/state/supervisor.lock/pid"
run lock "2026-11-11 22:00"
check "lock: second supervisor refused" '[ "$(cat $WORK/lock/rc)" = 1 ] && grep -q "déjà actif" "$WORK/lock/stderr"'

# --- 6b. stale lock (dead pid) is taken over; empty pid file taken over after retries
sh -c 'exit 0' & dead=$!; wait "$dead" || true
mkdir -p "$WORK/stale/state/supervisor.lock"
echo "$dead" >"$WORK/stale/state/supervisor.lock/pid"
run stale "2026-11-12 08:00" DRY_RUN_QUOTA_ATTEMPTS="" DRY_RUN_CYCLE_SECONDS=600
check "stale: dead pid lock taken over, night completed" \
  '[ "$(cat $WORK/stale/rc)" = 0 ] && logs stale | grep -q "fin du superviseur" && [ ! -d "$WORK/stale/state/supervisor.lock" ]'
mkdir -p "$WORK/emptypid/state/supervisor.lock"
: >"$WORK/emptypid/state/supervisor.lock/pid"
run emptypid "2026-11-12 08:00" DRY_RUN_QUOTA_ATTEMPTS="" DRY_RUN_CYCLE_SECONDS=600 LOCK_RETRIES=1
check "emptypid: empty pid file taken over after retry" '[ "$(cat $WORK/emptypid/rc)" = 0 ]'

# --- 7. repeated (false) usage limits do not bypass MAX_FAILS
run quotabound "2026-11-11 23:00" DRY_RUN_QUOTA_ATTEMPTS="$(seq -s, 1 40)" QUOTA_MAX_RETRIES=2 \
  QUOTA_FALLBACK_SLEEP=300 MAX_FAILS=2 FAIL_BACKOFF=60
check "quotabound: quota streak counted as failure" \
  'logs quotabound | grep -q "compté comme échec" && logs quotabound | grep -q "trop d.échecs consécutifs"'
q=$(logs quotabound | grep -c "lancement orchestrateur" || true)
check "quotabound: bounded sessions ($q)" '[ "$q" = 6 ]'

# --- 8. real mode with a fake claude: SIGTERM kills the session tree and its watchdog
S=$WORK/signal
mkdir -p "$S/state" "$S/handoff"
cat >"$WORK/fakeclaude" <<EOF
#!/usr/bin/env bash
cat >/dev/null
sleep 300 & echo \$! >"$S/child.pid"
echo \$\$ >"$S/claude.pid"
wait
EOF
chmod +x "$WORK/fakeclaude"
h=$(date -u +%H)
env TZ=UTC NIGHT_RELAY_REPO="$WORK" NIGHT_RELAY_STATE="$S/state" NIGHT_RELAY_HANDOFF_DIR="$S/handoff" \
  CLAUDE_BIN="$WORK/fakeclaude" START_HM="$(printf '%02d00' $(( (10#$h + 23) % 24 )))" \
  STOP_HM="$(printf '%02d00' $(( (10#$h + 3) % 24 )))" MIN_CYCLE_SECONDS=60 ORCH_TIMEOUT=7717 KILL_GRACE=2 \
  bash "$SUP" >"$S/stdout" 2>"$S/stderr" &
sup=$!
for _ in $(seq 1 50); do [ -s "$S/claude.pid" ] && [ -s "$S/child.pid" ] && break; sleep 0.2; done
sleep 0.5
kill -TERM "$sup"
src=0; wait "$sup" || src=$?
cpid=$(cat "$S/claude.pid" 2>/dev/null || echo 0); kpid=$(cat "$S/child.pid" 2>/dev/null || echo 0)
check "signal: fake session started" '[ "$cpid" != 0 ] && [ "$kpid" != 0 ]'
check "signal: supervisor exits 130" '[ "$src" = 130 ]'
check "signal: no surviving session process" '! kill -0 "$cpid" 2>/dev/null && ! kill -0 "$kpid" 2>/dev/null'
check "signal: no surviving watchdog" '! pgrep -f "sleep 7717" >/dev/null'
check "signal: stderr file removed" '! ls "$S"/state/runs/*.err >/dev/null 2>&1'
check "signal: lock released" '[ ! -d "$S/state/supervisor.lock" ]'
check "signal: stop logged" 'grep -q "signal reçu" "$S/state/supervisor.log"'

check "no claude/doppler/curl/gh call" '[ ! -f "$WORK/forbidden" ]'

echo "# $PASS ok, $FAIL échec(s)"
[ "$FAIL" = 0 ]
