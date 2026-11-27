#!/usr/bin/env bash
# PLT-540 : rapport Optio sans modèle de ce que chaque tâche a fait et de ce
# qu'elle demande.
#
# Pourquoi : la vue « Needs you » d'Optio affiche un titre et un motif
# générique, jamais le résultat du travail. Paul ne voit pas ce que font les
# agents. Ce script relit la liste des tâches de l'API Optio et rend un rapport
# Markdown : une ligne par tâche (état, ticket, PR, motif, résumé du résultat,
# tokens, coût) et, en tête, les compteurs et la liste des tâches qui
# demandent une intervention.
#
# Le rapport est déterministe : aucun modèle n'intervient, le script ne fait
# que relire des champs. Sans modèle, pas de résumé inventé : ce qui n'est pas
# dans l'API n'est pas dans le rapport.
#
# Usage :
#   bash scripts/optio/factory-report.sh [--hours N] [--input FILE]
#                                         [--api-url URL]
#
# Entrées :
#   --hours N       période couverte par le rapport, en heures (24 par
#                   défaut). Une tâche appartient à la période quand sa
#                   dernière activité connue (updatedAt, sinon createdAt) est
#                   postérieure au début de la période ; une tâche sans
#                   horodatage lisible est conservée (son activité est
#                   inconnue, pas absente).
#   --input FILE    liste de tâches JSON locale, au lieu de l'API (tests,
#                   relecture hors réseau). Deux formes acceptées : un
#                   tableau de tâches, ou un objet {"tasks": [...]}.
#   --api-url URL   base de l'API Optio
#                   (défaut : http://optio-api.optio.svc.cluster.local:4000).
#
# Environnement (identique à dispatch.sh) :
#   OPTIO_API_TOKEN      jeton de l'API Optio (en-tête Authorization: Bearer) ;
#   OPTIO_API_URL        base de l'API Optio ;
#   OPTIO_WORKSPACE_ID   espace de travail (en-tête x-workspace-id, facultatif).
#
# Sortie : le rapport Markdown sur stdout. Une seule requête, en lecture :
# GET /api/tasks?limit=200. Aucune écriture, aucune valeur de jeton affichée.
#
# Codes de retour : 0 succès, 1 erreur de lecture ou de données, 2 usage ou
# configuration.
set -euo pipefail

readonly DEFAULT_API_URL="http://optio-api.optio.svc.cluster.local:4000"
readonly DEFAULT_HOURS=24
readonly TASK_LIMIT=200
readonly SUMMARY_MAX=120
readonly TITLE_MAX=60

hours=$DEFAULT_HOURS
input_file=""
api_url_override=""

optio_token=""
workspace_id=""
api_url=$DEFAULT_API_URL
work_dir=""

usage() {
  cat <<'USAGE'
usage: optio/factory-report.sh [--hours N] [--input FILE] [--api-url URL]

  --hours N       période du rapport, en heures (24 par défaut)
  --input FILE    liste de tâches JSON locale, au lieu de l'API
  --api-url URL   base de l'API Optio
USAGE
}

warn() {
  echo "optio-factory-report: $*" >&2
}

die_usage() {
  warn "$*"
  usage >&2
  exit 2
}

# --- entrées -----------------------------------------------------------------

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --hours)
        [ "$#" -ge 2 ] || die_usage "--hours needs a number"
        hours=$2
        shift 2
        ;;
      --input)
        [ "$#" -ge 2 ] || die_usage "--input needs a file"
        input_file=$2
        shift 2
        ;;
      --api-url)
        [ "$#" -ge 2 ] || die_usage "--api-url needs an url"
        api_url_override=$2
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
  case "$hours" in
    '' | *[!0-9]*) die_usage "--hours must be a non-negative integer" ;;
  esac
}

# Le jeton n'est demandé que pour l'appel API : une liste locale se lit sans
# aucune variable d'environnement.
check_api_environment() {
  optio_token="${OPTIO_API_TOKEN:-}"
  [ -n "$optio_token" ] || die_usage "OPTIO_API_TOKEN is required"
  workspace_id="${OPTIO_WORKSPACE_ID:-}"
  api_url="${api_url_override:-${OPTIO_API_URL:-$DEFAULT_API_URL}}"
}

# --- lecture -----------------------------------------------------------------

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

# Une seule requête, en lecture : la liste des tâches.
fetch_tasks() {
  write_headers "$work_dir/optio-headers" \
    "Authorization: Bearer $optio_token" \
    "Content-Type: application/json"
  if [ -n "$workspace_id" ]; then
    printf 'x-workspace-id: %s\n' "$workspace_id" >>"$work_dir/optio-headers"
  fi
  local out="$work_dir/http-body" err="$work_dir/http-error"
  : >"$out"
  : >"$err"
  local code
  if ! code="$(curl -sS -o "$out" -w '%{http_code}' \
    -H "@$work_dir/optio-headers" \
    "$api_url/api/tasks?limit=$TASK_LIMIT" 2>"$err")"; then
    warn "the Optio API is unreachable: $(tr '\n' ' ' <"$err" | cut -c1-200)"
    return 1
  fi
  if ! [[ "$code" =~ ^2[0-9][0-9]$ ]]; then
    warn "the Optio API answered HTTP $code"
    return 1
  fi
  if ! jq -e . "$out" >/dev/null 2>&1; then
    warn "the Optio API did not answer JSON"
    return 1
  fi
  cp "$out" "$work_dir/tasks.json"
  return 0
}

# Une liste de tâches est un tableau, ou un objet qui porte un tableau
# "tasks" : c'est la forme de l'API. Toute autre forme est une erreur, pas une
# liste vide.
check_task_list() {
  local file=$1
  if ! jq -e . "$file" >/dev/null 2>&1; then
    warn "the task list is not JSON: $file"
    return 1
  fi
  if ! jq -e 'if type == "array" then true
              elif (type == "object" and (.tasks? | type) == "array") then true
              else false end' "$file" >/dev/null 2>&1; then
    warn "the task list is neither an array nor an object with a tasks array: $file"
    return 1
  fi
  return 0
}

# --- rapport -----------------------------------------------------------------

# Le rapport est rendu par jq : les champs sont lus tels quels, un champ absent
# s'affiche « inconnu », jamais zéro. Aucun résumé n'est inventé.
IFS= read -r -d '' jq_program <<'JQ' || true
def lc:
  ascii_downcase;

def norm_text:
  if . == null then ""
  elif type == "string" then .
  else tostring end;

def one_line:
  gsub("[\r\n\t]+"; " ") | gsub(" {2,}"; " ") | gsub("^ +"; "") | gsub(" +$"; "");

# Une cellule de tableau Markdown : une seule ligne, la barre verticale
# échappée. La barre oblique inverse est doublée d'abord : une barre
# verticale déjà échappée dans la source ne doit pas devenir un séparateur.
def md_cell:
  one_line | split("\\") | join("\\\\") | split("|") | join("\\|");

def trunc($n):
  if (length > $n) then ((.[0:($n - 1)] | gsub(" +$"; "")) + "…") else . end;

def as_int:
  if type == "number" then .
  elif type == "string" and test("^-?[0-9]+$") then tonumber
  else null end;

# Un horodatage ISO 8601 en secondes depuis l'époque. Les millisecondes et
# l'offset UTC explicite sont retirés ; une date illisible donne null.
def iso_epoch:
  (if type == "string" then . else "" end)
  | sub("\\.[0-9]+"; "")
  | sub("\\+00:00$"; "Z")
  | (try fromdateiso8601 catch null);

# La première capture d'une expression régulière sur une chaîne. match échoue
# sur une chaîne qui ne correspond pas : le résultat est vide, pas une erreur.
def first_match($re; $s):
  ([try ($s | match($re) | .captures[0].string) catch empty] | .[0]) // "";

# Le ticket : l'identifiant du fournisseur quand l'API le donne, sinon
# l'identifiant du titre (« [PLT-540] … »).
def ticket_of:
  (if ((.ticketExternalId? // "") | norm_text) != ""
   then (.ticketExternalId | norm_text)
   else first_match("\\[(?<id>[A-Za-z][A-Za-z0-9]*-[0-9]+)\\]";
                    ((.title? // "") | norm_text))
   end);

# La PR : le numéro quand l'API le donne, sinon celui déduit de l'URL.
def pr_of:
  ((.prNumber? // null) | as_int) as $n
  | if ($n != null and $n > 0) then "#" + ($n | tostring)
    else (first_match("/pull/(?<n>[0-9]+)"; ((.prUrl? // "") | norm_text))
          | if . == "" then "" else "#" + . end)
    end;

# Les tokens : le total quand les deux directions sont connues, une seule
# direction sinon, « inconnu » quand aucune ne l'est.
def tokens_of($in; $out):
  if $in == null and $out == null then "inconnu"
  elif $in == null then (($out | tostring) + " (out)")
  elif $out == null then (($in | tostring) + " (in)")
  else ((($in + $out) | tostring)
        + " (in " + ($in | tostring) + " / out " + ($out | tostring) + ")")
  end;

def norm_task:
  . as $t
  | (($t.state? // "") | norm_text | one_line | lc) as $state
  | (($t.updatedAt? // "") | norm_text | one_line) as $updated
  | (($t.createdAt? // "") | norm_text | one_line) as $created
  | (if $updated != "" then $updated elif $created != "" then $created else "" end) as $activity
  | (($t.inputTokens? // null) | as_int) as $in
  | (($t.outputTokens? // null) | as_int) as $out
  | (($t.costUsd? // "") | norm_text | one_line) as $cost
  | (($t.errorMessage? // "") | norm_text | one_line) as $reason
  | (($t.resultSummary? // "") | norm_text | one_line) as $summary
  | (($t | ticket_of) | one_line) as $ticket
  | (($t | pr_of) | one_line) as $pr
  | (($t.title? // "") | norm_text | one_line) as $title
  | {
      title: (if $title == "" then "inconnu" else ($title | md_cell) end),
      titleShort: (if $title == "" then "inconnu" else ($title | trunc($title_max) | md_cell) end),
      state: (if $state == "" then "inconnu" else $state end),
      ticket: (if $ticket == "" then "inconnu" else ($ticket | md_cell) end),
      pr: (if $pr == "" then "inconnu" else ($pr | md_cell) end),
      reason: (if $reason == "" then "inconnu" else ($reason | md_cell) end),
      summary: (if $summary == "" then "inconnu" else ($summary | trunc($summary_max) | md_cell) end),
      tokens: (tokens_of($in; $out)),
      cost: (if $cost == "" then "inconnu" else ("$" + $cost) end),
      activity: (if $activity == "" then "inconnu" else $activity end),
      epoch: ($activity | iso_epoch)
    };

def task_list:
  if type == "array" then .
  elif (type == "object" and (.tasks? | type) == "array") then .tasks
  else [] end;

(task_list) as $raw
| (now) as $now
| ($now - ($hours * 3600)) as $since
| ([$raw[] | norm_task]) as $rows
| ([$rows[] | select((.epoch == null) or (.epoch >= $since))]) as $kept
| ($kept | sort_by([-(.epoch // 0), .title])) as $ordered
| ($ordered | group_by(.state)
   | map({state: .[0].state, count: length})
   | sort_by([-(.count), .state])) as $states
| ([$kept[] | select(.tokens == "inconnu")] | length) as $without_tokens
| ([$ordered[] | select(.state == "needs_attention")]) as $attention
| ([
    "# Rapport Optio — " + ($hours | tostring) + " h",
    "",
    "Période : " + ($since | todate) + " → " + ($now | todate),
    "Source : " + $source,
    "",
    "## Résumé",
    "",
    "- Tâches : " + ($kept | length | tostring),
    "- Par état : "
      + (if ($states | length) == 0 then "aucune"
         else ($states | map(.state + " " + (.count | tostring)) | join(", "))
         end),
    "- Sans compte de tokens : " + ($without_tokens | tostring),
    "",
    "## Needs attention",
    ""
  ]
   + (if ($attention | length) == 0
      then ["Aucune tâche en needs_attention."]
      else ($attention
            | map("- " + (if .ticket == "inconnu" then .titleShort else .ticket end)
                  + (if .pr == "inconnu" then "" else " (" + .pr + ")" end)
                  + " — " + .reason))
      end)
   + ["", "## Tâches", ""]
   + (if ($ordered | length) == 0
      then ["Aucune tâche sur la période."]
      else ["| Tâche | État | Ticket | PR | Motif | Résultat | Tokens | Coût | Dernière activité |",
            "|---|---|---|---|---|---|---|---|---|"]
           + ($ordered
              | map("| " + .titleShort + " | " + .state + " | " + .ticket + " | "
                    + .pr + " | " + .reason + " | " + .summary + " | " + .tokens
                    + " | " + .cost + " | " + .activity + " |"))
      end)) as $lines
| $lines | join("\n")
JQ

render_report() {
  local file=$1 source=$2
  if ! jq -r \
    --argjson hours "$hours" \
    --argjson title_max "$TITLE_MAX" \
    --argjson summary_max "$SUMMARY_MAX" \
    --arg source "$source" \
    "$jq_program" "$file"; then
    warn "the report could not be rendered"
    return 1
  fi
  return 0
}

# --- entrée principale -------------------------------------------------------

main() {
  parse_args "$@"

  local source tasks_file
  if [ -n "$input_file" ]; then
    [ -r "$input_file" ] || die_usage "cannot read --input file: $input_file"
    tasks_file=$input_file
    source="fichier local $(printf '%s' "$input_file" | tr '\n' ' ')"
  else
    check_api_environment
    work_dir="$(mktemp -d)"
    trap 'rm -rf "$work_dir"' EXIT
    if ! fetch_tasks; then
      return 1
    fi
    tasks_file="$work_dir/tasks.json"
    source="API Optio — GET /api/tasks?limit=$TASK_LIMIT (lecture seule)"
  fi

  if ! check_task_list "$tasks_file"; then
    return 1
  fi
  render_report "$tasks_file" "$source"
}

main "$@"
