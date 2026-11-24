# Argo CD MCP operator contract

This deployment is the read-only machine interface to Argo CD for SRE agents.

## Security

- `mcp-for-argocd` is pinned to v0.9.0 or newer because v0.8.0 is affected by GHSA-rp45-5x3v-48mr.
- `MCP_READ_ONLY=true` removes application mutation, sync and resource-action tools.
- `ARGOCD_API_TOKEN` authenticates the MCP server outbound to Argo CD.
- `MCP_AUTH_TOKEN` is a distinct inbound bearer token for callers.
- The Argo account `argocd-mcp` maps only to `role:readonly`.
- CiliumNetworkPolicy `argocd-mcp` is a second boundary: ingress on 3000 only from the Gateway (Envoy, entities `ingress`/`host`/`remote-node`) and from `omnigent-sandboxes`.

## Activation

Active since 2026-11-19 (`replicas: 1`, `externalsecret.yaml` rendered).

- Argo token: `argocd account generate-token --core --account argocd-mcp` piped into `scripts/doppler-safe.sh set ARGOCD_MCP_API_TOKEN -p cluster -c prd`.
- Inbound token: random, Doppler `cluster/prd` `ARGOCD_MCP_AUTH_TOKEN`.
- Local operator access (Claude Code): `claude mcp add -s local argocd -- bash <repo>/scripts/argocd-mcp-stdio.sh`. The script opens `kubectl port-forward` 127.0.0.1:13030 → `svc/argocd-mcp:3000` when needed and runs `scripts/lib/mcp-http-bridge.py` (stdio ↔ HTTP) under `doppler-safe.sh run --only ARGOCD_MCP_AUTH_TOKEN`; the token stays in the bridge environment. A `headersHelper` cannot work: doppler-mask replaces the token in stdout.
- Proof 2026-11-19: 11 tools exposed, all read-only; `list_applications` PASS; `sync_application` → `Tool ... not found`.
- Rotation: generate a new token, `set` it in Doppler, let the ExternalSecret refresh (Reloader restarts the pod), then revoke the old token id with `argocd account delete-token`.

## External access (PLT-401)

Paul's decision of 2026-11-21: external AIs may query Argo CD read-only through this MCP; the Argo CD UI stays LAN-only (`argocd.smadja.dev` is attached to Gateway `internal` only).

- Endpoint: `https://argocd-mcp.smadja.dev/mcp` (MCP streamable HTTP, stateless, `POST` only). HTTPRoute `argocd-mcp` on Gateway `external` forwards `POST /mcp` exactly; `/healthz`, `/sse`, `GET /mcp` and every other path get the Gateway 404. The server also accepts the new `Host` through `--allowed-host-header`.
- DNS: none to create. The existing `*.smadja.dev` wildcard of the Cloudflare tunnel (homelab-infra, INV-EDGE-01) already reaches Gateway `external`.
- Authentication: mandatory inbound bearer. Every request carries `Authorization: Bearer <ARGOCD_MCP_AUTH_TOKEN>`; the server answers 401 without it and refuses to start exposed without `MCP_AUTH_TOKEN`. Authorization is read-only twice: `MCP_READ_ONLY=true` (no mutation, sync or resource-action tool) and the Argo account `argocd-mcp` limited to `role:readonly`. Never relax either.
- Note: `ha-mcp` (hassio) is not the model here: its route is LAN-only since MANDAT 6. The public-MCP precedent is Hindsight (`memory.smadja.dev`): Cloudflare Access with a service token in front, then the application's own bearer.
- Hardening in homelab-infra (not in this repository, Paul's gesture): a Cloudflare Access application `argocd-mcp` (self-hosted, host `argocd-mcp.smadja.dev`) with a `non_identity` policy on one dedicated service token, as in `terraform/cloudflare/hindsight-homelab.tf`. Once active, callers also send `CF-Access-Client-Id` and `CF-Access-Client-Secret`. Until then the bearer is the only authentication layer. Add `argocd-mcp.smadja.dev` to `docs/operations/public-routes-decisions.json` there.
- Caller setup (the token is given to the AI client by Paul out of band, never in Git or chat): MCP server type HTTP, URL above, header `Authorization: Bearer <token>`.
- Proof after merge (no value printed): without header → 401/403; with the bearer `tools/list` shows read-only tools and no `sync_application`; `list_applications` returns applications; `GET /healthz`, `GET /mcp` and `/sse` from outside → 404; `https://argocd.smadja.dev` from outside → 404.
- Rotation of the inbound bearer: new random value in Doppler `cluster/prd` `ARGOCD_MCP_AUTH_TOKEN` (`scripts/doppler-safe.sh set`), ExternalSecret refresh (Reloader restarts the pod), then give the new value to external clients. The old value stops working at the restart; there is no overlap window.

No token value belongs in Git or diagnostic output.
