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
# ligne de commande ; un seul passage à la fois ; jq 1.6. PLT-542 : places,
# plusieurs dépôts, PR d'un autre dépôt, reprises après la limite du forfait.
#
# Lecture seule, aucun accès cluster, aucun appel réseau. Autonome : mktemp,
# aucune écriture dans le dépôt.
# Les programmes jq sont entre apostrophes : leurs $variables sont à jq.
# shellcheck disable=SC2016
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
          # Comme curl : un fichier d'en-têtes illisible fait échouer l'appel.
          if [ ! -r "$hfile" ]; then
            echo "curl: option -H: error encountered when reading a file" >&2
            exit 26
          fi
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

# Les requêtes Linear partagent une URL : le nom de l'opération les distingue.
case "$body_content" in
  *OptioFollowUp*) response="linear-followup.json" ;;
  *OptioNote* | *OptioDone*) response="linear-write.json" ;;
esac

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
  cp "$fixture_dir/optio-repos.json" "$dir/optio-repos.json"
  cp "$fixture_dir/optio-events-empty.json" "$dir/optio-events.json"
  : >"$dir/calls.log"
  : >"$dir/argv.log"
  : >"$dir/headers.log"
  cp "$intake" "$dir/intake.md"
  # Aucune PR dans la liste d'Optio : le dépôt principal est relu sur GitHub.
  printf '{"pullRequests":[]}\n' >"$dir/optio-prs.json"
  printf '{"data":{"issues":{"nodes":[]}}}\n' >"$dir/linear-followup.json"
  # Les routes sont ordonnées : /retry et /cancel avant /api/tasks.
  {
    printf '%s\n' 'POST https://api.linear.app/graphql linear.json'
    printf '%s\n' 'GET https://api.github.com/repos/smadjapaul/kube-ops/pulls github-pulls.json'
    printf '%s\n' 'GET /main/docs/operations/optio-intake.md intake.md'
    printf '%s\n' 'GET /api/pull-requests optio-prs.json'
    printf '%s\n' 'POST /retry optio-retry.json'
    printf '%s\n' 'POST /cancel optio-cancel.json'
    printf '%s\n' 'GET /events optio-events.json'
    printf '%s\n' 'GET /api/repos optio-repos.json'
    printf 'GET /api/tasks?limit=1000 optio-tasks.json %s\n' "$next_tasks"
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
  jq -e 'keys == ["cancelled", "closed", "created", "errors", "fixes", "notices", "resumed", "retried", "reviews", "skipped", "tickets_read"]' \
    <<<"$(summary_of "$dir")" >/dev/null ||
    fail "reason=unexpected_summary_keys case=$name summary=$(summary_of "$dir")"
  jq -e 'has("tasks") and has("reviews") and has("fixes") and has("retries") and has("resumes") and has("closures") and has("notices") and has("cancellations") and has("skipped")' \
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
# La PR fermée ne parvient pas au sélecteur : ni action, ni écart.
expect_counter "$dir" skipped 0 pr-closed
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

# --- 6 quinquies. des PR fermées ne bloquent pas la revue d'une PR ouverte ----

dir="$(setup_case review-cap linear-empty.json optio-tasks-review-cap.json github-pulls-new-head.json)"
run_dispatch "$dir" --apply
expect_rc "$dir" 0 review-cap
expect_counter "$dir" reviews 1 review-cap
expect_counter "$dir" skipped 0 review-cap
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
# La tête est connue du sélecteur : la revue existante ne prend aucune place.
expect_counter "$dir" skipped 0 same-head
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

# --- 18. PLT-542 : plusieurs dépôts et places ---------------------------------

# Travaux fabriqués pour un cas : write_tasks <dossier> <programme jq>.
KUBE="https://github.com/smadjapaul/kube-ops"
HARNESS="https://github.com/smadjapaul/agent-harness"
write_tasks() {
  jq -n --arg kube "$KUBE" --arg harness "$HARNESS" '
    def task($id; $title; $state): {id: $id, title: $title, state: $state, repoUrl: $kube,
      prUrl: "", prNumber: null, prChecksStatus: "", retryCount: 0};
    def with_pr($n): . + {prNumber: $n, prUrl: (.repoUrl + "/pull/" + ($n | tostring)),
      prChecksStatus: "passing"};
    '"$2" >"$1/optio-tasks.json"
}

# Un ticket du dépôt demandé, à la place du ticket kube-ops de la fixture.
set_repo() {
  jq --arg repo "$2" '.data.issues.nodes[0].description |= gsub("Dépôt: kube-ops"; "Dépôt: " + $repo)' \
    "$1/linear.json" >"$1/linear.tmp"
  mv "$1/linear.tmp" "$1/linear.json"
  grep -Fq "Dépôt: $2" "$1/linear.json" || fail "reason=fixture_without_repo_line case=$1"
}

# Dix PR en attente ne prennent aucune place : la revue passe, puis le ticket.
dir="$(setup_case waiting-prs linear-one-ticket.json optio-tasks-empty.json github-pulls-new-head.json)"
write_tasks "$dir" '[range(1; 11) as $i | task("w\($i)"; "[PLT-\(800 + $i)] travail"; "pr_opened") | with_pr(100 + $i)]
  + [task("w42"; "[PLT-842] travail"; "pr_opened") | with_pr(42)]'
run_dispatch "$dir" --apply
expect_rc "$dir" 0 waiting-prs
expect_counter "$dir" reviews 1 waiting-prs
expect_counter "$dir" created 1 waiting-prs
jq -e '.title | startswith("[REVUE PR-42 ")' <<<"$(body_of "$dir" "/api/tasks" 1)" >/dev/null ||
  fail "reason=review_not_first case=waiting-prs"
cases=$((cases + 1))

# Une seule place libre (quatre agents en cours) : la revue, pas le ticket.
dir="$(setup_case one-place linear-one-ticket.json optio-tasks-empty.json github-pulls-new-head.json)"
write_tasks "$dir" '[range(1; 5) as $i | task("r\($i)"; "[PLT-\(800 + $i)] travail"; "running")]
  + [task("w42"; "[PLT-842] travail"; "pr_opened") | with_pr(42)]'
run_dispatch "$dir" --apply
expect_rc "$dir" 0 one-place
expect_counter "$dir" reviews 1 one-place
expect_counter "$dir" created 0 one-place
cases=$((cases + 1))

# Un ticket d'un autre dépôt : son URL et la consigne de merge.
dir="$(setup_case other-repo linear-one-ticket.json optio-tasks-empty.json github-pulls-empty.json)"
set_repo "$dir" agent-harness
run_dispatch "$dir" --apply
expect_rc "$dir" 0 other-repo
expect_counter "$dir" created 1 other-repo
body="$(body_of "$dir" "/api/tasks")"
jq -e --arg repo "$HARNESS" '.repoUrl == $repo' <<<"$body" >/dev/null ||
  fail "reason=unexpected_repo_url case=other-repo body=$body"
for expected in "Livre une seule PR dans le dépôt agent-harness" "(PLT-900)" "gh pr merge --squash" \
  "Fixes PLT-900" "homelab-infra et ha-config" ".github/"; do
  grep -Fq -- "$expected" <<<"$body" || fail "reason=missing_merge_consigne case=other-repo text=$expected"
done
grep -Fq "Ne merge pas." <<<"$body" && fail "reason=kube_ops_consigne case=other-repo"
cases=$((cases + 1))

# Le ticket kube-ops garde sa consigne, sans merge.
dir="$(setup_case kube-consigne linear-one-ticket.json optio-tasks-empty.json github-pulls-empty.json)"
run_dispatch "$dir" --apply
body="$(body_of "$dir" "/api/tasks")"
jq -e --arg repo "$KUBE" '.repoUrl == $repo' <<<"$body" >/dev/null ||
  fail "reason=unexpected_repo_url case=kube-consigne body=$body"
grep -Fq "Ne merge pas." <<<"$body" || fail "reason=missing_no_merge case=kube-consigne"
grep -Fq "gh pr merge --squash" <<<"$body" && fail "reason=merge_consigne case=kube-consigne"
cases=$((cases + 1))

# Dépôt absent d'Optio : écart, aucune création.
dir="$(setup_case unconfigured linear-one-ticket.json optio-tasks-empty.json github-pulls-empty.json)"
set_repo "$dir" website
run_dispatch "$dir" --apply
expect_rc "$dir" 0 unconfigured
expect_posts "$dir" "/api/tasks" 0 unconfigured
jq -e '.skipped[0].reason == "dépôt non configuré dans Optio : website"' <<<"$(actions_of "$dir")" >/dev/null ||
  fail "reason=unexpected_skip_reason case=unconfigured actions=$(actions_of "$dir")"
cases=$((cases + 1))

# Liste des dépôts illisible : aucun ticket, la revue continue, erreur comptée.
dir="$(setup_case repos-error linear-one-ticket.json optio-tasks-empty.json github-pulls-new-head.json)"
write_tasks "$dir" '[task("w42"; "[PLT-842] travail"; "pr_opened") | with_pr(42)]'
printf '500\n' >"$dir/optio-repos.json.status"
run_dispatch "$dir" --apply
expect_rc "$dir" 1 repos-error
expect_counter "$dir" errors 1 repos-error
expect_counter "$dir" created 0 repos-error
expect_counter "$dir" reviews 1 repos-error
cases=$((cases + 1))

# Les PR d'un autre dépôt : ni revue, ni correction, ni annulation, même quand
# le numéro existe (ou n'existe pas) dans kube-ops.
dir="$(setup_case foreign-pr linear-empty.json optio-tasks-empty.json github-pulls-new-head.json)"
write_tasks "$dir" '[
  (task("f1"; "[PLT-851] site"; "pr_opened") + {repoUrl: $harness} | with_pr(42)),
  (task("f2"; "[PLT-852] site"; "pr_opened") + {repoUrl: $harness} | with_pr(77) | .prChecksStatus = "failing"),
  (task("f3"; "[PLT-853] site"; "needs_attention") + {repoUrl: $harness} | with_pr(78)),
  (task("f4"; "[REVUE PR-79]"; "running") + {repoUrl: $harness}),
  (task("f5"; "[CORRIGE PR-80 1]"; "needs_attention")
   + {repoUrl: $harness, errorMessage: "Agent did not open a pull request"})]'
run_dispatch "$dir" --apply
expect_rc "$dir" 0 foreign-pr
expect_posts "$dir" "/api/tasks" 0 foreign-pr
expect_posts "$dir" "/cancel" 0 foreign-pr
expect_posts "$dir" "/retry" 0 foreign-pr
cases=$((cases + 1))

# Revue arrêtée par la limite du forfait : reprise, sous plafond et après délai.
failed_review='[task("w42"; "[PLT-842] travail"; "pr_opened") | with_pr(42),
  task("rv"; "[REVUE PR-42 bbbb2222]"; "failed")
  + {errorMessage: "API Error: 429 usage limit exceeded", completedAt: "2026-01-01T00:00:00.000Z"}]'

history() {
  jq -n --argjson n "$2" '{events: [range(0; $n) | {trigger: "user_retry"}]}' >"$1/optio-events.json"
}

dir="$(setup_case review-limit linear-empty.json optio-tasks-empty.json github-pulls-new-head.json)"
write_tasks "$dir" "$failed_review"
history "$dir" 5
run_dispatch "$dir" --apply
expect_rc "$dir" 0 review-limit
expect_counter "$dir" retried 1 review-limit
expect_counter "$dir" reviews 0 review-limit
grep -q "/api/tasks/rv/retry" "$dir/calls.log" || fail "reason=missing_retry case=review-limit"
cases=$((cases + 1))

dir="$(setup_case review-limit-ceiling linear-empty.json optio-tasks-empty.json github-pulls-new-head.json)"
write_tasks "$dir" "$failed_review"
history "$dir" 6
run_dispatch "$dir" --apply
expect_counter "$dir" retried 0 review-limit-ceiling
jq -e '.skipped[0].reason | test("plafond")' <<<"$(actions_of "$dir")" >/dev/null ||
  fail "reason=unexpected_skip_reason case=review-limit-ceiling actions=$(actions_of "$dir")"
cases=$((cases + 1))

dir="$(setup_case review-limit-wait linear-empty.json optio-tasks-empty.json github-pulls-new-head.json)"
write_tasks "$dir" "$failed_review | .[1].completedAt = (now | floor | todate)"
run_dispatch "$dir" --apply
expect_counter "$dir" retried 0 review-limit-wait
jq -e '.skipped[0].reason | test("reprise en attente")' <<<"$(actions_of "$dir")" >/dev/null ||
  fail "reason=unexpected_skip_reason case=review-limit-wait actions=$(actions_of "$dir")"
cases=$((cases + 1))

# Un autre échec de revue, ou une ancienne tête : pas de reprise.
dir="$(setup_case review-other-error linear-empty.json optio-tasks-empty.json github-pulls-new-head.json)"
write_tasks "$dir" "$failed_review | .[1].errorMessage = \"Exit code: 1\""
run_dispatch "$dir" --apply
expect_posts "$dir" "/retry" 0 review-other-error
cases=$((cases + 1))

dir="$(setup_case review-old-sha linear-empty.json optio-tasks-empty.json github-pulls-old-head.json)"
write_tasks "$dir" "$failed_review"
run_dispatch "$dir" --apply
expect_posts "$dir" "/retry" 0 review-old-sha
expect_counter "$dir" reviews 1 review-old-sha
cases=$((cases + 1))

# retryCount reste à 0 dans Optio : le plafond vient de l'historique.
dir="$(setup_case ticket-history-ceiling linear-empty.json optio-tasks-failed.json github-pulls-empty.json)"
history "$dir" 2
run_dispatch "$dir" --apply
expect_posts "$dir" "/retry" 0 ticket-history-ceiling
jq -e '.skipped[0].reason | test("plafond")' <<<"$(actions_of "$dir")" >/dev/null ||
  fail "reason=unexpected_skip_reason case=ticket-history-ceiling actions=$(actions_of "$dir")"
cases=$((cases + 1))

dir="$(setup_case history-error linear-empty.json optio-tasks-failed.json github-pulls-empty.json)"
printf '500\n' >"$dir/optio-events.json.status"
run_dispatch "$dir" --apply
expect_rc "$dir" 1 history-error
expect_posts "$dir" "/retry" 0 history-error
cases=$((cases + 1))

# Les reprises prennent des places : revue d'abord, ni ticket repris ni nouveau.
dir="$(setup_case retry-places linear-one-ticket.json optio-tasks-empty.json github-pulls-new-head.json)"
write_tasks "$dir" "$failed_review + [task(\"tk\"; \"[PLT-860] échec\"; \"failed\")]"
run_dispatch "$dir" --apply --slots 1
expect_rc "$dir" 0 retry-places
expect_counter "$dir" retried 1 retry-places
expect_counter "$dir" created 0 retry-places
grep -q "/api/tasks/rv/retry" "$dir/calls.log" || fail "reason=missing_retry case=retry-places"
run_dispatch "$dir" --apply --slots 2
expect_counter "$dir" retried 2 retry-places-two
expect_counter "$dir" created 0 retry-places-two
cases=$((cases + 1))

# jq 1.6 : reprises et autre dépôt, même décision.
dir="$(setup_case jq16-multi linear-one-ticket.json optio-tasks-empty.json github-pulls-new-head.json)"
set_repo "$dir" agent-harness
write_tasks "$dir" "$failed_review"
cp "$jq16_bin/jq" "$dir/bin/jq"
run_dispatch "$dir" --apply
expect_rc "$dir" 0 jq16-multi
expect_counter "$dir" retried 1 jq16-multi
expect_counter "$dir" created 1 jq16-multi
cases=$((cases + 1))

# --- 19. PLT-560 : reprises de PR, clôtures, pannes de pod, appels GitHub -----

# add_route <dossier> <fragment> <fichier> : la route passe devant les autres.
add_route() {
  printf 'GET %s %s\n' "$2" "$3" | cat - "$1/routes.tsv" >"$1/routes.tmp"
  mv "$1/routes.tmp" "$1/routes.tsv"
}

# open_pr <dossier> <numéro> <titre> <brouillon> : une PR ouverte d'agent-harness.
open_pr() {
  jq --arg repo "$HARNESS" --argjson n "$2" --arg title "$3" --argjson draft "$4" \
    '.pullRequests += [{number: $n, title: $title, draft: $draft,
       url: ("https://github.com/SmadjaPaul/agent-harness/pull/" + ($n | tostring)),
       headSha: "cccc3333dddd", createdAt: "2026-01-01T01:10:00Z",
       repo: {repoUrl: $repo}}]' "$1/optio-prs.json" >"$1/optio-prs.tmp"
  mv "$1/optio-prs.tmp" "$1/optio-prs.json"
}

# status_of <dossier> <numéro> <état> <checks> [mergeable]
status_of() {
  jq -n --arg state "$3" --arg checks "$4" --argjson mergeable "${5:-true}" \
    '{prState: $state, checksStatus: $checks, mergeable: $mergeable, headSha: "cccc3333dddd"}' \
    >"$1/status-$2.json"
  add_route "$1" "agent-harness%2Fpull%2F$2" "status-$2.json"
}

# harness_tasks <dossier> <programme jq> : travaux d'agent-harness.
harness_tasks() {
  write_tasks "$1" 'def h($id; $title; $state): task($id; $title; $state)
    + {repoUrl: $harness, createdAt: "2026-01-01T01:00:00.000Z",
       completedAt: "2026-01-01T01:30:00.000Z"};
    def own($n): . + {prNumber: $n,
      prUrl: ("https://github.com/SmadjaPaul/agent-harness/pull/" + ($n | tostring))};
    def nopr: . + {errorMessage: "Agent completed successfully but did not open a pull request."};
    '"$2"
}

# followup <dossier> <état du ticket> <linkKind|none> [commentaire] [numéro de PR]
followup() {
  jq -n --arg state "$2" --arg kind "$3" --arg comment "${4:-}" --argjson n "${5:-99}" '
    {data: {issues: {nodes: [{id: "uuid-552", identifier: "PLT-552", state: {type: $state},
      team: {states: {nodes: [{id: "st-review", name: "In Review", type: "started"},
        {id: "st-done", name: "Done", type: "completed"}]}},
      attachments: {nodes: [{url: ("https://github.com/SmadjaPaul/agent-harness/pull/" + ($n | tostring)),
        title: "feat: travail (PLT-552)", createdAt: "2026-01-01T01:10:00.000Z",
        metadata: (if $kind == "none" then {} else {linkKind: $kind} end)}]},
      comments: {nodes: (if $comment == "" then [] else [{body: $comment}] end)}}]}}}' \
    >"$1/linear-followup.json"
  printf '{"data":{"commentCreate":{"success":true},"issueUpdate":{"success":true}}}\n' \
    >"$1/linear-write.json"
}

count_bodies() {
  { grep -l -- "$2" "$1"/body.[0-9]* 2>/dev/null || true; } | wc -l | tr -d ' '
}

expect_writes() {
  local dir=$1 notes=$2 dones=$3 name=$4
  [[ "$(count_bodies "$dir" 'mutation OptioNote')" == "$notes" ]] ||
    fail "reason=unexpected_comments case=$name want=$notes"
  [[ "$(count_bodies "$dir" 'mutation OptioDone')" == "$dones" ]] ||
    fail "reason=unexpected_done case=$name want=$dones"
}

new_case() {
  setup_case "$1" linear-empty.json optio-tasks-empty.json github-pulls-empty.json
}

pr98='[h("o1"; "[PLT-552] travail"; "pr_opened") | own(98)]'

# PR verte restée ouverte : une tâche de reprise, dans le dépôt de la PR.
dir="$(new_case resume)"
harness_tasks "$dir" "$pr98"
open_pr "$dir" 98 "feat: travail (PLT-552)" false
status_of "$dir" 98 open passing
run_dispatch "$dir"
expect_rc "$dir" 0 resume-dry
expect_posts "$dir" "/api/tasks" 0 resume-dry
jq -e '.resumes[0].name == "[REPRISE agent-harness#98 cccc3333 1]"' <<<"$(actions_of "$dir")" >/dev/null ||
  fail "reason=missing_planned_resume actions=$(actions_of "$dir")"
run_dispatch "$dir" --apply
expect_rc "$dir" 0 resume
expect_output_shape "$dir" resume
expect_counter "$dir" resumed 1 resume
expect_posts "$dir" "/api/tasks" 1 resume
body="$(body_of "$dir" "/api/tasks")"
jq -e --arg repo "$HARNESS" '.repoUrl == $repo' <<<"$body" >/dev/null ||
  fail "reason=unexpected_resume_repo body=$body"
grep -Fq "la PR #98 du dépôt agent-harness (ticket PLT-552)" <<<"$body" ||
  fail "reason=missing_resume_consigne body=$body"
grep -Fq "gh pr merge 98 --squash" <<<"$body" || fail "reason=missing_resume_merge body=$body"
grep -Fq "gh pr view 98 --json" <<<"$body" || fail "reason=missing_resume_view body=$body"
for kept in "N'utilise jamais --admin" "N'ouvre aucune autre PR"; do
  grep -Fq "$kept" <<<"$body" || fail "reason=mangled_resume_consigne text=$kept"
done
grep -Eq 'IDENTIFIANT|REPO|PR #N' <<<"$body" && fail "reason=unreplaced_placeholder case=resume"
run_dispatch "$dir" --apply
expect_counter "$dir" resumed 0 resume-active
expect_posts "$dir" "/api/tasks" 1 resume-active
cases=$((cases + 1))

# Checks en échec ou conflit : reprise. Checks en attente ou brouillon : rien.
for variant in "failing true 1" "pending false 1" "pending true 0"; do
  read -r checks mergeable want <<<"$variant"
  dir="$(new_case "resume-$checks-$mergeable")"
  harness_tasks "$dir" "$pr98"
  open_pr "$dir" 98 "feat: travail (PLT-552)" false
  status_of "$dir" 98 open "$checks" "$mergeable"
  run_dispatch "$dir" --apply
  expect_counter "$dir" resumed "$want" "resume-$checks-$mergeable"
done
dir="$(new_case resume-draft)"
harness_tasks "$dir" "$pr98"
open_pr "$dir" 98 "feat: travail (PLT-552)" true
run_dispatch "$dir" --apply
expect_counter "$dir" resumed 0 resume-draft
dir="$(new_case resume-ticket-running)"
harness_tasks "$dir" "$pr98 + [h(\"o2\"; \"[PLT-552] travail\"; \"running\")]"
open_pr "$dir" 98 "feat: travail (PLT-552)" false
run_dispatch "$dir" --apply
expect_counter "$dir" resumed 0 resume-ticket-running
dir="$(new_case resume-no-place)"
harness_tasks "$dir" "$pr98"
open_pr "$dir" 98 "feat: travail (PLT-552)" false
status_of "$dir" 98 open passing
run_dispatch "$dir" --apply --slots 0
expect_counter "$dir" resumed 0 resume-no-place
cases=$((cases + 1))

# Une reprise terminée sur la même tête : PR laissée ouverte, signalée une fois.
tried="$pr98 + [h(\"p1\"; \"[REPRISE agent-harness#98 cccc3333 1]\"; \"cancelled\")]"
dir="$(new_case resume-same-head)"
harness_tasks "$dir" "$tried"
open_pr "$dir" 98 "feat: travail (PLT-552)" false
followup "$dir" started closes
run_dispatch "$dir" --apply
expect_rc "$dir" 0 resume-same-head
expect_counter "$dir" resumed 0 resume-same-head
expect_counter "$dir" notices 1 resume-same-head
expect_writes "$dir" 1 0 resume-same-head
dir="$(new_case resume-noticed)"
harness_tasks "$dir" "$tried"
open_pr "$dir" 98 "feat: travail (PLT-552)" false
followup "$dir" started closes "optio-dispatch, blocage agent-harness#98 cccc3333 : déjà dit"
run_dispatch "$dir" --apply
expect_counter "$dir" notices 0 resume-noticed
expect_writes "$dir" 0 0 resume-noticed
cases=$((cases + 1))

# Nouvelle tête : deuxième reprise ; trois reprises : plafond.
dir="$(new_case resume-new-head)"
harness_tasks "$dir" "$pr98 + [h(\"p1\"; \"[REPRISE agent-harness#98 aaaa1111 1]\"; \"cancelled\")]"
open_pr "$dir" 98 "feat: travail (PLT-552)" false
status_of "$dir" 98 open passing
run_dispatch "$dir" --apply
jq -e '.resumes[0].name == "[REPRISE agent-harness#98 cccc3333 2]"' <<<"$(actions_of "$dir")" >/dev/null ||
  fail "reason=missing_second_resume actions=$(actions_of "$dir")"
dir="$(new_case resume-ceiling)"
harness_tasks "$dir" "$pr98 + [range(1; 4) as \$k
  | h(\"p\\(\$k)\"; \"[REPRISE agent-harness#98 aaaa111\\(\$k) \\(\$k)]\"; \"cancelled\")]"
open_pr "$dir" 98 "feat: travail (PLT-552)" false
followup "$dir" started closes
run_dispatch "$dir" --apply
expect_counter "$dir" resumed 0 resume-ceiling
expect_counter "$dir" notices 1 resume-ceiling
jq -e 'any(.skipped[]; .reason | test("plafond"))' <<<"$(actions_of "$dir")" >/dev/null ||
  fail "reason=missing_resume_ceiling actions=$(actions_of "$dir")"
# Reprise terminée sans PR : elle quitte la file des interventions.
dir="$(new_case resume-done)"
harness_tasks "$dir" '[h("p1"; "[REPRISE agent-harness#98 cccc3333 1]"; "needs_attention") | nopr]'
run_dispatch "$dir" --apply
expect_counter "$dir" cancelled 1 resume-done
cases=$((cases + 1))

# PR non enregistrée par la tâche : reconnue par le ticket et la date.
for variant in "inside 2026-01-01T01:30:00.000Z 1" "outside 2026-01-01T00:00:00.000Z 0"; do
  read -r label end want <<<"$variant"
  dir="$(new_case "resume-title-$label")"
  harness_tasks "$dir" "[h(\"o1\"; \"[PLT-552] travail\"; \"needs_attention\") | nopr
    | .createdAt = \"2026-01-01T00:00:00.000Z\" | .completedAt = \"$end\"]"
  open_pr "$dir" 98 "[PLT-552] travail" false
  status_of "$dir" 98 open passing
  run_dispatch "$dir" --apply
  expect_counter "$dir" resumed "$want" "resume-title-$label"
done
cases=$((cases + 1))

# Consigne REPRISE absente : aucune reprise, erreur comptée.
dir="$(new_case resume-no-consigne)"
harness_tasks "$dir" "$pr98"
open_pr "$dir" 98 "feat: travail (PLT-552)" false
status_of "$dir" 98 open passing
sed 's/^Consigne REPRISE :$/Consigne ABSENTE :/' "$intake" >"$dir/intake-old.md"
run_dispatch "$dir" --apply --instructions "$dir/intake-old.md"
expect_rc "$dir" 1 resume-no-consigne
expect_posts "$dir" "/api/tasks" 0 resume-no-consigne
cases=$((cases + 1))

# PR mergée, aucune PR détectée : preuve, Done, puis annulation.
merged_task='[h("m1"; "[PLT-552] travail"; "needs_attention") | nopr]'
merged_case() {
  local d
  d="$(new_case "$1")"
  harness_tasks "$d" "$merged_task"
  followup "$d" "$2" "$3"
  status_of "$d" 99 "${4:-merged}" passing
  printf '%s' "$d"
}
dir="$(merged_case closure started closes)"
run_dispatch "$dir"
expect_writes "$dir" 0 0 closure-dry
expect_posts "$dir" "/cancel" 0 closure-dry
jq -e '.closures[0].done == true' <<<"$(actions_of "$dir")" >/dev/null ||
  fail "reason=missing_planned_closure actions=$(actions_of "$dir") err=$(tr '\n' ' ' <"$dir/err")"
run_dispatch "$dir" --apply
expect_rc "$dir" 0 closure
expect_counter "$dir" closed 1 closure
expect_writes "$dir" 1 1 closure
expect_posts "$dir" "/cancel" 1 closure
grep -l 'mutation OptioDone' "$dir"/body.[0-9]* | xargs grep -Fq '"stateId": "st-done"' ||
  fail "reason=unexpected_done_state case=closure"
grep -l 'mutation OptioNote' "$dir"/body.[0-9]* | xargs grep -Fq 'agent-harness/pull/99 est mergée' ||
  fail "reason=missing_proof case=closure"
# Les écritures Linear précèdent l'annulation.
[[ "$(grep -nE '/m1/cancel' "$dir/calls.log" | cut -d: -f1)" -gt \
  "$(grep -n 'api.linear.app' "$dir/calls.log" | tail -n 1 | cut -d: -f1)" ]] ||
  fail "reason=cancel_before_linear case=closure"
cases=$((cases + 1))

dir="$(merged_case closure-part-of started contributes)"
run_dispatch "$dir" --apply
expect_writes "$dir" 1 0 closure-part-of
expect_posts "$dir" "/cancel" 1 closure-part-of
# Sans lien connu, dépôt privé : preuve seule ; ligne Fixes lisible : Done.
dir="$(merged_case closure-private started none)"
run_dispatch "$dir" --apply
expect_rc "$dir" 0 closure-private
expect_writes "$dir" 1 0 closure-private
for variant in "fixes Fixes 1" "partof Part%20of 0"; do
  read -r label line want <<<"$variant"
  dir="$(merged_case "closure-body-$label" started none)"
  jq -n --arg b "${line//%20/ } PLT-552" '{body: $b}' >"$dir/github-pr.json"
  add_route "$dir" "api.github.com/repos/SmadjaPaul/agent-harness/pulls/99" github-pr.json
  run_dispatch "$dir" --apply
  expect_writes "$dir" 1 "$want" "closure-body-$label"
done
dir="$(merged_case closure-finished completed closes)"
run_dispatch "$dir" --apply
expect_writes "$dir" 0 0 closure-finished
expect_posts "$dir" "/cancel" 1 closure-finished
cases=$((cases + 1))

# PR encore ouverte, PR antérieure à la tâche ou Linear en échec : la tâche reste.
dir="$(merged_case closure-open started closes open)"
run_dispatch "$dir" --apply
expect_writes "$dir" 0 0 closure-open
expect_posts "$dir" "/cancel" 0 closure-open
dir="$(merged_case closure-old started closes)"
harness_tasks "$dir" "$merged_task | .[0].createdAt = \"2026-02-01T00:00:00.000Z\""
run_dispatch "$dir" --apply
expect_posts "$dir" "/cancel" 0 closure-old
dir="$(merged_case closure-write-error started closes)"
printf '{"errors":[{"message":"no"}]}\n' >"$dir/linear-write.json"
run_dispatch "$dir" --apply
expect_rc "$dir" 1 closure-write-error
expect_counter "$dir" closed 0 closure-write-error
expect_posts "$dir" "/cancel" 0 closure-write-error
dir="$(merged_case closure-read-error started closes)"
set_repo_ticket="$(cat "$fixture_dir/linear-one-ticket.json")"
printf '%s\n' "$set_repo_ticket" >"$dir/linear.json"
printf '{"errors":[{"message":"no"}]}\n' >"$dir/linear-followup.json"
run_dispatch "$dir" --apply
expect_rc "$dir" 1 closure-read-error
expect_counter "$dir" created 1 closure-read-error
expect_posts "$dir" "/cancel" 0 closure-read-error
cases=$((cases + 1))

# Panne de pod : reprise différée, plafonnée, signalée au plafond.
pod='[h("k1"; "[PLT-552] travail"; "failed") + {errorMessage: "Pod needs recovery; its persistent workspace is retained"}]'
for variant in "old 0 1 0" "recent 0 0 0" "wait-timeout 5 1 0" "ceiling 6 0 1"; do
  read -r label events want noted <<<"$variant"
  dir="$(new_case "pod-$label")"
  harness_tasks "$dir" "$pod"
  case "$label" in
    recent) harness_tasks "$dir" "$pod | .[0].completedAt = (now - 600 | floor | todate)" ;;
    wait-timeout) harness_tasks "$dir" "$pod | .[0].errorMessage = \"Timed out waiting for pod abc\"" ;;
  esac
  history "$dir" "$events"
  followup "$dir" started closes
  run_dispatch "$dir" --apply
  expect_rc "$dir" 0 "pod-$label"
  expect_counter "$dir" retried "$want" "pod-$label"
  expect_counter "$dir" notices "$noted" "pod-$label"
done
# La revue de kube-ops arrêtée par une panne de pod est reprise elle aussi.
dir="$(setup_case pod-review linear-empty.json optio-tasks-empty.json github-pulls-new-head.json)"
write_tasks "$dir" "$failed_review | .[1].errorMessage = \"Timed out waiting for pod abc\""
run_dispatch "$dir" --apply
expect_counter "$dir" retried 1 pod-review
# Une tâche en échec avec une PR ouverte : la PR est reprise, pas la tâche.
dir="$(new_case pod-with-pr)"
harness_tasks "$dir" "$pod"
open_pr "$dir" 98 "[PLT-552] travail" false
status_of "$dir" 98 open passing
run_dispatch "$dir" --apply
expect_counter "$dir" retried 0 pod-with-pr
expect_counter "$dir" resumed 1 pod-with-pr
cases=$((cases + 1))

# La liste d'Optio fait foi pour kube-ops : aucun appel à l'API GitHub.
dir="$(setup_case optio-pulls linear-one-ticket.json optio-tasks-empty.json github-pulls-empty.json)"
write_tasks "$dir" '[task("w42"; "[PLT-842] travail"; "pr_opened") | with_pr(42)]'
jq -n --arg repo "$KUBE" '{pullRequests: [{number: 42, title: "t", draft: false,
  url: ($repo + "/pull/42"), headSha: "bbbb2222ffff", createdAt: "2026-01-01T00:00:00Z",
  repo: {repoUrl: $repo}}]}' >"$dir/optio-prs.json"
run_dispatch "$dir" --no-instructions --apply
expect_rc "$dir" 0 optio-pulls
expect_counter "$dir" reviews 1 optio-pulls
expect_counter "$dir" created 1 optio-pulls
grep -q "api.github.com" "$dir/calls.log" &&
  fail "reason=anonymous_github_call calls=$(tr '\n' ' ' <"$dir/calls.log")"
# Liste d'Optio illisible : repli sur GitHub, erreur comptée.
printf '500\n' >"$dir/optio-prs.json.status"
rm -f "$dir/state-tasks.json"
run_dispatch "$dir"
expect_rc "$dir" 1 optio-pulls-error
grep -q "api.github.com/repos/smadjapaul/kube-ops/pulls" "$dir/calls.log" ||
  fail "reason=missing_github_fallback"
cases=$((cases + 1))

# jq 1.6 : reprise et clôture, même décision.
dir="$(merged_case jq16-closure started closes)"
cp "$jq16_bin/jq" "$dir/bin/jq"
run_dispatch "$dir" --apply
expect_rc "$dir" 0 jq16-closure
expect_counter "$dir" closed 1 jq16-closure
cases=$((cases + 1))

# --- 20. le script n'écrit pas dans le dépôt ----------------------------------

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
