#!/usr/bin/env bash
# PLT-527 : orchestrateur Optio sans LLM.
#
# Pourquoi : la prise des tickets était faite par un modèle toutes les 10 min
# alors que toutes ses règles sont déterministes. Ce script les applique :
# il lit Linear (une seule requête filtrée), lit les travaux Optio, décide avec
# scripts/optio/select-actions.sh, relit l'état réel des PR sur GitHub et crée
# les tâches de ticket, de revue et de correction.
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
#  "skipped":n,"errors":n}.
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
readonly DEFAULT_SLOTS=10
readonly PER_PAGE=100
readonly MAX_PAGES=5

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

apply_mode=false
slots=$DEFAULT_SLOTS
instructions_file=""
select_actions_file=""
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

HTTP_CODE=""
HTTP_BODY=""
HTTP_ERROR=""

code_instruction=""
review_consigne=""
correction_consigne=""
consigne_suffix=""

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
  if ! http_request GET "$api_url/api/tasks?limit=200" "$work_dir/optio-headers"; then
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
        prUrl: (.prUrl // ""),
        prNumber: (.prNumber // null),
        prChecksStatus: (.prChecksStatus // ""),
        conflicts: (.conflicts // false)
      }]' "$work_dir/tasks.json" >"$work_dir/work.json"
  return 0
}

# L'état réel des PR, relu sur GitHub : l'état mis en cache par Optio
# (prState) n'est jamais utilisé pour décider.
fetch_pr_state() {
  write_headers "$work_dir/github-headers" \
    "Accept: application/vnd.github+json" \
    "User-Agent: kube-ops-optio-dispatch"
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

pr_is_open() {
  local number=$1
  jq -e --arg n "$number" 'any(.[]; (.number | tostring) == $n)' "$work_dir/pulls.json" >/dev/null
}

# --- décision ----------------------------------------------------------------

# Le script de sélection est celui du dépôt ; le travail de commande n'a pas de
# dépôt cloné, il est donc téléchargé depuis la branche main quand il est
# absent.
resolve_select_actions() {
  if [ -n "$select_actions_file" ]; then
    if [ -f "$select_actions_file" ]; then
      printf '%s' "$select_actions_file"
      return 0
    fi
    download_to "$GITHUB_RAW_BASE/$SELECT_ACTIONS_PATH" "$work_dir/select-actions.sh"
    printf '%s' "$work_dir/select-actions.sh"
    return 0
  fi
  if [ -f "$script_dir/select-actions.sh" ]; then
    printf '%s' "$script_dir/select-actions.sh"
    return 0
  fi
  download_to "$GITHUB_RAW_BASE/$SELECT_ACTIONS_PATH" "$work_dir/select-actions.sh"
  printf '%s' "$work_dir/select-actions.sh"
  return 0
}

download_to() {
  local url=$1 target=$2
  if ! http_request GET "$url" "$work_dir/github-headers"; then
    api_error "GitHub" "$HTTP_ERROR"
    return 1
  fi
  cp "$HTTP_BODY" "$target"
  return 0
}

run_decision() {
  local select_actions
  if ! select_actions="$(resolve_select_actions)"; then
    return 1
  fi
  if [ ! -r "$select_actions" ]; then
    api_error "Optio" "the selection script is not readable: $select_actions"
    return 1
  fi
  if ! bash "$select_actions" \
    --linear "$work_dir/linear.json" \
    --work "$work_dir/work.json" \
    --slots "$slots" >"$work_dir/decision.json" 2>"$work_dir/decision-error"; then
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
    [ -z "$correction_consigne" ] || [ -z "$consigne_suffix" ]; then
    warn "the instructions do not hold the four expected passages"
    errors=$((errors + 1))
      return 1
  fi
  return 0
}

download_instructions() {
  local target=$1
  if ! http_request GET "$GITHUB_REPO_API/contents/$INSTRUCTIONS_PATH?ref=main" \
    "$work_dir/github-headers"; then
    api_error "GitHub" "$HTTP_ERROR"
    return 1
  fi
  local content
  content="$(jq -r '.content // ""' "$HTTP_BODY" 2>/dev/null || echo "")"
  if [ -n "$content" ]; then
    if ! printf '%s' "$content" | base64 -d >"$target" 2>/dev/null; then
      warn "the instructions of GitHub are not readable"
      errors=$((errors + 1))
          return 1
    fi
    return 0
  fi
  local download_url
  download_url="$(jq -r '.download_url // ""' "$HTTP_BODY" 2>/dev/null || echo "")"
  if [ -z "$download_url" ]; then
    warn "GitHub did not return the instructions"
    errors=$((errors + 1))
      return 1
  fi
  if ! http_request GET "$download_url" "$work_dir/github-headers"; then
    api_error "GitHub" "$HTTP_ERROR"
    return 1
  fi
  cp "$HTTP_BODY" "$target"
  return 0
}

# Le fichier des consignes contient quatre passages délimités : la consigne de
# code (entre guillemets, après « puis : »), la consigne REVUE et la consigne
# CORRECTION (entre <<< et >>>), et la phrase à ajouter à la fin de chacune.
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
  local current="" line
  while IFS= read -r line; do
    case "$line" in
      "@@CODE@@") current="code"; continue ;;
      "@@REVUE@@") current="review"; continue ;;
      "@@CORRECTION@@") current="fix"; continue ;;
      "@@SUFFIX@@") current="suffix"; continue ;;
    esac
    case "$current" in
      code) code_instruction="${code_instruction:+$code_instruction }$line" ;;
      review) review_consigne="${review_consigne:+$review_consigne }$line" ;;
      fix) correction_consigne="${correction_consigne:+$correction_consigne }$line" ;;
      suffix) consigne_suffix="${consigne_suffix:+$consigne_suffix }$line" ;;
    esac
  done <"$work_dir/consignes.txt"
  return 0
}

# --- plan --------------------------------------------------------------------

build_plan() {
  local jq_program
  IFS= read -r -d '' jq_program <<'JQ' || true
def lc: ascii_downcase;
def is_active:
  ((.state // "") | lc) as $s
  | ($s != "completed" and $s != "cancelled" and $s != "canceled" and $s != "failed");
def has_pr:
  (((.prUrl // "") | tostring) != "")
  or ((((.prNumber // null) | tostring) != "null")
      and (((.prNumber // null) | tostring) != "")
      and (((.prNumber // null) | tostring) != "0"));
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
| ([$T[]
    | select(((.title // "") | test("^\\[[A-Za-z][A-Za-z0-9]*-[0-9]+\\]")))
    | select(((.title // "") | startswith("[REVUE")) | not)
    | select(((.title // "") | startswith("[CORRIGE")) | not)
    | select(((.state // "") | lc) == "failed")
    | select(has_pr | not)
    | {id: (.id | tostring), name: (.title // ""),
       retryCount: ((.retryCount // 0)
                    | if type == "number" then . else (try tonumber catch 0) end)}]) as $failed
| ([$failed[] | select(.retryCount < $max_retries)]) as $retryable
| ([$failed[] | select(.retryCount >= $max_retries)
    | {id: .name,
       reason: ("reprise au plafond : " + (.retryCount | tostring) + " reprises déjà faites")}]) as $skip_ceiling
| ([$T[]
    | select(is_active)
    | select(((.title // "") | test("^\\[(REVUE|CORRIGE) PR-[0-9]+")))
    | . as $w
    | ((title_pr_number) // (.prNumber // null)) as $n
    | select($n != null)
    | (open_pr($P; $n)) as $p
    | select($p == null)
    | {id: (.id | tostring), name: ($w.title // ""), prNumber: $n,
       reason: "PR fermée ou mergée"}]) as $cancels
| ([$cand_tasks[], $cand_reviews[], $cand_fixes[]
    | . as $c
    | select(.name as $n | ($names | index($n)) != null)
    | {id: .name, reason: ("travail existant : " + .name)}]) as $skip_existing
| {
    tasks: [$cand_tasks[] | . as $c | select(.name as $n | ($names | index($n)) == null)],
    reviews: [$cand_reviews[] | . as $c | select(.name as $n | ($names | index($n)) == null)],
    fixes: [$cand_fixes[] | . as $c | select(.name as $n | ($names | index($n)) == null)],
    retries: $retryable,
    cancellations: $cancels,
    skipped: ((($d.skipped // []) | map({id: (.id // ""), reason: (.reason // "")}))
              + $skip_existing + $skip_closed_pr + $skip_ceiling)
  }
JQ
  jq -n --slurpfile decision "$work_dir/decision.json" \
    --slurpfile linear "$work_dir/linear.json" \
    --slurpfile tasks "$work_dir/tasks.json" \
    --slurpfile pulls "$work_dir/pulls.json" \
    --argjson max_retries "$MAX_RETRIES" \
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
    --arg rev "$review_consigne" \
    --arg corr "$correction_consigne" \
    --arg suffix "$consigne_suffix" '
    .tasks |= map(. as $t
      | .prompt = ($t.identifier + "\n" + ($t.url // "") + "\n\n<ticket>\n"
                   + ($t.description // "") + "\n</ticket>\n\n"
                   + ($code | split("(IDENTIFIANT)") | join("(" + $t.identifier + ")"))))
    | .reviews |= map(. as $r
      | .prompt = (($rev | gsub("\\bN\\b"; ($r.prNumber | tostring))) + "\n\n" + $suffix))
    | .fixes |= map(. as $f
      | .prompt = (($corr | gsub("\\bN\\b"; ($f.prNumber | tostring))) + "\n\n" + $suffix))
  ' "$work_dir/plan.json" >"$work_dir/plan.tmp"
  mv "$work_dir/plan.tmp" "$work_dir/plan.json"
}

plan_count() {
  jq -r "[(.tasks | length), (.reviews | length), (.fixes | length)] | add" "$work_dir/plan.json"
}

# Toute action à créer, reprises et annulations comprises.
plan_count_all() {
  jq -r '[.tasks, .reviews, .fixes, .retries, .cancellations] | map(if type == "array" then length else 0 end) | add' \
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
  if ! http_request GET "$api_url/api/tasks?limit=200" "$work_dir/optio-headers"; then
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
  if ! http_request GET "$api_url/api/tasks?limit=200" "$work_dir/optio-headers"; then
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

# Une reprise n'a lieu que si la tâche est toujours en échec, sans PR et sous
# le plafond des reprises. La raison du refus est écrite sur la sortie
# standard ; le code de retour vaut 0 quand la reprise est refusée.
retry_blocked_reason() {
  local id=$1 task state number count
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
  number="$(jq -r '(.prNumber // null) | if . == null then "" else tostring end' <<<"$task")"
  if [ -n "$number" ] && [ "$number" != "0" ]; then
    if pr_is_open "$number"; then
      printf '%s' "la tâche a déjà une PR ouverte"
    else
      printf '%s' "PR fermée ou mergée"
    fi
    return 0
  fi
  count="$(jq -r '(.retryCount // 0) | if type == "number" then . else 0 end' <<<"$task")"
  if [ "$count" -ge "$MAX_RETRIES" ]; then
    printf '%s' "reprise au plafond"
    return 0
  fi
  return 1
}

create_task() {
  local name=$1 prompt=$2 model=$3
  jq -n --arg title "$name" --arg prompt "$prompt" --arg repo "$repo_url" \
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
}

apply_plan() {
  local entry name prompt model number id

  # Tâches de ticket.
  jq -c '.tasks[]' "$work_dir/plan.json" >"$work_dir/apply-tasks.ndjson"
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    name="$(jq -r '.name' <<<"$entry")"
    prompt="$(jq -r '.prompt' <<<"$entry")"
    model="$(jq -r '.model' <<<"$entry")"
    if ! refresh_task_names; then return 1; fi
    if jq -e --arg n "$name" 'index($n) != null' <<<"$task_names" >/dev/null; then
      remove_from_plan tasks "$name"
      add_skip "$name" "travail existant : $name"
      continue
    fi
    if ! create_task "$name" "$prompt" "$model"; then return 1; fi
    created=$((created + 1))
  done <"$work_dir/apply-tasks.ndjson"

  # Revues, corrections et reprises : l'état réel des PR est relu juste avant.
  if [ "$(plan_count_all)" != "0" ]; then
    if ! fetch_pr_state; then return 1; fi
    recheck_pr_candidates
  fi

  jq -c '.reviews[]' "$work_dir/plan.json" >"$work_dir/apply-reviews.ndjson"
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    name="$(jq -r '.name' <<<"$entry")"
    prompt="$(jq -r '.prompt' <<<"$entry")"
    if ! refresh_task_names; then return 1; fi
    if jq -e --arg n "$name" 'index($n) != null' <<<"$task_names" >/dev/null; then
      remove_from_plan reviews "$name"
      add_skip "$name" "travail existant : $name"
      continue
    fi
    if ! create_task "$name" "$prompt" "text/strong"; then return 1; fi
    reviews_created=$((reviews_created + 1))
  done <"$work_dir/apply-reviews.ndjson"

  jq -c '.fixes[]' "$work_dir/plan.json" >"$work_dir/apply-fixes.ndjson"
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    name="$(jq -r '.name' <<<"$entry")"
    prompt="$(jq -r '.prompt' <<<"$entry")"
    if ! refresh_task_names; then return 1; fi
    if jq -e --arg n "$name" 'index($n) != null' <<<"$task_names" >/dev/null; then
      remove_from_plan fixes "$name"
      add_skip "$name" "travail existant : $name"
      continue
    fi
    if ! create_task "$name" "$prompt" "text/strong"; then return 1; fi
    fixes_created=$((fixes_created + 1))
  done <"$work_dir/apply-fixes.ndjson"

  # Reprises des tâches échouées sans PR : l'état réel est relu avant.
  jq -c '.retries[]' "$work_dir/plan.json" >"$work_dir/apply-retries.ndjson"
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    id="$(jq -r '.id' <<<"$entry")"
    name="$(jq -r '.name' <<<"$entry")"
    if ! refresh_task_states; then return 1; fi
    reason=""
    if reason="$(retry_blocked_reason "$id")"; then
      remove_from_plan retries "$name"
      add_skip "$name" "$reason"
      continue
    fi
    if ! post_action retry "$id"; then return 1; fi
    retried=$((retried + 1))
  done <"$work_dir/apply-retries.ndjson"

  # Annulation des revues et corrections d'une PR fermée ou mergée.
  jq -c '.cancellations[]' "$work_dir/plan.json" >"$work_dir/apply-cancellations.ndjson"
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    id="$(jq -r '.id' <<<"$entry")"
    if ! post_action cancel "$id"; then return 1; fi
    cancelled=$((cancelled + 1))
  done <"$work_dir/apply-cancellations.ndjson"

  return 0
}

# --- sortie -------------------------------------------------------------------

emit_output() {
  local plan="$work_dir/plan.json"
  if [ ! -f "$plan" ]; then
    jq -n --argjson apply "$apply_mode" \
      '{mode: (if $apply then "apply" else "dry-run" end), apply: $apply,
        tasks: [], reviews: [], fixes: [], retries: [], cancellations: [],
        skipped: []}' >"$plan"
  fi
  skipped="$(jq '.skipped | length' "$plan")"
  jq -c --argjson apply "$apply_mode" '
    {mode: (if $apply then "apply" else "dry-run" end), apply: $apply,
     tasks: .tasks, reviews: .reviews, fixes: .fixes, retries: .retries,
     cancellations: .cancellations, skipped: .skipped}
  ' "$plan"
  jq --compact-output -n --argjson tickets_read "$tickets_read" --argjson created "$created" \
    --argjson reviews "$reviews_created" --argjson fixes "$fixes_created" \
    --argjson retried "$retried" --argjson cancelled "$cancelled" \
    --argjson skipped "$skipped" --argjson errors "$errors" \
    '{tickets_read: $tickets_read, created: $created, reviews: $reviews,
      fixes: $fixes, retried: $retried, cancelled: $cancelled,
      skipped: $skipped, errors: $errors}'
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
  if ! fetch_pr_state; then
    emit_output
    return 1
  fi
  if ! run_decision; then
    emit_output
    return 1
  fi
  if ! build_plan; then
    emit_output
    return 1
  fi
  if [ "$(plan_count)" != "0" ]; then
    if ! load_instructions; then
      emit_output
      return 1
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
