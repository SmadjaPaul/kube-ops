#!/usr/bin/env bash
# PLT-523 : tests de scripts/optio/pr-scope-check.sh.
#
# Le script est le contrôle déterministe du périmètre d'une PR (chemins réservés,
# taille du diff, nombre de fichiers) : il lit une liste de fichiers et refuse la PR
# hors périmètre. Ce test joue sa vraie ligne de commande sur des listes écrites dans
# un dossier temporaire, puis vérifie le code de retour et les raisons affichées.
#
# Cas couverts : PR documentaire acceptée ; un fichier sous chacun de deux préfixes
# réservés ; fichier de type rbac ; diff trop gros ; trop de fichiers ; limites
# atteintes exactement ; seuils personnalisés ; usage invalide ; sortie stable ; liste
# des chemins réservés alignée sur la consigne REVUE de docs/operations/optio-intake.md.
#
# Lecture seule, aucun appel réseau, aucun accès cluster. Autonome : mktemp, aucune
# écriture dans le dépôt.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo_root/scripts/optio/pr-scope-check.sh"
test_file="$repo_root/tests/harness/optio-pr-scope-check-test.sh"
bash_list="$repo_root/scripts/check-bash-tests.list"
intake="$repo_root/docs/operations/optio-intake.md"

command -v jq >/dev/null || { echo "OPTIO_PR_SCOPE_CHECK=BLOCKED reason=jq_required"; exit 2; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "OPTIO_PR_SCOPE_CHECK=FAIL $*" >&2
  exit 1
}

[[ -f "$script" ]] || fail "reason=missing_script path=$script"
[[ -r "$intake" ]] || fail "reason=missing_intake path=$intake"

# Le test doit tourner dans la porte locale canonique.
grep -qx 'tests/harness/optio-pr-scope-check-test.sh' "$bash_list" ||
  fail "reason=not_listed file=scripts/check-bash-tests.list"

# Aucun appel réseau : le script juge le fichier fourni, il ne lit pas GitHub.
if grep -vE '^[[:space:]]*#' "$script" |
  grep -qE '(^|[^[:alnum:]_])(curl|wget|nc|ncat|ssh|scp)([^[:alnum:]_]|$)|https?://'; then
  fail "reason=network_call_detected"
fi

RC=0
OUT=""
ERR=""

# run_case <nom> <json> [arguments...] : joue le script et remplit RC, OUT et ERR.
run_case() {
  local name=$1
  local json=$2
  shift 2
  local dir="$tmp/$name"
  mkdir -p "$dir"
  printf '%s\n' "$json" >"$dir/files.json"
  RC=0
  bash "$script" --files "$dir/files.json" "$@" >"$dir/out" 2>"$dir/err" || RC=$?
  OUT="$(cat "$dir/out")"
  ERR="$(cat "$dir/err")"
}

expect_rc() {
  local want=$1
  local name=$2
  [[ "$RC" == "$want" ]] ||
    fail "reason=unexpected_rc case=$name want=$want got=$RC out=$OUT err=$ERR"
}

expect_out() {
  local needle=$1
  local name=$2
  grep -Fq -- "$needle" <<<"$OUT" ||
    fail "reason=missing_output case=$name needle=$needle out=$OUT"
}

expect_no_out() {
  local needle=$1
  local name=$2
  if grep -Fq -- "$needle" <<<"$OUT"; then
    fail "reason=unexpected_output case=$name needle=$needle out=$OUT"
  fi
}

cases=0

# 1. PR documentaire : dans le périmètre, sortie OK.
run_case doc-pr '[
  {"path":"docs/operations/optio-review.md","additions":12,"deletions":3},
  {"path":"docs/operations/optio-intake.md","additions":1,"deletions":0}
]'
expect_rc 0 doc-pr
expect_out "OK" doc-pr
expect_no_out "FAIL" doc-pr
cases=$((cases + 1))

# 2. Un fichier sous un préfixe réservé (.github/) : refus.
run_case reserved-github '[
  {"path":".github/workflows/v1-contract.yaml","additions":4,"deletions":0}
]'
expect_rc 1 reserved-github
expect_out "FAIL" reserved-github
expect_out ".github/" reserved-github
expect_out ".github/workflows/v1-contract.yaml" reserved-github
cases=$((cases + 1))

# 3. Un fichier sous un autre préfixe réservé (k8s/infrastructure/security/) : refus.
run_case reserved-security '[
  {"path":"k8s/infrastructure/security/agent-operator/scope.tsv","additions":2,"deletions":1}
]'
expect_rc 1 reserved-security
expect_out "k8s/infrastructure/security/" reserved-security
expect_out "k8s/infrastructure/security/agent-operator/scope.tsv" reserved-security
cases=$((cases + 1))

# 4. Fichier de type rbac hors préfixe réservé : refus par le motif de nom.
run_case rbac-file '[
  {"path":"k8s/applications/platform/example/rbac.yaml","additions":6,"deletions":0}
]'
expect_rc 1 rbac-file
expect_out "rbac" rbac-file
expect_out "k8s/applications/platform/example/rbac.yaml" rbac-file
cases=$((cases + 1))

# 5. Diff trop gros : 450 lignes pour un maximum de 400.
run_case diff-too-large '[
  {"path":"docs/operations/optio-review.md","additions":300,"deletions":150}
]'
expect_rc 1 diff-too-large
expect_out "diff trop gros" diff-too-large
expect_out "450" diff-too-large
cases=$((cases + 1))

# 6. Trop de fichiers : 16 fichiers pour un maximum de 15.
too_many_json="$(jq -nc '[range(0;16) as $i | {path: ("docs/operations/f" + ($i | tostring) + ".md"), additions: 1, deletions: 0}]')"
run_case too-many-files "$too_many_json"
expect_rc 1 too-many-files
expect_out "trop de fichiers" too-many-files
expect_out "16" too-many-files
cases=$((cases + 1))

# 7. Limites atteintes exactement (15 fichiers, 400 lignes) : accepté.
at_limits_json="$(jq -nc '[range(0;15) as $i | {path: ("docs/operations/f" + ($i | tostring) + ".md"), additions: (if $i == 0 then 36 else 26 end), deletions: 0}]')"
run_case at-limits "$at_limits_json"
expect_rc 0 at-limits
expect_out "OK" at-limits
cases=$((cases + 1))

# 8. Seuils personnalisés : les deux raisons sont affichées.
run_case custom-limits '[
  {"path":"docs/operations/optio-review.md","additions":20,"deletions":0},
  {"path":"docs/operations/optio-intake.md","additions":20,"deletions":0},
  {"path":"docs/operations/optio-alerts.md","additions":20,"deletions":0}
]' --max-lines 30 --max-files 2
expect_rc 1 custom-limits
expect_out "diff trop gros" custom-limits
expect_out "trop de fichiers" custom-limits
cases=$((cases + 1))

# 9. Les autres entrées de la liste réservée : nom de fichier exact, motif et
#    catégories rbac, role, rolebinding, store de secrets, exception de politique.
run_case reserved-exact '[{"path":".justfile","additions":1,"deletions":0}]'
expect_rc 1 reserved-exact
expect_out ".justfile" reserved-exact
run_case reserved-glob '[{"path":"docs/decisions.md","additions":1,"deletions":0}]'
expect_rc 1 reserved-glob
expect_out "docs/decisions*" reserved-glob
run_case role-file '[{"path":"k8s/applications/platform/example/rolebindings.yaml","additions":1,"deletions":0}]'
expect_rc 1 role-file
expect_out "role" role-file
run_case secretstore-file '[{"path":"k8s/applications/platform/example/secretstore.yaml","additions":1,"deletions":0}]'
expect_rc 1 secretstore-file
expect_out "secretstore" secretstore-file
run_case policy-exception-file '[{"path":"k8s/applications/ai/opencode/policy-exception.yaml","additions":1,"deletions":0}]'
expect_rc 1 policy-exception-file
expect_out "policy-exception" policy-exception-file
cases=$((cases + 5))

# 10. Un nom de fichier qui contient un mot réservé sans être un manifest Kubernetes
#     n'est pas refusé : la catégorie porte sur les objets, pas sur la prose.
run_case not-a-manifest '[{"path":"docs/operations/secrets-drill-d1-pg-shared-role.md","additions":1,"deletions":0}]'
expect_rc 0 not-a-manifest
expect_out "OK" not-a-manifest
cases=$((cases + 1))

# 11. Entrées tolérées : tableau JSON nu, additions ou suppressions absentes,
#     chemin contenant un espace.
run_case bare-array '[{"path":"docs/operations/optio-review.md","additions":1,"deletions":0}]'
expect_rc 0 bare-array
run_case missing-counts '[{"path":"docs/operations/optio-review.md"}]'
expect_rc 0 missing-counts
run_case spaced-path '[{"path":"docs/operations/une note.md","additions":2,"deletions":0}]'
expect_rc 0 spaced-path
expect_out "OK" spaced-path
cases=$((cases + 3))

# 12. Usage invalide : code 2, pas de verdict.
expect_usage() {
  local name=$1
  shift
  local rc=0
  bash "$script" "$@" >/dev/null 2>&1 || rc=$?
  [[ "$rc" == "2" ]] || fail "reason=unexpected_rc case=$name want=2 got=$rc"
}
printf '%s\n' '{"files":[]}' >"$tmp/empty.json"
printf '%s\n' 'pas du json' >"$tmp/broken.json"
printf '%s\n' '{"files":[{"additions":1,"deletions":0}]}' >"$tmp/empty-path.json"
expect_usage missing-files --max-lines 10
expect_usage unknown-flag --files "$tmp/empty.json" --unknown
expect_usage bad-max-lines --files "$tmp/empty.json" --max-lines abc
expect_usage negative-max-files --files "$tmp/empty.json" --max-files -1
expect_usage unreadable-file --files "$tmp/absent.json"
expect_usage broken-json --files "$tmp/broken.json"
expect_usage empty-path --files "$tmp/empty-path.json"
cases=$((cases + 7))

# 13. Sortie stable : deux exécutions donnent le même octet.
run_case stable '[{"path":"k8s/infrastructure/security/x.yaml","additions":3,"deletions":0}]'
first_rc=$RC
bash "$script" --files "$tmp/stable/files.json" >"$tmp/stable/out2" 2>/dev/null || true
cmp -s "$tmp/stable/out" "$tmp/stable/out2" || fail "reason=unstable_output case=stable"
[[ "$first_rc" == "1" ]] || fail "reason=unexpected_rc case=stable want=1 got=$first_rc"
cases=$((cases + 1))

# 14. La liste des chemins réservés du script est celle de la consigne REVUE
#     (docs/operations/optio-intake.md, étape 7). Les deux listes doivent rester
#     identiques : le test échoue si l'une change sans l'autre.
reserved_block="$(awk '
  index($0, "(.github/") && !started { started = 1 }
  started { print }
  started && index($0, "exception file)") { exit }
' "$intake")"
[[ -n "$reserved_block" ]] ||
  fail "reason=consigne_list_not_found file=docs/operations/optio-intake.md"
normalized="$(printf '%s' "$reserved_block" | tr '\n' ' ' | tr -s ' ')"
path_part="${normalized%%any *}"
tail_part="${normalized#*any }"
tail_part="${tail_part%%;*}"
doc_paths="$(printf '%s' "$path_part" | tr ',' '\n' |
  sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | sed '1s/^(//' | grep -v '^$' || true)"
script_paths="$(sed -n '/^readonly RESERVED_PATHS=(/,/^)/p' "$script" |
  grep -o "'[^']*'" | tr -d "'")"
[[ -n "$doc_paths" ]] || fail "reason=consigne_paths_empty"
[[ -n "$script_paths" ]] || fail "reason=script_paths_empty"
if ! diff -u <(printf '%s\n' "$doc_paths" | sort) <(printf '%s\n' "$script_paths" | sort) \
  >"$tmp/reserved.diff" 2>&1; then
  cat "$tmp/reserved.diff" >&2
  fail "reason=reserved_list_out_of_sync file=docs/operations/optio-intake.md"
fi
for keyword in rbac role rolebinding 'secret store' 'policy exception'; do
  grep -Fq -- "$keyword" <<<"$tail_part" ||
    fail "reason=consigne_category_missing keyword=$keyword"
done
for pattern in rbac role secretstore secret-store policy-exception; do
  grep -Fq -- "'$pattern'" "$script" ||
    fail "reason=reserved_file_pattern_missing pattern=$pattern"
done
cases=$((cases + 1))

if command -v shellcheck >/dev/null; then
  shellcheck -s bash "$script" "$test_file" || fail "reason=shellcheck_failed"
fi

echo "OPTIO_PR_SCOPE_CHECK=PASS cases=$cases"
