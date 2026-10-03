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

The Deployment intentionally remains at `replicas: 0` and this directory intentionally does not render `externalsecret.yaml` yet.

1. Reconcile the Argo account/RBAC changes.
2. Generate an Argo CD API token for account `argocd-mcp`.
3. Store it in Doppler `cluster/prd` as `ARGOCD_MCP_API_TOKEN`.
4. Store an independent random inbound token as `ARGOCD_MCP_AUTH_TOKEN`.
5. Add `externalsecret.yaml` to this kustomization.
6. Scale the desired Deployment to one replica in Git.
7. Prove read-only tools work and mutation/sync tools are unavailable.

No token value belongs in Git or diagnostic output.
