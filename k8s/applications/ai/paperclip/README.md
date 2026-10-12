# Paperclip V1

Paperclip is the control plane for the software factory. The Kubernetes deployment intentionally reuses the homelab's existing platform primitives:

- Argo CD for desired-state delivery.
- Paperclip Operator `0.19.1`.
- CloudNativePG PostgreSQL on `longhorn-fast`.
- Barman/WAL + scheduled base backups to Hetzner Object Storage.
- ESO/Doppler for bootstrap/runtime secrets.
- LiteLLM as the single model gateway.
- Cilium + Gateway API + private ExternalDNS/UniFi for local-first access.
- Velero/Kopia for the Paperclip data PVC.

## Deployment contract

The Paperclip server deployment is operator-native, not a hand-built Deployment. The canonical workload is `paperclip.inc/v1alpha1 Instance/paperclip`; the operator owns the generated workload, Service, RBAC and lifecycle resources.

The installed operator API already exposes the first-party Kubernetes execution surface through:

- `spec.plugins`;
- `spec.adapters.execution`;
- per-tenant `ResourceQuota` / `LimitRange`;
- Cilium-aware sandbox egress policy.

Do not replace the operator with bespoke Deployment/Job plumbing.

Git desired state currently pins the Paperclip server image in `instance.yaml`. CLI/company tooling may be newer than the live server; do not infer a runtime upgrade from the CLI version. Server upgrades remain separately qualified because they can include database migrations and adapter/default changes.

## Required Doppler keys

In `cluster/prd`:

- `APP_PAPERCLIP_BETTER_AUTH_SECRET`
- `APP_PAPERCLIP_SECRETS_MASTER_KEY`
- `APP_PAPERCLIP_LITELLM_API_KEY`

The LiteLLM value must be a dedicated virtual key limited to the models needed by Paperclip. Do not use the LiteLLM master key.

## Authentication — human board and headless operator

Live `Instance/paperclip` uses `authenticated` + `private` and native Better Auth.
No generic OIDC/Authentik flow is assumed to be operational without a separate
end-to-end proof. Do not switch to `local_trusted` to unblock an automation.

### Initial instance administration (existing GitOps bootstrap)

The upstream operator owns `spec.auth.adminUser` on the Paperclip Instance:

- `paperclip-admin@smadja.dev`, with bootstrap password supplied by
  `ExternalSecret/paperclip-admin-bootstrap`;
- Doppler source: `cluster/prd:APP_PAPERCLIP_ADMIN_PASSWORD`;
- this ExternalSecret is intentionally separate from
  `paperclip-runtime-secrets`, so bootstrap failure cannot remove the live
  Better Auth signing secret or model gateway credentials;
- the operator bootstrap Job initially signs up the user through Better Auth
  and assigns the initial instance-admin role. It must be idempotent.

The `spec.auth.adminUser` configuration is **active**. Historical guidance to
avoid automatic admin bootstrap or instead use board claim is obsolete for this
installation. Inspect the current operator status before changing signup
policy: the bootstrap Job needs the regular email signup endpoint for the
initial run. Never export the admin password, session cookies, or Better Auth
signing secret into the operator automation environment.

### Two separate API identities

| Caller | Native mechanism | Authority |
| --- | --- | --- |
| Human browser | Better Auth session cookie | Current Board user roles |
| Codex / trusted technical operator | Named **Board API key** (`pcp_board_...`) | Roles of the key's owning Board user |
| Autonomous Paperclip agent | Agent API key or per-run JWT | Agent/company/run capabilities |

Native implementation in the pinned Paperclip fork:

- `server/src/middleware/auth.ts`: bearer token resolves as a Board key
  *before* attempting agent token/JWT authentication; sessions are used only
  when no bearer token is presented.
- `server/src/services/board-auth.ts`: Board keys are generated randomly,
  stored by hash, and checked for expiration/revocation on requests.
- `server/src/routes/access.ts`: `GET /api/cli-auth/me`,
  `POST /api/board-api-keys`, `GET /api/board-api-keys`, and
  `DELETE /api/board-api-keys/:keyId`.
- `cli/src/commands/client/auth.ts` and `token.ts`: upstream
  `paperclipai auth login`, `auth whoami`, `token board create/list/revoke`.

**Do not use an agent API key** for Board administration. Do not repurpose
the one-time bootstrap password, copy a browser cookie, mint a JWT manually,
or write auth database tables directly. The CLI's
`token board create --company-id` records an audit context: it does **not**
restrict the resulting key to that company. A Board key inherits the user's
current rights; protect it accordingly.

### Provision the headless operator once

The initial pairing is a **single explicit human approval**, not a recurring
browser dependency:

1. From a machine with private-network reachability and an upstream-compatible
   CLI, run
   `paperclipai auth login --instance-admin --no-browser --api-base https://paperclip.smadja.dev`.
2. Sign in as `paperclip-admin@smadja.dev` and approve the displayed
   challenge in the browser; the CLI retains a short-lived Board credential
   in its owner-only local auth store.
3. Verify using
   `paperclipai auth whoami --api-base https://paperclip.smadja.dev`:
   `source=board_key` and `isInstanceAdmin=true` must both hold.
4. In a **secret-safe, non-logged operator terminal**, create a distinct
   named credential via
   `paperclipai token board create --name codex-factory-operator --ttl-days 90 --api-base https://paperclip.smadja.dev`.
   **Warning:** this official CLI command prints the token once. Redirect
   the creation response directly into an approved secret-handling path;
   never paste the token into PRs, transcripts, CI logs, tickets, or agent
   prompts. Do not enable shell tracing.
5. Place the named token in Doppler `cluster/prd` under
   `APP_PAPERCLIP_OPERATOR_BOARD_API_KEY`. Grant **only trusted operator
   processes** read access. At execution, map this value to
   `PAPERCLIP_API_KEY`, with
   `PAPERCLIP_API_URL=https://paperclip.smadja.dev`.
   Explicit `PAPERCLIP_API_KEY` takes precedence over local CLI credentials
   and suppresses interactive auth recovery in the CLI.
6. Verify from a fresh, non-browser operator process using
   `paperclipai auth whoami --api-base https://paperclip.smadja.dev`;
   require `source=board_key` and `isInstanceAdmin=true`, then perform
   **one harmless Board read** before attempting writes.

The operator credential is deliberately **not** part of the Paperclip server's
`envFrom`, an ESO projection into `paperclip-runtime-secrets`, a Sandbox H3
runtime environment, or an agent's `PAPERCLIP_API_KEY`. Only the trusted
external operator reads it from Doppler. Provisioning the Doppler value does not
by itself create or grant remote network access to the private HTTPRoute.

### Lifespan, rotation and recovery

- A credential obtained from `auth login` expires after **30 days** by
  default. The separately named operator key above expires after **90 days**.
  Upstream also offers `--never-expires`, but it is not recommended here.
- Before expiry, use the still-valid named Board key from the trusted
  operator to create a replacement via the native Board-key API; securely
  update Doppler, prove the **new** identity from a fresh operator process,
  then revoke the old key by its ID. Allow overlap only during verification;
  do not revoke first. An automated rotation requires an explicitly
  authorized Doppler write identity and a tested secret-safe transport.
- Board API keys live in Paperclip PostgreSQL and remain valid across server
  Pod restarts or browser-session expiration. Rotating
  `BETTER_AUTH_SECRET` does not by itself revoke these DB-backed keys.
  User deletion, role changes, key expiration or revocation still apply.
- `401`: absent/invalid/expired credential or missing valid session;
  `403`: authenticated caller lacks the requested Board/company/instance
  permission. Confirm with `/api/cli-auth/me` before diagnosing the
  target operation. Do not auto-retry an unauthorized mutation.
- Recovery after total key loss uses a new **upstream CLI approval** by the
  existing instance admin, not a bypass of auth. Keep access limited to the
  private Gateway and keep tokens out of model prompts, repository files,
  heartbeat environments, and telemetry.

Automated acceptance gates: no-browser `auth whoami` from a fresh process,
expected admin identity and Board source, authorized harmless Board read,
rejected invalid/expired/revoked key, no leaked token in logs or H3
environment, and token still working after a Paperclip restart. Exercise
rotation and old-key revocation before declaring long-term autonomy proven.

## Managed GitHub connection

Paperclip `2026.916.1` already contains the upstream managed GitHub identity path; no server upgrade is required just to expose it.

On a self-hosted instance, the upstream `managed` GitHub method is intentionally hidden from the advertised gallery until the instance is enrolled with the Paperclip Cloud Connector and the broker advertises the `github.code` profile. Seeing only `mcp-key` before enrollment does **not** mean that a PAT is required.

The canonical V1 path is:

1. keep the advanced PAT method unused;
2. keep agent broker traffic in-cluster through `PAPERCLIP_GITHUB_BROKER_URL=http://paperclip:3100`; Paperclip may reach the hosted GitHub MCP endpoint `api.githubcopilot.com:443` in addition to the existing GitHub API surfaces, but the broker itself has no public route, listener, or DNS name;
3. complete the upstream self-host enrollment as an instance administrator;
4. authorize the upstream GitHub App with selected repository access;
5. install that managed connection for the Implementation Engineer (or Company when explicitly intended);
6. prove clone/fetch, branch/push and PR creation in the separately approved DOC smoke.

Self-host enrollment generates the upstream signing/sealing identity in Paperclip's persistent instance data under its owner-only secrets directory. Do not copy that identity into Doppler or replace it with a custom Kubernetes Secret unless upstream changes its storage contract. Paperclip Cloud owns the fixed OAuth callback and webhook inbox; provider credentials are sealed to the enrolled instance and persisted in Paperclip's existing encrypted secret store.

Enrollment, GitHub authorization and managed-connection installation are credential/access mutations and remain explicit R2 gates. The harmless DOC smoke is a separate R2 gate.

## Execution posture

There are two distinct concerns:

1. **Paperclip server placement** — already Kubernetes-native through the Paperclip Operator.
2. **Agent execution placement** — currently bootstrap-local through `opencode_local`, with the first-party Kubernetes sandbox provider as the target production boundary.

`opencode_local` is acceptable for the first harmless DOC smoke because it proves Company -> issue DAG -> delegation -> review -> PR without changing the runtime boundary at the same time. It is not the final security boundary for autonomous production work.

The target is the upstream `@paperclipai/plugin-kubernetes` execution path backed by Kubernetes sandboxes, with role/capability restrictions enforced by pod, network, credential and RBAC boundaries rather than prompts alone.

A non-live candidate overlay and qualification runbook live under:

`poc/kubernetes-execution/`

That overlay is deliberately not referenced by the production `kustomization.yaml` and must not be enabled as part of an unrelated Paperclip change.

Qualification order:

1. complete Company/backlog bootstrap;
2. run the harmless DOC smoke with the existing local adapter;
3. run one disposable Kubernetes-sandbox POC with no production credential;
4. prove namespace/pod cleanup, egress restriction, resource quotas and callback/model path;
5. migrate roles progressively;
6. only then treat Kubernetes sandbox execution as the production factory runtime.

Known upstream sandbox/runtime-image defects must be treated as upstream blockers, not patched inside running Paperclip containers.

## Company and backlog

`company/` is the portable Company definition. Git remains canonical for Company intent.

`company/projects/kube-ops/backlog-seed.yaml` is the canonical backlog inventory. Paperclip does not natively import that seed format, so `scripts/paperclip/import-backlog-seed.mjs` is the bounded one-shot adapter from the Git seed to the official Paperclip issues API. It defaults to dry-run, uses stable managed-description markers for identity, and must not create or update live issues without a separately approved R2 apply.

Paperclip stores runtime work state; it does not replace Git as desired state.
