#!/usr/bin/env bash
# Rejeu de commits reels : le garde doit detecter ce qu'il doit detecter.
#   b9a307f7 (retrait d'un PVC Retain sans Prune=false)      -> BLOCK (rc 3)
#   e63fc72e (retrait d'un PVC proteges par Delete=false seul) -> BLOCK (rc 3)
#   35326c66 (documentation seule)                             -> PASS  (rc 0)
# Exige le depot complet (fetch-depth 0). Niveau de preuve : STATIC.
#
# Un rc 2 (BLOCKED, « rendu impossible ») n'est pas un verdict du plan : c'est un echec de
# rendu, le plus souvent un chart Helm injoignable (reseau). Ces echecs sont transitoires :
# le calcul est relance avant de conclure. Les verdicts attendus (0 PASS, 3 BLOCK) restent
# verifies tels quels : seul un rendu impossible est reessaye, jamais un verdict.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
PY=${PLAN_PYTHON:-python3}
OUT=${REPLAY_OUT:-$(mktemp -d)}
mkdir -p "$OUT"
fail=0

# Les racines Atlantis ont ete retirees de roots.txt (PLT-46), mais le rejeu de
# e63fc72e doit encore les rendre : roots de rejeu = roots.txt + racines retirees.
REPLAY_ROOTS="$OUT/replay-roots.txt"
{ cat "$ROOT/scripts/plan/roots.txt"; echo "k8s/poc/atlantis-plan-only"; echo "k8s/poc/atlantis-apps"; } >"$REPLAY_ROOTS"

# Nombre de calculs par commit quand le rendu est impossible (2 = rc du plan).
REPLAY_ATTEMPTS=${REPLAY_ATTEMPTS:-3}
case "$REPLAY_ATTEMPTS" in (''|*[!0-9]*) REPLAY_ATTEMPTS=3 ;; esac
[ "$REPLAY_ATTEMPTS" -ge 1 ] || REPLAY_ATTEMPTS=1
# Pause entre deux tentatives (secondes).
REPLAY_RETRY_SLEEP=${REPLAY_RETRY_SLEEP:-10}

replay() {
  local commit=$1 want=$2 label=$3
  local rc attempt=1
  while :; do
    "$PY" "$ROOT/scripts/plan/plan_diff.py" pr --repo "$ROOT" --roots "$REPLAY_ROOTS" \
      --base-ref "$commit^" --head-ref "$commit" \
      --json "$OUT/$commit.json" --md "$OUT/$commit.md" >"$OUT/$commit.stdout" 2>&1
    rc=$?
    # rc 2 : rendu impossible (chart injoignable, reseau). Ce n'est pas un verdict du
    # plan, on reessaie ; un verdict (0 ou 3) sort de la boucle tel quel.
    if [ "$rc" -ne 2 ] || [ "$attempt" -ge "$REPLAY_ATTEMPTS" ]; then
      break
    fi
    attempt=$((attempt + 1))
    echo "REPLAY $commit $label : rendu impossible (rc=2), tentative $attempt/$REPLAY_ATTEMPTS"
    sleep "$REPLAY_RETRY_SLEEP"
  done
  if [ "$rc" -eq "$want" ]; then
    echo "REPLAY $commit $label : PASS (rc=$rc attendu $want)"
  else
    echo "REPLAY $commit $label : FAIL (rc=$rc, attendu $want)"
    tail -20 "$OUT/$commit.stdout"
    fail=1
  fi
}

replay b9a307f7 3 "retrait PVC Retain sans protection"
replay e63fc72e 3 "retrait PVC Delete=false seul"
replay 35326c66 0 "documentation seule"

# Le rejeu b9a307f7 doit nommer le PVC retire, pas seulement echouer.
if grep -q "audiobookrequest-config" "$OUT/b9a307f7.md" 2>/dev/null; then
  echo "REPLAY b9a307f7 nomme audiobookrequest-config : PASS"
else
  echo "REPLAY b9a307f7 nomme audiobookrequest-config : FAIL"
  fail=1
fi
if grep -q "atlantis-pilot-data" "$OUT/e63fc72e.md" 2>/dev/null; then
  echo "REPLAY e63fc72e nomme atlantis-pilot-data : PASS"
else
  echo "REPLAY e63fc72e nomme atlantis-pilot-data : FAIL"
  fail=1
fi

exit "$fail"
