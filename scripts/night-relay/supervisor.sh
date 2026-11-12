#!/usr/bin/env bash
# Night relay supervisor (PLT-201). No LLM here: plain shell.
#
# Usage:
#   nohup caffeinate -i bash scripts/night-relay/supervisor.sh &
#
# One night per run: waits for the window (default 23:00-08:30, local time),
# then runs cycles one by one. A cycle has two stages:
#   1. execution (no LLM decides): while the dispatcher dry-run gives a
#      `choisi :` ticket, the supervisor itself runs the REAL dispatcher for
#      that ticket (lock wip:claude-<lane>, model from the ticket label,
#      bounded `claude -p`, checkpoint). One lane, one ticket at a time.
#   2. review: one orchestrator session (ORCH_MODEL, default opus) reviews and
#      merges the PRs, completes RECONCILED/RUNTIME evidence, writes the handoff.
#      It never selects or refuses a ticket.
# Usage limits are waited out; at 09:00 the report runs, then the script exits.
#
# Environment (all optional):
#   DRY_RUN=1                 no network, no claude: simulated cycles and clock
#   NIGHT_RELAY_FAKE_NOW      start epoch of the simulated clock (DRY_RUN only)
#   NIGHT_RELAY_REPO          repository the sessions run in (default: this repo)
#   NIGHT_RELAY_STATE         state dir: log, runs, lock (default: scripts/night-relay/state)
#   NIGHT_RELAY_HANDOFF_DIR   handoff dir (default: scripts/night-relay/handoff)
#   START_HM=2300 STOP_HM=0830 REPORT_HM=0900 REPORT_DEADLINE_HM=1200
#   MAX_CYCLES=40 MAX_FAILS=3 MIN_CYCLE_SECONDS=1800 ORCH_TIMEOUT=10800 REPORT_TIMEOUT=3600
#   KILL_GRACE=30             seconds between SIGTERM and SIGKILL (timeout, signal)
#   QUOTA_FALLBACK_SLEEP=1800 QUOTA_MIN_SLEEP=300 QUOTA_MARGIN=120
#   QUOTA_MAX_RETRIES=4       consecutive usage-limit retries before counting a failure
#   LOCK_RETRIES=5            retries (1 s) while the lock pid file is still empty
#   EMPTY_SLEEP=300 FAIL_BACKOFF=600 WINDOW_GRACE=1800
#   MIN_ACTIVE_SECONDS=120    a session shorter than this is an idle cycle (whatever its statut)
#   IDLE_LONG_AFTER=3 IDLE_LONG_SLEEP=900  after IDLE_LONG_AFTER consecutive idle cycles,
#                             pause IDLE_LONG_SLEEP (never less than EMPTY_SLEEP) instead of EMPTY_SLEEP
#   LOG_MAX_BYTES=1048576 RUN_MAX_BYTES=262144 RUNS_KEEP=60
#   CLAUDE_BIN=claude ORCH_MODEL=opus  model of the review session
# Execution stage (dispatcher):
#   NIGHT_RELAY_DISPATCH      dispatcher command (default: bash scripts/doppler-safe.sh run --
#                             python3 scripts/dispatcher/dispatch.py; DRY_RUN: unset = empty queue)
#   DISPATCH_LANE=local DISPATCH_DRY_TIMEOUT=300 DISPATCH_TIMEOUT=10500 (> the dispatcher's own 2 h 45)
#   DISPATCH_PERMISSION_MODE=bypassPermissions  exported to the dispatcher's claude -p
#                             (a headless session cannot answer a permission prompt; the limits
#                             are the hooks and wrappers: secret-output-guard, doppler-safe, kubectl-ro)
#   MAX_RUNS_PER_CYCLE=3      real runs before a review
#   TICKET_MAX_FAILS=MAX_FAILS consecutive failures of one ticket before it is skipped for the night
#   REVIEW_IDLE_INTERVAL=3600 without any run, at most one review per interval
#   NIGHT_RELAY_KUBE_STATUS   per-cycle Kubernetes preflight (default: scripts/night-relay/kube-status.sh)
#   KUBE_CHECK_TIMEOUT=120    bound of one preflight attempt, in seconds
#   KUBE_CHECK_ATTEMPTS=2 KUBE_CHECK_RETRY_DELAY=60  attempts before declaring it unavailable
# DRY_RUN scenario knobs (tests):
#   DRY_RUN_CYCLE_SECONDS=5400  simulated duration of one orchestrator session
#   DRY_RUN_REPORT_SECONDS=600  simulated duration of the report session
#   DRY_RUN_QUOTA_ATTEMPTS="2"  attempt numbers (1-based, all sessions) hitting the limit
#   DRY_RUN_QUOTA_RESET_IN      seconds until reset in the simulated message (unset: no time given)
#   DRY_RUN_QUOTA_MSG           verbatim limit message (overrides DRY_RUN_QUOTA_RESET_IN)
#   DRY_RUN_FAIL_ATTEMPTS=""    attempt numbers that fail without writing a handoff
#   DRY_RUN_EMPTY_ATTEMPTS=""   attempt numbers whose handoff says `statut: file-vide`
#   DRY_RUN_KUBE="disponible (simulation)"  Kubernetes line given to the prompt (no preflight run),
#                             unless NIGHT_RELAY_KUBE_STATUS is set: that local fake is then run

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=${NIGHT_RELAY_REPO:-$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || (cd "$SCRIPT_DIR/../.." && pwd))}
STATE=${NIGHT_RELAY_STATE:-$SCRIPT_DIR/state}
HANDOFF_DIR=${NIGHT_RELAY_HANDOFF_DIR:-$SCRIPT_DIR/handoff}
LOG_FILE=$STATE/supervisor.log
RUNS=$STATE/runs
LOCK_DIR=$STATE/supervisor.lock
CLOCK_FILE=$STATE/clock

DRY_RUN=${DRY_RUN:-0}
START_HM=${START_HM:-2300}
STOP_HM=${STOP_HM:-0830}
REPORT_HM=${REPORT_HM:-0900}
REPORT_DEADLINE_HM=${REPORT_DEADLINE_HM:-1200}
MAX_CYCLES=${MAX_CYCLES:-40}  # productive cycles only: idle and failed cycles are bounded elsewhere
MAX_FAILS=${MAX_FAILS:-3}
MIN_CYCLE_SECONDS=${MIN_CYCLE_SECONDS:-1800}
ORCH_TIMEOUT=${ORCH_TIMEOUT:-10800}
REPORT_TIMEOUT=${REPORT_TIMEOUT:-3600}
KILL_GRACE=${KILL_GRACE:-30}
QUOTA_MAX_RETRIES=${QUOTA_MAX_RETRIES:-4}
LOCK_RETRIES=${LOCK_RETRIES:-5}
QUOTA_FALLBACK_SLEEP=${QUOTA_FALLBACK_SLEEP:-1800}
QUOTA_MIN_SLEEP=${QUOTA_MIN_SLEEP:-300}
QUOTA_MARGIN=${QUOTA_MARGIN:-120}
EMPTY_SLEEP=${EMPTY_SLEEP:-300}
FAIL_BACKOFF=${FAIL_BACKOFF:-600}
WINDOW_GRACE=${WINDOW_GRACE:-1800}
LOG_MAX_BYTES=${LOG_MAX_BYTES:-1048576}
RUN_MAX_BYTES=${RUN_MAX_BYTES:-262144}
RUNS_KEEP=${RUNS_KEEP:-60}
CLAUDE_BIN=${CLAUDE_BIN:-claude}
ORCH_MODEL=${ORCH_MODEL:-opus}
DISPATCH_LANE=${DISPATCH_LANE:-local}
DISPATCH_DRY_TIMEOUT=${DISPATCH_DRY_TIMEOUT:-300}
DISPATCH_TIMEOUT=${DISPATCH_TIMEOUT:-10500}
MAX_RUNS_PER_CYCLE=${MAX_RUNS_PER_CYCLE:-3}
TICKET_MAX_FAILS=${TICKET_MAX_FAILS:-$MAX_FAILS}
REVIEW_IDLE_INTERVAL=${REVIEW_IDLE_INTERVAL:-3600}
export DISPATCH_PERMISSION_MODE=${DISPATCH_PERMISSION_MODE:-bypassPermissions}
if [ "$DRY_RUN" = 1 ]; then
  DISPATCH_CMD=${NIGHT_RELAY_DISPATCH:-}
else
  DISPATCH_CMD=${NIGHT_RELAY_DISPATCH:-bash scripts/doppler-safe.sh run -- python3 scripts/dispatcher/dispatch.py}
fi
KUBE_STATUS_CMD=${NIGHT_RELAY_KUBE_STATUS:-$SCRIPT_DIR/kube-status.sh}
KUBE_CHECK_TIMEOUT=${KUBE_CHECK_TIMEOUT:-120}
KUBE_CHECK_ATTEMPTS=${KUBE_CHECK_ATTEMPTS:-2}
KUBE_CHECK_RETRY_DELAY=${KUBE_CHECK_RETRY_DELAY:-60}
MIN_ACTIVE_SECONDS=${MIN_ACTIVE_SECONDS:-120}
IDLE_LONG_AFTER=${IDLE_LONG_AFTER:-3}
IDLE_LONG_SLEEP=${IDLE_LONG_SLEEP:-900}
[ "$IDLE_LONG_SLEEP" -ge "$EMPTY_SLEEP" ] || IDLE_LONG_SLEEP=$EMPTY_SLEEP

DRY_RUN_CYCLE_SECONDS=${DRY_RUN_CYCLE_SECONDS:-5400}
DRY_RUN_REPORT_SECONDS=${DRY_RUN_REPORT_SECONDS:-600}
DRY_RUN_QUOTA_ATTEMPTS=${DRY_RUN_QUOTA_ATTEMPTS-2}
DRY_RUN_FAIL_ATTEMPTS=${DRY_RUN_FAIL_ATTEMPTS:-}
DRY_RUN_EMPTY_ATTEMPTS=${DRY_RUN_EMPTY_ATTEMPTS:-}
DRY_RUN_KUBE=${DRY_RUN_KUBE:-disponible (simulation)}

ATTEMPT=0          # every claude session launched (orchestrator or report)
QUOTA_WAIT=0       # set by quota_wait_from when a usage limit is detected
SESSION_PID=""     # running claude session (killed on signal)
WATCHDOG_PID=""    # its timeout watchdog
SESSION_ERR=""     # its stderr file (removed on signal)
KUBE_LINE=""       # last Kubernetes preflight line (kube_status)
DISPATCH_SEQ=0     # dispatcher calls (run file names)
EXEC_RUNS=0        # real dispatcher runs of the last execution stage
EXEC_STATE=""      # idle | busy | error | stop
EXEC_SUMMARY=""    # one line per run/skip of the last execution stage
PENDING=""         # runs/skips not yet given to a successful review
DRY_OUT=""         # last dispatcher dry-run output
LAST_REVIEW=0      # epoch of the last review session

# --- clock -----------------------------------------------------------------
if date --version >/dev/null 2>&1; then GNU_DATE=1; else GNU_DATE=0; fi

now() {
  if [ "$DRY_RUN" = 1 ]; then cat "$CLOCK_FILE"; else date +%s; fi
}

fmt() { # fmt EPOCH FORMAT -> local time
  if [ "$GNU_DATE" = 1 ]; then date -d "@$1" "+$2"; else date -r "$1" "+$2"; fi
}

local_epoch() { # local_epoch "YYYY-MM-DD" "HHMM" -> epoch
  local hm=$2
  if [ "$GNU_DATE" = 1 ]; then
    date -d "$1 ${hm:0:2}:${hm:2:2}:00" +%s
  else
    date -j -f "%Y-%m-%d %H:%M:%S" "$1 ${hm:0:2}:${hm:2:2}:00" +%s
  fi
}

next_at() { # next_at HHMM FROM -> first epoch > FROM at local HH:MM (DST-safe)
  local day t
  day=$(fmt "$2" %Y-%m-%d)
  t=$(local_epoch "$day" "$1")
  if [ "$t" -le "$2" ]; then
    day=$(fmt $(( $2 + 86400 )) %Y-%m-%d)
    t=$(local_epoch "$day" "$1")
  fi
  echo "$t"
}

nap() { # nap SECONDS: simulated in DRY_RUN, chunked real sleep otherwise
  local s=$1
  [ "$s" -gt 0 ] || return 0
  if [ "$DRY_RUN" = 1 ]; then
    echo $(( $(cat "$CLOCK_FILE") + s )) >"$CLOCK_FILE"
    return 0
  fi
  local until=$(( $(date +%s) + s ))
  while [ "$(date +%s)" -lt "$until" ]; do
    local left=$(( until - $(date +%s) ))
    sleep $(( left < 600 ? left : 600 ))
  done
}

nap_in_window() { # nap, but never past the end of the window
  local left=$(( WINDOW_END - $(now) ))
  [ "$left" -gt 0 ] || return 0
  nap $(( $1 < left ? $1 : left ))
}

sleep_until() { local d=$(( $1 - $(now) )); nap "$d"; }

# --- bounded log -----------------------------------------------------------
log() {
  local line
  line="$(fmt "$(now)" '%Y-%m-%dT%H:%M:%S%z') $*"
  if [ -f "$LOG_FILE" ]; then
    local size
    size=$(wc -c <"$LOG_FILE" | tr -d ' ')
    if [ $(( size + ${#line} + 1 )) -gt "$LOG_MAX_BYTES" ]; then
      mv -f "$LOG_FILE" "$LOG_FILE.1"
    fi
  fi
  printf '%s\n' "$line" >>"$LOG_FILE"
}

prune_runs() {
  # keep the RUNS_KEEP most recent run files
  local files
  # shellcheck disable=SC2012 # names are generated by this script
  files=$(ls -1t "$RUNS" 2>/dev/null | tail -n +$(( RUNS_KEEP + 1 )))
  [ -n "$files" ] || return 0
  while IFS= read -r f; do rm -f "$RUNS/$f"; done <<<"$files"
}

in_list() { # in_list N "1,2 3"
  local x
  for x in ${2//,/ }; do [ "$x" = "$1" ] && return 0; done
  return 1
}

failed() { # failed RC OUT_JSON: non-zero exit or "is_error": true in the result JSON
  [ "$1" -ne 0 ] || grep -Eq '"is_error"[[:space:]]*:[[:space:]]*true' "$2" 2>/dev/null
}

# --- usage-limit detection --------------------------------------------------
# Sets QUOTA_WAIT (seconds) and returns 0 if the failed session hit a usage limit.
quota_wait_from() { # quota_wait_from FILE... (stdout json + stderr of a FAILED run)
  local text t reset="" hm h m ap
  text=$(cat "$@" 2>/dev/null | head -c 65536)
  if ! grep -Eiq "limite d'usage :|usage limit|limit reached|hit your (usage )?limit|rate_limit_error|out of extra usage|limit will reset|resets? at" <<<"$text"; then
    return 1
  fi
  t=$(now)
  # 1) "Claude AI usage limit reached|1731340800"
  reset=$(grep -Eo 'limit reached\|[0-9]{10}' <<<"$text" | head -1 | grep -Eo '[0-9]{10}' || true)
  # 2) "resets 3am", "resets at 3:30 pm", "resets 03:00"
  if [ -z "$reset" ]; then
    hm=$(grep -Eio 'resets?( at)? [0-9]{1,2}(:[0-9]{2})? ?(am|pm)?' <<<"$text" | head -1 \
         | sed -E 's/^[Rr][Ee][Ss][Ee][Tt][Ss]?( [Aa][Tt])? //' || true)
    if [ -n "$hm" ]; then
      h=$(grep -Eo '^[0-9]{1,2}' <<<"$hm")
      m=$(grep -Eo ':[0-9]{2}' <<<"$hm" | tr -d ':' || true)
      ap=$(grep -Eio '(am|pm)$' <<<"$hm" | tr '[:upper:]' '[:lower:]' || true)
      m=${m:-00}
      h=$((10#$h))
      [ "$ap" = pm ] && [ "$h" -lt 12 ] && h=$(( h + 12 ))
      [ "$ap" = am ] && [ "$h" -eq 12 ] && h=0
      if [ "$h" -le 23 ]; then reset=$(next_at "$(printf '%02d%02d' "$h" "$((10#$m))")" "$t"); fi
    fi
  fi
  if [ -n "$reset" ] && [ "$reset" -gt "$t" ]; then
    QUOTA_WAIT=$(( reset - t + QUOTA_MARGIN ))
    log "limite d'usage : réinitialisation à $(fmt "$reset" %H:%M), attente ${QUOTA_WAIT}s"
  else
    QUOTA_WAIT=$QUOTA_FALLBACK_SLEEP
    log "limite d'usage : heure de réinitialisation inconnue, attente bornée ${QUOTA_WAIT}s puis nouvel essai"
  fi
  [ "$QUOTA_WAIT" -ge "$QUOTA_MIN_SLEEP" ] || QUOTA_WAIT=$QUOTA_MIN_SLEEP
  return 0
}

# --- one claude session -------------------------------------------------------
proc_tree() { # proc_tree PID -> PID and all its descendants
  local c
  echo "$1"
  for c in $(pgrep -P "$1" 2>/dev/null); do proc_tree "$c"; done
}

kill_tree() { # kill_tree PID: SIGTERM the tree, SIGKILL survivors after KILL_GRACE
  local pids p i
  pids=$(proc_tree "$1")
  # shellcheck disable=SC2086 # word splitting wanted
  kill -TERM $pids 2>/dev/null
  for (( i = 0; i < KILL_GRACE; i++ )); do
    for p in $pids; do kill -0 "$p" 2>/dev/null && break; p=""; done
    [ -n "$p" ] || return 0
    sleep 1
  done
  # shellcheck disable=SC2086
  kill -KILL $pids 2>/dev/null
  return 0
}

stop_watchdog() {
  [ -n "$WATCHDOG_PID" ] || return 0
  pkill -P "$WATCHDOG_PID" 2>/dev/null; kill "$WATCHDOG_PID" 2>/dev/null; wait "$WATCHDOG_PID" 2>/dev/null
  WATCHDOG_PID=""
}

stop_session() { # on signal/exit: kill the running session, its watchdog, drop its stderr
  stop_watchdog
  if [ -n "$SESSION_PID" ]; then kill_tree "$SESSION_PID"; wait "$SESSION_PID" 2>/dev/null; fi
  SESSION_PID=""
  if [ -n "$SESSION_ERR" ]; then rm -f "$SESSION_ERR" "$SESSION_ERR.timeout"; fi
  SESSION_ERR=""
}

# run_session KIND MODEL PROMPT_FILE OUT_JSON ERR_FILE TIMEOUT HANDOFF_OUT
# Returns claude's exit code (124 on timeout).
run_session() {
  local kind=$1 model=$2 prompt=$3 out=$4 err=$5 timeout=$6 handoff=$7
  ATTEMPT=$(( ATTEMPT + 1 ))
  if [ "$DRY_RUN" = 1 ]; then
    simulate_session "$kind" "$prompt" "$out" "$err" "$handoff" "$timeout"
    return $?
  fi
  local rc
  SESSION_ERR=$err
  (cd "$REPO" && exec "$CLAUDE_BIN" -p --model "$model" --permission-mode bypassPermissions \
     --output-format json <"$prompt") >"$out" 2>"$err" &
  SESSION_PID=$!
  # watchdog: SIGTERM the session tree at timeout, SIGKILL it after KILL_GRACE,
  # so wait below always returns
  ( sleep "$timeout"; touch "$err.timeout"; kill_tree "$SESSION_PID" ) &
  WATCHDOG_PID=$!
  wait "$SESSION_PID"; rc=$?
  stop_watchdog
  SESSION_PID=""
  if [ -f "$err.timeout" ]; then rm -f "$err.timeout"; rc=124; fi
  return "$rc"
}

simulate_session() { # no network, no claude: fake JSON, fake handoff, simulated time
  local kind=$1 prompt=$2 out=$3 err=$4 handoff=$5 timeout=$6
  cp "$prompt" "$STATE/dry-run/prompt-$ATTEMPT.txt"
  : >"$err"
  if in_list "$ATTEMPT" "$DRY_RUN_QUOTA_ATTEMPTS"; then
    nap 60
    local msg="You've hit your usage limit"
    if [ -n "${DRY_RUN_QUOTA_MSG:-}" ]; then
      msg=$DRY_RUN_QUOTA_MSG
    elif [ -n "${DRY_RUN_QUOTA_RESET_IN:-}" ]; then
      msg="Claude AI usage limit reached|$(( $(now) + DRY_RUN_QUOTA_RESET_IN ))"
    fi
    printf '{"type":"result","subtype":"success","is_error":true,"result":"%s","num_turns":1}\n' "$msg" >"$out"
    return 1
  fi
  local dur=$DRY_RUN_CYCLE_SECONDS
  [ "$kind" = report ] && dur=$DRY_RUN_REPORT_SECONDS
  if [ "$dur" -gt "$timeout" ]; then
    nap "$timeout"
    echo '{"type":"result","subtype":"error_during_execution","is_error":true}' >"$out"
    return 124
  fi
  nap "$dur"
  if in_list "$ATTEMPT" "$DRY_RUN_FAIL_ATTEMPTS"; then
    echo "simulated crash" >"$err"
    return 1
  fi
  local statut=continue
  in_list "$ATTEMPT" "$DRY_RUN_EMPTY_ATTEMPTS" && statut=file-vide
  local prev name
  name=$(basename "$handoff" .md)
  prev=$(grep -Eo 'Handoff précédent : .*' "$prompt" | head -1 | sed 's/^Handoff précédent : //')
  {
    echo "statut: $statut"
    echo "cycle: $name"
    echo "precedent: $prev"
    echo "## Faits"
    echo "- (simulation) aucun ticket réel"
  } >"$handoff"
  printf '{"type":"result","subtype":"success","is_error":false,"result":"%s ok","num_turns":3,"total_cost_usd":0,"usage":{"input_tokens":1,"output_tokens":1}}\n' "$kind" >"$out"
  return 0
}

# --- Kubernetes preflight (per cycle) ----------------------------------------------
# One non-sensitive line for the prompt: "disponible (...)" | "indisponible (categorie : RAISON)".
# kube-status.sh reuses scripts/lib/kube-preflight.sh; only its enum reason is kept.
# Runs in this shell (sets KUBE_LINE) so a signal can stop it like a session.
# A transient failure (timeout, API blip) is retried: KUBE_CHECK_ATTEMPTS attempts,
# KUBE_CHECK_RETRY_DELAY apart, each bounded by KUBE_CHECK_TIMEOUT.
kube_status() {
  if [ "$DRY_RUN" = 1 ] && [ -z "${NIGHT_RELAY_KUBE_STATUS:-}" ]; then KUBE_LINE=$DRY_RUN_KUBE; return 0; fi
  local i
  for (( i = 1; i <= KUBE_CHECK_ATTEMPTS; i++ )); do
    kube_status_once "$i"
    case "$KUBE_LINE" in disponible*) return 0 ;; esac
    if [ "$i" -lt "$KUBE_CHECK_ATTEMPTS" ]; then
      log "préflight Kubernetes : tentative $i/$KUBE_CHECK_ATTEMPTS $KUBE_LINE, nouvel essai dans ${KUBE_CHECK_RETRY_DELAY}s"
      nap_in_window "$KUBE_CHECK_RETRY_DELAY"
    fi
  done
  [ "$KUBE_CHECK_ATTEMPTS" -le 1 ] || KUBE_LINE="$KUBE_LINE après $KUBE_CHECK_ATTEMPTS tentatives"
}

kube_status_once() { # kube_status_once ATTEMPT
  # one file per attempt: a late watchdog of attempt N cannot mark attempt N+1 as timed out
  local f="$RUNS/kube-status.$$.$1" line pid
  # a preflight killed by SIGKILL cannot run its cleanup: sweep stale temp kubeconfigs
  find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name 'kube-ops-operator-access.*' -mmin +360 \
    -exec rm -rf {} + 2>/dev/null
  rm -f "$f" "$f.timeout"
  (cd "$REPO" && exec bash "$KUBE_STATUS_CMD") >"$f" 2>/dev/null </dev/null &
  SESSION_PID=$!
  pid=$SESSION_PID
  # mark a timeout only if the preflight is still running (stop_watchdog may kill
  # the sleep first, letting this subshell go on for an instant)
  ( sleep "$KUBE_CHECK_TIMEOUT"; kill -0 "$pid" 2>/dev/null || exit 0; touch "$f.timeout"; kill_tree "$pid" ) >/dev/null 2>&1 &
  WATCHDOG_PID=$!
  wait "$SESSION_PID" 2>/dev/null
  stop_watchdog
  SESSION_PID=""
  line=$(head -1 "$f" 2>/dev/null | tr -cd 'A-Za-z0-9 ():._+-' | cut -c1-120)
  [ -f "$f.timeout" ] && line="indisponible (preflight_timeout : ${KUBE_CHECK_TIMEOUT}s)"
  rm -f "$f" "$f.timeout"
  case "$line" in
    disponible*|indisponible*) ;;
    *) line="indisponible (inconnu : sortie du preflight illisible)" ;;
  esac
  KUBE_LINE=$line
}

# --- execution stage: the supervisor runs the real dispatcher ---------------------
run_bounded() { # run_bounded TIMEOUT OUT CMD... -> rc (124 on timeout); stdout+stderr to OUT, cwd REPO
  local timeout=$1 out=$2 pid rc
  shift 2
  rm -f "$out.timeout"
  (cd "$REPO" && exec "$@") >"$out" 2>&1 </dev/null &
  SESSION_PID=$!
  pid=$SESSION_PID
  ( sleep "$timeout"; kill -0 "$pid" 2>/dev/null || exit 0; touch "$out.timeout"; kill_tree "$pid" ) >/dev/null 2>&1 &
  WATCHDOG_PID=$!
  wait "$SESSION_PID"; rc=$?
  stop_watchdog
  SESSION_PID=""
  if [ -f "$out.timeout" ]; then rm -f "$out.timeout"; rc=124; fi
  return "$rc"
}

dispatch() { # dispatch TIMEOUT OUT DISPATCH_ARGS... -> rc of dispatch.py (0 ok, 1 run failed, 2 error, 3 choice changed)
  local timeout=$1 out=$2 cmd
  shift 2
  if [ -z "$DISPATCH_CMD" ]; then  # DRY_RUN without a fake dispatcher: no network, empty queue
    echo "file vide pour la voie $DISPATCH_LANE" >"$out"
    return 0
  fi
  read -ra cmd <<<"$DISPATCH_CMD"
  run_bounded "$timeout" "$out" "${cmd[@]}" "$@"
}

skip_list() { # tickets skipped for the rest of the night, comma-separated
  local f out=""
  for f in "$TICKETS"/*.skip; do
    [ -e "$f" ] || continue
    f=${f##*/}
    out+="${out:+,}${f%.skip}"
  done
  echo "$out"
}

skip_ticket() { # skip_ticket ID REASON: never rerun tonight, comment the ticket once
  local id=$1 why=$2 rc
  echo "$why" >"$TICKETS/$id.skip"
  log "ticket $id sauté pour la nuit : $why"
  DISPATCH_SEQ=$(( DISPATCH_SEQ + 1 ))
  dispatch "$DISPATCH_DRY_TIMEOUT" "$RUNS/$NIGHT-d$DISPATCH_SEQ.skip.txt" \
    --lane "$DISPATCH_LANE" --comment-skip "$id" --why "$why"; rc=$?
  [ "$rc" -eq 0 ] || log "ticket $id : commentaire de saut non posé (code $rc)"
}

note() { EXEC_SUMMARY+="  - $*"$'\n'; }

# exec_stage: while the dry-run designates a ticket, run the real dispatcher for it.
# Sequential: one lane, one ticket, one dispatcher at a time. Sets EXEC_RUNS,
# EXEC_STATE, EXEC_SUMMARY, DRY_OUT.
exec_stage() {
  local iter=0 quotas=0 rc dry out chosen fp skips limit timeout t fails
  EXEC_RUNS=0 EXEC_STATE=idle EXEC_SUMMARY=""
  while :; do
    iter=$(( iter + 1 ))
    if [ "$iter" -gt $(( MAX_RUNS_PER_CYCLE * 4 + QUOTA_MAX_RETRIES + 2 )) ]; then
      log "dispatcher : borne d'itérations du cycle atteinte"; break
    fi
    if [ "$EXEC_RUNS" -ge "$MAX_RUNS_PER_CYCLE" ]; then
      log "dispatcher : $EXEC_RUNS exécutions (MAX_RUNS_PER_CYCLE) : place à la revue"; break
    fi
    t=$(now)
    if [ $(( WINDOW_END - t )) -lt "$MIN_CYCLE_SECONDS" ]; then
      log "dispatcher : moins de ${MIN_CYCLE_SECONDS}s avant la fin de fenêtre : pas de nouveau ticket"; break
    fi
    skips=$(skip_list)
    DISPATCH_SEQ=$(( DISPATCH_SEQ + 1 ))
    dry="$RUNS/$NIGHT-d$DISPATCH_SEQ.dry.txt"
    # shellcheck disable=SC2086 # optional --skip pair
    dispatch "$DISPATCH_DRY_TIMEOUT" "$dry" --lane "$DISPATCH_LANE" --dry-run ${skips:+--skip "$skips"}; rc=$?
    DRY_OUT=$dry
    if [ "$rc" -ne 0 ]; then
      log "dispatcher (dry-run) : échec (code $rc)"; EXEC_STATE=error; break
    fi
    chosen=$(grep -Eo '^choisi : [A-Z]+-[0-9]+' "$dry" | head -1 | sed 's/^choisi : //')
    if [ -z "$chosen" ]; then
      log "dispatcher : aucun ticket choisi pour la voie $DISPATCH_LANE"; break
    fi
    if grep -q 'occupée par' "$dry"; then
      log "dispatcher : $chosen choisi mais voie $DISPATCH_LANE occupée ($(grep -Eo 'occupée par [A-Z0-9, -]+' "$dry" | head -1)) : aucune exécution"
      EXEC_STATE=busy; break
    fi
    fp=$(grep -E "^progrès : $chosen " "$dry" | head -1 | sed "s/^progrès : $chosen //")
    if [ -n "$fp" ] && [ -f "$TICKETS/$chosen.fp" ] && [ "$(cat "$TICKETS/$chosen.fp")" = "$fp" ]; then
      skip_ticket "$chosen" "aucun progrès (ni PR ni commentaire) depuis sa dernière exécution"
      note "$chosen : sauté, aucun progrès depuis sa dernière exécution"
      continue
    fi
    limit=$(( WINDOW_END + WINDOW_GRACE ))
    [ "$limit" -le $(( REPORT_AT - 300 )) ] || limit=$(( REPORT_AT - 300 ))
    timeout=$(( limit - t ))
    [ "$timeout" -le "$DISPATCH_TIMEOUT" ] || timeout=$DISPATCH_TIMEOUT
    DISPATCH_SEQ=$(( DISPATCH_SEQ + 1 ))
    out="$RUNS/$NIGHT-d$DISPATCH_SEQ.run.txt"
    log "dispatcher réel : $chosen (voie $DISPATCH_LANE, permission $DISPATCH_PERMISSION_MODE, timeout ${timeout}s)"
    # shellcheck disable=SC2086
    dispatch "$timeout" "$out" --lane "$DISPATCH_LANE" --expect "$chosen" ${skips:+--skip "$skips"}; rc=$?
    if [ "$rc" -eq 3 ] || { [ "$rc" -eq 0 ] && grep -q '^file vide' "$out"; }; then
      log "dispatcher : choix changé depuis le dry-run, nouvelle lecture"; continue
    fi
    if grep -q 'occupée par\|course perdue' "$out"; then
      log "dispatcher : $chosen non lancé, voie $DISPATCH_LANE prise entre-temps"; EXEC_STATE=busy; break
    fi
    if [ "$rc" -eq 0 ] && grep -q "^$chosen : succès" "$out"; then
      EXEC_RUNS=$(( EXEC_RUNS + 1 )); quotas=0
      rm -f "$TICKETS/$chosen.fails"
      echo "$fp" >"$TICKETS/$chosen.fp"
      log "dispatcher : $chosen terminé (succès)"
      note "$chosen : session terminée (succès), sortie $out"
      continue
    fi
    if [ "$rc" -ne 0 ] && grep -q "^limite d'usage :" "$out" && quota_wait_from "$out"; then
      quotas=$(( quotas + 1 ))
      if [ "$quotas" -le "$QUOTA_MAX_RETRIES" ]; then
        if [ $(( $(now) + QUOTA_WAIT )) -ge "$WINDOW_END" ]; then
          log "réinitialisation après la fin de fenêtre : arrêt des cycles"; EXEC_STATE=stop; break
        fi
        nap "$QUOTA_WAIT"
        continue
      fi
      log "limite d'usage : $QUOTA_MAX_RETRIES nouveaux essais consécutifs déjà faits, compté comme échec"
      quotas=0
    fi
    if [ "$rc" -eq 124 ] || grep -q "^$chosen : échec" "$out"; then
      EXEC_RUNS=$(( EXEC_RUNS + 1 ))
      fails=$(( $(cat "$TICKETS/$chosen.fails" 2>/dev/null || echo 0) + 1 ))
      echo "$fails" >"$TICKETS/$chosen.fails"
      rm -f "$TICKETS/$chosen.fp"
      log "dispatcher : $chosen échec (code $rc, échecs consécutifs du ticket $fails/$TICKET_MAX_FAILS)"
      note "$chosen : échec (code $rc, $fails/$TICKET_MAX_FAILS), sortie $out"
      if [ "$fails" -ge "$TICKET_MAX_FAILS" ]; then
        skip_ticket "$chosen" "$fails échecs consécutifs"
      else
        nap_in_window "$FAIL_BACKOFF"
      fi
      continue
    fi
    log "dispatcher : erreur de l'outil (code $rc) sur $chosen, sortie $out"
    EXEC_STATE=error; break
  done
  PENDING+=$EXEC_SUMMARY
}

# --- handoffs -------------------------------------------------------------------
handoff_indices() { # handoff_indices NIGHT -> cycle numbers, ascending
  local f b
  for f in "$HANDOFF_DIR/$1"-*.md; do
    [ -e "$f" ] || continue
    b=${f##*/}; b=${b#"$1"-}; b=${b%.md}
    [[ $b =~ ^[0-9]+$ ]] && echo "$b"
  done | sort -n
}

latest_handoff() { # most recent handoff (any night): highest night, then highest cycle
  local f b
  for f in "$HANDOFF_DIR"/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-*.md; do
    [ -e "$f" ] || continue
    b=${f##*/}; b=${b%.md}
    [[ ${b:11} =~ ^[0-9]+$ ]] && echo "${b:0:10} ${b:11} $f"
  done | sort -k1,1 -k2,2n | tail -1 | cut -d' ' -f3-
}

next_index() { # next_index NIGHT
  local n
  n=$(handoff_indices "$1" | tail -1)
  echo $(( ${n:-0} + 1 ))
}

stub_handoff() { # stub_handoff PATH RC ERR_FILE PREV
  local errsize name
  errsize=$(wc -c <"$3" 2>/dev/null | tr -d ' ')
  name=$(basename "$1" .md)
  {
    echo "statut: echec"
    echo "cycle: $name"
    echo "precedent: ${4:-aucun}"
    echo "## Blocages (preuve)"
    echo "- Le superviseur a écrit ce handoff : la session orchestrateur s'est terminée (code $2) sans handoff."
    echo "  stderr : ${errsize:-0} octets (contenu non recopié). Reprendre depuis le handoff précédent."
  } >"$1"
}

build_prompt() { # build_prompt TEMPLATE OUT then key/value context lines on stdin
  { cat "$1"; echo; echo "## Contexte du superviseur"; cat; } >"$2"
}

# --- night ------------------------------------------------------------------------
run_cycles() {
  local cycles=0 fails=0 quotas=0 idle=0 t t0 dur n handoff prev prompt out err rc timeout statut limit pause
  while :; do
    t=$(now)
    if [ "$t" -ge "$WINDOW_END" ]; then log "fin de fenêtre $(fmt "$WINDOW_END" %H:%M)"; break; fi
    if [ $(( WINDOW_END - t )) -lt "$MIN_CYCLE_SECONDS" ]; then
      log "moins de ${MIN_CYCLE_SECONDS}s avant la fin de fenêtre : pas de nouveau cycle"; break
    fi
    if [ "$cycles" -ge "$MAX_CYCLES" ]; then log "borne MAX_CYCLES=$MAX_CYCLES (cycles productifs) atteinte"; break; fi
    n=$(next_index "$NIGHT")
    handoff="$HANDOFF_DIR/$NIGHT-$n.md"
    prev=$(latest_handoff)
    prompt="$RUNS/$NIGHT-$n.prompt.md"
    out="$RUNS/$NIGHT-$n.json"
    err="$RUNS/$NIGHT-$n.err"
    kube_status
    log "cycle $NIGHT-$n : Kubernetes $KUBE_LINE"
    exec_stage
    if [ "$EXEC_STATE" = stop ]; then break; fi
    if [ "$EXEC_STATE" = error ]; then
      fails=$(( fails + 1 ))
      log "cycle $NIGHT-$n : dispatcher en échec (échecs consécutifs $fails/$MAX_FAILS)"
      if [ "$fails" -ge "$MAX_FAILS" ]; then log "trop d'échecs consécutifs : arrêt des cycles"; break; fi
      nap_in_window "$FAIL_BACKOFF"
      continue
    fi
    t=$(now)  # the preflight and the runs may have taken hours
    if [ "$EXEC_RUNS" -eq 0 ] && [ -z "$PENDING" ] && [ $(( t - LAST_REVIEW )) -lt "$REVIEW_IDLE_INTERVAL" ]; then
      idle=$(( idle + 1 ))
      pause=$EMPTY_SLEEP
      [ "$idle" -lt "$IDLE_LONG_AFTER" ] || pause=$IDLE_LONG_SLEEP
      log "aucune exécution, dernière revue il y a $(( t - LAST_REVIEW ))s (< ${REVIEW_IDLE_INTERVAL}s) : pas de revue, pause ${pause}s (inactifs consécutifs : $idle)"
      nap_in_window "$pause"
      prune_runs
      continue
    fi
    # a session may overrun the window by WINDOW_GRACE, but never past REPORT_AT - 5 min
    limit=$(( WINDOW_END + WINDOW_GRACE ))
    [ "$limit" -le $(( REPORT_AT - 300 )) ] || limit=$(( REPORT_AT - 300 ))
    if [ $(( limit - t )) -lt 600 ]; then log "moins de 600s avant la limite des sessions : pas de revue, le rapport reprendra"; break; fi
    build_prompt "$SCRIPT_DIR/orchestrator.md" "$prompt" <<EOF
- Cycle : $NIGHT-$n
- Handoff précédent : ${prev:-aucun}
- Handoff à écrire : $handoff
- Fin de fenêtre : $(fmt "$WINDOW_END" '%Y-%m-%d %H:%M') (heure locale)
- Dépôt : $REPO
- Kubernetes : $KUBE_LINE
- Exécutions du dispatcher depuis la dernière revue (voie $DISPATCH_LANE) :
${PENDING:-  - aucune}
- Tickets sautés cette nuit par le superviseur : $(skip_list | sed 's/^$/aucun/')
- Dernier dry-run du dispatcher ($(basename "${DRY_OUT:-aucun}")) :
$(grep -E '^(à reprendre|choisi|progrès|file vide|voie .* occupée)' "${DRY_OUT:-/dev/null}" 2>/dev/null | cut -c1-200 | sed 's/^/  /' || true)
EOF
    timeout=$(( limit - t ))
    [ "$timeout" -le "$ORCH_TIMEOUT" ] || timeout=$ORCH_TIMEOUT
    log "cycle $NIGHT-$n : lancement orchestrateur (revue $ORCH_MODEL, précédent : $(basename "${prev:-aucun}"), timeout ${timeout}s)"
    t0=$(now)
    run_session orchestrator "$ORCH_MODEL" "$prompt" "$out" "$err" "$timeout" "$handoff"; rc=$?
    dur=$(( $(now) - t0 ))
    LAST_REVIEW=$(now)
    if failed "$rc" "$out" && [ ! -f "$handoff" ] && quota_wait_from "$out" "$err"; then
      quotas=$(( quotas + 1 ))
    else
      quotas=0
    fi
    if [ "$quotas" -gt "$QUOTA_MAX_RETRIES" ]; then
      log "limite d'usage : $QUOTA_MAX_RETRIES nouveaux essais consécutifs déjà faits, compté comme échec"
      quotas=0
    elif [ "$quotas" -gt 0 ]; then
      rm -f "$err"
      t=$(now)
      if [ $(( t + QUOTA_WAIT )) -ge "$WINDOW_END" ]; then
        log "réinitialisation après la fin de fenêtre : arrêt des cycles"
        break
      fi
      nap "$QUOTA_WAIT"
      continue
    fi
    # cycles counts productive cycles only (MAX_CYCLES): an idle cycle backs off but
    # never ends the night (window end); a failure is bounded by MAX_FAILS
    if [ "$rc" -eq 0 ] && [ -f "$handoff" ]; then
      fails=0
      PENDING=""
      statut=$(grep -m1 -E '^statut:' "$handoff" | sed -E 's/^statut:[[:space:]]*//')
      log "cycle $NIGHT-$n : ok, statut ${statut:-inconnu}, durée ${dur}s"
      if [ "$statut" = arret ]; then log "l'orchestrateur demande l'arrêt"; break; fi
      # idle guard: an empty queue or a session too short to have produced work
      # (PR, merge, ticket update) is idle whatever its statut; idle cycles back off
      if [ "$EXEC_RUNS" -eq 0 ] && { [ "$statut" = file-vide ] || [ "$dur" -lt "$MIN_ACTIVE_SECONDS" ]; }; then
        idle=$(( idle + 1 ))
        pause=$EMPTY_SLEEP
        [ "$idle" -lt "$IDLE_LONG_AFTER" ] || pause=$IDLE_LONG_SLEEP
        if [ "$statut" = file-vide ]; then
          log "file vide (cycles inactifs consécutifs : $idle) : pause ${pause}s"
        else
          log "cycle inactif (${dur}s < ${MIN_ACTIVE_SECONDS}s, statut ${statut:-inconnu}, consécutifs : $idle) : pause ${pause}s"
        fi
        nap_in_window "$pause"
      else
        idle=0
        cycles=$(( cycles + 1 ))
      fi
    else
      fails=$(( fails + 1 ))
      [ -f "$handoff" ] || stub_handoff "$handoff" "$rc" "$err" "$prev"
      log "cycle $NIGHT-$n : échec (code $rc, échecs consécutifs $fails/$MAX_FAILS)"
      if [ "$fails" -ge "$MAX_FAILS" ]; then log "trop d'échecs consécutifs : arrêt des cycles"; break; fi
      nap_in_window "$FAIL_BACKOFF"
    fi
    rm -f "$err"
    [ -f "$out" ] && [ "$(wc -c <"$out")" -gt "$RUN_MAX_BYTES" ] && truncate_file "$out"
    prune_runs
  done
}

truncate_file() { local tmp="$1.tmp"; head -c "$RUN_MAX_BYTES" "$1" >"$tmp" && mv -f "$tmp" "$1"; }

run_report() {
  local report_at=$1 deadline prompt out err rc list report quotas=0
  deadline=$(next_at "$REPORT_DEADLINE_HM" "$report_at")
  sleep_until "$report_at"
  report="$HANDOFF_DIR/$NIGHT-rapport.md"
  list=$(handoff_indices "$NIGHT" | sed "s|.*|  - $HANDOFF_DIR/$NIGHT-&.md|")
  prompt="$RUNS/$NIGHT-rapport.prompt.md"
  out="$RUNS/$NIGHT-rapport.json"
  err="$RUNS/$NIGHT-rapport.err"
  build_prompt "$SCRIPT_DIR/report.md" "$prompt" <<EOF
- Nuit : $NIGHT ($(fmt "$NIGHT_START" %H:%M)-$(fmt "$WINDOW_END" %H:%M))
- Handoffs de la nuit :
${list:-  - aucun}
- Rapport local à écrire : $report
- Journal du superviseur : $LOG_FILE (borné)
- Dépôt : $REPO
EOF
  while :; do
    log "rapport : lancement (opus)"
    run_session report opus "$prompt" "$out" "$err" "$REPORT_TIMEOUT" "$report"; rc=$?
    if failed "$rc" "$out" && quota_wait_from "$out" "$err"; then
      quotas=$(( quotas + 1 ))
      if [ "$quotas" -gt "$QUOTA_MAX_RETRIES" ]; then
        log "rapport : limite d'usage, $QUOTA_MAX_RETRIES nouveaux essais déjà faits, abandon"
        break
      fi
      if [ $(( $(now) + QUOTA_WAIT )) -ge "$deadline" ]; then
        log "rapport : limite d'usage au-delà de $(fmt "$deadline" %H:%M), abandon"
        break
      fi
      nap "$QUOTA_WAIT"
      continue
    fi
    log "rapport : terminé (code $rc)"
    break
  done
  rm -f "$err"
  [ -f "$out" ] && [ "$(wc -c <"$out")" -gt "$RUN_MAX_BYTES" ] && truncate_file "$out"
  prune_runs
  if [ "$DRY_RUN" != 1 ] && command -v osascript >/dev/null 2>&1; then
    osascript -e "display notification \"Rapport de nuit $NIGHT : code ${rc:-?}\" with title \"night-relay\"" >/dev/null 2>&1 || true
  fi
}

take_lock() { # single instance; a stale lock (dead pid) is taken over
  local holder i
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    holder=""
    # an empty pid file means another supervisor is taking the lock: retry briefly
    for (( i = 0; i <= LOCK_RETRIES; i++ )); do
      holder=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
      [ -z "$holder" ] && [ -d "$LOCK_DIR" ] && [ "$i" -lt "$LOCK_RETRIES" ] && { sleep 1; continue; }
      break
    done
    if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
      echo "night-relay: superviseur déjà actif (pid $holder)" >&2
      exit 1
    fi
    rm -rf "$LOCK_DIR"
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
      echo "night-relay: verrou pris par un autre superviseur pendant la reprise" >&2
      exit 1
    fi
  fi
  echo $$ >"$LOCK_DIR/pid.tmp" && mv -f "$LOCK_DIR/pid.tmp" "$LOCK_DIR/pid"
}

main() {
  mkdir -p "$STATE" "$RUNS" "$HANDOFF_DIR"
  if [ "$DRY_RUN" = 1 ]; then
    mkdir -p "$STATE/dry-run"
    [ -f "$CLOCK_FILE" ] || echo "${NIGHT_RELAY_FAKE_NOW:-$(date +%s)}" >"$CLOCK_FILE"
  fi
  take_lock
  trap 'stop_session; rm -rf "$LOCK_DIR"' EXIT
  trap 'log "signal reçu : arrêt de la session en cours"; stop_session; exit 130' INT TERM

  local t candidate end
  t=$(now)
  candidate=$(next_at "$START_HM" $(( t - 86400 )))
  end=$(next_at "$STOP_HM" "$candidate")
  if [ "$t" -lt "$end" ]; then
    NIGHT_START=$candidate
  else
    NIGHT_START=$(next_at "$START_HM" "$t")
  fi
  WINDOW_END=$(next_at "$STOP_HM" "$NIGHT_START")
  NIGHT=$(fmt "$NIGHT_START" %Y-%m-%d)
  TICKETS=$STATE/tickets/$NIGHT  # per-night ticket state: .fails, .fp (progress), .skip
  mkdir -p "$TICKETS"
  REPORT_AT=$(next_at "$REPORT_HM" "$NIGHT_START")
  local report_at=$REPORT_AT
  log "démarrage (DRY_RUN=$DRY_RUN, revue $ORCH_MODEL, dispatcher voie $DISPATCH_LANE) : nuit $NIGHT, fenêtre $(fmt "$NIGHT_START" '%d %H:%M')-$(fmt "$WINDOW_END" '%d %H:%M'), rapport $(fmt "$report_at" '%d %H:%M')"
  sleep_until "$NIGHT_START"
  run_cycles
  run_report "$report_at"
  log "fin du superviseur"
}

main "$@"
