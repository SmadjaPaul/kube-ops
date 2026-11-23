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
  # Aucun secret en clair dans les manifestes rendus.
  if grep -Eq 'kind: Secret$' <<<"$out"; then
    echo "FAIL: Secret en clair rendu" >&2
    exit 1
  fi
fi
echo "ma-reconcile-test: PASS"
