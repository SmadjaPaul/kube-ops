#!/usr/bin/env bash
set -euo pipefail

# Decide si la garde service-contract (check:service-contract) doit tourner pour ce job.
# Sortie : "run" ou "skip". "run" par defaut : tout evenement autre que pull_request, diff
# impossible, ou au moins un fichier touchant un chemin valide par la garde. Le job v1-contract
# (nom de check requis) tourne et reste vert dans les deux cas : seule la garde est sautee.
#
# Chemins couverts par la garde (leur modification declenche le run) :
#   k8s/**, golden-paths/**, catalog/**, scripts/catalog/**, tests/fixtures/service-contract/**,
#   tests/harness/service-contract*, tests/harness/pg-shared-homelab-isolation-guard-test.sh,
#   package.json (definit les checks), scripts/run-checks-parallel.mjs, scripts/v1-guard-scope.sh,
#   .github/workflows/v1-contract.yaml (le workflow lui-meme).
#
# V1_CHANGED_FILES (un chemin par ligne) surcharge le diff, pour les tests du detecteur.

if [[ -n "${V1_CHANGED_FILES:-}" ]]; then
  changed="$V1_CHANGED_FILES"
elif [[ "${GITHUB_EVENT_NAME:-}" != pull_request || -z "${GITHUB_BASE_SHA:-}" || -z "${GITHUB_HEAD_SHA:-}" ]]; then
  echo run
  exit 0
elif ! changed="$(git diff --name-only "$GITHUB_BASE_SHA" "$GITHUB_HEAD_SHA" 2>/dev/null)"; then
  echo run
  exit 0
fi

[[ -n "$changed" ]] || { echo run; exit 0; }

while IFS= read -r path; do
  case "$path" in
    k8s/*|golden-paths/*|catalog/*|scripts/catalog/*|tests/fixtures/service-contract/*) echo run; exit 0 ;;
    tests/harness/service-contract*|tests/harness/pg-shared-homelab-isolation-guard-test.sh) echo run; exit 0 ;;
    package.json|scripts/run-checks-parallel.mjs|scripts/v1-guard-scope.sh|.github/workflows/v1-contract.yaml) echo run; exit 0 ;;
  esac
done <<< "$changed"
echo skip
