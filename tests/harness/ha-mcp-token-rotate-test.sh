#!/usr/bin/env bash
# PRD-80: statique (kustomize, RBAC sans create) + test du script contre un faux HA WebSocket.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP="$ROOT/k8s/applications/automation/hassio"

python3 -I "$ROOT/tests/harness/ha-mcp-token-rotate-test.py"

if command -v kustomize >/dev/null 2>&1; then
  out="$(kustomize build "$APP")"
  grep -q 'secret.reloader.stakater.com/reload: ha-mcp-token' <<<"$out"
  grep -q 'name: ha-mcp-token-rotate-script' <<<"$out"
  # Le Role ne doit jamais accorder create ni list sur les Secrets.
  if grep -A8 'kind: Role$' <<<"$out" | grep -Eq '(create|list|delete)'; then
    echo "FAIL: Role ha-mcp-token-rotate trop large" >&2
    exit 1
  fi
fi
echo "ha-mcp-token-rotate-test: PASS"
