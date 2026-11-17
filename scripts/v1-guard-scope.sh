#!/usr/bin/env bash
set -euo pipefail

# Decide si le SELF-TEST de la garde service-contract (check:service-contract-selftest, ~34 relances
# de la garde) doit tourner. Sortie : "run" ou "skip". La garde elle-meme (check:service-contract)
# tourne toujours : c'est elle qui valide la PR. Le job v1-contract (check requis) reste vert dans
# les deux cas ; seul le self-test est saute (SKIP_CHECKS dans le runner).
#
# Evenements pris en charge : pull_request et merge_group (base_sha/head_sha de la file) ; tout autre
# evenement (push main, schedule) : run.
#
# Le self-test tourne si la PR touche la garde, son test, le template golden-path, le chart
# platform-app, les fixtures, l'outillage de checks ou le workflow. Erreur de diff : run (par defaut).
#
# V1_CHANGED_FILES (un chemin par ligne) surcharge le diff, pour les tests du detecteur.

if [[ -n "${V1_CHANGED_FILES:-}" ]]; then
  changed="$V1_CHANGED_FILES"
elif [[ ( "${GITHUB_EVENT_NAME:-}" != pull_request && "${GITHUB_EVENT_NAME:-}" != merge_group ) || -z "${GITHUB_BASE_SHA:-}" || -z "${GITHUB_HEAD_SHA:-}" ]]; then
  echo run
  exit 0
elif ! changed="$(git diff --name-only "$GITHUB_BASE_SHA" "$GITHUB_HEAD_SHA" 2>/dev/null)"; then
  echo run
  exit 0
fi

[[ -n "$changed" ]] || { echo run; exit 0; }

while IFS= read -r path; do
  case "$path" in
    tests/harness/service-contract*|tests/harness/pg-shared-homelab-isolation-guard-test.sh) echo run; exit 0 ;;
    tests/fixtures/service-contract/*|golden-paths/*|k8s/charts/platform-app/*) echo run; exit 0 ;;
    package.json|scripts/run-checks-parallel.mjs|scripts/v1-guard-scope.sh|.github/workflows/v1-contract.yaml) echo run; exit 0 ;;
  esac
done <<< "$changed"
echo skip
