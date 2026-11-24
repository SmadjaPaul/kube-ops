#!/usr/bin/env bash
# PRD-104: test du script contre un faux HA + contrat statique du CronJob suspendu.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP="$ROOT/k8s/applications/automation/hassio"

python3 -I "$ROOT/tests/harness/ha-agent-mcp-smoke-test.py"

yaml="$APP/ha-agent-mcp-smoke.yaml"
grep -q 'suspend: true' "$yaml" || { echo "FAIL: CronJob ha-agent-mcp-smoke doit etre suspendu" >&2; exit 1; }
grep -q 'backoffLimit: 0' "$yaml" || { echo "FAIL: backoffLimit 0 attendu" >&2; exit 1; }
grep -q 'activeDeadlineSeconds: 120' "$yaml" || { echo "FAIL: activeDeadlineSeconds 120 attendu" >&2; exit 1; }
if grep -q 'ttlSecondsAfterFinished' "$yaml"; then echo "FAIL: pas de ttlSecondsAfterFinished (logs a lire)" >&2; exit 1; fi
if grep -Eq '^kind: (Role|RoleBinding|ClusterRole)$' "$yaml"; then echo "FAIL: aucun RBAC attendu" >&2; exit 1; fi
if command -v kustomize >/dev/null 2>&1; then
  kustomize build "$APP" | grep -q 'name: ha-agent-mcp-smoke-script'
fi
echo "ha-agent-mcp-smoke-test: PASS"
