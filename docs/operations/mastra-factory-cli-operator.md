# Mastra Factory operator access (v0.1.19)

This runbook records the supported CLI/MCP boundary observed on 2026-11-09 for
`https://factory.smadja.dev` (`@mastra/factory@0.27.0`). It does not authorize
run retries, approvals, transitions, or changes to Factory configuration.

## Official CLI

Install the upstream skill for Codex:

```bash
npx skills add mastra-ai/skills --skill mastra-factory
```

Use the official CLI without changing application dependencies:

```bash
FACTORY_URL=https://factory.smadja.dev
env -u NODE_TLS_REJECT_UNAUTHORIZED npm exec --yes --package=mastra@latest --package=@mastra/core@latest --package=typescript@latest -- \
  mastra api --url "$FACTORY_URL" factory project list '{"page":0,"perPage":10}'
```

The command is read-only, but this deployment returned HTTP 401. `mastra auth
login` authenticates to Mastra Platform; it does not create a session for this
self-hosted Better Auth deployment. The CLI accepts an explicit `--header`, but
do not reuse Mastra Platform credentials or copy a browser cookie. No supported
interactive self-hosted CLI login or short-lived CLI token issuer is configured
here, so authenticated Factory commands remain blocked until a first-party
Better Auth CLI/OAuth flow is made available.

## Native MCP

`@mastra/factory@0.27.0` supports the project MCP route
`/web/factory/projects/:projectId/mcp`; it requires both an auth provider and a
configured authorization server. On the deployed server,
`GET /web/config/features` returned `{"knowledge":false,"mcp":false}` and the
MCP route and protected-resource metadata route returned HTTP 401. The runtime
does not currently mount MCP.

Authentik is configured as Better Auth's OIDC sign-in provider. Factory's
Better Auth adapter validates Better Auth session tokens; it does not validate
Authentik access tokens. Therefore adding an Authentik issuer URL to MCP
metadata alone would not make MCP requests authenticate. Do not set
`MASTRA_FACTORY_MCP_AUTHORIZATION_SERVER` until the bearer-token validation and
organization checks are supported end to end.

## Read-only record for the blocked run

The authenticated CLI/API read was blocked by HTTP 401. A bounded CNPG inspection
used only `BEGIN READ ONLY` and `SELECT` against the exact session/run identifiers:

- Work Item `799d87e2-5b9d-4883-a3e0-473c4fdeb6a3`; board card
  `5dac9364-8c8a-4574-9176-7fd7dc03225f`; board `work`, stage `intake`, revision 3.
  No Linear source row or autonomous run was linked to either ID.
- Session `4bc19542-22b7-4d20-85f0-21a5b161af72` has an active `chat` binding.
- Run `24156226-ab90-4b95-bc21-22e17037f3c4` is persisted as `suspended` at
  `toolCallStep`; `resumeClaimedAt` is `2026-11-09T09:39:45.488Z`.
- Pending-start `749e4f74-c190-47da-b5b3-f35af8359eb4` is `sent`, attempts 0,
  with no lease owner or expiry. No autonomous-run/dispatch, deferred decision,
  workflow-owner row, or memory-run-fence row matched these IDs. No Sandbox
  object exists; the only SandboxClaim is `ClaimExpired`, with an opaque session
  fingerprint that could not be safely mapped to this session.
- A prior UI observation showed a pending `factory_transition_work_item`
  approval for expected revision 3; the current deferred-decision and attention
  receipt tables contain no matching row.

The previous resume error said another resume had already claimed this run.
The persisted `resumeClaimedAt` marker remains, but its owner is not available
in the current owner/fence tables. Treat the resume owner as unknown: do not
retry or clear the marker. The exact safe next step is a supported authenticated
Factory inspection/reconciliation that exposes the run owner and claim state.

## Configuration ownership

TypeScript and GitOps declare Factory wiring, deployment flags, budgets, and
integration secret references. CNPG currently stores Factory projects, boards,
work items, sessions, source-control bindings, pending starts, decisions, model
packs/providers, and integration settings. Use native Factory configuration
APIs once authenticated; do not add a parallel synchronizer or edit CNPG data.
