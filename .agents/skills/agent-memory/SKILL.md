---
name: agent-memory
description: Read and write the shared agent memory (Hindsight MCP, bank agents-homelab) at ticket start and ticket end. Pointers only, never document copies.
---

# Agent memory (Hindsight)

Decision: D-2026-11-14-03 (homelab-infra `docs/decisions.md`). Tracking: PLT-301.
Status: the MCP endpoint is NOT active yet (public hostname awaits Paul). If the
`hindsight` MCP server is absent or fails, continue the ticket without memory.
Memory never blocks a ticket and never replaces `docs/decisions.md`.

## Bank

- Engineering agents use one bank: `agents-homelab` (single-bank URL `/mcp/agents-homelab/`).
- Never read or write another bank (personal banks belong to their owners).

## When to read (ticket start, once)

`recall` with the component and the ticket subject, for example
`"CNPG R2 barman pièges"`. Keep at most 5 results. Open the pointed decision,
ticket or PR only if it applies. Do not paste recall output into Linear or Git.

## When to write (ticket end, 0 to 3 entries)

`retain` only what a future session needs and cannot find in one hop:
a decision, a trap (piège), a lesson. Nothing else: no status, no logs, no secrets,
no document copy, no personal data.

Format (one entry = one fact, French, STE80, at most 3 sentences):

```text
Type: piège | leçon | décision
Composant: <cnpg | argo | oke | r2 | ...>
Fait: <one or two sentences>
Source: <D-AAAA-MM-JJ-NN | PLT-n | URL de PR>
```

If the fact contradicts `docs/decisions.md`, the file wins: write a ticket, not a memory.

## Client configuration (after activation)

Export these environment variables from Doppler (names only, never write a
value in a file):

| Client variable | Doppler source |
|---|---|
| `HINDSIGHT_MCP_URL` | `https://memory.<domain>` (not secret; PLT-304) |
| `HINDSIGHT_API_KEY` | `cluster/prd` `APP_HINDSIGHT_MCP_API_KEY` |
| `CF_ACCESS_CLIENT_ID` | `infrastructure/prd` `HINDSIGHT_CF_ACCESS_CLIENT_ID` |
| `CF_ACCESS_CLIENT_SECRET` | `infrastructure/prd` `HINDSIGHT_CF_ACCESS_CLIENT_SECRET` |

Claude Code (`.mcp.json` or `claude mcp add`):

```json
{"mcpServers": {"hindsight": {"type": "http",
  "url": "${HINDSIGHT_MCP_URL}/mcp/agents-homelab/",
  "headers": {"Authorization": "Bearer ${HINDSIGHT_API_KEY}",
              "CF-Access-Client-Id": "${CF_ACCESS_CLIENT_ID}",
              "CF-Access-Client-Secret": "${CF_ACCESS_CLIENT_SECRET}"}}}}
```

Codex (`~/.codex/config.toml`): `[mcp_servers.hindsight]` with the same `url`,
`bearer_token_env_var = "HINDSIGHT_API_KEY"` and `env_http_headers` for the two
`CF-Access-*` headers. Check the syntax against the installed Codex version.
