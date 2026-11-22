---
name: agent-memory
description: Read and write the shared agent memory (Hindsight MCP, bank agents-homelab) at ticket start and ticket end. Pointers only, never document copies.
---

# Agent memory (Hindsight)

Decision: D-2026-11-14-03 (homelab-infra `docs/decisions.md`), amended by
D-2026-11-18-01 rule 3: Hindsight runs on the homelab, not on OKE. Tracking: PLT-305
(agent switch), PLT-368 (security and backup proof), PLT-304 (access path, needs Paul).
Status: NO agent endpoint is active. The Cloudflare edge in `terraform/cloudflare/oracle-a1.tf`
targets OKE, not the homelab, and must not be applied for memory. If the `hindsight`
MCP server is absent or fails, continue the ticket without memory.
Memory never blocks a ticket and never replaces `docs/decisions.md`.

## Three layers, never mixed

1. Personal memory: per principal, in that principal's own bank. Agents do not read or write it.
2. Operational memory: this skill, bank `agents-homelab`, pointers and traps only.
3. Authoritative state: Git, Linear, runtime. Memory never stores status or decisions as truth.

A write that belongs to layer 3 is refused: write a ticket or a decision instead.

## Bank and access

| Bank | Who | Agent access |
|---|---|---|
| `agents-homelab` | engineering agents (Claude Code) | read and write, via MCP, this skill's rules |
| personal banks | their owner | none |

Complete list of banks: not yet read from the homelab instance (no admin read done for
this change). To complete with a read-only check before PLT-305.

Access: one Hindsight API key (`APP_HINDSIGHT_MCP_API_KEY`, cluster/prd) reaches every
bank, so the edge must route only `/mcp/agents-homelab/` (PLT-304). Cloudflare Access
service token on top (names: `HINDSIGHT_CF_ACCESS_CLIENT_ID` / `_SECRET`, infrastructure/prd).

## Retention (proposal, not decided)

Proposed for Paul's decision: entries are kept without automatic expiry. A wrong entry is
corrected by a new entry that cites the decision, never edited silently. Deletion is done
by Paul only. PLT-368 stays open until this is decided.

## No secret in memory (rule, checked before every write)

Before `retain`, save the candidate entry to a file and run:

```bash
python3 -I scripts/agent-memory-entry-check.py entry.txt
```

It refuses an entry with a private key, a known token format, a `name=value` secret,
a sensitive URL parameter or a long mixed alphanumeric string, and prints only the rule
name, never the value. Test: `bash tests/agent-guard/agent-memory-entry-test.sh`.
Limit: this check is procedural. The server-side enforcement on Hindsight is still open
in PLT-368; a value that slips through must be reported and not repeated.

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

Precondition: one Hindsight API key reaches every bank. Activate this
configuration only when the edge routes nothing but `/mcp/agents-homelab/`
(tunnel ingress `path`, homelab-infra `terraform/cloudflare/oracle-a1.tf`) and
PLT-304 has proven that another path returns 404.

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

