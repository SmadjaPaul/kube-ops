#!/usr/bin/env bash
# PLT-555 : le lanceur scripts/run-checks-parallel.mjs decide du resultat de la
# porte locale du depot (`just check` = `npm run check:local`). Aucun test ne le
# couvrait : une regression du lanceur (code de sortie, liste des sous-checks,
# ordre de restitution) passerait la porte verte sans que personne ne le voie.
#
# Ce test rejoue le lanceur dans un bac a sable : une copie du lanceur (donc la
# racine du depot est le dossier temporaire), un faux package.json pour les
# sous-checks npm et une liste bash de fixtures. Aucun reseau, aucune ecriture
# dans le depot, aucun port fixe.
#
# Cas couverts :
#   - un echec parmi des succes rend le code 1, le resume compte l'echec et le
#     code de retour du sous-check est restitue ;
#   - l'echec d'un sous-check npm rend lui aussi le code 1 ;
#   - des sous-checks qui reussissent rendent le code 0 ;
#   - SKIP_CHECKS saute le bon element (liste bash ou sous-check npm) sans
#     l'executer, et le reste de la porte passe ;
#   - une porte ou tout est saute rend le code 1 (une porte vide n'est pas verte) ;
#   - la liste bash ignore les commentaires et les lignes vides ;
#   - la sortie garde l'ordre d'origine des sous-checks, meme quand un
#     sous-check lent se termine apres les autres (le resume, lui, est trie par
#     duree decroissante) ;
#   - un sous-check qui ne peut pas demarrer ne rend jamais la porte verte.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
launcher="$repo_root/scripts/run-checks-parallel.mjs"
test_file="$repo_root/tests/harness/run-checks-parallel-test.sh"
bash_list="$repo_root/scripts/check-bash-tests.list"

fail() {
  echo "RUN_CHECKS_PARALLEL=FAIL $*" >&2
  exit 1
}

command -v node >/dev/null || { echo "RUN_CHECKS_PARALLEL=BLOCKED reason=node_required"; exit 2; }
command -v npm >/dev/null || { echo "RUN_CHECKS_PARALLEL=BLOCKED reason=npm_required"; exit 2; }

[[ -f "$launcher" ]] || fail "reason=missing_launcher path=$launcher"

# Le test doit tourner dans la porte locale canonique.
grep -qx 'tests/harness/run-checks-parallel-test.sh' "$bash_list" ||
  fail "reason=not_listed file=scripts/check-bash-tests.list"

# Le lanceur couvert est bien celui que la porte locale du depot execute.
grep -q '"check:local": "node scripts/run-checks-parallel.mjs' "$repo_root/package.json" ||
  fail "reason=launcher_not_used_by_check_local file=package.json"
grep -q -- '--bash-list scripts/check-bash-tests.list' "$repo_root/package.json" ||
  fail "reason=bash_list_not_used_by_check_local file=package.json"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/run-checks-parallel-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

# --- bac a sable -----------------------------------------------------------------
# Le lanceur calcule sa racine depuis l'emplacement du fichier : copie a l'identique
# dans $tmp/scripts, la racine du bac a sable est donc $tmp.
mkdir -p "$tmp/scripts" "$tmp/tests"
cp "$launcher" "$tmp/scripts/run-checks-parallel.mjs"
cmp -s "$launcher" "$tmp/scripts/run-checks-parallel.mjs" || fail "reason=copy_differs"

cat >"$tmp/package.json" <<'JSON'
{
  "name": "run-checks-parallel-fixture",
  "version": "0.0.0",
  "private": true,
  "scripts": {
    "sub-ok": "echo MARK sub-ok",
    "sub-fail": "echo MARK sub-fail; exit 3"
  }
}
JSON

cat >"$tmp/tests/one-ok.sh" <<'SH'
#!/usr/bin/env bash
echo "MARK one-ok"
SH
cat >"$tmp/tests/two-ok.sh" <<'SH'
#!/usr/bin/env bash
echo "MARK two-ok"
SH
cat >"$tmp/tests/boom.sh" <<'SH'
#!/usr/bin/env bash
echo "MARK boom"
exit 7
SH
cat >"$tmp/tests/slow-ok.sh" <<'SH'
#!/usr/bin/env bash
echo "MARK slow-ok"
sleep 2
SH

# Listes bash : les commentaires et les lignes vides sont ignores, l'ordre des
# lignes utiles est l'ordre d'origine de la sortie attendue.
cat >"$tmp/checks.list" <<'LIST'
# un commentaire de tete

tests/one-ok.sh
   # un commentaire indente
tests/two-ok.sh
LIST
cat >"$tmp/checks-fail.list" <<'LIST'
# un echec au milieu de succes
tests/one-ok.sh
tests/boom.sh
tests/two-ok.sh
LIST
cat >"$tmp/checks-order.list" <<'LIST'
tests/slow-ok.sh
tests/one-ok.sh
tests/two-ok.sh
LIST

# --- helpers ---------------------------------------------------------------------
RUN_OUT="$tmp/run.out"
RUN_ERR="$tmp/run.err"
RUN_RC=0

run_launcher() { # <args...> : lance le lanceur, stdout et stderr sont captures
  RUN_RC=0
  "$@" >"$RUN_OUT" 2>"$RUN_ERR" || RUN_RC=$?
}

group_names() { sed -n 's/^::group::\([^ ]*\) .*/\1/p' "$RUN_OUT"; }

expect_rc() { # <attendu>
  [[ "$RUN_RC" -eq "$1" ]] ||
    fail "reason=unexpected_rc want=$1 got=$RUN_RC stderr=$(tr '\n' ' ' <"$RUN_ERR")"
}

expect_groups() { # <liste de noms, un par ligne>
  local actual
  actual="$(group_names)"
  [[ "$actual" == "$1" ]] ||
    fail "reason=unexpected_groups want=$(printf '%s' "$1" | tr '\n' ' ') got=$(printf '%s' "$actual" | tr '\n' ' ')"
}

# --- un echec parmi des succes rend le code 1 ------------------------------------
run_launcher node "$tmp/scripts/run-checks-parallel.mjs" --bash-list checks-fail.list sub-ok
expect_rc 1
expect_groups "tests/one-ok.sh
tests/boom.sh
tests/two-ok.sh
sub-ok"
grep -q '^::group::tests/boom.sh ([0-9.]*s, rc=7)$' "$RUN_OUT" || fail "reason=missing_failure_code"
grep -q '^::group::tests/one-ok.sh ([0-9.]*s, rc=0)$' "$RUN_OUT" || fail "reason=unexpected_success_code"
grep -q '^  FAIL .*tests/boom\.sh$' "$RUN_OUT" || fail "reason=failure_not_in_resume"
grep -q 'echecs=1/4' "$RUN_OUT" || fail "reason=unexpected_failure_count"

# --- l'echec d'un sous-check npm rend aussi le code 1 -----------------------------
run_launcher node "$tmp/scripts/run-checks-parallel.mjs" --bash-list checks.list sub-fail
expect_rc 1
grep -q '^::group::sub-fail ([0-9.]*s, rc=3)$' "$RUN_OUT" || fail "reason=missing_failure_code"
grep -q 'echecs=1/3' "$RUN_OUT" || fail "reason=unexpected_failure_count"

# --- des sous-checks qui reussissent rendent le code 0 -----------------------------
run_launcher node "$tmp/scripts/run-checks-parallel.mjs" --bash-list checks.list
expect_rc 0
expect_groups "tests/one-ok.sh
tests/two-ok.sh"
grep -q 'echecs=0/2' "$RUN_OUT" || fail "reason=unexpected_failure_count"

# --- SKIP_CHECKS saute le bon element (liste bash) --------------------------------
run_launcher env SKIP_CHECKS=tests/two-ok.sh node "$tmp/scripts/run-checks-parallel.mjs" --bash-list checks.list
expect_rc 0
grep -qx 'SKIPPED (perimetre non touche): tests/two-ok.sh' "$RUN_OUT" ||
  fail "reason=skip_not_reported"
expect_groups "tests/one-ok.sh"
if grep -q 'MARK two-ok' "$RUN_OUT"; then fail "reason=skipped_check_still_ran"; fi

# --- SKIP_CHECKS saute le bon element (sous-check npm) ----------------------------
run_launcher env SKIP_CHECKS=sub-ok node "$tmp/scripts/run-checks-parallel.mjs" --bash-list checks.list sub-ok
expect_rc 0
grep -qx 'SKIPPED (perimetre non touche): sub-ok' "$RUN_OUT" || fail "reason=skip_not_reported"
expect_groups "tests/one-ok.sh
tests/two-ok.sh"

# --- une porte ou tout est saute n'est pas verte ----------------------------------
run_launcher env SKIP_CHECKS=tests/one-ok.sh,tests/two-ok.sh node \
  "$tmp/scripts/run-checks-parallel.mjs" --bash-list checks.list
expect_rc 1
grep -q 'aucun sous-check a executer' "$RUN_ERR" || fail "reason=empty_gate_not_reported"

# --- la liste bash ignore les commentaires et les lignes vides ----------------------
# La liste contient deux commentaires (l'un indente) et une ligne vide : seuls les
# deux scripts reels doivent apparaitre, dans l'ordre de la liste.
run_launcher node "$tmp/scripts/run-checks-parallel.mjs" --bash-list checks.list
expect_rc 0
expect_groups "tests/one-ok.sh
tests/two-ok.sh"
if group_names | grep -q '^#'; then fail "reason=comment_ran_as_a_check"; fi

# --- la sortie garde l'ordre d'origine ---------------------------------------------
# Le sous-check lent est le premier de la liste : il se termine apres les autres
# (concurrence), mais il doit rester le premier groupe restitue.
run_launcher node "$tmp/scripts/run-checks-parallel.mjs" --bash-list checks-order.list
expect_rc 0
expect_groups "tests/slow-ok.sh
tests/one-ok.sh
tests/two-ok.sh"
resume_first="$(grep -E '^  (OK|FAIL) ' "$RUN_OUT" | head -1)"
[[ "$resume_first" == *'tests/slow-ok.sh' ]] ||
  fail "reason=resume_not_sorted_by_duration first=$resume_first"

# --- un sous-check qui ne peut pas demarrer ne rend jamais la porte verte ------------
# `npm` est absent du PATH : le lanceur ne peut pas demarrer le sous-check npm.
# La porte doit rester rouge (le lanceur plante sur une erreur de spawn non
# geree : le code est bien different de 0, c'est ce qui compte ici).
mkdir -p "$tmp/nonpm"
ln -sf "$(command -v node)" "$tmp/nonpm/node"
ln -sf "$(command -v bash)" "$tmp/nonpm/bash"
run_launcher env "PATH=$tmp/nonpm" "$tmp/nonpm/node" "$tmp/scripts/run-checks-parallel.mjs" sub-ok
[[ "$RUN_RC" -ne 0 ]] || fail "reason=green_gate_with_unrunnable_check"

if command -v shellcheck >/dev/null; then
  shellcheck -s bash "$test_file" || fail "reason=shellcheck_failed"
fi

echo "RUN_CHECKS_PARALLEL=PASS cases=9"
