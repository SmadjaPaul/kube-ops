#!/usr/bin/env bash
# Le rejeu du plan (tests/plan/replay.sh) ne doit pas confondre un echec de rendu
# transitoire (rc 2 : « rendu impossible », chart Helm injoignable) et un verdict du plan.
# Le rejeu relance le calcul quand le rendu echoue, et echoue toujours quand le rendu
# reste impossible. Ce test rejoue le script avec un faux plan_diff.py : aucun reseau,
# aucun kustomize, aucune ecriture dans le depot.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/plan-replay-retry.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/repo/tests/plan" "$tmp/repo/scripts/plan"
cp "$repo_root/tests/plan/replay.sh" "$tmp/repo/tests/plan/replay.sh"
: >"$tmp/repo/scripts/plan/roots.txt"

# Faux plan_diff.py : le verdict est commande par FAKE_PLAN_MODE.
#   transient  : premier calcul en rc 2 (rendu impossible), suivants au verdict attendu.
#   persistent : toujours rc 2 (rendu impossible qui dure).
cat >"$tmp/repo/scripts/plan/plan_diff.py" <<'PY'
import os
import sys

EXPECTED = {"b9a307f7": 3, "e63fc72e": 3, "35326c66": 0}

args = sys.argv[1:]
md = args[args.index("--md") + 1]
head = args[args.index("--head-ref") + 1]
counter = md + ".count"
count = int(open(counter).read().strip()) + 1 if os.path.exists(counter) else 1
with open(counter, "w", encoding="utf-8") as fh:
    fh.write(str(count))
short = next((c for c in EXPECTED if head.startswith(c)), head)
mode = os.environ.get("FAKE_PLAN_MODE", "transient")
if mode == "persistent" or (mode == "transient" and count == 1):
    sys.stderr.write("helm: chart injoignable\n")
    sys.exit(2)
with open(md, "w", encoding="utf-8") as fh:
    if short == "b9a307f7":
        fh.write("| - | PersistentVolumeClaim app/audiobookrequest-config |")
    elif short == "e63fc72e":
        fh.write("| - | PersistentVolumeClaim atlantis/atlantis-pilot-data |")
sys.exit(EXPECTED.get(short, 0))
PY

run_replay() {
  local mode=$1
  local out="$tmp/out-$mode"
  mkdir -p "$out"
  set +e
  FAKE_PLAN_MODE="$mode" PLAN_PYTHON=python3 REPLAY_OUT="$out" \
    REPLAY_ATTEMPTS=3 REPLAY_RETRY_SLEEP=0 \
    bash "$tmp/repo/tests/plan/replay.sh" >"$out/log" 2>&1
  replay_rc=$?
  set -e
  replay_log="$out/log"
  replay_out="$out"
}

# Un echec de rendu transitoire ne doit pas faire echouer le rejeu : le calcul est rejoue.
run_replay transient
[[ "$replay_rc" -eq 0 ]] || {
  cat "$replay_log" >&2
  echo "expected the replay to pass after a transient render failure" >&2
  exit 1
}
grep -q 'REPLAY b9a307f7 .*: PASS' "$replay_log" || { cat "$replay_log" >&2; exit 1; }
grep -q 'rendu impossible (rc=2)' "$replay_log" || { cat "$replay_log" >&2; exit 1; }
# Un seul echec de rendu par commit : le calcul est rejoue une fois, pas plus.
[[ "$(cat "$replay_out/b9a307f7.md.count")" == "2" ]] || { cat "$replay_log" >&2; exit 1; }
[[ "$(cat "$replay_out/35326c66.md.count")" == "2" ]] || { cat "$replay_log" >&2; exit 1; }

# Un rendu qui reste impossible doit toujours faire echouer le rejeu (fail-closed).
run_replay persistent
[[ "$replay_rc" -eq 1 ]] || {
  cat "$replay_log" >&2
  echo "expected the replay to fail when the render stays impossible" >&2
  exit 1
}
grep -q 'REPLAY b9a307f7 .*: FAIL (rc=2, attendu 3)' "$replay_log" || { cat "$replay_log" >&2; exit 1; }
# Les tentatives sont bornees : trois calculs, pas une boucle infinie.
[[ "$(cat "$replay_out/b9a307f7.md.count")" == "3" ]] || { cat "$replay_log" >&2; exit 1; }

echo "plan replay retry: PASS (echec de rendu transitoire rejoue, rendu impossible durable toujours en echec)"
