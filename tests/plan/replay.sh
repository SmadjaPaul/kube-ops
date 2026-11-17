#!/usr/bin/env bash
# Rejeu de commits reels : le garde doit detecter ce qu'il doit detecter.
#   b9a307f7 (retrait d'un PVC Retain sans Prune=false)      -> BLOCK (rc 3)
#   e63fc72e (retrait d'un PVC proteges par Delete=false seul) -> BLOCK (rc 3)
#   35326c66 (documentation seule)                             -> PASS  (rc 0)
# Exige le depot complet (fetch-depth 0). Niveau de preuve : STATIC.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
PY=${PLAN_PYTHON:-python3}
OUT=${REPLAY_OUT:-$(mktemp -d)}
mkdir -p "$OUT"
fail=0

replay() {
  local commit=$1 want=$2 label=$3
  local rc
  "$PY" "$ROOT/scripts/plan/plan_diff.py" pr --repo "$ROOT" --roots "$ROOT/scripts/plan/roots.txt" \
    --base-ref "$commit^" --head-ref "$commit" \
    --json "$OUT/$commit.json" --md "$OUT/$commit.md" >"$OUT/$commit.stdout" 2>&1
  rc=$?
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
