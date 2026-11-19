#!/usr/bin/env bash
# headersHelper for the Claude Code MCP entry `argocd` (read-only Argo CD MCP).
#
# 1. Ensures a local port-forward 127.0.0.1:${ARGOCD_MCP_LOCAL_PORT:-13030} -> svc/argocd-mcp:3000.
# 2. Prints {"Authorization":"Bearer <ARGOCD_MCP_AUTH_TOKEN>"} on stdout for Claude Code.
#
# stdout carries only the header JSON; every diagnostic goes to stderr.
# The token comes from Doppler cluster/prd through scripts/doppler-safe.sh and is never logged.
#
# Register (local scope, no token stored):
#   claude mcp add-json -s local argocd \
#     '{"type":"http","url":"http://127.0.0.1:13030/mcp","headersHelper":"bash <repo>/scripts/argocd-mcp-headers.sh"}'
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
    # kubectl reads the kubeconfig at start; the preflight cleanup may remove it afterwards.
    nohup kubectl -n agent-observers port-forward --address 127.0.0.1 svc/argocd-mcp "${port}:3000" \
      >"$log" 2>&1 </dev/null &
    disown
  ) >&2
  for _ in $(seq 1 30); do
    healthy && break
    sleep 0.5
  done
  healthy || { echo "argocd-mcp: port-forward not healthy on ${port} (see ${log})" >&2; exit 1; }
fi

bash "$root/scripts/doppler-safe.sh" run --only ARGOCD_MCP_AUTH_TOKEN -p cluster -c prd -- \
  sh -c 'jq -cn --arg t "$ARGOCD_MCP_AUTH_TOKEN" "{Authorization: (\"Bearer \" + \$t)}"'
