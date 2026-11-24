#!/usr/bin/env bash
# PRD-83: reconciliateur Music Assistant : tests Python (faux MA) + contrat statique du kustomize.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP="$ROOT/k8s/applications/automation/music-assistant"

python3 -I "$ROOT/tests/harness/ma-reconcile-test.py"

if command -v kustomize >/dev/null 2>&1; then
  out="$(kustomize build "$APP")"
  # Aucun declenchement automatique : les deux CronJobs sont suspendus.
  [ "$(grep -c 'suspend: true' <<<"$out")" -eq 2 ] || {
    echo "FAIL: les CronJobs ma-reconcile doivent etre suspendus" >&2
    exit 1
  }
  grep -q 'name: ma-reconcile-script' <<<"$out"
  grep -q 'name: ma-reconcile-desired' <<<"$out"
  grep -q 'name: ma-reconcile-token' <<<"$out"
  # Le jeton MA n'est pas dans Doppler : Secret natif, hors Git.
  if grep -q 'key: APP_MA_RECONCILE_TOKEN' <<<"$out"; then
    echo "FAIL: jeton MA via ExternalSecret" >&2
    exit 1
  fi
  grep -q 'key: APP_MA_POLYFIN_PASSWORD' <<<"$out"
  # PRD-84 : jeton HA range par PATCH d'un seul Secret natif ; ni create, ni get, ni liste.
  role="$(awk '/^kind: Role$/{f=1} f&&/^---/{exit} f' <<<"$out" | tr -d '\n' | tr -s ' ')"
  [[ "$role" == *"resourceNames: - ma-home-assistant-token resources: - secrets verbs: - patch" ]] || {
    echo "FAIL: Role ma-reconcile doit etre patch seul sur le Secret ma-home-assistant-token" >&2
    exit 1
  }
  grep -q 'name: ma-home-assistant-token' <<<"$out"
  # Seul le job apply monte le jeton de ServiceAccount.
  [ "$(grep -c 'automountServiceAccountToken: true' <<<"$out")" -eq 1 ] || {
    echo "FAIL: un seul CronJob (apply) monte le jeton de ServiceAccount" >&2
    exit 1
  }
  # Aucun secret en clair dans les manifestes rendus.
  if grep -Eq 'kind: Secret$' <<<"$out"; then
    echo "FAIL: Secret en clair rendu" >&2
    exit 1
  fi
fi
echo "ma-reconcile-test: PASS"
