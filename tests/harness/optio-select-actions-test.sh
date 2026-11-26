#!/usr/bin/env bash
# PLT-522 : le script scripts/optio/select-actions.sh applique les étapes 2 à 7
# de docs/operations/optio-intake.md de façon déterministe. Ce test le joue sur
# des fixtures et compare la sortie à la sortie attendue.
#
# Chaque fixture de tests/fixtures/optio-select/ est un fichier unique :
#   { "slots": 10, "linear": {...}, "work": {...}, "expected": {...} }
# `linear` et `work` sont les deux entrées du script ; `expected` est la sortie
# attendue (mêmes clés que la sortie réelle). Le test écrit les deux entrées
# dans un dossier temporaire et appelle le script avec sa vraie ligne de
# commande, jamais avec un format propriétaire.
#
# Lecture seule, aucun accès cluster, aucun appel réseau. Autonome : mktemp,
# aucune écriture dans le dépôt.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo_root/scripts/optio/select-actions.sh"
test_file="$repo_root/tests/harness/optio-select-actions-test.sh"
fixture_dir="$repo_root/tests/fixtures/optio-select"
bash_list="$repo_root/scripts/check-bash-tests.list"

command -v jq >/dev/null || { echo "OPTIO_SELECT_ACTIONS=BLOCKED reason=jq_required"; exit 2; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "OPTIO_SELECT_ACTIONS=FAIL $*" >&2
  exit 1
}

[[ -f "$script" ]] || fail "reason=missing_script path=$script"

# Le test doit tourner dans la porte locale canonique.
grep -qx 'tests/harness/optio-select-actions-test.sh' "$bash_list" ||
  fail "reason=not_listed file=scripts/check-bash-tests.list"

# Aucun appel réseau : le script décide, il ne lit ni Linear ni GitHub.
if grep -vE '^[[:space:]]*#' "$script" |
  grep -qE '(^|[^[:alnum:]_])(curl|wget|nc|ncat|ssh|scp)([^[:alnum:]_]|$)|https?://'; then
  fail "reason=network_call_detected"
fi

mapfile -t cases < <(find "$fixture_dir" -maxdepth 1 -name '*.json' | sort)
((${#cases[@]} >= 8)) || fail "reason=not_enough_cases count=${#cases[@]}"

run_case() {
  local case_file=$1
  local name
  name="$(basename "$case_file" .json)"
  local case_dir="$tmp/$name"
  mkdir -p "$case_dir"
  local slots
  slots="$(jq -r '.slots // 10' "$case_file")"
  jq '.linear' "$case_file" >"$case_dir/linear.json"
  jq '.work' "$case_file" >"$case_dir/work.json"
  jq '.expected' "$case_file" >"$case_dir/expected-raw.json"

  local rc=0
  bash "$script" --linear "$case_dir/linear.json" --work "$case_dir/work.json" \
    --slots "$slots" >"$case_dir/out.json" 2>"$case_dir/err" || rc=$?
  ((rc == 0)) || fail "reason=script_failed case=$name rc=$rc detail=$(tr '\n' ' ' <"$case_dir/err")"

  # La sortie n'expose que les quatre clés du contrat.
  jq -e 'keys == ["create_fixes", "create_reviews", "create_tasks", "skipped"]' \
    "$case_dir/out.json" >/dev/null ||
    fail "reason=unexpected_output_keys case=$name"

  # Comparaison des fichiers : jq -S neutralise la mise en forme, l'ordre des
  # tableaux reste comparé (c'est lui qui porte le tri explicite).
  jq -S . "$case_dir/expected-raw.json" >"$case_dir/expected.json"
  jq -S . "$case_dir/out.json" >"$case_dir/actual.json"
  if ! diff -u "$case_dir/expected.json" "$case_dir/actual.json" >"$case_dir/diff" 2>&1; then
    cat "$case_dir/diff" >&2
    fail "reason=output_mismatch case=$name"
  fi

  # Sortie stable : deux exécutions donnent le même octet.
  rc=0
  bash "$script" --linear "$case_dir/linear.json" --work "$case_dir/work.json" \
    --slots "$slots" >"$case_dir/out2.json" 2>/dev/null || rc=$?
  ((rc == 0)) || fail "reason=script_failed_on_second_run case=$name rc=$rc"
  cmp -s "$case_dir/out.json" "$case_dir/out2.json" || fail "reason=unstable_output case=$name"

  echo "  case $name: PASS"
}

for case_file in "${cases[@]}"; do
  run_case "$case_file"
done

# Le nombre de places par défaut est 10 : 9 travaux actifs laissent une place,
# 10 travaux actifs n'en laissent aucune.
default_places() {
  local active=$1
  local expected=$2
  local case_dir="$tmp/default-$active"
  mkdir -p "$case_dir"
  jq -n '{
    data: { issues: { nodes: [ {
      identifier: "PLT-900", title: "Reprise du graphique de latence",
      description: "Reprise du graphique de latence.\n\nDépôt: kube-ops\n",
      priority: 1, createdAt: "2026-01-01T00:00:00.000Z",
      url: "https://linear.app/boule/issue/PLT-900",
      labels: { nodes: [ { name: "wip:optio" } ] },
      assignee: null, relations: { nodes: [] }
    } ] } }
  }' >"$case_dir/linear.json"
  jq -n --argjson n "$active" '{
    works: [ range(0; $n) as $i | {
      name: ("[PLT-" + (100 + $i | tostring) + "] travail"),
      state: "running"
    } ]
  }' >"$case_dir/work.json"
  local rc=0
  bash "$script" --linear "$case_dir/linear.json" --work "$case_dir/work.json" \
    >"$case_dir/out.json" 2>"$case_dir/err" || rc=$?
  ((rc == 0)) || fail "reason=script_failed case=default-places rc=$rc"
  jq -e --argjson n "$expected" '.create_tasks | length == $n' "$case_dir/out.json" >/dev/null ||
    fail "reason=unexpected_default_places active=$active expected_tasks=$expected"
}

default_places 9 1
default_places 10 0

# Usage : sortie 2 sur une entrée absente, illisible ou invalide.
printf '%s\n' '{"works":[]}' >"$tmp/empty-work.json"
printf '%s\n' 'pas du json' >"$tmp/broken.json"
expect_rc() {
  local want=$1
  shift
  local rc=0
  bash "$script" "$@" >/dev/null 2>&1 || rc=$?
  ((rc == want)) || fail "reason=unexpected_rc want=$want got=$rc args=$*"
}
expect_rc 2 --work "$tmp/empty-work.json"
expect_rc 2 --linear "$tmp/absent.json" --work "$tmp/empty-work.json"
expect_rc 2 --linear "$tmp/broken.json" --work "$tmp/empty-work.json"
expect_rc 2 --linear "$tmp/empty-work.json" --work "$tmp/broken.json"
expect_rc 2 --linear "$tmp/empty-work.json" --work "$tmp/empty-work.json" --slots abc
expect_rc 2 --linear "$tmp/empty-work.json" --work "$tmp/empty-work.json" --slots -1
expect_rc 2 --linear "$tmp/empty-work.json" --work "$tmp/empty-work.json" --unknown-flag

if command -v shellcheck >/dev/null; then
  shellcheck -s bash "$script" "$test_file" || fail "reason=shellcheck_failed"
fi

echo "OPTIO_SELECT_ACTIONS=PASS cases=${#cases[@]}"
