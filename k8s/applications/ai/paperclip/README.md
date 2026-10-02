# Paperclip V1

Paperclip is the V1 control plane for the software factory. This deployment intentionally reuses the homelab's existing platform primitives:

- Argo CD for desired-state delivery.
- Paperclip Operator `0.19.1`.
- CloudNativePG PostgreSQL 17.7 on `longhorn-fast`.
- Barman/WAL + weekly base backups to Hetzner Object Storage.
- ESO/Doppler for bootstrap/runtime secrets.
- LiteLLM as the single model gateway.
- Cilium + Gateway API + private ExternalDNS/UniFi for local-first access.
- Velero/Kopia for the Paperclip data PVC.

## Required Doppler keys

In `cluster/prd`:

- `APP_PAPERCLIP_BETTER_AUTH_SECRET`
- `APP_PAPERCLIP_SECRETS_MASTER_KEY`
- `APP_PAPERCLIP_LITELLM_API_KEY`

The LiteLLM value should be a dedicated virtual key limited to the models needed by Paperclip. Do not use the LiteLLM master key.

## Authentication

Paperclip runs in `authenticated` mode at `https://paperclip.smadja.dev` but its HTTPRoute attaches only to `Gateway/internal`.

Paperclip `2026.1001.0` still uses native Better Auth for human sign-in; the
generic OIDC work remains tracked by upstream PR #3040. A minimal
environment-gated generic OIDC implementation exists in the `namhtpyn/paperclip`
fork, but V1 does not adopt that fork or a full downstream merge. If a
downstream bridge becomes necessary, it must be a separately reviewed,
minimal patch with an explicit removal path once upstream ships the feature.

The upgrade candidate from `2026.916.1` to `2026.1001.0` is not applied yet.
The candidate runs migrations `0280`–`0283`, retires legacy Composio
connections without an automatic migration, and changes unconfigured execution
harnesses to full-auto defaults. The Operator `0.19.1` Instance API accepts the
current image-tag-based CR without an app-version pin, but the upgrade remains
gated on the runtime secret contract, database migration qualification, and the
existing Paperclip acceptance tests.

The Paperclip Operator's automatic authenticated-mode `adminUser` bootstrap is intentionally not used because upstream documents a current CEO-promotion/config-mode bug. Claim the instance through the supported board-claim flow.

## Execution posture

Global scheduled heartbeats remain disabled in V1 pending qualification of the
upgrade path and the existing burst-wakeup/PostgreSQL-pool regression. Agents
are invoked explicitly/on-demand. Paperclip budgets are useful telemetry but
are not the only financial guardrail; model/provider limits remain enforced in
LiteLLM/provider accounts.

Kubernetes sandbox execution is deliberately deferred until the first-party Paperclip Kubernetes plugin and Agent Sandbox API are stable enough for this cluster. V1 tests the Paperclip control plane and local OpenCode adapter first.

## Company

`company/` is the portable Agent Companies definition. Import it only after the Paperclip instance is healthy and claimed. Git remains the canonical copy of the company package.
