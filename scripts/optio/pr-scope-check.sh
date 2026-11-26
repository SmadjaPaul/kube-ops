#!/usr/bin/env bash
# PLT-523 : contrôle déterministe du périmètre d'une PR kube-ops.
#
# Pourquoi : les chemins réservés de kube-ops ne sont protégés que par la consigne du
# relecteur (docs/operations/optio-review.md : « aucun contrôle technique »). Ce script
# rend ce contrôle déterministe et testable : il lit la liste des fichiers d'une PR et
# refuse, avec des raisons, une PR hors périmètre (chemin réservé, diff trop gros,
# trop de fichiers). Aucun appel réseau : il ne fait que juger le fichier fourni.
#
# Usage :
#   bash scripts/optio/pr-scope-check.sh --files <fichier> [--max-lines 400] [--max-files 15]
#
# Entrées :
#   --files FILE    sortie de `gh pr view N --json files` : chemin, additions et
#                   suppressions par fichier. Un tableau JSON nu est aussi accepté.
#   --max-lines N   lignes modifiées maximum (additions + suppressions), 400 par défaut.
#   --max-files N   fichiers touchés maximum, 15 par défaut.
#
# Sortie (stdout) :
#   OK             la PR est dans le périmètre (code de retour 0) ;
#   FAIL: <raison> une raison par ligne : d'abord les chemins réservés (ordre des
#                   fichiers), puis les seuils de taille (code de retour 1).
#
# Codes de retour : 0 dans le périmètre, 1 hors périmètre, 2 usage ou entrée invalide.
set -euo pipefail

readonly DEFAULT_MAX_LINES=400
readonly DEFAULT_MAX_FILES=15

# Chemins réservés : liste recopiée telle quelle de la consigne REVUE
# (docs/operations/optio-intake.md, étape 7, point 3 « it touches a reserved path »).
# Une entrée qui finit par « / » couvre le répertoire et tout son contenu ; une entrée
# qui finit par « * » couvre les chemins qui commencent par son préfixe ; sinon
# l'entrée est le chemin exact, à la racine du dépôt.
readonly RESERVED_PATHS=(
  '.github/'
  '.justfile'
  'scripts/plan/'
  'AGENTS.md'
  'CLAUDE.md'
  'CODEOWNERS'
  'policy/'
  'policies/'
  'golden-paths/'
  'docs/decisions*'
  'k8s/bootstrap/'
  'k8s/clusters/'
  'k8s/charts/platform-app/'
  'k8s/infrastructure/auth/'
  'k8s/infrastructure/security/'
  'k8s/infrastructure/network/'
  'k8s/infrastructure/controllers/argocd/'
  'k8s/infrastructure/controllers/external-secrets/'
)

# Même consigne REVUE, dernière entrée : « any rbac, role, rolebinding, secret store or
# policy exception file ». Ces catégories n'ont pas de chemin fixe : le seul signal
# déterministe dans ce dépôt est le nom du fichier. Les motifs ci-dessous sont donc
# des sous-chaînes du nom de fichier, appliquées aux manifestes Kubernetes (.yaml,
# .yml), seuls fichiers qui portent ces objets.
readonly RESERVED_FILE_PATTERNS=(
  'rbac'
  'role'
  'secretstore'
  'secret-store'
  'policy-exception'
)

usage() {
  echo "usage: optio/pr-scope-check.sh --files FILE [--max-lines N] [--max-files N]" >&2
}

die() {
  echo "optio-pr-scope-check: $*" >&2
  exit 2
}

# Entrée réservée trouvée : écrit l'entrée correspondante, sinon code 1.
reserved_path_rule() {
  local path=$1
  local entry
  for entry in "${RESERVED_PATHS[@]}"; do
    if [[ "$entry" == */ ]]; then
      if [[ "$path" == "$entry"* ]]; then
        printf '%s\n' "$entry"
        return 0
      fi
    elif [[ "$entry" == *'*' ]]; then
      if [[ "$path" == "${entry%\*}"* ]]; then
        printf '%s\n' "$entry"
        return 0
      fi
    elif [[ "$path" == "$entry" ]]; then
      printf '%s\n' "$entry"
      return 0
    fi
  done
  return 1
}

# Fichier réservé trouvé (rbac, role, rolebinding, store de secrets, exception de
# politique) : écrit le motif correspondant, sinon code 1.
reserved_file_rule() {
  local path=$1
  local base=${path##*/}
  local pattern
  case "$base" in
    *.yaml | *.yml) ;;
    *) return 1 ;;
  esac
  for pattern in "${RESERVED_FILE_PATTERNS[@]}"; do
    if [[ "$base" == *"$pattern"* ]]; then
      printf '%s\n' "$pattern"
      return 0
    fi
  done
  return 1
}

files_file=""
max_lines=$DEFAULT_MAX_LINES
max_files=$DEFAULT_MAX_FILES

while [ "$#" -gt 0 ]; do
  case "$1" in
    --files)
      [ "$#" -ge 2 ] || die "--files needs a file"
      files_file=$2
      shift 2
      ;;
    --max-lines)
      [ "$#" -ge 2 ] || die "--max-lines needs a number"
      max_lines=$2
      shift 2
      ;;
    --max-files)
      [ "$#" -ge 2 ] || die "--max-files needs a number"
      max_files=$2
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

[ -n "$files_file" ] || {
  usage
  die "--files is required"
}
case "$max_lines" in
  '' | *[!0-9]*) die "--max-lines must be a non-negative integer" ;;
esac
case "$max_files" in
  '' | *[!0-9]*) die "--max-files must be a non-negative integer" ;;
esac
[ -r "$files_file" ] || die "cannot read --files file: $files_file"

# Liste des fichiers : objet {"files": [...]}, {"files": {"nodes": [...]}} ou tableau nu.
files_json="$(jq -c '
  (if type == "array" then .
   elif (.files? | type) == "array" then .files
   elif ((.files.nodes? | type) == "array") then .files.nodes
   else error("no file list found") end)
  | map({
      path: ((.path // "") | tostring),
      additions: (((.additions // 0) | tonumber?) // 0 | floor),
      deletions: (((.deletions // 0) | tonumber?) // 0 | floor)
    })
' "$files_file")" || die "invalid JSON in --files file: $files_file"

if [ "$(jq -r '[.[] | select(.path == "")] | length' <<<"$files_json")" != "0" ]; then
  die "a file without a path was found in --files file: $files_file"
fi

total_lines=0
file_count=0
reason_count=0

while IFS=$'\t' read -r path additions deletions; do
  file_count=$((file_count + 1))
  total_lines=$((total_lines + additions + deletions))
  if rule="$(reserved_path_rule "$path")"; then
    printf 'FAIL: chemin réservé (%s) : %s\n' "$rule" "$path"
    reason_count=$((reason_count + 1))
  elif pattern="$(reserved_file_rule "$path")"; then
    printf 'FAIL: fichier réservé (%s) : %s\n' "$pattern" "$path"
    reason_count=$((reason_count + 1))
  fi
done < <(jq -r '.[] | [.path, (.additions | tostring), (.deletions | tostring)] | @tsv' <<<"$files_json")

if [ "$total_lines" -gt "$max_lines" ]; then
  printf 'FAIL: diff trop gros : %s lignes (maximum %s)\n' "$total_lines" "$max_lines"
  reason_count=$((reason_count + 1))
fi

if [ "$file_count" -gt "$max_files" ]; then
  printf 'FAIL: trop de fichiers : %s (maximum %s)\n' "$file_count" "$max_files"
  reason_count=$((reason_count + 1))
fi

[ "$reason_count" -eq 0 ] || exit 1
printf 'OK\n'
