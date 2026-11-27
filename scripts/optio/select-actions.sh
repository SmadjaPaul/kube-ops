#!/usr/bin/env bash
# PLT-522 : sélection déterministe des actions de l'orchestrateur Optio.
#
# Ce script est la version testable des étapes 2 à 7 de
# docs/operations/optio-intake.md. Il ne crée rien : il lit une réponse
# GraphQL Linear, la liste des travaux Optio et un nombre de places, puis écrit
# sur stdout le JSON des actions à prendre. Aucun appel réseau, aucun accès
# cluster, aucune écriture.
#
# Usage :
#   bash scripts/optio/select-actions.sh --linear FILE --work FILE [--slots N]
#                                 [--repos a,b] [--main-repo URL]
#
# Entrées :
#   --linear FILE  réponse GraphQL Linear, data.issues.nodes : identifier,
#                  title, description, priority, createdAt, url, labels,
#                  assignee, relations bloquantes et état du ticket bloquant.
#                  Une relation de type blockedBy (dans relations) ou de type
#                  blocks (dans inverseRelations) désigne le ticket bloquant.
#   --work FILE    travaux Optio : name, state, repoUrl, prUrl, prNumber,
#                  prChecksStatus, conflicts ; headSha8 (tête actuelle de la PR)
#                  et retryPending (reprise attendue), facultatifs.
#   --slots N      places d'agent (défaut 5).
#   --repos a,b    dépôts configurés dans Optio (défaut : tous les dépôts admis).
#   --main-repo URL  seul dépôt dont les PR donnent des revues et corrections
#                  (défaut : github.com/smadjapaul/kube-ops). Un travail
#                  sans repoUrl est rattaché à ce dépôt.
#
# Sortie (stdout, une ligne JSON) :
#   {"create_tasks":[...],"create_reviews":[...],"create_fixes":[...],
#    "skipped":[{"id","reason"}]}
#
# Règles reprises de la consigne de l'orchestrateur, sans en ajouter :
#   - un ticket écarté porte sa raison dans skipped (première règle satisfaite,
#     dans l'ordre de la consigne) ;
#   - la ligne « Dépôt: <nom> » est cherchée ligne par ligne, avec un nom de la
#     liste ALLOWED_REPOS : une mention dans une autre phrase ne vaut pas la
#     ligne, et deux dépôts différents écartent le ticket ;
#   - la zone « ha-config » ne s'applique pas à un ticket du dépôt ha-config ;
#   - un ticket éligible mais sans place libre n'est ni créé ni écarté : il sera
#     repris au passage suivant ;
#   - les places libres se partagent : d'abord les revues et corrections
#     (étape 7), puis les tâches (étape 5) sur les places restantes ;
#   - une PR en conflit passe en correction même si ses checks passent : une
#     PR en conflit ne peut pas être mergée.
#
# États de travail terminaux : completed (terminé), cancelled (annulé, graphie de
# l'API Optio ; « canceled » toléré), failed (échoué). Ne prennent pas non plus de
# place, faute d'agent en cours : pr_opened, needs_attention, waiting_on_deps.
# Tout autre état (pending, queued, provisioning, running, état inconnu) occupe
# une place.
#
# Codes de retour : 0 succès, 2 usage ou entrée invalide.
set -euo pipefail

# Zones interdites de l'étape 2 de docs/operations/optio-intake.md, reprises
# telles quelles. Chaque entrée est "<terme de la consigne>|<motif de recherche>" :
# le motif est une expression régulière insensible à la casse, cherchée dans le
# titre et la description du ticket.
readonly FORBIDDEN_ZONES=(
  'Talos|talos'
  'Proxmox|proxmox'
  'UniFi|unifi'
  'ha-config|ha-config'
  'factory-platform|factory-platform'
  'une décision|décision'
  'une charte|charte'
  'policies/|policies/'
  'AGENTS.md|agents\.md'
  'CLAUDE.md|claude\.md'
  'CODEOWNERS|codeowners'
  'un ruleset|ruleset'
  '.github/workflows|\.github/workflows'
  'des secrets|secret'
  'une suppression de données|suppression de données'
)

# Dépôts qu'un ticket peut désigner par sa ligne « Dépôt: <nom> ».
readonly ALLOWED_REPOS=(
  kube-ops
  agent-harness
  website
  homelab-infra
  Atlas
  ha-config
  terraform-provider-polyfin
  terraform-provider-aiostreams
)

usage() {
  echo "usage: optio/select-actions.sh --linear FILE --work FILE [--slots N] [--repos a,b] [--main-repo URL]" >&2
}

die() {
  echo "optio-select-actions: $*" >&2
  exit 2
}

linear_file=""
work_file=""
slots=5
repos_csv=""
repos_given=false
main_repo="github.com/smadjapaul/kube-ops"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --linear)
      [ "$#" -ge 2 ] || die "--linear needs a file"
      linear_file=$2
      shift 2
      ;;
    --work)
      [ "$#" -ge 2 ] || die "--work needs a file"
      work_file=$2
      shift 2
      ;;
    --slots)
      [ "$#" -ge 2 ] || die "--slots needs a number"
      slots=$2
      shift 2
      ;;
    --repos)
      [ "$#" -ge 2 ] || die "--repos needs a list"
      repos_csv=$2
      repos_given=true
      shift 2
      ;;
    --main-repo)
      [ "$#" -ge 2 ] || die "--main-repo needs an url"
      main_repo=$2
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[ -n "$linear_file" ] || { usage; die "--linear is required"; }
[ -n "$work_file" ] || { usage; die "--work is required"; }
case "$slots" in
  '' | *[!0-9]*) die "--slots must be a non-negative integer" ;;
esac

[ -r "$linear_file" ] || die "cannot read --linear file: $linear_file"
[ -r "$work_file" ] || die "cannot read --work file: $work_file"
jq . "$linear_file" >/dev/null 2>&1 || die "invalid JSON in --linear file: $linear_file"
jq . "$work_file" >/dev/null 2>&1 || die "invalid JSON in --work file: $work_file"

forbidden_json="$(printf '%s\n' "${FORBIDDEN_ZONES[@]}" | jq -Rn '[inputs | split("|") | {term: .[0], pattern: .[1]}]')"

allowed_json="$(printf '%s\n' "${ALLOWED_REPOS[@]}" | jq -Rn '[inputs]')"
if [ "$repos_given" = false ]; then
  repos_csv="$(IFS=,; printf '%s' "${ALLOWED_REPOS[*]}")"
fi
configured_json="$(jq -cn --arg csv "$repos_csv" '$csv | split(",") | map(select(length > 0) | ascii_downcase)')"

IFS= read -r -d '' jq_program <<'JQ' || true
# --- helpers ---------------------------------------------------------------

def lc:
  ascii_downcase;

def as_int:
  if type == "number" then .
  elif type == "string" and test("^-?[0-9]+$") then tonumber
  else null end;

def truthy:
  if . == null then false
  elif type == "boolean" then .
  elif type == "number" then . != 0
  elif type == "string" then ((length > 0) and (lc != "false") and (lc != "0") and (lc != "no"))
  elif type == "array" or type == "object" then length > 0
  else false end;

def norm_labels:
  if . == null then []
  elif type == "string" then [.]
  elif type == "array" then
    [.[] | if type == "string" then . else ((.name // "") | tostring) end | select(length > 0)]
  elif type == "object" and ((.nodes // null) | type) == "array" then
    (.nodes | norm_labels)
  else [] end;

def norm_state:
  if . == null then ""
  elif type == "string" then lc
  elif type == "object" then
    ((.type // .name // "") | if type == "string" then lc else "" end)
  else "" end;

def rel_type:
  (lc | gsub("[^a-z]"; ""));

def terminal_state:
  (. == "completed" or . == "cancelled" or . == "canceled" or . == "failed");

def active_state:
  (terminal_state | not);

# Un travail qui consomme, ou va consommer, un agent.
def agent_state:
  (active_state
   and . != "pr_opened" and . != "needs_attention" and . != "waiting_on_deps");

def norm_url:
  (lc | sub("^https?://"; "") | sub("/+$"; "") | sub("\\.git$"; "") | sub("/+$"; ""));

def repo_names:
  [split("\n")[]
   | [match("^\\s*dépôt\\s*:\\s*([A-Za-z0-9._-]+)\\s*$"; "i")]
   | .[0] // empty
   | (.captures[0].string | lc) as $n
   | $allowed[]
   | select(lc == $n)]
  | unique;

def finished_state:
  (. == "completed" or . == "cancelled" or . == "canceled" or . == "done");

def prio_rank:
  if . == 1 then 1
  elif . == 2 then 2
  elif . == 3 then 3
  elif . == 4 then 4
  elif . == 0 then 5
  else 6 end;

def has_assignee:
  if (.assignee? | type) == "object" then
    (((.assignee.name // .assignee.id // .assignee.email // "") | tostring) | length) > 0
  elif (.assignee? | type) == "string" then
    ((.assignee | length) > 0)
  else false end;

# Capture nommée "n" d'une expression régulière. Les versions de jq
# n'exposent pas les captures nommées de la même façon (.n, .namedCaptures.n
# ou la capture nommée dans .captures) : les trois formes sont lues.
def captured_n:
  (.n // .namedCaptures.n // ([.captures[]? | select(.name == "n") | .string][0]) // empty);

# Numéro de PR : le champ prNumber s'il est là, sinon le numéro déduit de
# l'URL. capture() est gardé dans un try : jq 1.6 lève une erreur quand l'URL
# ne correspond pas, jq 1.7 renvoie un résultat vide. Sans ce garde-fou, le
# script s'arrête sur le premier travail sans PR.
def pr_number:
  (if (.prNumber? | type) == "number" then .prNumber
   elif ((.prNumber? // "") | type) == "string" then ((.prNumber | as_int) // null)
   else null end) as $n
  | if $n != null then $n
    else ([((.prUrl // "")
             | (try capture("/(?:pull|merge_requests)/(?<n>[0-9]+)") catch empty)
             | captured_n
             | tonumber?)] | .[0])
    end;

def blockers_of:
  ((.blockers? // []) | if type == "array" then . else [] end) as $explicit
  | (((.relations? // {}) | (.nodes? // [])) | if type == "array" then . else [] end) as $rel
  | (((.inverseRelations? // {}) | (.nodes? // [])) | if type == "array" then . else [] end) as $inv
  | ($explicit
     + [$rel[] | select(((.type // "") | rel_type) == "blockedby") | (.relatedIssue // empty)]
     # Une relation entrante porte le bloqueur dans « issue » : « relatedIssue » y
     # désigne le ticket lui-même (PLT-562).
     + [$inv[] | select(((.type // "") | rel_type) as $t | ($t == "blocks" or $t == "blockedby"))
             | (.issue // .relatedIssue // empty)])
  | map(select(type == "object"))
  | map({identifier: ((.identifier // .id // "") | tostring), state: (.state | norm_state)});

# PLT-562 : palier (P0, J1 à J7) puis nombre de tickets ouverts débloqués,
# comme Atlas priorities.yaml.
def palier_rank:
  ([.[] | if . == "P0" then 0 elif test("^J[1-7]$") then (.[1:] | tonumber) else empty end] | min) // 8;

def unblocks_count:
  [(((.relations? // {}) | (.nodes? // [])) | if type == "array" then . else [] end)[]
   | select(((.type // "") | rel_type) == "blocks")
   | (.relatedIssue // empty)
   | select((.state | norm_state | finished_state) | not)]
  | length;

def norm_issue:
  {
    identifier: ((.identifier // "") | tostring),
    title: ((.title // "") | tostring),
    description: ((.description // "") | tostring),
    priority: ((.priority | as_int) // 0),
    createdAt: ((.createdAt // "") | tostring),
    url: ((.url // "") | tostring),
    labels: (.labels | norm_labels),
    assigned: has_assignee,
    blockers: blockers_of,
    unblocks: unblocks_count
  };

def norm_work:
  (((.repoUrl // "") | tostring) | norm_url) as $repo
  | ($main_repo | norm_url) as $main
  | (((.prUrl // "") | tostring) | norm_url) as $url
  | {
    main: (($repo == "" or $repo == $main)
           and ($url == "" or ($url | startswith("github.com/") | not)
                or ($url | startswith($main + "/")))),
    headSha8: ((.headSha8 // "") | tostring),
    retryPending: ((.retryPending // false) | truthy),
    name: ((.name // "") | tostring),
    state: (.state | norm_state),
    prNumber: pr_number,
    prUrl: ((.prUrl // "") | tostring),
    checks: ((.prChecksStatus // "") | lc),
    conflicts: ((.conflicts // false) | truthy)
  };

# --- entrées ---------------------------------------------------------------

($linear[0] // {}) as $L
| ($work[0] // {}) as $W
| (if ($L | type) == "object" then
     (if ($L.data | type) == "object" then ($L.data.issues // null)
      elif ($L.issues | type) == "object" then $L.issues
      elif ($L.issues | type) == "array" then {nodes: $L.issues}
      else null end)
   else null end) as $raw_issues
| (if ($raw_issues | type) == "object" then ($raw_issues.nodes // [])
   elif ($raw_issues | type) == "array" then $raw_issues
   else [] end) as $issue_nodes
| (if ($W | type) == "array" then $W
   elif ($W | type) == "object" then ($W.works // [])
   else [] end) as $work_nodes
| ([$work_nodes[] | norm_work]) as $works
| ([$issue_nodes[] | norm_issue]) as $issues

# --- étapes 2 et 3 : écarts ------------------------------------------------

| [$issues[]
   | . as $i
   | ($i.title + "\n" + $i.description) as $text
   | ([$forbidden[] | select((.pattern) as $p | ($text | test($p; "i"))) | .term]) as $zones
   | ([$works[] | select((.name | startswith("[" + $i.identifier + "]"))) | .name]) as $dupes
   | ([$i.blockers[] | select((.state | finished_state) | not) | .identifier] | sort) as $open
   | ($i.labels | map(lc)) as $labels_lc
   | ($i.labels | map(select((lc | startswith("attend:"))))) as $attend
   | ($labels_lc | index("needs-operator")) as $needs_operator
   | ($labels_lc | index("différé")) as $deferred
   | ($i.description | repo_names) as $repos
   | ($repos[0] // "") as $repo
   | ([$zones[] | select((. == "ha-config" and $repo == "ha-config") | not)]) as $blocking
   | . + {repo: $repo, skip_reason:
       (if $i.assigned then "assigné"
        elif ($open | length) > 0 then
          "bloqué par un ticket non terminé : " + ($open | join(", "))
        elif $needs_operator != null then "label interdit : Needs-operator"
        elif $deferred != null then "label interdit : Différé"
        elif ($attend | length) > 0 then "label interdit : " + $attend[0]
        elif ($repos | length) == 0 then "description sans ligne Dépôt reconnue"
        elif ($repos | length) > 1 then
          "plusieurs dépôts désignés : " + ($repos | join(", "))
        elif ($repo | lc) as $r | ($configured | index($r)) == null then
          "dépôt non configuré dans Optio : " + $repo
        elif ($blocking | length) > 0 then "zone interdite citée : " + $blocking[0]
        elif ($dupes | length) > 0 then "travail existant : " + $dupes[0]
        else null end)}
  ] as $decided

# --- étape 4 : places --------------------------------------------------------

| ([$works[] | select((.state | agent_state))] | length) as $busy_count
| ($slots - $busy_count) as $free_raw
| (if $free_raw < 0 then 0 else $free_raw end) as $free_slots

# --- étape 7 : revue et correction, servies en premier -----------------------

| ([$works[] | select(.main)]) as $main_works
| ([$main_works[]
    | select(.prNumber != null)
    | select((.name | startswith("[REVUE")) | not)
    | select((.name | startswith("[CORRIGE")) | not)]
   | group_by(.prNumber)
   | map(([.[] | select(.conflicts or .checks == "failing")]
          + [.[] | select(.checks == "passing")] + .) | .[0])) as $pr_works
| ([$pr_works[]
    | . as $w
    | ($w.prNumber | tostring) as $n
    | ([$main_works[]
        | select(.name == ("[REVUE PR-" + $n + "]")
                 or ($w.headSha8 != ""
                     and .name == ("[REVUE PR-" + $n + " " + $w.headSha8 + "]")))]
       | length) as $reviews
    | ([$main_works[] | select((.name | startswith("[CORRIGE PR-" + $n + " ")))]) as $corrections
    | ($corrections | length) as $corr_count
    | ([$corrections[] | select((.state | active_state) or .retryPending)] | length) as $corr_active
    | (if ($w.conflicts or $w.checks == "failing") then
         (if ($corr_count < 3 and $corr_active == 0) then
            {kind: "fix", prNumber: $w.prNumber, prUrl: $w.prUrl,
             name: ("[CORRIGE PR-" + $n + " " + (($corr_count + 1) | tostring) + "]"),
             attempt: ($corr_count + 1)}
          else empty end)
       elif $w.checks == "passing" then
         (if $reviews == 0 then
            {kind: "review", prNumber: $w.prNumber, prUrl: $w.prUrl,
             name: ("[REVUE PR-" + $n + "]")}
          else empty end)
       else empty end)]) as $actions
| ($actions | sort_by([.prNumber, .kind])) as $ordered_actions
| ($ordered_actions[0:5]) as $capped_actions
| ($capped_actions[0:$free_slots]) as $chosen

# --- étape 5 : tickets sur les places restantes ------------------------------

| ($free_slots - ($chosen | length)) as $remaining
| ([$decided[] | select(.skip_reason == null)]) as $eligible
| ($eligible | sort_by([(.priority | prio_rank), (.labels | palier_rank), (- .unblocks),
                        .createdAt, .identifier])) as $ordered
| ($ordered[0:5]) as $capped_tasks
| ($capped_tasks[0:$remaining]) as $tasks

# --- sortie stable ---------------------------------------------------------

| {
    create_tasks: ([$tasks[]
                    | {identifier: .identifier,
                       name: ("[" + .identifier + "] " + .title),
                       title: .title,
                       repo: .repo,
                       url: .url,
                       priority: .priority,
                       createdAt: .createdAt,
                       description: .description}]),
    create_reviews: ([$chosen[]
                      | select(.kind == "review")
                      | {prNumber: .prNumber, prUrl: .prUrl, name: .name}]),
    create_fixes: ([$chosen[]
                    | select(.kind == "fix")
                    | {prNumber: .prNumber, prUrl: .prUrl, name: .name, attempt: .attempt}]),
    skipped: ([$decided[]
               | select(.skip_reason != null)
               | {id: .identifier, reason: .skip_reason}]
              | sort_by(.id))
  }
JQ

decision="$(jq -c -n \
  --slurpfile linear "$linear_file" \
  --slurpfile work "$work_file" \
  --argjson slots "$slots" \
  --argjson forbidden "$forbidden_json" \
  --argjson allowed "$allowed_json" \
  --argjson configured "$configured_json" \
  --arg main_repo "$main_repo" \
  "$jq_program")"
[ -n "$decision" ] || die "internal error: empty decision"
printf '%s\n' "$decision"
