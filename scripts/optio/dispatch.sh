#!/usr/bin/env bash
# PLT-527 : orchestrateur Optio sans LLM.
#
# Pourquoi : la prise des tickets était faite par un modèle toutes les 10 min
# alors que toutes ses règles sont déterministes. Ce script les applique :
# il lit Linear (une seule requête filtrée), lit les travaux Optio, décide avec
# scripts/optio/select-actions.sh, relit l'état réel des PR sur GitHub et crée
# les tâches de ticket, de revue et de correction.
#
# PLT-542 : les tickets peuvent viser plusieurs dépôts configurés dans Optio.
# Les revues et corrections ne concernent que le dépôt principal (--repo-url).
# Seules les tâches qui consomment un agent prennent une place.
#
# PLT-560 : l'état des PR est lu par l'API Optio (GitHub anonyme en repli) ;
# une PR d'un autre dépôt restée ouverte après la tâche reçoit une tâche de
# REPRISE bornée ; une tâche sans PR détectée dont la PR est mergée est annulée
# et son ticket reçoit la preuve ; une panne de pod est reprise plus tard.
#
# Sans --apply, le script n'écrit rien (ni Optio, ni Linear) : il affiche
# seulement les actions prévues, en JSON. Avec --apply, il les exécute.
#
# Usage :
#   bash scripts/optio/dispatch.sh [--apply] [--slots N] [--instructions FILE]
#                                 [--select-actions FILE] [--api-url URL]
#                                 [--repo-url URL]
#
# Environnement :
#   LINEAR_INTAKE_KEY    clé Linear (LINEAR_API_KEY acceptée en repli) ;
#   OPTIO_API_TOKEN      jeton de l'API Optio (en-tête Authorization: Bearer) ;
#   OPTIO_API_URL        base de l'API Optio
#                        (défaut : http://optio-api.optio.svc.cluster.local:4000) ;
#   OPTIO_WORKSPACE_ID   espace de travail (en-tête x-workspace-id, facultatif) ;
#   OPTIO_DISPATCH_LOCK_FILE  fichier de verrou local (défaut : $TMPDIR/optio-dispatch.lock).
#
# Sortie : deux lignes JSON. La première décrit les actions (prévues en mode
# essai, effectuées en mode --apply), la dernière est le compte rendu :
# {"tickets_read":n,"created":n,"reviews":n,"fixes":n,"retried":n,"cancelled":n,
#  "skipped":n,"errors":n,"resumed":n,"closed":n,"notices":n}.
#
# Codes de retour : 0 succès, 1 erreur d'API, 2 usage ou configuration,
# 3 un passage est déjà en cours.
set -euo pipefail

readonly DEFAULT_API_URL="http://optio-api.optio.svc.cluster.local:4000"
readonly DEFAULT_REPO_URL="https://github.com/smadjapaul/kube-ops"
readonly LINEAR_GRAPHQL_URL="https://api.linear.app/graphql"
readonly GITHUB_REPO_API="https://api.github.com/repos/smadjapaul/kube-ops"
readonly GITHUB_RAW_BASE="https://raw.githubusercontent.com/smadjapaul/kube-ops/main"
readonly INSTRUCTIONS_PATH="docs/operations/optio-intake.md"
readonly SELECT_ACTIONS_PATH="scripts/optio/select-actions.sh"
readonly MAX_RETRIES=2
# Un échec dû à la limite du forfait (fenêtre de 5 heures) attend entre deux
# reprises et a un plafond plus haut : 6 reprises espacées d'une heure.
readonly MAX_LIMIT_RETRIES=6
readonly LIMIT_RETRY_DELAY=3600
readonly LIMIT_ERROR_PATTERN='usage limit|(^|[^0-9A-Za-z])429([^0-9A-Za-z]|$)'
# Une panne de pod (CPU saturé) ne se répare pas en quelques secondes : reprise
# différée, avec un plafond.
readonly MAX_INFRA_RETRIES=6
readonly INFRA_RETRY_DELAY=1800
readonly INFRA_ERROR_PATTERN='Timed out waiting for pod|Pod needs recovery|Pod is recovering'
# Tâches de REPRISE d'une PR d'un autre dépôt : 3 au plus par PR, une par tête.
readonly MAX_RESUMES=3
readonly NO_CHECKS_DELAY=900
readonly NO_PR_PATTERN='did not open a pull request'
readonly DEFAULT_SLOTS=5
readonly TASKS_LIMIT=1000
readonly PER_PAGE=100
readonly MAX_PAGES=5

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

apply_mode=false
slots=$DEFAULT_SLOTS
instructions_file=""
select_actions_file=""
select_actions_path=""
api_url_override=""
repo_url=$DEFAULT_REPO_URL

linear_key=""
optio_token=""
workspace_id=""
api_url=$DEFAULT_API_URL
work_dir=""

tickets_read=0
created=0
reviews_created=0
fixes_created=0
retried=0
cancelled=0
skipped=0
errors=0
resumed=0
closed=0
notices=0
resume_places=0

HTTP_CODE=""
HTTP_BODY=""
HTTP_ERROR=""

configured_repos=""
free_places=0
review_retries=0
applied=0

code_instruction=""
review_consigne=""
correction_consigne=""
consigne_suffix=""
other_consigne=""
resume_consigne=""

usage() {
  cat >&2 <<'USAGE'
usage: optio/dispatch.sh [--apply] [--slots N] [--instructions FILE]
                         [--select-actions FILE] [--api-url URL] [--repo-url URL]
USAGE
}

warn() {
  echo "optio-dispatch: $*" >&2
}

die_usage() {
  warn "$*"
  usage
  exit 2
}

# --- entrées -----------------------------------------------------------------

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --apply)
        apply_mode=true
        shift
        ;;
      --slots)
        [ "$#" -ge 2 ] || die_usage "--slots needs a number"
        slots=$2
        shift 2
        ;;
      --instructions)
        [ "$#" -ge 2 ] || die_usage "--instructions needs a file"
        instructions_file=$2
        shift 2
        ;;
      --select-actions)
        [ "$#" -ge 2 ] || die_usage "--select-actions needs a file"
        select_actions_file=$2
        shift 2
        ;;
      --api-url)
        [ "$#" -ge 2 ] || die_usage "--api-url needs an url"
        api_url_override=$2
        shift 2
        ;;
      --repo-url)
        [ "$#" -ge 2 ] || die_usage "--repo-url needs an url"
        repo_url=$2
        shift 2
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        die_usage "unknown argument: $1"
        ;;
    esac
  done
  case "$slots" in
    '' | *[!0-9]*) die_usage "--slots must be a non-negative integer" ;;
  esac
}

check_environment() {
  linear_key="${LINEAR_INTAKE_KEY:-${LINEAR_API_KEY:-}}"
  [ -n "$linear_key" ] || die_usage "LINEAR_INTAKE_KEY (or LINEAR_API_KEY) is required"
  optio_token="${OPTIO_API_TOKEN:-}"
  [ -n "$optio_token" ] || die_usage "OPTIO_API_TOKEN is required"
  workspace_id="${OPTIO_WORKSPACE_ID:-}"
  api_url="${api_url_override:-${OPTIO_API_URL:-$DEFAULT_API_URL}}"
}

# Un seul passage à la fois : le verrou est local au nœud, flock est facultatif.
acquire_lock() {
  local lock_file="${OPTIO_DISPATCH_LOCK_FILE:-${TMPDIR:-/tmp}/optio-dispatch.lock}"
  if ! command -v flock >/dev/null 2>&1; then
    warn "flock is absent: no local lock is taken"
    return 0
  fi
  if ! (umask 077 && : >"$lock_file") 2>/dev/null; then
    warn "the lock file is not writable: $lock_file"
    return 0
  fi
  exec 9>"$lock_file"
  if ! flock -n 9; then
    warn "another pass is already running (lock $lock_file)"
    emit_output
    exit 3
  fi
}

# --- HTTP --------------------------------------------------------------------

# Les secrets ne passent jamais en argument : ils sont écrits dans un fichier
# d'en-têtes en mode 600, lu par curl avec -H @fichier.
write_headers() {
  local file=$1
  shift
  (umask 077 && : >"$file")
  chmod 600 "$file"
  local header
  for header in "$@"; do
    printf '%s\n' "$header" >>"$file"
  done
}

# http_request <méthode> <url> [fichier d'en-têtes] [fichier de corps]
# Renvoie 0 si la réponse est un 2xx, 1 sinon.
http_request() {
  local method=$1 url=$2 headers=${3:-} body=${4:-}
  local out="$work_dir/http-body" err="$work_dir/http-error"
  : >"$out"
  : >"$err"
  local -a args=(-sS -o "$out" -w '%{http_code}' -X "$method")
  if [ -n "$headers" ]; then args+=(-H "@$headers"); fi
  if [ -n "$body" ]; then args+=(--data-binary "@$body"); fi
  args+=("$url")
  local rc=0
  HTTP_CODE="$(curl "${args[@]}" 2>"$err")" || rc=$?
  HTTP_BODY="$out"
  if [ "$rc" -ne 0 ]; then
    HTTP_ERROR="$(tr '\n' ' ' <"$err" | cut -c1-200)"
    return 1
  fi
  if ! [[ "$HTTP_CODE" =~ ^2[0-9][0-9]$ ]]; then
    HTTP_ERROR="HTTP $HTTP_CODE"
    return 1
  fi
  HTTP_ERROR=""
  return 0
}

api_error() {
  errors=$((errors + 1))
  warn "API error ($1): $2"
}

# --- lectures ----------------------------------------------------------------

linear_query='query OptioIntake {
  issues(filter: { labels: { name: { eq: "wip:optio" } }, state: { type: { in: ["backlog", "unstarted"] } } }, first: 50) {
    nodes {
      identifier
      title
      description
      priority
      createdAt
      url
      labels { nodes { name } }
      assignee { id name }
      relations(first: 50) { nodes { type relatedIssue { identifier state { type name } } } }
      inverseRelations(first: 50) { nodes { type relatedIssue { identifier state { type name } } } }
    }
  }
}'

# Une seule requête Linear, filtrée côté serveur (50 au plus).
fetch_linear() {
  jq -n --arg q "$linear_query" '{query: $q}' >"$work_dir/linear-request.json"
  write_headers "$work_dir/linear-headers" \
    "Authorization: $linear_key" \
    "Content-Type: application/json"
  if ! http_request POST "$LINEAR_GRAPHQL_URL" "$work_dir/linear-headers" "$work_dir/linear-request.json"; then
    api_error "Linear" "$HTTP_ERROR"
    return 1
  fi
  if ! jq -e . "$HTTP_BODY" >/dev/null 2>&1; then
    api_error "Linear" "the response is not JSON"
    return 1
  fi
  if jq -e '(.errors // []) | length > 0' "$HTTP_BODY" >/dev/null 2>&1; then
    api_error "Linear" "the GraphQL query returned errors"
    return 1
  fi
  cp "$HTTP_BODY" "$work_dir/linear.json"
  tickets_read="$(jq '(.data.issues.nodes // []) | length' "$work_dir/linear.json")"
  return 0
}

# La liste des travaux Optio, et la forme attendue par select-actions.sh.
fetch_optio_tasks() {
  write_headers "$work_dir/optio-headers" \
    "Authorization: Bearer $optio_token" \
    "Content-Type: application/json"
  if [ -n "$workspace_id" ]; then
    printf 'x-workspace-id: %s\n' "$workspace_id" >>"$work_dir/optio-headers"
  fi
  if ! http_request GET "$api_url/api/tasks?limit=$TASKS_LIMIT" "$work_dir/optio-headers"; then
    api_error "Optio" "$HTTP_ERROR"
    return 1
  fi
  if ! jq -e . "$HTTP_BODY" >/dev/null 2>&1; then
    api_error "Optio" "the response is not JSON"
    return 1
  fi
  jq 'if type == "array" then . elif (.tasks? | type) == "array" then .tasks else [] end' \
    "$HTTP_BODY" >"$work_dir/tasks.json"
  jq '[.[] | {
        name: (.title // ""),
        state: (.state // ""),
        repoUrl: (.repoUrl // ""),
        prUrl: (.prUrl // ""),
        prNumber: (.prNumber // null),
        prChecksStatus: (.prChecksStatus // ""),
        conflicts: (.conflicts // false)
      }]' "$work_dir/tasks.json" >"$work_dir/work.json"
  return 0
}

# Les dépôts configurés dans Optio (GET /api/repos, réponse {"repos":[...]}) :
# seuls les noms sous le même propriétaire que le dépôt principal sont gardés.
# En cas d'échec la liste reste vide : aucun ticket n'est pris, les revues et
# corrections continuent, et l'erreur est comptée.
fetch_optio_repos() {
  configured_repos=""
  if ! http_request GET "$api_url/api/repos" "$work_dir/optio-headers"; then
    api_error "Optio" "$HTTP_ERROR"
    return 0
  fi
  if ! jq -e '(.repos? | type) == "array"' "$HTTP_BODY" >/dev/null 2>&1; then
    api_error "Optio" "the repository list has an unexpected shape"
    return 0
  fi
  configured_repos="$(jq -r --arg main "$repo_url" '
    def norm: (ascii_downcase | sub("/+$"; "") | sub("\\.git$"; "") | sub("/+$"; ""));
    ($main | norm | sub("[^/]+$"; "")) as $owner
    | [.repos[] | (.repoUrl // "") | norm | select(startswith($owner)) | ltrimstr($owner)
       | select(contains("/") | not)]
    | unique | join(",")' "$HTTP_BODY")"
  return 0
}

# Toutes les PR ouvertes des dépôts configurés, lues par l'API Optio avec son
# propre accès GitHub (dépôts privés compris, aucun appel anonyme). Optio omet en
# silence un dépôt en erreur : une absence ne prouve jamais une fermeture hors du
# contrôle fait dans fetch_pr_state.
fetch_optio_prs() {
  echo '[]' >"$work_dir/open-prs.json"
  if ! http_request GET "$api_url/api/pull-requests" "$work_dir/optio-headers"; then
    api_error "Optio" "pull requests: $HTTP_ERROR"
    return 1
  fi
  if ! jq -e '(.pullRequests? | type) == "array"' "$HTTP_BODY" >/dev/null 2>&1; then
    api_error "Optio" "the pull request list has an unexpected shape"
    return 1
  fi
  jq '[.pullRequests[]
       | {number, title: (.title // ""), draft: (.draft // false), url: (.url // ""),
          sha: (.headSha // ""), createdAt: (.createdAt // ""),
          repoUrl: (.repo.repoUrl // "")}]' "$HTTP_BODY" >"$work_dir/open-prs.json"
}

# L'état réel des PR du dépôt principal. La liste d'Optio fait foi quand elle
# contient entre 1 et 49 PR de ce dépôt (une page complète, ni vide ni tronquée) ;
# sinon la liste est relue sur GitHub sans jeton (60 requêtes par heure).
fetch_pr_state() {
  if fetch_optio_prs &&
    jq -e --arg repo "$repo_url" '
      def norm: (ascii_downcase | sub("/+$"; "") | sub("\\.git$"; "") | sub("/+$"; ""));
      [.[] | select((.repoUrl | norm) == ($repo | norm))]
      | if length > 0 and length < 50
        then map({number, head: {sha: .sha}}) else false end' \
      "$work_dir/open-prs.json" >"$work_dir/pulls.tmp"; then
    mv "$work_dir/pulls.tmp" "$work_dir/pulls.json"
    return 0
  fi
  fetch_github_pulls
}

# Les en-têtes des lectures anonymes de GitHub, écrits avant chaque usage.
write_github_headers() {
  write_headers "$work_dir/github-headers" \
    "Accept: application/vnd.github+json" \
    "User-Agent: kube-ops-optio-dispatch"
}

fetch_github_pulls() {
  write_github_headers
  : >"$work_dir/pulls.ndjson"
  local page=1 count=0
  while [ "$page" -le "$MAX_PAGES" ]; do
    if ! http_request GET \
      "$GITHUB_REPO_API/pulls?state=open&per_page=$PER_PAGE&page=$page" \
      "$work_dir/github-headers"; then
      api_error "GitHub" "$HTTP_ERROR"
      return 1
    fi
    if ! jq -e . "$HTTP_BODY" >/dev/null 2>&1; then
      api_error "GitHub" "the response is not JSON"
      return 1
    fi
    count="$(jq 'if type == "array" then length else 0 end' "$HTTP_BODY")"
    jq -c '.[]' "$HTTP_BODY" >>"$work_dir/pulls.ndjson"
    if [ "$count" -lt "$PER_PAGE" ]; then
      break
    fi
    page=$((page + 1))
  done
  jq -s '.' "$work_dir/pulls.ndjson" >"$work_dir/pulls.json"
  return 0
}

# pr_status <url de PR> : état, checks et tête d'une PR de n'importe quel dépôt
# configuré, écrits dans $work_dir/pr-status.json.
pr_status() {
  local encoded
  encoded="$(jq -rn --arg u "$1" '$u | @uri')"
  if ! http_request GET "$api_url/api/pull-requests/status?prUrl=$encoded" "$work_dir/optio-headers"; then
    api_error "Optio" "pull request status: $HTTP_ERROR"
    return 1
  fi
  if ! jq -e '(.prState? | type) == "string"' "$HTTP_BODY" >/dev/null 2>&1; then
    api_error "Optio" "the pull request status has an unexpected shape"
    return 1
  fi
  cp "$HTTP_BODY" "$work_dir/pr-status.json"
}

pr_is_open() {
  local number=$1
  jq -e --arg n "$number" 'any(.[]; (.number | tostring) == $n)' "$work_dir/pulls.json" >/dev/null
}

# --- PR d'autres dépôts restées ouvertes (PLT-560) ------------------------------

# Fonctions jq communes aux reprises et aux clôtures.
# shellcheck disable=SC2016
readonly JQ_COMMON='
def norm: (ascii_downcase | sub("/+$"; "") | sub("\\.git$"; "") | sub("/+$"; ""));
def is_main: ((.repoUrl // "") | norm) as $u | ($u == "" or $u == ($repo | norm));
def st: ((.state // "") | ascii_downcase);
def idle: (st as $s | $s == "completed" or $s == "cancelled" or $s == "canceled"
           or $s == "failed" or $s == "pr_opened" or $s == "needs_attention");
def epoch: (try (sub("\\.[0-9]+"; "") | fromdateiso8601) catch null);
def ident: ([(.title // "") | match("^\\[([A-Za-z][A-Za-z0-9]*-[0-9]+)\\]")] | .[0])
  | if . == null then null else .captures[0].string end;
def tagged($id): ((. // "") | test("[\\(\\[]" + $id + "[\\)\\]]"; "i"));
'

# Une PR ouverte appartient à une tâche de ticket quand c'est sa PR, ou quand une
# tâche qui n'a rien enregistré a un titre de PR portant son ticket et une PR
# créée pendant son exécution. Rien d'autre n'est repris.
build_resume_candidates() {
  local jq_program
  IFS= read -r -d '' jq_program <<'JQ' || true
($tasks[0]) as $T
| ($prs[0] | map(. + {repoKey: (.repoUrl | norm)})) as $P
| ([$T[]
    | select((is_main | not) and idle and st != "cancelled" and st != "canceled")
    | . as $t
    | (ident) as $id
    | select($id != null)
    | select(any($T[]; ident == $id and (idle | not)) | not)
    | $P[]
    | . as $p
    | select($p.repoKey == (($t.repoUrl // "") | norm))
    | select((($t.prUrl // "") | norm) == ($p.url | norm)
             or ((($t.prUrl // "") == "") and ($t | st == "needs_attention" or st == "failed")
                 and ($p.title | tagged($id))
                 and (($p.createdAt | epoch) as $c
                      | ($t.createdAt // "" | epoch) as $from
                      | (($t.completedAt // $t.updatedAt // "") | epoch) as $to
                      | $c != null and $from != null and $c >= $from - 120
                        and ($to == null or $c <= $to + 600))))
    | {task: ($t.title // ""), identifier: $id, repoUrl: $t.repoUrl,
       repo: ($p.repoKey | split("/") | last), prNumber: $p.number, prUrl: $p.url,
       draft: $p.draft, sha8: ($p.sha | .[0:8]), createdAt: $p.createdAt}]
   ) as $matched
| ($matched | group_by(.prUrl) | map(.[0])) as $unique
| [$unique[]
   | . as $c
   | ("[REPRISE " + $c.repo + "#" + ($c.prNumber | tostring) + " ") as $prefix
   | ([$T[] | select(((.title // "") | startswith($prefix))
                     and ((.repoUrl // "") | norm) == ($c.repoUrl | norm))]) as $done
   | ([$done[] | select((.title // "") | startswith($prefix + $c.sha8 + " "))]) as $same
   | $c + {name: ($prefix + $c.sha8 + " " + (($done | length) + 1 | tostring) + "]"),
           key: ($c.repo + "#" + ($c.prNumber | tostring) + " " + $c.sha8)}
   | . + (if $c.draft then {skip: "PR en brouillon"}
          elif any($done[]; idle | not) then {skip: "reprise de PR en cours"}
          elif any($same[]; st != "failed") then
            {skip: "PR laissée ouverte après une reprise sur cette tête", blocked: true}
          elif ($done | length) >= $max then
            {skip: ("reprises de PR au plafond : " + ($max | tostring)), blocked: true}
          elif any($same[]; ((.completedAt // .updatedAt // "") | epoch) as $f
                            | $f != null and (now - $f) < $delay) then
            {skip: "reprise de PR en attente : échec récent"}
          else {skip: null} end)] as $all
| {matched: ($matched | map(.task) | unique), candidates: $all}
JQ
  jq -n --slurpfile tasks "$work_dir/tasks.json" \
    --slurpfile prs "$work_dir/open-prs.json" \
    --arg repo "$repo_url" --argjson max "$MAX_RESUMES" --argjson delay "$LIMIT_RETRY_DELAY" \
    "$JQ_COMMON$jq_program" >"$work_dir/resume-candidates.json"
}

# La CI est relue pour chaque PR candidate : des checks en attente interdisent
# la reprise (le passage suivant reviendra).
plan_resumes() {
  if ! build_resume_candidates; then
    warn "the pull requests to resume could not be listed"
    errors=$((errors + 1))
    return 1
  fi
  : >"$work_dir/resumes.ndjson"
  : >"$work_dir/resume-skips.ndjson"
  local entry reason
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    reason="$(jq -r '.skip // ""' <<<"$entry")"
    if [ -z "$reason" ]; then
      if ! pr_status "$(jq -r '.prUrl' <<<"$entry")"; then
        reason="état de la PR illisible"
      else
        reason="$(jq -r --argjson entry "$entry" --argjson wait "$NO_CHECKS_DELAY" '
          (try ($entry.createdAt | sub("\\.[0-9]+"; "") | fromdateiso8601) catch null) as $c
          | if .prState != "open" then "PR fermée ou mergée"
            elif .mergeable == false then ""
            elif .checksStatus == "pending" then "CI en cours"
            elif .checksStatus == "none" and $c != null and (now - $c) < $wait then
              "aucun check encore publié"
            else "" end' "$work_dir/pr-status.json")"
      fi
    fi
    if [ -z "$reason" ]; then
      printf '%s\n' "$entry" >>"$work_dir/resumes.ndjson"
    else
      jq -c --arg reason "$reason" '. + {skip: $reason}' <<<"$entry" >>"$work_dir/resume-skips.ndjson"
    fi
  done < <(jq -c '.candidates[]' "$work_dir/resume-candidates.json")
  jq -n --slurpfile eligible "$work_dir/resumes.ndjson" \
    --slurpfile skips "$work_dir/resume-skips.ndjson" \
    --slurpfile found "$work_dir/resume-candidates.json" '
    {matched: $found[0].matched,
     eligible: ($eligible | sort_by(.prUrl)),
     skipped: ($skips | map({id: .key, reason: .skip})),
     blocked: ($skips | map(select(.blocked == true)
               | {identifier, key, prUrl, reason: .skip}))}' >"$work_dir/resumes.json"
}

# --- reprises -----------------------------------------------------------------

# Les tâches en échec qui peuvent être reprises : une tâche de ticket sans PR
# (tous dépôts), ou une revue ou correction du dépôt principal arrêtée par la
# limite du forfait et encore utile (PR ouverte, même tête pour une revue).
build_retry_candidates() {
  local jq_program
  IFS= read -r -d '' jq_program <<'JQ' || true
def norm: (ascii_downcase | sub("/+$"; "") | sub("\\.git$"; "") | sub("/+$"; ""));
def is_main: ((.repoUrl // "") | norm) as $u | ($u == "" or $u == ($repo | norm));
def st: ((.state // "") | ascii_downcase);
def has_pr:
  (((.prUrl // "") | tostring) != "")
  or (((.prNumber // null) | tostring) as $n | $n != "null" and $n != "" and $n != "0");
def limit_hit: ((.errorMessage // "") | tostring | test($limit_pattern; "i"));
def infra_hit: ((.errorMessage // "") | tostring | test($infra_pattern; "i"));
def parts($re): ([(.title // "") | match($re)] | .[0] // null)
  | if . == null then null else [.captures[] | .string] end;
def open_pr($n): ([$pulls[0][] | select((.number | tostring) == $n)] | .[0]) // null;
def candidate($kind; $pr; $sha):
  {id: (.id | tostring), name: (.title // ""), kind: $kind, prNumber: $pr, sha8: $sha,
   limit: limit_hit, infra: ((limit_hit | not) and infra_hit),
   failedAt: (.completedAt // .updatedAt // ""),
   retryCount: ((.retryCount // 0)
                | if type == "number" then . else (try tonumber catch 0) end)};

($tasks[0]) as $T
| ([$T[]
    | select(st == "failed" and is_main and (limit_hit or infra_hit))
    | . as $t
    | (parts("^\\[REVUE PR-([0-9]+)(?: ([0-9A-Fa-f]+))?\\]")) as $m
    | select($m != null)
    | (open_pr($m[0])) as $p
    | select($p != null)
    | (($p.head.sha // "") | .[0:8]) as $head
    | select(($m[1] // "") == "" or $m[1] == $head)
    | candidate("review"; ($m[0] | tonumber); ($m[1] // ""))]
   | group_by(.prNumber) | map(.[0])) as $reviews
| ([$T[]
    | select(is_main)
    | . as $t
    | (parts("^\\[CORRIGE PR-([0-9]+) ([0-9]+)\\]")) as $m
    | select($m != null)
    | {pr: ($m[0] | tonumber), k: ($m[1] | tonumber), task: $t}]) as $corrections
| ([$corrections[]
    | . as $c
    | select(($c.task | st) == "failed" and ($c.task | limit_hit or infra_hit))
    | select(open_pr($c.pr | tostring) != null)
    # La correction la plus récente seulement, et aucune autre en cours.
    | select(all($corrections[]; .pr != $c.pr or .k <= $c.k))
    | select(all($corrections[];
                 .pr != $c.pr or ((.task | st) as $s
                 | $s == "failed" or $s == "completed" or $s == "cancelled" or $s == "canceled")))
    # La PR doit encore avoir besoin d'une correction.
    | select(any($T[];
                 is_main and ((.prNumber // 0) | tostring) == ($c.pr | tostring)
                 and (((.prChecksStatus // "") | ascii_downcase) as $k
                      | $k == "failing" or $k == "conflicts" or (.conflicts // false) == true)))
    | $c.task | candidate("fix"; $c.pr; "")]) as $fixes
| ([$T[]
    | select((.title // "") | test("^\\[[A-Za-z][A-Za-z0-9]*-[0-9]+\\]"))
    | select(st == "failed")
    | select(has_pr | not)
    # Une PR ouverte trouvée pour la tâche : c'est la PR qui est reprise.
    | select((.title // "") as $n | ($resumes[0].matched | index($n)) == null)
    | candidate("ticket"; null; "")]) as $tickets
| $reviews + $fixes + $tickets
JQ
  jq -c -n --slurpfile tasks "$work_dir/tasks.json" \
    --slurpfile pulls "$work_dir/pulls.json" \
    --slurpfile resumes "$work_dir/resumes.json" \
    --arg repo "$repo_url" \
    --arg limit_pattern "$LIMIT_ERROR_PATTERN" \
    --arg infra_pattern "$INFRA_ERROR_PATTERN" \
    "$jq_program" >"$work_dir/candidates.json"
}

# Le nombre de reprises vient de l'historique de la tâche : Optio v0.26.4
# n'incrémente pas retryCount quand une tâche de dépôt est reprise par l'API.
# Sans historique lisible, la tâche n'est pas reprise.
plan_retries() {
  if ! build_retry_candidates; then
    warn "the retry candidates could not be listed"
    errors=$((errors + 1))
    return 1
  fi
  : >"$work_dir/retries.ndjson"
  local entry id count
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    id="$(jq -r '.id' <<<"$entry")"
    count=-1
    if ! http_request GET "$api_url/api/tasks/$id/events" "$work_dir/optio-headers"; then
      api_error "Optio" "$HTTP_ERROR"
    elif ! jq -e '(.events? | type) == "array"' "$HTTP_BODY" >/dev/null 2>&1; then
      api_error "Optio" "the task history has an unexpected shape"
    else
      count="$(jq '[.events[] | select(.trigger == "user_retry")] | length' "$HTTP_BODY")"
    fi
    jq -c --argjson events "$count" '. + {events: $events}' <<<"$entry" >>"$work_dir/retries.ndjson"
  done < <(jq -c '.[]' "$work_dir/candidates.json")

  # eligible : reprise possible ; skipped : écartée avec sa raison ;
  # pending : sous le plafond (une correction en attente bloque la suivante).
  jq -s -c --argjson max "$MAX_RETRIES" --argjson limit_max "$MAX_LIMIT_RETRIES" \
    --argjson delay "$LIMIT_RETRY_DELAY" --argjson infra_max "$MAX_INFRA_RETRIES" \
    --argjson infra_delay "$INFRA_RETRY_DELAY" '
    def age: (try (now - (sub("\\.[0-9]+"; "") | fromdateiso8601)) catch null);
    map(. + {count: ([.retryCount, .events] | max)}
        | . + {ceiling: (if .limit then $limit_max elif .infra then $infra_max else $max end),
               wait: (if .limit then $delay elif .infra then $infra_delay else 0 end)}
        | (.failedAt | age) as $age
        | . + {skip:
            (if .events < 0 then "historique des reprises illisible"
             elif .count >= .ceiling then
               "reprise au plafond : " + (.count | tostring) + " reprises déjà faites"
             elif .wait > 0 and $age != null and $age < .wait then
               "reprise en attente : "
               + (if .limit then "limite du forfait" else "panne de pod" end)
               + ", échec de moins de " + ((.wait / 60) | floor | tostring) + " min"
             else null end)})
    | {eligible: map(select(.skip == null)),
       skipped: map(select(.skip != null) | {id: .name, reason: .skip}),
       pending: map(select(.events < 0 or .count < .ceiling) | .name),
       blocked: map(select(.kind == "ticket" and .events >= 0 and .count >= .ceiling)
                    | ([.name | match("^\\[([A-Za-z][A-Za-z0-9]*-[0-9]+)\\]")] | .[0].captures[0].string) as $i
                    | {identifier: $i, key: ($i + " " + .id), prUrl: "",
                       reason: ("tâche Optio en échec, " + (.count | tostring)
                                + " reprises déjà faites")})}
  ' "$work_dir/retries.ndjson" >"$work_dir/retries.json"
}

# Les places libres : les revues et corrections reprises passent en premier,
# puis le sélecteur reçoit ce qui reste.
count_places() {
  free_places="$(jq --argjson slots "$slots" '
    [.[] | (.state // "" | ascii_downcase)
     | select(. != "completed" and . != "cancelled" and . != "canceled" and . != "failed"
              and . != "pr_opened" and . != "needs_attention" and . != "waiting_on_deps")]
    | ($slots - length) | if . < 0 then 0 else . end' "$work_dir/tasks.json")"
  review_retries="$(jq --argjson free "$free_places" \
    '[.eligible[] | select(.kind != "ticket")] | .[0:$free] | length' "$work_dir/retries.json")"
  resume_places="$(jq --argjson free "$((free_places - review_retries))" \
    '.eligible[0:$free] | length' "$work_dir/resumes.json")"
}

# --- décision ----------------------------------------------------------------

# Le script de sélection est celui du dépôt ; le travail de commande n'a pas de
# dépôt cloné, il est donc téléchargé depuis la branche main quand il est
# absent. Le chemin est rendu dans select_actions_path et la fonction est
# appelée dans le shell courant : dans une substitution de commande, l'appel à
# api_error qui compte l'erreur de téléchargement tournerait dans un
# sous-processus et son incrément serait perdu.
resolve_select_actions() {
  select_actions_path=""
  if [ -n "$select_actions_file" ]; then
    if [ -f "$select_actions_file" ]; then
      select_actions_path="$select_actions_file"
      return 0
    fi
  elif [ -f "$script_dir/select-actions.sh" ]; then
    select_actions_path="$script_dir/select-actions.sh"
    return 0
  fi
  if ! download_to "$GITHUB_RAW_BASE/$SELECT_ACTIONS_PATH" "$work_dir/select-actions.sh"; then
    return 1
  fi
  select_actions_path="$work_dir/select-actions.sh"
  return 0
}

download_to() {
  local url=$1 target=$2
  write_github_headers
  if ! http_request GET "$url" "$work_dir/github-headers"; then
    api_error "GitHub" "$HTTP_ERROR"
    return 1
  fi
  cp "$HTTP_BODY" "$target"
  return 0
}

run_decision() {
  local select_actions
  if ! resolve_select_actions; then
    return 1
  fi
  select_actions="$select_actions_path"
  if [ ! -r "$select_actions" ]; then
    api_error "Optio" "the selection script is not readable: $select_actions"
    return 1
  fi
  # Le sélecteur plafonne les revues et corrections par numéro de PR croissant :
  # une PR fermée ou mergée prendrait une place à chaque passage et les PR
  # récentes ne seraient jamais choisies. Le travail reste, sans sa PR.
  # Les numéros de PR d'un autre dépôt ne sont jamais comparés à ceux du dépôt
  # principal : ils sont retirés avant la sélection.
  if ! jq -n --slurpfile works "$work_dir/work.json" \
    --slurpfile pulls "$work_dir/pulls.json" \
    --slurpfile retries "$work_dir/retries.json" \
    --arg repo "$repo_url" '
      def norm: (ascii_downcase | sub("/+$"; "") | sub("\\.git$"; "") | sub("/+$"; ""));
      ($retries[0].pending) as $pending
      | $works[0]
      | map(. as $w
            | ((.prNumber // ((.prUrl // "") | split("/") | last)) | tostring) as $n
            | ((.repoUrl // "") | norm) as $u
            | ([$pulls[0][] | select((.number | tostring) == $n)] | .[0]) as $p
            | (if ($u == "" or $u == ($repo | norm)) and $p != null
               then .headSha8 = (($p.head.sha // "") | .[0:8])
               else .prNumber = null | .prUrl = "" end)
            | .retryPending = (($pending | index($w.name)) != null))' >"$work_dir/work-open.json"; then
    warn "the work list could not be filtered"
    errors=$((errors + 1))
    return 1
  fi
  if ! bash "$select_actions" \
    --linear "$work_dir/linear.json" \
    --work "$work_dir/work-open.json" \
    --slots "$((slots - review_retries - resume_places))" \
    --repos "$configured_repos" \
    --main-repo "$repo_url" >"$work_dir/decision.json" 2>"$work_dir/decision-error"; then
    warn "the selection failed: $(tr '\n' ' ' <"$work_dir/decision-error" | cut -c1-200)"
    errors=$((errors + 1))
      return 1
  fi
  if ! jq -e . "$work_dir/decision.json" >/dev/null 2>&1; then
    warn "the selection returned no usable decision"
    errors=$((errors + 1))
      return 1
  fi
  return 0
}

# --- tâches mergées et blocages (PLT-560) ----------------------------------------

# shellcheck disable=SC2016
linear_followup_query='query OptioFollowUp($filter: IssueFilter) {
  issues(filter: $filter, first: 30) {
    nodes {
      id
      identifier
      state { type }
      team { states(first: 20) { nodes { id name type } } }
      attachments(first: 10) { nodes { url title createdAt metadata } }
      comments(first: 50, filter: { body: { contains: "optio-dispatch" } }) { nodes { body } }
    }
  }
}'

# linear_send <fichier de requête> : une requête ou mutation Linear ; la réponse
# reste dans HTTP_BODY.
linear_send() {
  if ! http_request POST "$LINEAR_GRAPHQL_URL" "$work_dir/linear-headers" "$1"; then
    api_error "Linear" "$HTTP_ERROR"
    return 1
  fi
  if ! jq -e '((.errors // []) | length) == 0 and (.data | type) == "object"' "$HTTP_BODY" >/dev/null 2>&1; then
    api_error "Linear" "the GraphQL request returned errors"
    return 1
  fi
}

# Optio 0.26.4 ne détecte pas toujours la PR qu'un agent a mergée lui-même : la
# tâche attend alors dans « needs_attention ».
build_closure_candidates() {
  jq -n --slurpfile tasks "$work_dir/tasks.json" \
    --slurpfile resumes "$work_dir/resumes.json" \
    --arg repo "$repo_url" --arg no_pr "$NO_PR_PATTERN" \
    "$JQ_COMMON"'
    ($tasks[0]) as $T
    | [$T[]
       | select(st == "needs_attention" and ((.errorMessage // "") | test($no_pr)))
       | select((is_main | not) or ((.prNumber // 0) | tostring) == "0")
       | . as $t
       | (ident) as $id
       | select($id != null)
       | select((.title // "") as $n | ($resumes[0].matched | index($n)) == null)
       | select(any($T[]; ident == $id and (idle | not)) | not)
       | {taskId: (.id | tostring), name: .title, identifier: $id,
          repoUrl: (.repoUrl | if . == null or . == "" then $repo else . end | norm),
          createdAt: (.createdAt // "")}]' >"$work_dir/closure-candidates.json"
}

# La preuve qu'un ticket peut passer à Done : le lien « closes » de Linear, ou,
# s'il est absent et le dépôt public, la ligne « Fixes » de la PR.
fixes_proven() {
  local url=$1 id=$2 kind=$3 api
  case "$kind" in
    closes) return 0 ;;
    contributes | links) return 1 ;;
  esac
  api="$(sed -E 's#^https://github\.com/([^/]+)/([^/]+)/pull/([0-9]+)$#https://api.github.com/repos/\1/\2/pulls/\3#' <<<"$url")"
  [ "$api" != "$url" ] || return 1
  write_github_headers
  # Un dépôt privé répond 404 : la preuve manque, ce n'est pas une erreur.
  http_request GET "$api" "$work_dir/github-headers" || return 1
  jq -e --arg id "$id" '(.body // "") as $b
    | ($b | test("(fixes|closes|resolves)[ \t]+\\[?" + $id + "(?![0-9])"; "i"))
      and (($b | test("part of[ \t]+\\[?" + $id + "(?![0-9])"; "i")) | not)' \
    "$HTTP_BODY" >/dev/null 2>&1
}

plan_followups() {
  echo '[]' >"$work_dir/closures.json"
  echo '[]' >"$work_dir/notices.json"
  if ! build_closure_candidates; then
    warn "the merged tasks could not be listed"
    errors=$((errors + 1))
    return 0
  fi
  jq -n --slurpfile closures "$work_dir/closure-candidates.json" \
    --slurpfile resumes "$work_dir/resumes.json" \
    --slurpfile retries "$work_dir/retries.json" \
    --arg q "$linear_followup_query" '
    ([$closures[0][], $resumes[0].blocked[], $retries[0].blocked[] | .identifier | ascii_upcase]
     | unique | .[0:30]) as $ids
    | if ($ids | length) == 0 then empty else
        {query: $q, variables: {filter: {"or":
          ($ids | map(split("-")) | group_by(.[0])
           | map({team: {key: {eq: .[0][0]}}, number: {in: map(.[1] | tonumber)}}))}}}
      end' >"$work_dir/followup-request.json"
  [ -s "$work_dir/followup-request.json" ] || return 0
  # Une lecture impossible n'arrête pas le passage : l'erreur est comptée.
  linear_send "$work_dir/followup-request.json" || return 0
  jq '.data.issues.nodes // []' "$HTTP_BODY" >"$work_dir/followup.json"

  jq --slurpfile resumes "$work_dir/resumes.json" --slurpfile retries "$work_dir/retries.json" -n \
    --slurpfile issues "$work_dir/followup.json" '
    [$resumes[0].blocked[], $retries[0].blocked[]
     | . as $b
     | ($issues[0][] | select(.identifier == ($b.identifier | ascii_upcase))) as $i
     | select($i.state.type != "completed" and $i.state.type != "canceled")
     | ("optio-dispatch, blocage " + $b.key) as $marker
     | select(any($i.comments.nodes[]?; (.body // "") | contains($marker)) | not)
     | {identifier: $i.identifier, issueId: $i.id, key: $b.key,
        body: ($marker + " : " + $b.reason + ". "
               + (if $b.prUrl != "" then "PR : " + $b.prUrl + ". " else "" end)
               + "Le dispatch ne fera plus rien seul : geste humain attendu.")}]' \
    >"$work_dir/notices.json"

  : >"$work_dir/closures.ndjson"
  local entry urls url merged open sha kind id
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    id="$(jq -r '.identifier | ascii_upcase' <<<"$entry")"
    # Les PR du ticket, dans le dépôt de la tâche, liées pendant son exécution.
    urls="$(jq -r --argjson e "$entry" --arg id "$id" "$JQ_COMMON"'
      [.[] | select(.identifier == $id) | .attachments.nodes[]?
       | select((.url | ascii_downcase) | startswith($e.repoUrl + "/pull/"))
       | select(.title | tagged($id))
       | ((.createdAt // "") | epoch) as $c
       | ($e.createdAt | epoch) as $from
       | select($c != null and $from != null and $c >= $from - 120)]
      | sort_by(.createdAt) | reverse | .[0:3][]
      | .url + " " + ((.metadata.linkKind? // "unknown") | tostring)' \
      --arg repo "$repo_url" "$work_dir/followup.json")"
    merged=""
    open=false
    while read -r url kind; do
      [ -n "$url" ] || continue
      if ! pr_status "$url"; then
        open=true
        continue
      fi
      case "$(jq -r '.prState' "$work_dir/pr-status.json")" in
        merged)
          if [ -z "$merged" ]; then
            merged="$url $kind"
            sha="$(jq -r '(.headSha // "") | .[0:8]' "$work_dir/pr-status.json")"
          fi
          ;;
        open) open=true ;;
      esac
    done <<<"$urls"
    # Sans PR mergée, ou avec une PR encore ouverte, la tâche reste visible.
    if [ -z "$merged" ] || [ "$open" = true ]; then
      continue
    fi
    url="${merged% *}"
    kind="${merged##* }"
    local proven=false
    if fixes_proven "$url" "$id" "$kind"; then proven=true; fi
    jq -c -n --argjson e "$entry" --slurpfile issues "$work_dir/followup.json" \
      --arg id "$id" --arg url "$url" --arg sha "$sha" --arg kind "$kind" \
      --argjson proven "$proven" '
      ($issues[0][] | select(.identifier == $id)) as $i
      | ($i.state.type == "completed" or $i.state.type == "canceled") as $finished
      | ([$i.team.states.nodes[]? | select(.type == "completed")]
         | (map(select(.name == "Done")) + .) | .[0].id // null) as $state
      | ($url | split("/") | .[-3] + "#" + .[-1]) as $short
      | ("optio-dispatch, preuve de merge " + $short) as $marker
      | ($proven and ($finished | not) and $state != null) as $done
      | $e + {issueId: $i.id, prUrl: $url, sha8: $sha, linkKind: $kind, done: $done,
              stateId: $state,
              comment: (if $finished or any($i.comments.nodes[]?; (.body // "") | contains($marker))
                        then null
                        else $marker + " : " + $url + " est mergée (tête " + $sha
                             + ", état lu par l API Optio). La tâche Optio " + $e.taskId
                             + " sans PR détectée est annulée. "
                             + (if $done then "Ticket passé à Done (la PR le corrige)."
                                else "Ticket laissé ouvert : aucune ligne Fixes prouvée, contrôle à faire." end)
                        end)}' >>"$work_dir/closures.ndjson"
  done < <(jq -c '.[]' "$work_dir/closure-candidates.json")
  jq -s '.' "$work_dir/closures.ndjson" >"$work_dir/closures.json"
}

# --- consignes ----------------------------------------------------------------

# Les consignes de code, de revue et de correction sont recopiées mot pour mot
# depuis docs/operations/optio-intake.md.
load_instructions() {
  local source
  if [ -n "$instructions_file" ]; then
    if [ ! -r "$instructions_file" ]; then
      warn "the instructions file is not readable: $instructions_file"
      errors=$((errors + 1))
          return 1
    fi
    source="$instructions_file"
  else
    source="$work_dir/instructions.md"
    if ! download_instructions "$source"; then
      return 1
    fi
  fi
  extract_consignes "$source"
  if [ -z "$code_instruction" ] || [ -z "$review_consigne" ] ||
    [ -z "$correction_consigne" ] || [ -z "$consigne_suffix" ] ||
    [ -z "$other_consigne" ]; then
    warn "the instructions do not hold the five expected passages"
    errors=$((errors + 1))
      return 1
  fi
  return 0
}

# raw.githubusercontent.com ne compte pas dans le quota de l'API GitHub.
download_instructions() {
  download_to "$GITHUB_RAW_BASE/$INSTRUCTIONS_PATH" "$1"
}

# Le fichier des consignes contient six passages délimités : la consigne de
# code (entre guillemets, après « puis : »), les consignes REVUE, CORRECTION,
# AUTRE-DEPOT et REPRISE (entre <<< et >>>), et la phrase à ajouter à la fin de
# la revue et de la correction. La consigne REPRISE manquante n'écarte que les
# reprises de PR.
extract_consignes() {
  local source=$1
  cat >"$work_dir/extract.awk" <<'AWK'
    function emit(tag, text) {
      sub(/[[:space:]]+$/, "", text)
      print "@@" tag "@@"
      print text
    }
    BEGIN { section = ""; text = ""; mode = ""; code = 0; cbuf = ""; suffix = 0; sbuf = "" }
    /^[[:space:]]*Consigne REVUE[[:space:]]*:[[:space:]]*$/ { mode = "REVUE"; next }
    /^[[:space:]]*Consigne CORRECTION[[:space:]]*:[[:space:]]*$/ { mode = "CORRECTION"; next }
    /^[[:space:]]*Consigne AUTRE-DEPOT[[:space:]]*:[[:space:]]*$/ { mode = "OTHER"; next }
    /^[[:space:]]*Consigne REPRISE[[:space:]]*:[[:space:]]*$/ { mode = "RESUME"; next }
    mode != "" && /^[[:space:]]*<<<[[:space:]]*$/ { section = mode; text = ""; mode = ""; next }
    section != "" && /^[[:space:]]*>>>[[:space:]]*$/ { emit(section, text); section = ""; text = ""; next }
    section != "" { line = $0; sub(/^[[:space:]]+/, "", line); text = text line " "; next }
    /puis :[[:space:]]*$/ { code = 1; next }
    code == 1 {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      if (first == 0) { sub(/^"/, "", line); first = 1 }
      if (line ~ /n'ouvre pas de PR\./) {
        sub(/".*$/, "", line)
        emit("CODE", cbuf line)
        code = 0; cbuf = ""; first = 0
        next
      }
      cbuf = cbuf line " "
    }
    /mot pour mot : "Never run the full test suite/ {
      suffix = 1
      line = $0
      sub(/^.*mot pour mot : "/, "", line)
      sbuf = line " "
      next
    }
    suffix == 1 {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      if (line ~ /CI is the evidence\."/) {
        sub(/".*$/, "", line)
        emit("SUFFIX", sbuf line)
        suffix = 0; sbuf = ""
        next
      }
      sbuf = sbuf line " "
    }
AWK
  awk -f "$work_dir/extract.awk" "$source" >"$work_dir/consignes.txt"

  code_instruction=""
  review_consigne=""
  correction_consigne=""
  consigne_suffix=""
  other_consigne=""
  resume_consigne=""
  local current="" line
  while IFS= read -r line; do
    case "$line" in
      "@@CODE@@") current="code"; continue ;;
      "@@REVUE@@") current="review"; continue ;;
      "@@CORRECTION@@") current="fix"; continue ;;
      "@@SUFFIX@@") current="suffix"; continue ;;
      "@@OTHER@@") current="other"; continue ;;
      "@@RESUME@@") current="resume"; continue ;;
    esac
    case "$current" in
      code) code_instruction="${code_instruction:+$code_instruction }$line" ;;
      review) review_consigne="${review_consigne:+$review_consigne }$line" ;;
      fix) correction_consigne="${correction_consigne:+$correction_consigne }$line" ;;
      suffix) consigne_suffix="${consigne_suffix:+$consigne_suffix }$line" ;;
      other) other_consigne="${other_consigne:+$other_consigne }$line" ;;
      resume) resume_consigne="${resume_consigne:+$resume_consigne }$line" ;;
    esac
  done <"$work_dir/consignes.txt"
  return 0
}

# --- plan --------------------------------------------------------------------

build_plan() {
  local jq_program
  IFS= read -r -d '' jq_program <<'JQ' || true
def lc: ascii_downcase;
def norm: (lc | sub("/+$"; "") | sub("\\.git$"; "") | sub("/+$"; ""));
def is_main: ((.repoUrl // "") | norm) as $u | ($u == "" or $u == ($repo | norm));
# Le dépôt principal garde --repo-url ; les autres sont sous le même propriétaire.
def url_of($name):
  ($repo | norm) as $m
  | ($m | sub("[^/]+$"; "")) as $owner
  | if ($owner + ($name | lc)) == $m then $repo else $owner + ($name | lc) end;
def is_active:
  ((.state // "") | lc) as $s
  | ($s != "completed" and $s != "cancelled" and $s != "canceled" and $s != "failed");
def title_pr_number:
  ([(.title // "")
    | match("\\[(?:REVUE|CORRIGE) PR-(?<n>[0-9]+)")
    | .captures[]
    | select(.name == "n")
    | .string]
   | .[0]) // null;
def open_pr($P; $n):
  ([$P[] | select((.number | tostring) == ($n | tostring))] | .[0]) // null;
def sha8($s):
  (($s // "") | split("") | .[0:8] | join(""));

($decision[0]) as $d
| ($linear[0].data.issues.nodes // []) as $issues
| ($tasks[0]) as $T
| ($pulls[0]) as $P
| ([$T[] | (.title // "")]) as $names
| ([$d.create_tasks[]?
    | . as $t
    | (($issues | map(select(.identifier == $t.identifier)) | .[0]) // {}) as $issue
    | ([($issue.labels.nodes // [])[] | (.name // "") | lc]) as $labels
    | {identifier: $t.identifier, name: $t.name, url: $t.url,
       description: ($t.description // ""),
       repo: $t.repo, repoUrl: url_of($t.repo),
       main: ((url_of($t.repo) | norm) == ($repo | norm)),
       model: (if ($labels | index("agent:opus")) != null
               then "code/frontier" else "text/strong" end)}]) as $cand_tasks
| ([$d.create_reviews[]?
    | . as $r
    | (open_pr($P; $r.prNumber)) as $p
    | select($p != null)
    | (sha8($p.head.sha)) as $sha
    | {prNumber: $r.prNumber, prUrl: $r.prUrl, sha8: $sha,
       name: ("[REVUE PR-" + ($r.prNumber | tostring) + " " + $sha + "]")}]) as $cand_reviews
| ([$d.create_fixes[]?
    | . as $f
    | (open_pr($P; $f.prNumber)) as $p
    | select($p != null)
    | {prNumber: $f.prNumber, prUrl: $f.prUrl, name: $f.name,
       attempt: ($f.attempt // 1)}]) as $cand_fixes
| ([$d.create_reviews[]?, $d.create_fixes[]?
    | . as $a
    | (open_pr($P; $a.prNumber)) as $p
    | select($p == null)
    | {id: ("PR-" + ($a.prNumber | tostring)),
       reason: "PR fermée ou mergée"}]) as $skip_closed_pr
| ($retries[0]) as $R
| ($resumes[0].eligible[0:$resume_places]) as $cand_resumes
| ($free - $review_retries - ($cand_resumes | length) - ($cand_reviews | length) - ($cand_fixes | length)
   | if . < 0 then 0 else . end) as $after_reviews
| ([$R.eligible[] | select(.kind == "ticket")] | .[0:$after_reviews]) as $ticket_retries
| ($after_reviews - ($ticket_retries | length)) as $task_places
| (([$R.eligible[] | select(.kind != "ticket")] | .[0:$review_retries]) + $ticket_retries) as $retryable
| ([$T[]
    | select(is_active and is_main)
    | select(((.title // "") | test("^\\[(REVUE|CORRIGE) PR-[0-9]+")))
    | . as $w
    | ((title_pr_number) // (.prNumber // null)) as $n
    | select($n != null)
    | (open_pr($P; $n)) as $p
    | select($p == null)
    | {id: (.id | tostring), name: ($w.title // ""), prNumber: $n,
       reason: "PR fermée ou mergée"}]) as $cancels
# Optio ne sort jamais seul une tâche de « needs_attention ». Trois cas sont
# sans objet : une revue, correction ou reprise de PR terminée (elle n'ouvre
# jamais de PR) et une tâche de ce dépôt dont la PR est fermée ou mergée. Les
# tâches mergées sans PR détectée passent par les clôtures. Tout autre motif reste.
| ([$T[]
    | select(((.state // "") | lc) == "needs_attention")
    | . as $w
    | (title_pr_number) as $tn
    | (if ((.title // "") | startswith("[REPRISE ")) then
         (if ((.errorMessage // "") | test("did not open a pull request"))
          then {prNumber: null, reason: "reprise de PR terminée : aucune PR attendue"}
          else empty end)
       elif $tn != null and is_main then
         (if ((.errorMessage // "") | test("did not open a pull request"))
          then {prNumber: $tn, reason: "revue ou correction terminée : aucune PR attendue"}
          else empty end)
       elif $tn == null and (((.repoUrl // "") | norm) == ($repo | norm))
            and ((.prNumber // 0) | tostring) != "0"
            and open_pr($P; .prNumber) == null then
         {prNumber: .prNumber, reason: "PR fermée ou mergée"}
       else empty end)
    | {id: ($w.id | tostring), name: ($w.title // ""), prNumber: .prNumber,
       reason: .reason, requires_state: "needs_attention"}]) as $stale
| ([$cand_tasks[], $cand_reviews[], $cand_fixes[]
    | . as $c
    | select(.name as $n | ($names | index($n)) != null)
    | {id: .name, reason: ("travail existant : " + .name)}]) as $skip_existing
| {
    tasks: ([$cand_tasks[] | . as $c | select(.name as $n | ($names | index($n)) == null)]
            | .[0:$task_places]),
    reviews: [$cand_reviews[] | . as $c | select(.name as $n | ($names | index($n)) == null)],
    fixes: [$cand_fixes[] | . as $c | select(.name as $n | ($names | index($n)) == null)],
    resumes: [$cand_resumes[] | . as $c | select(.name as $n | ($names | index($n)) == null)
              | {name, identifier, repo, repoUrl, prNumber, prUrl, sha8}],
    closures: $closures[0],
    notices: $notices[0],
    retries: [$retryable[] | {id, name, kind, prNumber, sha8, retryCount: .count, ceiling}],
    cancellations: (($stale + ([$cancels[] | select(.id as $i | all($stale[]; .id != $i))]))
                    | map(select(.id as $i | all($closures[0][]; .taskId != $i)))),
    skipped: ((($d.skipped // []) | map({id: (.id // ""), reason: (.reason // "")}))
              + $skip_existing + $skip_closed_pr + $R.skipped + $resumes[0].skipped)
  }
JQ
  jq -n --slurpfile decision "$work_dir/decision.json" \
    --slurpfile linear "$work_dir/linear.json" \
    --slurpfile tasks "$work_dir/tasks.json" \
    --slurpfile pulls "$work_dir/pulls.json" \
    --slurpfile retries "$work_dir/retries.json" \
    --slurpfile resumes "$work_dir/resumes.json" \
    --slurpfile closures "$work_dir/closures.json" \
    --slurpfile notices "$work_dir/notices.json" \
    --argjson resume_places "$resume_places" \
    --argjson free "$free_places" \
    --argjson review_retries "$review_retries" \
    --arg repo "$repo_url" \
    "$jq_program" >"$work_dir/plan.json" || {
    warn "the plan could not be built"
    errors=$((errors + 1))
      return 1
  }
  return 0
}

# Les prompts sont ajoutés après le plan : les consignes ne sont téléchargées
# que lorsqu'il y a une création à faire.
build_prompts() {
  jq --arg code "$code_instruction" \
    --arg other "$other_consigne" \
    --arg rev "$review_consigne" \
    --arg corr "$correction_consigne" \
    --arg suffix "$consigne_suffix" \
    --arg resume "$resume_consigne" '
    .resumes |= map(. as $s
      | .prompt = ($resume | gsub("\\bN\\b(?![^ ,.;:)])"; ($s.prNumber | tostring))
                   | split("IDENTIFIANT") | join($s.identifier)
                   | split("REPO") | join($s.repo)))
    | .tasks |= map(. as $t
      | .prompt = ($t.identifier + "\n" + ($t.url // "") + "\n\n<ticket>\n"
                   + ($t.description // "") + "\n</ticket>\n\n"
                   + (if $t.main
                      then ($code | split("(IDENTIFIANT)") | join("(" + $t.identifier + ")"))
                      else ($other | split("IDENTIFIANT") | join($t.identifier)
                            | split("REPO") | join($t.repo))
                      end)))
    | .reviews |= map(. as $r
      | .prompt = (($rev | gsub("\\bN\\b"; ($r.prNumber | tostring))) + "\n\n" + $suffix))
    | .fixes |= map(. as $f
      | .prompt = (($corr | gsub("\\bN\\b"; ($f.prNumber | tostring))) + "\n\n" + $suffix))
  ' "$work_dir/plan.json" >"$work_dir/plan.tmp"
  mv "$work_dir/plan.tmp" "$work_dir/plan.json"
}

plan_count() {
  jq -r "[.tasks, .reviews, .fixes, .resumes | length] | add" "$work_dir/plan.json"
}

# Toute action à créer, reprises et annulations comprises.
plan_count_all() {
  jq -r '[.tasks, .reviews, .fixes, .resumes, .retries, .cancellations, .closures]
         | map(if type == "array" then length else 0 end) | add' \
    "$work_dir/plan.json"
}

remove_from_plan() {
  local section=$1 name=$2
  jq --arg s "$section" --arg n "$name" '.[$s] |= map(select(.name != $n))' \
    "$work_dir/plan.json" >"$work_dir/plan.tmp"
  mv "$work_dir/plan.tmp" "$work_dir/plan.json"
}

add_skip() {
  jq --arg id "$1" --arg reason "$2" \
    '.skipped += [{id: $id, reason: $reason}]' \
    "$work_dir/plan.json" >"$work_dir/plan.tmp"
  mv "$work_dir/plan.tmp" "$work_dir/plan.json"
}

# --- écritures ----------------------------------------------------------------

refresh_task_names() {
  if ! http_request GET "$api_url/api/tasks?limit=$TASKS_LIMIT" "$work_dir/optio-headers"; then
    api_error "Optio" "$HTTP_ERROR"
    return 1
  fi
  task_names="$(jq -c '[if type == "array" then .[]
                             elif (.tasks? | type) == "array" then .tasks[]
                             else empty end | (.title // "")]' "$HTTP_BODY")"
  return 0
}

# L'état réel des travaux est relu avant une reprise : la tâche peut avoir
# changé entre la lecture initiale et l'application du plan.
refresh_task_states() {
  if ! http_request GET "$api_url/api/tasks?limit=$TASKS_LIMIT" "$work_dir/optio-headers"; then
    api_error "Optio" "$HTTP_ERROR"
    return 1
  fi
  if ! jq -e . "$HTTP_BODY" >/dev/null 2>&1; then
    api_error "Optio" "the response is not JSON"
    return 1
  fi
  jq 'if type == "array" then . elif (.tasks? | type) == "array" then .tasks else [] end' \
    "$HTTP_BODY" >"$work_dir/tasks-now.json"
  return 0
}

# Une reprise n'a lieu que si la tâche est toujours en échec, encore utile et
# sous son plafond. La raison du refus est écrite sur la sortie standard ; le
# code de retour vaut 0 quand la reprise est refusée.
retry_blocked_reason() {
  local entry=$1 id task state number kind sha ceiling count own
  id="$(jq -r '.id' <<<"$entry")"
  kind="$(jq -r '.kind' <<<"$entry")"
  ceiling="$(jq -r '.ceiling' <<<"$entry")"
  task="$(jq -c --arg id "$id" '[.[] | select((.id | tostring) == $id)] | .[0] // empty' \
    "$work_dir/tasks-now.json")"
  if [ -z "$task" ]; then
    printf '%s' "la tâche n'existe plus"
    return 0
  fi
  state="$(jq -r '(.state // "") | ascii_downcase' <<<"$task")"
  if [ "$state" != "failed" ]; then
    printf '%s' "la tâche n'est plus en échec"
    return 0
  fi
  if [ "$kind" = "ticket" ]; then
    number="$(jq -r '(.prNumber // null) | if . == null or . == 0 then "" else tostring end' <<<"$task")"
    own="$(jq -r --arg main "$repo_url" '
      def norm: (ascii_downcase | sub("/+$"; "") | sub("\\.git$"; "") | sub("/+$"; ""));
      ((.repoUrl // "") | norm) as $u | $u == "" or $u == ($main | norm)' <<<"$task")"
    if [ -n "$number" ] && [ "$own" = true ]; then
      if pr_is_open "$number"; then
        printf '%s' "la tâche a déjà une PR ouverte"
      else
        printf '%s' "PR fermée ou mergée"
      fi
      return 0
    fi
    if [ -n "$number" ] || [ -n "$(jq -r '.prUrl // ""' <<<"$task")" ]; then
      printf '%s' "la tâche a déjà une PR"
      return 0
    fi
  else
    number="$(jq -r '.prNumber' <<<"$entry")"
    sha="$(jq -r '.sha8 // ""' <<<"$entry")"
    if ! pr_is_open "$number"; then
      printf '%s' "PR fermée ou mergée"
      return 0
    fi
    if [ -n "$sha" ] && ! jq -e --arg n "$number" --arg sha "$sha" \
      'any(.[]; (.number | tostring) == $n and (((.head.sha // "") | .[0:8]) == $sha))' \
      "$work_dir/pulls.json" >/dev/null; then
      printf '%s' "la PR a une nouvelle tête"
      return 0
    fi
  fi
  count="$(jq -r '(.retryCount // 0) | if type == "number" then . else 0 end' <<<"$task")"
  if [ "$count" -ge "$ceiling" ]; then
    printf '%s' "reprise au plafond"
    return 0
  fi
  return 1
}

create_task() {
  local name=$1 prompt=$2 model=$3 repo=${4:-$repo_url}
  jq -n --arg title "$name" --arg prompt "$prompt" --arg repo "$repo" \
    --arg model "$model" \
    '{title: $title, prompt: $prompt, repoUrl: $repo, owner: "me",
      autoMerge: false, autoResume: false,
      metadata: {agentOptions: {claudeModel: $model,
                                 claudeContextWindow: "200k",
                                 claudeEffort: "medium"}}}' \
    >"$work_dir/create.json"
  if ! http_request POST "$api_url/api/tasks" "$work_dir/optio-headers" "$work_dir/create.json"; then
    api_error "Optio" "$HTTP_ERROR"
    return 1
  fi
  return 0
}

post_action() {
  # post_action <chemin> <identifiant>
  local path=$1 id=$2
  printf '%s' '{}' >"$work_dir/empty.json"
  if ! http_request POST "$api_url/api/tasks/$id/$path" "$work_dir/optio-headers" "$work_dir/empty.json"; then
    api_error "Optio" "$HTTP_ERROR"
    return 1
  fi
  return 0
}

# L'état réel des PR est relu avant les créations de revue et de correction.
recheck_pr_candidates() {
  local section entry number
  for section in reviews fixes; do
    jq -c ".${section}[]" "$work_dir/plan.json" >"$work_dir/recheck.ndjson"
    while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      number="$(jq -r '.prNumber' <<<"$entry")"
      if ! pr_is_open "$number"; then
        remove_from_plan "$section" "$(jq -r '.name' <<<"$entry")"
        add_skip "PR-$number" "PR fermée ou mergée"
      fi
    done <"$work_dir/recheck.ndjson"
  done
  # Une PR d'un autre dépôt sortie de la liste d'Optio n'est plus reprise.
  jq -n --slurpfile prs "$work_dir/open-prs.json" --slurpfile plan "$work_dir/plan.json" '
    [$prs[0][] | .url] as $open
    | $plan[0]
    | [.resumes[] | select(.prUrl as $u | ($open | index($u)) == null)] as $gone
    | .resumes -= $gone
    | .skipped += [$gone[] | {id: .name, reason: "PR fermée ou mergée"}]' \
    >"$work_dir/plan.tmp"
  mv "$work_dir/plan.tmp" "$work_dir/plan.json"
}

# Linear d'abord, puis l'annulation : une écriture refusée laisse la tâche en
# place pour le passage suivant. Le commentaire précède le changement d'état.
apply_closure() {
  local entry=$1 id
  id="$(jq -r '.taskId' <<<"$entry")"
  refresh_task_states || return 1
  jq -e --arg id "$id" \
    'any(.[]; (.id | tostring) == $id and ((.state // "") | ascii_downcase) == "needs_attention")' \
    "$work_dir/tasks-now.json" >/dev/null || return 1
  if [ "$(jq -r '.comment // ""' <<<"$entry")" != "" ]; then
    linear_comment "$(jq -r '.issueId' <<<"$entry")" "$(jq -r '.comment' <<<"$entry")" || return 1
  fi
  if [ "$(jq -r '.done' <<<"$entry")" = true ]; then
    jq -n --argjson e "$entry" '{
      query: "mutation OptioDone($id: String!, $stateId: String!) { issueUpdate(id: $id, input: {stateId: $stateId}) { success } }",
      variables: {id: $e.issueId, stateId: $e.stateId}}' >"$work_dir/linear-write.json"
    linear_send "$work_dir/linear-write.json" || return 1
  fi
  post_action cancel "$id"
}

linear_comment() {
  jq -n --arg issue "$1" --arg body "$2" '{
    query: "mutation OptioNote($issueId: String!, $body: String!) { commentCreate(input: {issueId: $issueId, body: $body}) { success } }",
    variables: {issueId: $issue, body: $body}}' >"$work_dir/linear-write.json"
  linear_send "$work_dir/linear-write.json"
}

apply_followups() {
  local entry
  jq -c '.closures[]' "$work_dir/plan.json" >"$work_dir/apply-closures.ndjson"
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    if apply_closure "$entry"; then
      closed=$((closed + 1))
    else
      remove_from_plan closures "$(jq -r '.name' <<<"$entry")"
      add_skip "$(jq -r '.name' <<<"$entry")" "clôture non faite : état changé ou écriture refusée"
    fi
  done <"$work_dir/apply-closures.ndjson"
  jq -c '.notices[]' "$work_dir/plan.json" >"$work_dir/apply-notices.ndjson"
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    if linear_comment "$(jq -r '.issueId' <<<"$entry")" "$(jq -r '.body' <<<"$entry")"; then
      notices=$((notices + 1))
    fi
  done <"$work_dir/apply-notices.ndjson"
}

# Une création ou une reprise refusée par l'API est comptée et n'arrête pas les
# suivantes ; une lecture impossible arrête le passage.
apply_creations() {
  # apply_creations <section> ; le compteur est tenu par l'appelant.
  local section=$1 entry name prompt model repo
  applied=0
  jq -c ".${section}[]" "$work_dir/plan.json" >"$work_dir/apply-$section.ndjson"
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    name="$(jq -r '.name' <<<"$entry")"
    prompt="$(jq -r '.prompt' <<<"$entry")"
    model="$(jq -r '.model // "text/strong"' <<<"$entry")"
    repo="$(jq -r --arg main "$repo_url" '.repoUrl // $main' <<<"$entry")"
    if ! refresh_task_names; then return 1; fi
    if jq -e --arg n "$name" 'index($n) != null' <<<"$task_names" >/dev/null; then
      remove_from_plan "$section" "$name"
      add_skip "$name" "travail existant : $name"
      continue
    fi
    if ! create_task "$name" "$prompt" "$model" "$repo"; then
      remove_from_plan "$section" "$name"
      add_skip "$name" "création refusée par Optio : $HTTP_ERROR"
      continue
    fi
    applied=$((applied + 1))
  done <"$work_dir/apply-$section.ndjson"
  return 0
}

apply_retries() {
  # apply_retries <filtre jq sur la reprise>
  local filter=$1 entry name id reason
  jq -c ".retries[] | select($filter)" "$work_dir/plan.json" >"$work_dir/apply-retries.ndjson"
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    id="$(jq -r '.id' <<<"$entry")"
    name="$(jq -r '.name' <<<"$entry")"
    if ! refresh_task_states; then return 1; fi
    reason=""
    if reason="$(retry_blocked_reason "$entry")"; then
      remove_from_plan retries "$name"
      add_skip "$name" "$reason"
      continue
    fi
    if ! post_action retry "$id"; then
      remove_from_plan retries "$name"
      add_skip "$name" "reprise refusée par Optio : $HTTP_ERROR"
      continue
    fi
    retried=$((retried + 1))
  done <"$work_dir/apply-retries.ndjson"
  return 0
}

apply_plan() {
  local entry name id

  # L'état réel des PR est relu juste avant les écritures.
  if [ "$(plan_count_all)" != "0" ]; then
    if ! fetch_pr_state; then return 1; fi
    recheck_pr_candidates
  fi

  # Revues et corrections d'abord, puis les tickets.
  apply_retries '.kind != "ticket"' || return 1
  apply_creations reviews || return 1
  reviews_created=$applied
  apply_creations fixes || return 1
  fixes_created=$applied
  apply_creations resumes || return 1
  resumed=$applied
  apply_retries '.kind == "ticket"' || return 1
  apply_creations tasks || return 1
  created=$applied

  # Annulations : travaux d'une PR fermée ou mergée, attentes sans objet.
  jq -c '.cancellations[]' "$work_dir/plan.json" >"$work_dir/apply-cancellations.ndjson"
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    id="$(jq -r '.id' <<<"$entry")"
    if [ "$(jq -r '.requires_state // ""' <<<"$entry")" = "needs_attention" ]; then
      if ! refresh_task_states; then return 1; fi
      if ! jq -e --arg id "$id" \
        'any(.[]; (.id | tostring) == $id and ((.state // "") | ascii_downcase) == "needs_attention")' \
        "$work_dir/tasks-now.json" >/dev/null; then
        name="$(jq -r '.name' <<<"$entry")"
        remove_from_plan cancellations "$name"
        add_skip "$name" "la tâche n'attend plus d'intervention"
        continue
      fi
    fi
    if ! post_action cancel "$id"; then continue; fi
    cancelled=$((cancelled + 1))
  done <"$work_dir/apply-cancellations.ndjson"

  apply_followups
  return 0
}

# --- sortie -------------------------------------------------------------------

emit_output() {
  local plan="$work_dir/plan.json"
  if [ ! -f "$plan" ]; then
    jq -n --argjson apply "$apply_mode" \
      '{mode: (if $apply then "apply" else "dry-run" end), apply: $apply,
        tasks: [], reviews: [], fixes: [], resumes: [], closures: [], notices: [],
        retries: [], cancellations: [],
        skipped: []}' >"$plan"
  fi
  skipped="$(jq '.skipped | length' "$plan")"
  jq -c --argjson apply "$apply_mode" '
    {mode: (if $apply then "apply" else "dry-run" end), apply: $apply,
     tasks: .tasks, reviews: .reviews, fixes: .fixes, resumes: .resumes,
     closures: .closures, notices: .notices, retries: .retries,
     cancellations: .cancellations, skipped: .skipped}
  ' "$plan"
  jq --compact-output -n --argjson tickets_read "$tickets_read" --argjson created "$created" \
    --argjson reviews "$reviews_created" --argjson fixes "$fixes_created" \
    --argjson retried "$retried" --argjson cancelled "$cancelled" \
    --argjson skipped "$skipped" --argjson errors "$errors" \
    --argjson resumed "$resumed" --argjson closed "$closed" --argjson notices "$notices" \
    '{tickets_read: $tickets_read, created: $created, reviews: $reviews,
      fixes: $fixes, retried: $retried, cancelled: $cancelled,
      skipped: $skipped, errors: $errors, resumed: $resumed, closed: $closed,
      notices: $notices}'
}

main() {
  parse_args "$@"
  check_environment
  work_dir="$(mktemp -d)"
  trap 'rm -rf "$work_dir"' EXIT
  acquire_lock

  if ! fetch_linear; then
    emit_output
    return 1
  fi
  if ! fetch_optio_tasks; then
    emit_output
    return 1
  fi
  fetch_optio_repos
  if ! fetch_pr_state; then
    emit_output
    return 1
  fi
  if ! plan_resumes; then
    emit_output
    return 1
  fi
  if ! plan_retries; then
    emit_output
    return 1
  fi
  count_places
  if ! run_decision; then
    emit_output
    return 1
  fi
  plan_followups
  if ! build_plan; then
    emit_output
    return 1
  fi
  if [ "$(plan_count)" != "0" ]; then
    if ! load_instructions; then
      emit_output
      return 1
    fi
    if [ -z "$resume_consigne" ] && [ "$(jq '.resumes | length' "$work_dir/plan.json")" != "0" ]; then
      warn "the instructions do not hold the resume passage: no pull request is resumed"
      errors=$((errors + 1))
      jq '.resumes = []' "$work_dir/plan.json" >"$work_dir/plan.tmp"
      mv "$work_dir/plan.tmp" "$work_dir/plan.json"
    fi
    build_prompts
  fi
  if [ "$apply_mode" = true ]; then
    if ! apply_plan; then
      emit_output
      return 1
    fi
  fi
  emit_output
  if [ "$errors" -gt 0 ]; then
    return 1
  fi
  return 0
}

main "$@"
