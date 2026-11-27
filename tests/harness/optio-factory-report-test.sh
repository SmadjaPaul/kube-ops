#!/usr/bin/env bash
# PLT-540 : tests de scripts/optio/factory-report.sh.
#
# Le script rend un rapport Markdown de ce que chaque tâche Optio a fait et de
# ce qu'elle demande : une ligne par tâche (état, ticket, PR, motif, résumé du
# résultat, tokens, coût) et, en tête, les compteurs et la liste des tâches
# needs_attention. Il est déterministe, en lecture seule, sans modèle.
#
# Ce test le joue hors réseau : une liste locale de tâches (--input) et, pour
# le seul cas qui parle à l'API, un faux curl qui sert une fixture et journalise
# les requêtes. Aucun appel réseau, aucun accès cluster.
#
# Cas couverts : usage (--help, option inconnue, --hours invalide, --input
# illisible) ; liste vide ; liste complète (compteurs par état, tâches sans
# compte de tokens, liste needs_attention, ligne par tâche, échappement
# Markdown, résumé tronqué) ; champs absents (« inconnu », jamais zéro) ;
# forme de l'API ({"tasks": [...]}) ; période (tâche récente gardée, tâche
# ancienne écartée, tâche sans horodatage conservée) ; appel API (une seule
# requête GET /api/tasks?limit=200, aucun jeton dans la sortie ni dans la ligne
# de commande, en-têtes présents) ; erreur d'API ; jq 1.6 ; le dépôt n'est pas
# modifié par le test.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo_root/scripts/optio/factory-report.sh"
test_file="$repo_root/tests/harness/optio-factory-report-test.sh"
fixture_dir="$repo_root/tests/fixtures/optio-factory-report"
bash_list="$repo_root/scripts/check-bash-tests.list"

command -v jq >/dev/null || { echo "OPTIO_FACTORY_REPORT=BLOCKED reason=jq_required"; exit 2; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "OPTIO_FACTORY_REPORT=FAIL $*" >&2
  exit 1
}

[[ -f "$script" ]] || fail "reason=missing_script path=$script"
[[ -r "$fixture_dir/tasks-empty.json" ]] || fail "reason=missing_fixture path=$fixture_dir"

# Le test doit tourner dans la porte locale canonique.
grep -qx 'tests/harness/optio-factory-report-test.sh' "$bash_list" ||
  fail "reason=not_listed file=scripts/check-bash-tests.list"

# Le rapport est en lecture seule : le script ne doit jamais choisir une autre
# méthode que GET, ni contenir un verbe d'écriture.
if grep -nE '(^|[^-])-X[[:space:]]|--request' "$script"; then
  fail "reason=explicit_method_detected"
fi
if grep -nE '(^|[^A-Za-z])(POST|PUT|PATCH|DELETE)([^A-Za-z]|$)' "$script"; then
  fail "reason=write_verb_detected"
fi

# jq 1.6 lève une erreur « capture requires a match » quand l'entrée ne
# correspond pas à l'expression régulière ; jq 1.7 renvoie un résultat vide.
# Ce shim rejoue le comportement de jq 1.6 : le rapport doit être le même avec
# les deux versions.
real_jq="$(command -v jq)"
jq16_bin="$tmp/jq16"
mkdir -p "$jq16_bin"
cat >"$jq16_bin/jq" <<SHIM
#!/usr/bin/env bash
# Émulateur de jq 1.6 : capture/1 échoue quand l'entrée ne correspond pas et
# expose les captures nommées sous .namedCaptures.
set -euo pipefail
override='def capture(\$re): ([match(\$re)] | if length == 0 then error("capture requires a match") else .[0] | {captures: .captures, namedCaptures: (.captures | map({key: .name, value: .string}) | from_entries)} end); '
args=("\$@")
main=0
for arg in "\${args[@]}"; do
  if [ "\$arg" = "--slurpfile" ]; then
    main=1
  fi
done
if ((main)); then
  last=\$((\${#args[@]} - 1))
  args[\$last]="\$override\${args[\$last]}"
fi
exec "$real_jq" "\${args[@]}"
SHIM
chmod +x "$jq16_bin/jq"

# --- faux curl ---------------------------------------------------------------

# Le faux curl sert une fixture locale et journalise la méthode, l'URL, la
# ligne de commande et les en-têtes sous forme d'empreinte : le test vérifie
# ainsi qu'aucun secret ne passe en argument et qu'aucune écriture n'est
# demandée à l'API.
make_fake_curl() {
  local bin_dir=$1
  mkdir -p "$bin_dir"
  cat >"$bin_dir/curl" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail
dir="${OPTIO_REPORT_FAKE_DIR:?fake dir}"
printf '%s\n' "$*" >>"$dir/argv.log"

method=GET
out=""
writeout=""
url=""
args=("$@")
i=0
while [ "$i" -lt "${#args[@]}" ]; do
  a="${args[$i]}"
  case "$a" in
    -o) out="${args[$((i + 1))]:-}"; i=$((i + 2));;
    -w) writeout="${args[$((i + 1))]:-}"; i=$((i + 2));;
    -X|--request) method="${args[$((i + 1))]:-}"; i=$((i + 2));;
    -H)
      h="${args[$((i + 1))]:-}"
      case "$h" in
        @*)
          hfile="${h#@}"
          if [ -r "$hfile" ]; then
            while IFS= read -r line; do
              [ -n "$line" ] || continue
              hname="${line%%:*}"
              hval="${line#*:}"
              hval="${hval# }"
              printf '%s\t%s\n' "$hname" \
                "$(printf '%s' "$hval" | sha256sum | cut -d' ' -f1)" >>"$dir/headers.log"
            done <"$hfile"
          fi
          ;;
        *)
          printf '%s\t%s\n' "${h%%:*}" \
            "$(printf '%s' "${h#*:}" | sha256sum | cut -d' ' -f1)" >>"$dir/headers.log"
          ;;
      esac
      i=$((i + 2));;
    -*) i=$((i + 1));;
    *) url="$a"; i=$((i + 1));;
  esac
done

printf '%s\t%s\n' "$method" "$url" >>"$dir/calls.log"

status=200
serve=""
if [ -f "$dir/response.json" ]; then
  serve="$dir/response.json"
fi
if [ -f "$dir/response.status" ]; then
  status="$(cat "$dir/response.status")"
fi
if [ -n "$serve" ] && [ -f "$serve" ]; then
  if [ -n "$out" ]; then cp "$serve" "$out"; else cat "$serve"; fi
else
  [ -n "$out" ] && : >"$out"
  status=404
fi

if [ -n "$writeout" ]; then
  printf '%s' "$writeout" | sed "s/%{http_code}/$status/g"
fi
FAKE
  chmod +x "$bin_dir/curl"
}

# --- helpers -----------------------------------------------------------------

RC=0
run_report() {
  RC=0
  bash "$script" "$@" >"$tmp/out" 2>"$tmp/err" || RC=$?
}

expect_rc() {
  local want=$1 name=$2
  [[ "$RC" == "$want" ]] ||
    fail "reason=unexpected_rc case=$name want=$want got=$RC err=$(tr '\n' ' ' <"$tmp/err")"
}

expect_contains() {
  local needle=$1 name=$2
  grep -Fq -- "$needle" "$tmp/out" ||
    fail "reason=missing_text case=$name needle=$needle out=$(tr '\n' ' ' <"$tmp/out")"
}

expect_missing() {
  local needle=$1 name=$2
  if grep -Fq -- "$needle" "$tmp/out"; then
    fail "reason=unexpected_text case=$name needle=$needle out=$(tr '\n' ' ' <"$tmp/out")"
  fi
}

# La ligne d'un tableau qui contient le texte donné.
row_of() {
  local needle=$1
  grep -F -- "$needle" "$tmp/out" | grep -F '|' | head -n 1
}

# La cellule n-ième (1) d'une ligne de tableau. La barre verticale échappée
# (\|) ne sépare pas deux cellules.
cell_of() {
  local line=$1 index=$2
  printf '%s' "$line" \
    | sed 's/\\|/@PIPE@/g' \
    | awk -F'|' -v i="$index" '{ gsub(/^ +| +$/, "", $(i + 1)); print $(i + 1) }' \
    | sed 's/@PIPE@/|/g'
}

# Empreinte de l'état du dépôt : le test ne doit rien y écrire.
repo_snapshot() {
  {
    git -C "$repo_root" status --porcelain --untracked-files=all
    find "$repo_root/scripts/optio" "$repo_root/tests/harness" "$repo_root/tests/fixtures" \
      "$repo_root/scripts/check-bash-tests.list" -type f -exec sha256sum {} + 2>/dev/null | sort
  } | sha256sum | cut -d" " -f1
}

snapshot_before="$(repo_snapshot)"
cases=0

# --- 1. usage ----------------------------------------------------------------

run_report --help
expect_rc 0 help
expect_contains "usage: optio/factory-report.sh" help
cases=$((cases + 1))

run_report --unknown-flag
expect_rc 2 unknown-flag
cases=$((cases + 1))

run_report --hours abc
expect_rc 2 hours-not-a-number
cases=$((cases + 1))

run_report --hours -1
expect_rc 2 hours-negative
cases=$((cases + 1))

run_report --input "$tmp/absent.json"
expect_rc 2 input-missing
cases=$((cases + 1))

# --- 2. données invalides ----------------------------------------------------

printf 'pas du json\n' >"$tmp/broken.json"
run_report --input "$tmp/broken.json"
expect_rc 1 input-not-json
cases=$((cases + 1))

printf '{"limit": 200}\n' >"$tmp/wrong-shape.json"
run_report --input "$tmp/wrong-shape.json"
expect_rc 1 input-wrong-shape
cases=$((cases + 1))

# --- 3. liste vide -----------------------------------------------------------

run_report --input "$fixture_dir/tasks-empty.json"
expect_rc 0 empty
expect_contains "- Tâches : 0" empty
expect_contains "- Par état : aucune" empty
expect_contains "- Sans compte de tokens : 0" empty
expect_contains "Aucune tâche en needs_attention." empty
expect_contains "Aucune tâche sur la période." empty
cases=$((cases + 1))

# --- 4. liste complète -------------------------------------------------------

run_report --input "$fixture_dir/tasks-full.json" --hours 1000000
expect_rc 0 full
expect_contains "# Rapport Optio — 1000000 h" full
expect_contains "- Tâches : 3" full
expect_contains "- Par état : completed 1, failed 1, needs_attention 1" full
# Une seule tâche n'a aucun compte de tokens.
expect_contains "- Sans compte de tokens : 1" full
# La période est annoncée.
grep -Eq '^Période : [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z → ' "$tmp/out" ||
  fail "reason=missing_period case=full out=$(tr '\n' ' ' <"$tmp/out")"
# La liste needs_attention porte le motif.
expect_contains "- PLT-541 (#2106) — ci_failing_needs_attention" full
# Une ligne par tâche : état, ticket, PR, motif, résumé, tokens, coût.
row="$(row_of "[PLT-540] Rapport sans modèle")"
[[ -n "$row" ]] || fail "reason=missing_row case=full"
[[ "$(cell_of "$row" 2)" == "completed" ]] ||
  fail "reason=unexpected_state case=full cell=$(cell_of "$row" 2)"
[[ "$(cell_of "$row" 3)" == "PLT-540" ]] ||
  fail "reason=unexpected_ticket case=full cell=$(cell_of "$row" 3)"
[[ "$(cell_of "$row" 4)" == "#2107" ]] ||
  fail "reason=unexpected_pr case=full cell=$(cell_of "$row" 4)"
[[ "$(cell_of "$row" 5)" == "inconnu" ]] ||
  fail "reason=unexpected_reason case=full cell=$(cell_of "$row" 5)"
[[ "$(cell_of "$row" 7)" == "1234 (in 800 / out 434)" ]] ||
  fail "reason=unexpected_tokens case=full cell=$(cell_of "$row" 7)"
[[ "$(cell_of "$row" 8)" == "\$0.4210" ]] ||
  fail "reason=unexpected_cost case=full cell=$(cell_of "$row" 8)"
[[ "$(cell_of "$row" 9)" == "2026-01-01T00:10:00.000Z" ]] ||
  fail "reason=unexpected_activity case=full cell=$(cell_of "$row" 9)"
# La tâche en échec : un motif, un seul sens de tokens.
row="$(row_of "[PLT-542] Corriger le rapport")"
[[ -n "$row" ]] || fail "reason=missing_row case=failed"
[[ "$(cell_of "$row" 2)" == "failed" ]] ||
  fail "reason=unexpected_state case=failed cell=$(cell_of "$row" 2)"
[[ "$(cell_of "$row" 5)" == "agent_crashed" ]] ||
  fail "reason=unexpected_reason case=failed cell=$(cell_of "$row" 5)"
[[ "$(cell_of "$row" 7)" == "800 (in)" ]] ||
  fail "reason=unexpected_tokens case=failed cell=$(cell_of "$row" 7)"
# Le résumé est tronqué et la barre verticale du titre est échappée.
expect_contains "…" full
expect_contains "PLT-542] Corriger le rapport \\| valeurs manquantes" full
cases=$((cases + 1))

# --- 5. champs absents : « inconnu », jamais zéro ----------------------------

run_report --input "$fixture_dir/tasks-missing-fields.json" --hours 1000000
expect_rc 0 missing-fields
expect_contains "- Tâches : 3" missing-fields
expect_contains "- Sans compte de tokens : 3" missing-fields
row="$(row_of "[PLT-543] Une tâche sans compte")"
[[ -n "$row" ]] || fail "reason=missing_row case=missing-fields"
# La tâche sans rien : chaque champ absent vaut « inconnu », pas zéro.
row="$(grep -F -- "| inconnu | inconnu | inconnu | inconnu | inconnu | inconnu | inconnu | inconnu | inconnu |" \
  "$tmp/out" | head -n 1)"
[[ -n "$row" ]] || fail "reason=missing_empty_row case=missing-fields"
for index in 1 2 3 4 5 6 7 8 9; do
  [[ "$(cell_of "$row" "$index")" == "inconnu" ]] ||
    fail "reason=unexpected_cell case=missing-fields index=$index cell=$(cell_of "$row" "$index")"
done
# La tâche qui n'a qu'un état : le reste est inconnu.
row="$(row_of "[PLT-543] Une tâche sans compte")"
[[ "$(cell_of "$row" 2)" == "running" ]] ||
  fail "reason=unexpected_state case=missing-fields cell=$(cell_of "$row" 2)"
# Le ticket est déduit du titre quand l'API ne le donne pas.
[[ "$(cell_of "$row" 3)" == "PLT-543" ]] ||
  fail "reason=unexpected_ticket case=missing-fields cell=$(cell_of "$row" 3)"
for index in 4 5 6 7 8 9; do
  [[ "$(cell_of "$row" "$index")" == "inconnu" ]] ||
    fail "reason=unexpected_cell case=missing-fields index=$index cell=$(cell_of "$row" "$index")"
done
# Aucun zéro ne remplace un champ absent.
if grep -Eq '\| (0|[$]0) ' "$tmp/out"; then
  fail "reason=zero_for_absent_field case=missing-fields out=$(tr '\n' ' ' <"$tmp/out")"
fi
cases=$((cases + 1))

# --- 6. forme de l'API : {"tasks": [...]} ------------------------------------

run_report --input "$fixture_dir/tasks-api-shape.json" --hours 1000000
expect_rc 0 api-shape
expect_contains "- Tâches : 1" api-shape
expect_contains "PLT-544" api-shape
cases=$((cases + 1))

# --- 7. période --------------------------------------------------------------

# Une tâche récente, une tâche ancienne, une tâche sans horodatage.
jq -n '
  (now) as $n
  | [
      {id: "recent", title: "[PLT-900] Tâche récente", state: "completed",
       createdAt: (($n - 3600) | todate), updatedAt: (($n - 3600) | todate)},
      {id: "old", title: "[PLT-901] Tâche ancienne", state: "completed",
       createdAt: (($n - 172800) | todate), updatedAt: (($n - 172800) | todate)},
      {id: "undated", title: "[PLT-902] Tâche sans horodatage", state: "completed"}
    ]' >"$tmp/window.json"

run_report --input "$tmp/window.json"
expect_rc 0 window
expect_contains "- Tâches : 2" window
expect_contains "PLT-900" window
expect_contains "PLT-902" window
expect_missing "PLT-901" window
cases=$((cases + 1))

# --- 8. appel de l'API : une seule lecture, aucun secret --------------------

api_dir="$tmp/api"
mkdir -p "$api_dir/bin"
cp "$fixture_dir/tasks-full.json" "$api_dir/response.json"
: >"$api_dir/calls.log"
: >"$api_dir/argv.log"
: >"$api_dir/headers.log"
make_fake_curl "$api_dir/bin"

RC=0
PATH="$api_dir/bin:$PATH" \
  OPTIO_REPORT_FAKE_DIR="$api_dir" \
  OPTIO_API_TOKEN="fake-optio-token" \
  OPTIO_API_URL="http://optio-api.test:4000" \
  OPTIO_WORKSPACE_ID="fake-workspace" \
  bash "$script" --hours 1000000 >"$tmp/out" 2>"$tmp/err" || RC=$?
[[ "$RC" == "0" ]] || fail "reason=unexpected_rc case=api got=$RC err=$(tr '\n' ' ' <"$tmp/err")"
grep -Fq "PLT-540" "$tmp/out" || fail "reason=missing_report case=api"
# Une seule requête, en lecture, sur la liste des tâches.
[[ "$(wc -l <"$api_dir/calls.log" | tr -d ' ')" == "1" ]] ||
  fail "reason=unexpected_call_count case=api calls=$(tr '\n' ' ' <"$api_dir/calls.log")"
grep -Fq "GET" "$api_dir/calls.log" || fail "reason=unexpected_method case=api"
grep -Fq "/api/tasks?limit=200" "$api_dir/calls.log" ||
  fail "reason=unexpected_url case=api calls=$(tr '\n' ' ' <"$api_dir/calls.log")"
# Le jeton et l'espace de travail ne sont ni affichés ni passés en argument.
for secret in fake-optio-token fake-workspace; do
  if grep -Fq "$secret" "$tmp/out" "$tmp/err"; then
    fail "reason=secret_in_output case=api secret=$secret"
  fi
  if grep -Fq "$secret" "$api_dir/argv.log"; then
    fail "reason=secret_in_argv case=api secret=$secret"
  fi
done
# Les secrets sont dans les en-têtes, jamais dans la ligne de commande.
optio_hash="$(printf '%s' "Bearer fake-optio-token" | sha256sum | cut -d' ' -f1)"
workspace_hash="$(printf '%s' "fake-workspace" | sha256sum | cut -d' ' -f1)"
grep -Fq "Authorization	$optio_hash" "$api_dir/headers.log" ||
  fail "reason=missing_optio_header case=api headers=$(cat "$api_dir/headers.log")"
grep -Fq "x-workspace-id	$workspace_hash" "$api_dir/headers.log" ||
  fail "reason=missing_workspace_header case=api headers=$(cat "$api_dir/headers.log")"
cases=$((cases + 1))

# --- 9. erreur d'API ---------------------------------------------------------

printf '500\n' >"$api_dir/response.status"
RC=0
PATH="$api_dir/bin:$PATH" \
  OPTIO_REPORT_FAKE_DIR="$api_dir" \
  OPTIO_API_TOKEN="fake-optio-token" \
  OPTIO_API_URL="http://optio-api.test:4000" \
  bash "$script" >"$tmp/out" 2>"$tmp/err" || RC=$?
[[ "$RC" != "0" ]] || fail "reason=unexpected_rc case=api-error got=0"
grep -Fq "HTTP 500" "$tmp/err" || fail "reason=missing_error case=api-error err=$(cat "$tmp/err")"
cases=$((cases + 1))

# --- 10. jeton absent --------------------------------------------------------

RC=0
env -u OPTIO_API_TOKEN bash "$script" >"$tmp/out" 2>"$tmp/err" || RC=$?
[[ "$RC" == "2" ]] || fail "reason=unexpected_rc case=missing-token got=$RC"
cases=$((cases + 1))

# --- 11. jq 1.6 : le même rapport ---------------------------------------------

RC=0
PATH="$jq16_bin:$PATH" bash "$script" --input "$fixture_dir/tasks-full.json" \
  --hours 1000000 >"$tmp/out" 2>"$tmp/err" || RC=$?
[[ "$RC" == "0" ]] || fail "reason=unexpected_rc case=jq16 got=$RC err=$(tr '\n' ' ' <"$tmp/err")"
expect_contains "- Tâches : 3" jq16
expect_contains "- Par état : completed 1, failed 1, needs_attention 1" jq16
expect_contains "- PLT-541 (#2106) — ci_failing_needs_attention" jq16
cases=$((cases + 1))

# --- 12. le script n'écrit pas dans le dépôt ----------------------------------

snapshot_after="$(repo_snapshot)"
if [[ "$snapshot_after" != "$snapshot_before" ]]; then
  fail "reason=repository_modified_by_test"
fi
cases=$((cases + 1))

if command -v shellcheck >/dev/null; then
  shellcheck -s bash "$script" "$test_file" || fail "reason=shellcheck_failed"
fi

echo "OPTIO_FACTORY_REPORT=PASS cases=$cases"
