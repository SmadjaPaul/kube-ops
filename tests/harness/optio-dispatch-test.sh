#!/usr/bin/env bash
# PLT-527 : tests de scripts/optio/dispatch.sh.
#
# Le script est l'orchestrateur sans LLM : il lit Linear et l'API Optio, décide
# avec scripts/optio/select-actions.sh, relit l'état réel des PR sur GitHub et
# crée les tâches de ticket, de revue et de correction. Ce test le joue hors
# réseau : un faux curl dans le PATH sert des fixtures locales, et les
# requêtes envoyées sont inspectées.
#
# Cas couverts : file vide (aucune écriture) ; un ticket (une création en
# --apply, aucune sans) ; label agent:opus (modèle code/frontier) ; ticket
# assigné (aucun travail) ; second passage (aucun doublon) ; PR fermée ou mergée
# (aucune revue, aucune correction, annulation des travaux encore actifs) ;
# nouvelle tête de PR (nouvelle revue) ; tâche échouée (une reprise, puis le
# plafond, puis une tâche qui a changé entre deux lectures) ; erreur d'API
# (code de retour non nul, erreur comptée dans le compte rendu, y compris au
# téléchargement du script de sélection) ; consignes recopiées depuis
# docs/operations/optio-intake.md ; secret jamais dans la sortie ni dans la
# ligne de commande ; un seul passage à la fois ; jq 1.6.
#
# Lecture seule, aucun accès cluster, aucun appel réseau. Autonome : mktemp,
# aucune écriture dans le dépôt.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo_root/scripts/optio/dispatch.sh"
test_file="$repo_root/tests/harness/optio-dispatch-test.sh"
fixture_dir="$repo_root/tests/fixtures/optio-dispatch"
bash_list="$repo_root/scripts/check-bash-tests.list"
intake="$repo_root/docs/operations/optio-intake.md"

command -v jq >/dev/null || { echo "OPTIO_DISPATCH=BLOCKED reason=jq_required"; exit 2; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "OPTIO_DISPATCH=FAIL $*" >&2
  exit 1
}

[[ -f "$script" ]] || fail "reason=missing_script path=$script"
[[ -r "$intake" ]] || fail "reason=missing_intake path=$intake"

# Le test doit tourner dans la porte locale canonique.
grep -qx 'tests/harness/optio-dispatch-test.sh' "$bash_list" ||
  fail "reason=not_listed file=scripts/check-bash-tests.list"

# Le travail de commande n'a ni dépôt cloné ni authentification GitHub : le
# script ne doit appeler que curl, jamais gh, wget ni un shell réseau.
if grep -vE '^[[:space:]]*#' "$script" |
  grep -qE '(^|[^[:alnum:]_])(gh|wget|nc|ncat|ssh|scp)([^[:alnum:]_]|$)'; then
  fail "reason=forbidden_client_detected"
fi

# jq 1.6 lève une erreur « capture requires a match » quand l'entrée ne
# correspond pas à l'expression régulière ; jq 1.7 renvoie un résultat vide.
# Ce shim rejoue le comportement de jq 1.6 : la décision du script doit être
# la même avec les deux versions.
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

# Le faux curl sert des fixtures locales : routes.tsv associe une méthode, un
# fragment d'URL et un fichier de réponse. Il journalise les requêtes
# (calls.log), les corps envoyés (body.N) et les en-têtes sous forme d'empreinte
# (headers.log) : le test vérifie ainsi qu'aucun secret ne passe en argument.
make_fake_curl() {
  local bin_dir=$1
  mkdir -p "$bin_dir"
  cat >"$bin_dir/curl" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail
dir="${OPTIO_DISPATCH_FAKE_DIR:?fake dir}"
printf '%s\n' "$*" >>"$dir/argv.log"

method=GET
out=""
writeout=""
body=""
url=""
args=("$@")
i=0
while [ "$i" -lt "${#args[@]}" ]; do
  a="${args[$i]}"
  case "$a" in
    -o) out="${args[$((i + 1))]:-}"; i=$((i + 2));;
    -w) writeout="${args[$((i + 1))]:-}"; i=$((i + 2));;
    -X) method="${args[$((i + 1))]:-}"; i=$((i + 2));;
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
    --data-binary | --data | -d) body="${args[$((i + 1))]:-}"; i=$((i + 2));;
    -*) i=$((i + 1));;
    *) url="$a"; i=$((i + 1));;
  esac
done

body_content=""
if [ -n "$body" ]; then
  case "$body" in
    @*) [ -r "${body#@}" ] && body_content="$(cat "${body#@}")";;
    *) body_content="$body";;
  esac
fi

body_index=$(( $(cat "$dir/body.count" 2>/dev/null || echo 0) + 1 ))
printf '%s' "$body_index" >"$dir/body.count"
[ -n "$body_content" ] && printf '%s' "$body_content" >"$dir/body.$body_index"
printf '%s\t%s\t%s\n' "$method" "$url" "$body_index" >>"$dir/calls.log"

# Une route peut porter un quatrième champ : le fichier servi à partir de la
# deuxième lecture. L'état du travail change ainsi entre deux lectures.
reads=0
if [ "$method" = "GET" ]; then
  case "$url" in
    *"/api/tasks?"*)
      reads="$(cat "$dir/tasks.reads" 2>/dev/null || echo 0)"
      reads=$((reads + 1))
      printf '%s' "$reads" >"$dir/tasks.reads"
      ;;
  esac
fi

response=""
next_response=""
status=200
while read -r rmethod rneedle rfile rnext; do
  [ -n "${rmethod:-}" ] || continue
  case "$rmethod" in \#*) continue;; esac
  [ "$rmethod" = "$method" ] || continue
  case "$url" in
    *"$rneedle"*) response="$rfile"; next_response="$rnext"; break;;
  esac
done <"$dir/routes.tsv"

serve=""
if [ -n "$response" ] && [ -f "$dir/$response" ]; then
  serve="$dir/$response"
  [ -f "$dir/$response.status" ] && status="$(cat "$dir/$response.status")"
fi
if [ -n "$next_response" ] && [ "$reads" -gt 1 ] && [ -f "$dir/$next_response" ]; then
  serve="$dir/$next_response"
  status=200
fi
# La liste des travaux est mutée par les créations : le relecture avant chaque
# création doit voir la tâche déjà créée.
if [ "$method" = "GET" ] && [ -f "$dir/state-tasks.json" ]; then
  case "$url" in
    *"/api/tasks?"*) serve="$dir/state-tasks.json";;
  esac
fi

if [ -n "$serve" ]; then
  if [ -n "$out" ]; then cp "$serve" "$out"; else cat "$serve"; fi
else
  [ -n "$out" ] && : >"$out"
  status=404
fi

if [ "$method" = "POST" ]; then
  case "$url" in
    */api/tasks)
      title="$(printf '%s' "$body_content" | jq -r '.title // empty' 2>/dev/null)"
      if [ -n "$title" ]; then
        if [ -f "$dir/state-tasks.json" ]; then
          jq --arg t "$title" '. + [{id: "gen", title: $t, state: "queued",
            prUrl: "", prNumber: null, prChecksStatus: "", retryCount: 0}]' \
            "$dir/state-tasks.json" >"$dir/state-tasks.tmp" &&
            mv "$dir/state-tasks.tmp" "$dir/state-tasks.json"
        else
          jq -n --arg t "$title" '[{id: "gen", title: $t, state: "queued",
            prUrl: "", prNumber: null, prChecksStatus: "", retryCount: 0}]' \
            >"$dir/state-tasks.json"
        fi
      fi
      ;;
  esac
fi

if [ -n "$writeout" ]; then
  printf '%s' "$writeout" | sed "s/%{http_code}/$status/g"
fi
FAKE
  chmod +x "$bin_dir/curl"
}

# --- helpers -----------------------------------------------------------------

# setup_case <nom> <fixture linear> <fixture travaux> <fixture pulls>
setup_case() {
  local name=$1 linear_fixture=$2 tasks_fixture=$3 pulls_fixture=$4
  local next_tasks=${5:-}
  local dir="$tmp/$name"
  mkdir -p "$dir/bin"
  cp "$fixture_dir/$linear_fixture" "$dir/linear.json"
  cp "$fixture_dir/$tasks_fixture" "$dir/optio-tasks.json"
  if [ -n "$next_tasks" ]; then
    cp "$fixture_dir/$next_tasks" "$dir/$next_tasks"
  fi
  cp "$fixture_dir/$pulls_fixture" "$dir/github-pulls.json"
  cp "$fixture_dir/optio-created.json" "$dir/optio-created.json"
  cp "$fixture_dir/optio-retry.json" "$dir/optio-retry.json"
  cp "$fixture_dir/optio-cancel.json" "$dir/optio-cancel.json"
  cp "$fixture_dir/api-error.json" "$dir/api-error.json"
  : >"$dir/calls.log"
  : >"$dir/argv.log"
  : >"$dir/headers.log"
  # Le fichier des consignes est servi comme le fait l'API GitHub : base64.
  base64 <"$intake" | tr -d '\n' >"$dir/intake.b64"
  jq -n --rawfile b64 "$dir/intake.b64" '{content: $b64, encoding: "base64"}' \
    >"$dir/github-contents.json"
  rm -f "$dir/intake.b64"
  # Les routes sont ordonnées : /retry et /cancel avant /api/tasks.
  {
    printf '%s\n' 'POST https://api.linear.app/graphql linear.json'
    printf '%s\n' 'GET https://api.github.com/repos/smadjapaul/kube-ops/pulls github-pulls.json'
    printf '%s\n' 'GET https://api.github.com/repos/smadjapaul/kube-ops/contents github-contents.json'
    printf '%s\n' 'POST /retry optio-retry.json'
    printf '%s\n' 'POST /cancel optio-cancel.json'
    printf 'GET /api/tasks?limit=200 optio-tasks.json %s\n' "$next_tasks"
    printf '%s\n' 'POST /api/tasks optio-created.json'
  } >"$dir/routes.tsv"
  make_fake_curl "$dir/bin"
  printf '%s' "$dir"
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

RC=0
run_dispatch() {
  local dir=$1
  shift
  local args=()
  if [ "${1:-}" = "--no-instructions" ]; then
    shift
  else
    args=(--instructions "$intake")
  fi
  RC=0
  PATH="$dir/bin:$PATH" \
    OPTIO_DISPATCH_FAKE_DIR="$dir" \
    OPTIO_DISPATCH_LOCK_FILE="$dir/dispatch.lock" \
    LINEAR_INTAKE_KEY="fake-linear-key" \
    OPTIO_API_TOKEN="fake-optio-token" \
    OPTIO_API_URL="http://optio-api.test:4000" \
    OPTIO_WORKSPACE_ID="fake-workspace" \
    bash "$script" "${args[@]}" "$@" >"$dir/out" 2>"$dir/err" || RC=$?
}

expect_rc() {
  local dir=$1 want=$2 name=$3
  [[ "$RC" == "$want" ]] ||
    fail "reason=unexpected_rc case=$name want=$want got=$RC err=$(tr '\n' ' ' <"$dir/err")"
}

summary_of() {
  tail -n 1 "$1/out"
}

actions_of() {
  head -n 1 "$1/out"
}

expect_counter() {
  local dir=$1 key=$2 want=$3 name=$4
  local got
  got="$(jq -r --arg key "$key" '.[$key] // "absent"' <<<"$(summary_of "$dir")")"
  [[ "$got" == "$want" ]] ||
    fail "reason=unexpected_counter case=$name key=$key want=$want got=$got summary=$(summary_of "$dir")"
}

# Nombre d'appels POST dont l'URL se termine par le fragment donné : une
# création (/api/tasks) ne se confond pas avec une annulation
# (/api/tasks/<id>/cancel).
count_posts() {
  local dir=$1 needle=$2
  awk -v n="$needle" '$1 == "POST" && $2 ~ (n "$") { c++ } END { print c + 0 }' "$dir/calls.log"
}

expect_posts() {
  local dir=$1 needle=$2 want=$3 name=$4
  local got
  got="$(count_posts "$dir" "$needle")"
  [[ "$got" == "$want" ]] ||
    fail "reason=unexpected_posts case=$name needle=$needle want=$want got=$got"
}

# Corps de la nième requête POST dont l'URL contient le fragment donné.
body_of() {
  local dir=$1 needle=$2 occurrence=${3:-1}
  local index
  index="$(awk -v n="$needle" -v o="$occurrence" \
    '$1 == "POST" && $2 ~ (n "$") { c++; if (c == o) { print $3; exit } }' "$dir/calls.log")"
  [[ -n "$index" && -f "$dir/body.$index" ]] ||
    fail "reason=missing_body case=$dir needle=$needle occurrence=$occurrence"
  cat "$dir/body.$index"
}

expect_output_shape() {
  local dir=$1 name=$2
  local lines
  lines="$(wc -l <"$dir/out" | tr -d ' ')"
  [[ "$lines" == "2" ]] ||
    fail "reason=unexpected_output_lines case=$name want=2 got=$lines"
  jq -e 'keys == ["cancelled", "created", "errors", "fixes", "retried", "reviews", "skipped", "tickets_read"]' \
    <<<"$(summary_of "$dir")" >/dev/null ||
    fail "reason=unexpected_summary_keys case=$name summary=$(summary_of "$dir")"
  jq -e 'has("tasks") and has("reviews") and has("fixes") and has("retries") and has("cancellations") and has("skipped")' \
    <<<"$(actions_of "$dir")" >/dev/null ||
    fail "reason=unexpected_actions_keys case=$name actions=$(actions_of "$dir")"
}

cases=0

# --- 1. file vide : aucune écriture ------------------------------------------

dir="$(setup_case empty linear-empty.json optio-tasks-empty.json github-pulls-empty.json)"
run_dispatch "$dir"
expect_rc "$dir" 0 empty
expect_output_shape "$dir" empty
expect_counter "$dir" tickets_read 0 empty
expect_counter "$dir" created 0 empty
expect_counter "$dir" errors 0 empty
expect_posts "$dir" "/api/tasks" 0 empty
expect_posts "$dir" "/retry" 0 empty
expect_posts "$dir" "/cancel" 0 empty
cases=$((cases + 1))

# --- 2. un ticket : aucune écriture sans --apply ------------------------------

dir="$(setup_case one-ticket linear-one-ticket.json optio-tasks-empty.json github-pulls-empty.json)"
run_dispatch "$dir"
expect_rc "$dir" 0 one-ticket
expect_output_shape "$dir" one-ticket
expect_counter "$dir" tickets_read 1 one-ticket
expect_counter "$dir" created 0 one-ticket
expect_posts "$dir" "/api/tasks" 0 one-ticket
jq -e '.tasks | length == 1' <<<"$(actions_of "$dir")" >/dev/null ||
  fail "reason=missing_planned_task case=one-ticket actions=$(actions_of "$dir")"
jq -e '.tasks[0].identifier == "PLT-900"' <<<"$(actions_of "$dir")" >/dev/null ||
  fail "reason=unexpected_planned_task case=one-ticket actions=$(actions_of "$dir")"
cases=$((cases + 1))

# --- 2 bis. label agent:opus : le modèle code/frontier ------------------------

dir="$(setup_case opus linear-one-ticket-opus.json optio-tasks-empty.json github-pulls-empty.json)"
run_dispatch "$dir" --apply
expect_rc "$dir" 0 opus
expect_counter "$dir" created 1 opus
body="$(body_of "$dir" "/api/tasks")"
jq -e '.metadata.agentOptions.claudeModel == "code/frontier"' <<<"$body" >/dev/null ||
  fail "reason=unexpected_model case=opus body=$body"
cases=$((cases + 1))

# --- 2 ter. ticket assigné : aucun travail ------------------------------------

dir="$(setup_case assigned linear-assigned-ticket.json optio-tasks-empty.json github-pulls-empty.json)"
run_dispatch "$dir" --apply
expect_rc "$dir" 0 assigned
expect_counter "$dir" created 0 assigned
expect_posts "$dir" "/api/tasks" 0 assigned
jq -e '.skipped[0].reason | test("assign")' <<<"$(actions_of "$dir")" >/dev/null ||
  fail "reason=unexpected_skip_reason case=assigned actions=$(actions_of "$dir")"
cases=$((cases + 1))

# --- 3. un ticket : une création en --apply -----------------------------------

dir="$(setup_case one-ticket-apply linear-one-ticket.json optio-tasks-empty.json github-pulls-empty.json)"
run_dispatch "$dir" --apply
expect_rc "$dir" 0 one-ticket-apply
expect_output_shape "$dir" one-ticket-apply
expect_counter "$dir" created 1 one-ticket-apply
expect_posts "$dir" "/api/tasks" 1 one-ticket-apply
body="$(body_of "$dir" "/api/tasks")"
jq -e '.title == "[PLT-900] Reprise du graphique de latence"' <<<"$body" >/dev/null ||
  fail "reason=unexpected_created_title case=one-ticket-apply body=$body"
jq -e '.owner == "me" and .autoMerge == false and .autoResume == false' <<<"$body" >/dev/null ||
  fail "reason=unexpected_created_flags case=one-ticket-apply body=$body"
jq -e '.metadata.agentOptions.claudeModel == "text/strong"
  and .metadata.agentOptions.claudeContextWindow == "200k"
  and .metadata.agentOptions.claudeEffort == "medium"' <<<"$body" >/dev/null ||
  fail "reason=unexpected_created_options case=one-ticket-apply body=$body"
# La consigne de code est recopiée depuis docs/operations/optio-intake.md.
grep -Fq "Livre une seule PR dont le titre finit par (PLT-900)." <<<"$body" ||
  fail "reason=missing_code_consigne case=one-ticket-apply"
grep -Fq "Ne lance jamais la suite complète" <<<"$body" ||
  fail "reason=missing_code_consigne_tail case=one-ticket-apply"
grep -Fq "<ticket>" <<<"$body" || fail "reason=missing_ticket_marker case=one-ticket-apply"
cases=$((cases + 1))

# --- 4. second passage : aucun doublon ----------------------------------------

dir="$(setup_case second-pass linear-one-ticket.json optio-tasks-empty.json github-pulls-empty.json)"
run_dispatch "$dir" --apply
expect_rc "$dir" 0 second-pass-first
expect_counter "$dir" created 1 second-pass-first
run_dispatch "$dir" --apply
expect_rc "$dir" 0 second-pass
expect_counter "$dir" created 0 second-pass
expect_counter "$dir" skipped 1 second-pass
expect_posts "$dir" "/api/tasks" 1 second-pass
jq -e '.skipped[0].reason | test("travail existant")' <<<"$(actions_of "$dir")" >/dev/null ||
  fail "reason=unexpected_skip_reason case=second-pass actions=$(actions_of "$dir")"
cases=$((cases + 1))

# --- 5. PR fermée ou mergée : aucune revue, aucune correction ------------------

dir="$(setup_case pr-closed linear-empty.json optio-tasks-pr-failing.json github-pulls-empty.json)"
run_dispatch "$dir" --apply
expect_rc "$dir" 0 pr-closed
expect_counter "$dir" created 0 pr-closed
expect_counter "$dir" fixes 0 pr-closed
expect_counter "$dir" reviews 0 pr-closed
expect_posts "$dir" "/api/tasks" 0 pr-closed
jq -e '.skipped[0].reason | test("fermée ou mergée")' <<<"$(actions_of "$dir")" >/dev/null ||
  fail "reason=unexpected_skip_reason case=pr-closed actions=$(actions_of "$dir")"
cases=$((cases + 1))

# --- 6. PR fermée ou mergée : annulation des travaux encore actifs -------------

dir="$(setup_case pr-closed-active linear-empty.json optio-tasks-pr-closed-active.json github-pulls-empty.json)"
run_dispatch "$dir" --apply
expect_rc "$dir" 0 pr-closed-active
expect_counter "$dir" cancelled 2 pr-closed-active
expect_counter "$dir" created 0 pr-closed-active
expect_posts "$dir" "/api/tasks" 0 pr-closed-active
expect_posts "$dir" "/cancel" 2 pr-closed-active
cases=$((cases + 1))

# --- 6 bis. travaux déjà annulés (graphie de l'API) : aucune ré-annulation ----

dir="$(setup_case pr-closed-cancelled linear-empty.json optio-tasks-pr-closed-cancelled.json github-pulls-empty.json)"
run_dispatch "$dir" --apply
expect_rc "$dir" 0 pr-closed-cancelled
expect_counter "$dir" cancelled 0 pr-closed-cancelled
expect_counter "$dir" errors 0 pr-closed-cancelled
expect_posts "$dir" "/cancel" 0 pr-closed-cancelled
cases=$((cases + 1))

# --- 6 ter. attentes sans objet : annulées ; les autres restent ----------------

dir="$(setup_case attention linear-empty.json optio-tasks-attention.json github-pulls-new-head.json)"
run_dispatch "$dir" --apply
expect_rc "$dir" 0 attention
expect_counter "$dir" cancelled 2 attention
expect_posts "$dir" "/cancel" 2 attention
for id in attention-1 attention-4; do
  grep -q "/api/tasks/$id/cancel" "$dir/calls.log" || fail "reason=missing_cancel case=attention id=$id"
done
cases=$((cases + 1))

# --- 6 quater. la tâche a repris entre deux lectures : aucune annulation -------

dir="$(setup_case attention-moved linear-empty.json optio-tasks-attention.json github-pulls-new-head.json optio-tasks-attention-moved.json)"
run_dispatch "$dir" --apply
expect_rc "$dir" 0 attention-moved
expect_counter "$dir" cancelled 0 attention-moved
expect_posts "$dir" "/cancel" 0 attention-moved
cases=$((cases + 1))

# --- 7. nouvelle tête : nouvelle revue ----------------------------------------

dir="$(setup_case new-head linear-empty.json optio-tasks-review-old-head.json github-pulls-new-head.json)"
run_dispatch "$dir" --apply
expect_rc "$dir" 0 new-head
expect_counter "$dir" reviews 1 new-head
expect_posts "$dir" "/api/tasks" 1 new-head
body="$(body_of "$dir" "/api/tasks")"
jq -e '.title == "[REVUE PR-42 bbbb2222]"' <<<"$body" >/dev/null ||
  fail "reason=unexpected_review_name case=new-head body=$body"
grep -Fq "You are the code reviewer of exactly ONE pull request: PR #42." <<<"$body" ||
  fail "reason=missing_review_consigne case=new-head"
grep -Fq "Never run the full test suite and never start a background command" <<<"$body" ||
  fail "reason=missing_review_suffix case=new-head"
grep -Fq "PR #N" <<<"$body" && fail "reason=unreplaced_placeholder case=new-head"
cases=$((cases + 1))

# --- 8. même tête : pas de nouvelle revue -------------------------------------

dir="$(setup_case same-head linear-empty.json optio-tasks-review-old-head.json github-pulls-old-head.json)"
run_dispatch "$dir" --apply
expect_rc "$dir" 0 same-head
expect_counter "$dir" reviews 0 same-head
expect_posts "$dir" "/api/tasks" 0 same-head
jq -e '.skipped[0].reason | test("travail existant")' <<<"$(actions_of "$dir")" >/dev/null ||
  fail "reason=unexpected_skip_reason case=same-head actions=$(actions_of "$dir")"
cases=$((cases + 1))

# --- 9. tâche échouée : une reprise --------------------------------------------

dir="$(setup_case failed linear-empty.json optio-tasks-failed.json github-pulls-empty.json)"
run_dispatch "$dir" --apply
expect_rc "$dir" 0 failed
expect_counter "$dir" retried 1 failed
expect_posts "$dir" "/retry" 1 failed
body="$(body_of "$dir" "/retry")"
jq -e 'type == "object"' <<<"$body" >/dev/null ||
  fail "reason=unexpected_retry_body case=failed body=$body"
cases=$((cases + 1))

# --- 10. tâche échouée : plafond de reprise ------------------------------------

dir="$(setup_case failed-ceiling linear-empty.json optio-tasks-failed-ceiling.json github-pulls-empty.json)"
run_dispatch "$dir" --apply
expect_rc "$dir" 0 failed-ceiling
expect_counter "$dir" retried 0 failed-ceiling
expect_posts "$dir" "/retry" 0 failed-ceiling
jq -e '.skipped[0].reason | test("plafond")' <<<"$(actions_of "$dir")" >/dev/null ||
  fail "reason=unexpected_skip_reason case=failed-ceiling actions=$(actions_of "$dir")"
cases=$((cases + 1))

# --- 11. tâche échouée avec PR : pas de reprise -------------------------------

dir="$(setup_case failed-with-pr linear-empty.json optio-tasks-failed-with-pr.json github-pulls-empty.json)"
run_dispatch "$dir" --apply
expect_rc "$dir" 0 failed-with-pr
expect_counter "$dir" retried 0 failed-with-pr
expect_posts "$dir" "/retry" 0 failed-with-pr
cases=$((cases + 1))

# --- 11 bis. la tâche échouée a changé depuis la lecture ------------------------

# La tâche a une PR depuis la lecture initiale et la PR est fermée : la
# reprise est refusée, l'état réel des PR a été relu.
dir="$(setup_case failed-pr-appeared linear-empty.json optio-tasks-failed.json github-pulls-empty.json optio-tasks-failed-with-pr.json)"
run_dispatch "$dir" --apply
expect_rc "$dir" 0 failed-pr-appeared
expect_counter "$dir" retried 0 failed-pr-appeared
expect_posts "$dir" "/retry" 0 failed-pr-appeared
jq -e '.skipped[0].reason | test("PR")' <<<"$(actions_of "$dir")" >/dev/null ||
  fail "reason=unexpected_skip_reason case=failed-pr-appeared actions=$(actions_of "$dir")"
cases=$((cases + 1))

# La tâche n'est plus en échec : la reprise est refusée.
dir="$(setup_case failed-recovered linear-empty.json optio-tasks-failed.json github-pulls-empty.json optio-tasks-running.json)"
run_dispatch "$dir" --apply
expect_rc "$dir" 0 failed-recovered
expect_counter "$dir" retried 0 failed-recovered
expect_posts "$dir" "/retry" 0 failed-recovered
jq -e '.skipped[0].reason | test("échec")' <<<"$(actions_of "$dir")" >/dev/null ||
  fail "reason=unexpected_skip_reason case=failed-recovered actions=$(actions_of "$dir")"
cases=$((cases + 1))

# --- 12. consignes téléchargées depuis la branche main -------------------------

dir="$(setup_case downloaded linear-one-ticket.json optio-tasks-empty.json github-pulls-empty.json)"
run_dispatch "$dir" --no-instructions --apply
expect_rc "$dir" 0 downloaded
expect_counter "$dir" created 1 downloaded
body="$(body_of "$dir" "/api/tasks")"
grep -Fq "Livre une seule PR dont le titre finit par (PLT-900)." <<<"$body" ||
  fail "reason=missing_downloaded_consigne case=downloaded"
cases=$((cases + 1))

# --- 13. erreur d'API : code de retour non nul --------------------------------

dir="$(setup_case api-error linear-one-ticket.json optio-tasks-empty.json github-pulls-empty.json)"
printf '500\n' >"$dir/linear.json.status"
run_dispatch "$dir" --apply
[[ "$RC" != "0" ]] || fail "reason=unexpected_rc case=api-error got=0"
expect_counter "$dir" errors 1 api-error
expect_posts "$dir" "/api/tasks" 0 api-error
cases=$((cases + 1))

dir="$(setup_case api-error-tasks linear-one-ticket.json optio-tasks-empty.json github-pulls-empty.json)"
printf '503\n' >"$dir/optio-tasks.json.status"
run_dispatch "$dir" --apply
[[ "$RC" != "0" ]] || fail "reason=unexpected_rc case=api-error-tasks got=0"
expect_counter "$dir" errors 1 api-error-tasks
expect_posts "$dir" "/api/tasks" 0 api-error-tasks
cases=$((cases + 1))

# --- 13 bis. le script de sélection est introuvable : l'erreur est comptée ------

# Le script de sélection est téléchargé depuis main quand le fichier demandé est
# absent. Le téléchargement échoue ici (aucune route ne sert l'URL de main) :
# l'erreur d'API est rapportée une fois, avec sa cause, et elle est comptée
# dans le compte rendu. Une erreur ne passe jamais en silence.

dir="$(setup_case selection-download-error linear-one-ticket.json optio-tasks-empty.json github-pulls-empty.json)"
run_dispatch "$dir" --apply --select-actions "$dir/absent-select-actions.sh"
[[ "$RC" != "0" ]] || fail "reason=unexpected_rc case=selection-download-error got=0"
expect_counter "$dir" errors 1 selection-download-error
expect_posts "$dir" "/api/tasks" 0 selection-download-error
api_errors="$(grep -c 'API error (' "$dir/err" || true)"
[[ "$api_errors" == "1" ]] ||
  fail "reason=unexpected_api_error_count case=selection-download-error want=1 got=$api_errors err=$(tr '\n' ' ' <"$dir/err")"
cases=$((cases + 1))

# --- 13 ter. le script de sélection demandé est utilisé ------------------------

dir="$(setup_case selection-file linear-one-ticket.json optio-tasks-empty.json github-pulls-empty.json)"
run_dispatch "$dir" --apply --select-actions "$repo_root/scripts/optio/select-actions.sh"
expect_rc "$dir" 0 selection-file
expect_counter "$dir" created 1 selection-file
expect_counter "$dir" errors 0 selection-file
# Le fichier demandé est utilisé tel quel : rien n'est téléchargé.
if grep -Fq "raw.githubusercontent.com" "$dir/calls.log"; then
  fail "reason=unexpected_download case=selection-file calls=$(tr '\n' ' ' <"$dir/calls.log")"
fi
cases=$((cases + 1))

# --- 14. secret : jamais dans la sortie ni dans la ligne de commande ------------

dir="$(setup_case secrets linear-one-ticket.json optio-tasks-empty.json github-pulls-empty.json)"
run_dispatch "$dir" --apply
expect_rc "$dir" 0 secrets
for secret in fake-linear-key fake-optio-token fake-workspace; do
  if grep -Fq "$secret" "$dir/out" "$dir/err"; then
    fail "reason=secret_in_output case=secrets secret=$secret"
  fi
  if grep -Fq "$secret" "$dir/argv.log"; then
    fail "reason=secret_in_argv case=secrets secret=$secret"
  fi
done
# Les secrets sont dans les en-têtes, jamais dans la ligne de commande.
linear_hash="$(printf '%s' "fake-linear-key" | sha256sum | cut -d' ' -f1)"
optio_hash="$(printf '%s' "Bearer fake-optio-token" | sha256sum | cut -d' ' -f1)"
workspace_hash="$(printf '%s' "fake-workspace" | sha256sum | cut -d' ' -f1)"
grep -Fq "Authorization	$linear_hash" "$dir/headers.log" ||
  fail "reason=missing_linear_header case=secrets headers=$(cat "$dir/headers.log")"
grep -Fq "Authorization	$optio_hash" "$dir/headers.log" ||
  fail "reason=missing_optio_header case=secrets headers=$(cat "$dir/headers.log")"
grep -Fq "x-workspace-id	$workspace_hash" "$dir/headers.log" ||
  fail "reason=missing_workspace_header case=secrets headers=$(cat "$dir/headers.log")"
cases=$((cases + 1))

# --- 15. un seul passage à la fois --------------------------------------------

if command -v flock >/dev/null; then
  dir="$(setup_case lock linear-empty.json optio-tasks-empty.json github-pulls-empty.json)"
  exec 8>"$dir/dispatch.lock"
  flock -n 8 || fail "reason=cannot_hold_lock case=lock"
  run_dispatch "$dir"
  expect_rc "$dir" 3 lock
  exec 8>&-
  cases=$((cases + 1))
fi

# --- 16. usage ----------------------------------------------------------------

dir="$(setup_case usage linear-empty.json optio-tasks-empty.json github-pulls-empty.json)"
RC=0
bash "$script" --help >/dev/null 2>&1 || RC=$?
[[ "$RC" == "0" ]] || fail "reason=unexpected_rc case=help got=$RC"
RC=0
bash "$script" --unknown-flag >/dev/null 2>&1 || RC=$?
[[ "$RC" == "2" ]] || fail "reason=unexpected_rc case=unknown-flag got=$RC"
RC=0
env -u LINEAR_INTAKE_KEY -u LINEAR_API_KEY PATH="$dir/bin:$PATH" \
  OPTIO_DISPATCH_FAKE_DIR="$dir" OPTIO_API_TOKEN="fake-optio-token" \
  bash "$script" --instructions "$intake" >/dev/null 2>&1 || RC=$?
[[ "$RC" == "2" ]] || fail "reason=unexpected_rc case=missing-linear-key got=$RC"
cases=$((cases + 1))

# --- 17. jq 1.6 : la même décision --------------------------------------------

dir="$(setup_case jq16 linear-one-ticket.json optio-tasks-empty.json github-pulls-empty.json)"
RC=0
PATH="$jq16_bin:$dir/bin:$PATH" \
  OPTIO_DISPATCH_FAKE_DIR="$dir" \
  OPTIO_DISPATCH_LOCK_FILE="$dir/dispatch.lock" \
  LINEAR_INTAKE_KEY="fake-linear-key" \
  OPTIO_API_TOKEN="fake-optio-token" \
  OPTIO_API_URL="http://optio-api.test:4000" \
  OPTIO_WORKSPACE_ID="fake-workspace" \
  bash "$script" --instructions "$intake" --apply >"$dir/out" 2>"$dir/err" || RC=$?
[[ "$RC" == "0" ]] || fail "reason=unexpected_rc case=jq16 got=$RC err=$(tr '\n' ' ' <"$dir/err")"
expect_counter "$dir" created 1 jq16
expect_counter "$dir" tickets_read 1 jq16
cases=$((cases + 1))

# --- 18. le script n'écrit pas dans le dépôt ----------------------------------

snapshot_after="$(repo_snapshot)"

# L'état du dépôt est comparé avant et après : un test qui laisserait une
# trace (fichier créé, contenu modifié) est en échec.
if [[ "$snapshot_after" != "$snapshot_before" ]]; then
  fail "reason=repository_modified_by_test"
fi
cases=$((cases + 1))

if command -v shellcheck >/dev/null; then
  shellcheck -s bash "$script" "$test_file" || fail "reason=shellcheck_failed"
fi

echo "OPTIO_DISPATCH=PASS cases=$cases"
