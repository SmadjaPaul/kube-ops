# Argo CD MCP operator contract

This deployment is the read-only machine interface to Argo CD for SRE agents.

## Security

- `mcp-for-argocd` is pinned to v0.9.0 or newer because v0.8.0 is affected by GHSA-rp45-5x3v-48mr.
- `MCP_READ_ONLY=true` removes application mutation, sync and resource-action tools.
- `ARGOCD_API_TOKEN` authenticates the MCP server outbound to Argo CD.
- `MCP_AUTH_TOKEN` is a distinct inbound bearer token for callers.
- The Argo account `argocd-mcp` maps only to `role:readonly`.
- NetworkPolicy remains a second boundary.

## Activation

Active since 2026-11-19 (`replicas: 1`, `externalsecret.yaml` rendered).

- Argo token: `argocd account generate-token --core --account argocd-mcp` piped into `scripts/doppler-safe.sh set ARGOCD_MCP_API_TOKEN -p cluster -c prd`.
- Inbound token: random, Doppler `cluster/prd` `ARGOCD_MCP_AUTH_TOKEN`.
- Local operator access (Claude Code): `scripts/argocd-mcp-headers.sh` is the MCP `headersHelper`; it opens `kubectl port-forward` 127.0.0.1:13030 → `svc/argocd-mcp:3000` when needed and emits the bearer header from Doppler. `localhost`/`127.0.0.1` are always allowed Host values. Port-forward does not cross the NetworkPolicy.
- Rotation: generate a new token, `set` it in Doppler, let the ExternalSecret refresh (Reloader restarts the pod), then revoke the old token id with `argocd account delete-token`.

No token value belongs in Git or diagnostic output.
