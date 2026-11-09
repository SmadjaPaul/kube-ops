# Mastra Factory operator access (v0.1.19)

This runbook records the supported CLI/MCP boundary observed on 2026-11-09 for
`https://factory.smadja.dev` (`@mastra/factory@0.27.0`). It does not authorize
run retries, approvals, transitions, or changes to Factory configuration.

## Official CLI and headless Better Auth

Install the upstream skill for Codex:

```bash
npx skills add mastra-ai/skills --skill mastra-factory
```

Use the official CLI without changing application dependencies (this
unauthenticated example returned HTTP 401 on the self-hosted Factory; it only
checks CLI availability and API reachability, not operator access):

```bash
FACTORY_URL=https://factory.smadja.dev
env -u NODE_TLS_REJECT_UNAUTHORIZED npm exec --yes --package=mastra@latest --package=@mastra/core@latest --package=typescript@latest -- \
  mastra api --url "$FACTORY_URL" factory project list '{"page":0,"perPage":10}'
```

`mastra auth login` authenticates to Mastra Platform; it does not create a
session for this self-hosted Better Auth deployment. The CLI accepts an explicit
`--header`, but passing a session token there exposes it in the process argument
list. Do not do that, and do not copy cookies from a browser.

Headless reads were verified against the deployed Factory with the existing
operator account. The supported Better Auth endpoint is:

```text
POST https://factory.smadja.dev/auth/api/sign-in/email
Origin: https://factory.smadja.dev
Content-Type: application/json
{"email":"…","password":"…","rememberMe":false}
```

The response contains a Better Auth session `token`. Read it in a same-process
HTTPS client and send `Authorization: Bearer <token>` directly to Factory; do
not put credentials or the token in command arguments, shell history, files,
logs, or tickets. Obtain the password through a local secure prompt, not from a
browser session. The deployed `FactoryBootstrapBetterAuth` extends
`MastraAuthBetterAuth` 1.1.8, whose `authenticateToken()` accepts this Bearer
session form. The sign-in request must include the matching `Origin` (without it
the endpoint returns `403 MISSING_OR_NULL_ORIGIN`).

Verified read-only endpoints:

```text
GET /web/factory/projects
GET /web/factory/projects/:projectId/work-items
GET /web/factory/projects/:projectId/decisions?limit=100
```

For example, all three returned HTTP 200 for project
`8551e83c-15ca-498d-98d3-a606719a1370`. The project list contained two projects;
the target was `kube-ops`. Work Items returned the target card and its linked
canonical Work Item. The decisions endpoint returned its first page; no target
decision matched that page or the exact read-only CNPG query. The CLI itself
remains `CLI_PASS=FAIL` for authenticated use until it has a credential input
that does not expose the token in process arguments; the in-process HTTP method
is `HEADLESS_API_PASS`.

While the temporary session is still accessible, retrieve its non-token
`session.id` through the authenticated Better Auth `GET /auth/api/get-session`
endpoint using the same secure in-process client. Keep that identifier in the
operator's private recovery record, not a public ticket or log. Never infer a
session ID from the user ID or another browser session.

After a read, end the session with `POST /auth/api/sign-out`, the session cookie
from the same sign-in response, matching `Origin`, and JSON body `{}`. For a
temporary session that could not be signed out in its original process, Better
Auth's authenticated `GET /auth/api/list-sessions` and
`POST /auth/api/revoke-session` can revoke that exact session **only after**
matching its recorded `session.id` to a returned session. If no reliable ID
match exists, do not guess or revoke another session; seek an authorized
session-management recovery. Do not use `revoke-other-sessions` because it
would also sign out the operator's browser.

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

The official CLI remains unable to send the token without exposing it in argv.
The in-process authenticated Factory API read succeeded. A bounded CNPG
inspection used only `BEGIN READ ONLY` and `SELECT` against the exact
session/run identifiers:

- Work Item `799d87e2-5b9d-4883-a3e0-473c4fdeb6a3`; board card
  `5dac9364-8c8a-4574-9176-7fd7dc03225f`; board `work`, stage `intake`, revision 3.
  The authenticated Work Items endpoint confirmed the same card, linked Work
  Item, revision, and chat session; `runningSessionIds` and `parkedSessionIds`
  were empty. No Linear source row or autonomous run was linked to either ID.
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
