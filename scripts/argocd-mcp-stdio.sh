#!/usr/bin/env bash
# stdio MCP server for Claude Code: read-only Argo CD MCP (agent-observers/argocd-mcp).
#
# 1. Ensures a local port-forward 127.0.0.1:${ARGOCD_MCP_LOCAL_PORT:-13030} -> svc/argocd-mcp:3000.
# 2. Runs scripts/lib/mcp-http-bridge.py under `doppler-safe.sh run --only ARGOCD_MCP_AUTH_TOKEN`:
#    the bearer token stays in the bridge environment; stdout carries only MCP JSON-RPC,
#    still filtered by doppler-mask. Diagnostics go to stderr.
#
# Register (local scope, no token stored):
#   claude mcp add -s local argocd -- bash <repo>/scripts/argocd-mcp-stdio.sh
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
port="${ARGOCD_MCP_LOCAL_PORT:-13030}"
log="${TMPDIR:-/tmp}/argocd-mcp-port-forward.log"

healthy() { curl -fsS --max-time 2 "http://127.0.0.1:${port}/healthz" >/dev/null 2>&1; }

if ! healthy; then
  (
    # shellcheck disable=SC1091
    source "$root/scripts/lib/kube-preflight.sh"
    require_kube_access >&2
    # kubectl reads the kubeconfig at start; the preflight cleanup removes it once the tunnel is up.
    nohup kubectl -n agent-observers port-forward --address 127.0.0.1 svc/argocd-mcp "${port}:3000" \
      >"$log" 2>&1 </dev/null &
    disown
    # Keep the kubeconfig until kubectl has loaded it and the tunnel answers.
    for _ in $(seq 1 30); do
      healthy && break
      sleep 0.5
    done
  ) >&2
  healthy || { echo "argocd-mcp: port-forward not healthy on ${port} (see ${log})" >&2; exit 1; }
fi

export MCP_BRIDGE_URL="http://127.0.0.1:${port}/mcp" MCP_BRIDGE_TOKEN_ENV=ARGOCD_MCP_AUTH_TOKEN
exec bash "$root/scripts/doppler-safe.sh" run --only ARGOCD_MCP_AUTH_TOKEN -p cluster -c prd -- \
  python3 -I "$root/scripts/lib/mcp-http-bridge.py"
