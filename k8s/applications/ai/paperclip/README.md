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

Generic OIDC/Authentik support is not upstream in Paperclip stable as of 2026-09-30. V1 therefore uses the native Better Auth board-claim flow. Do not add oauth2-proxy/ForwardAuth or a permanent fork just to mask this gap. When upstream generic OIDC lands, migrate the native auth provider in place.

The Paperclip Operator's automatic authenticated-mode `adminUser` bootstrap is intentionally not used because upstream documents a current CEO-promotion/config-mode bug. Claim the instance through the supported board-claim flow.

## Execution posture

Global scheduled heartbeats are disabled in V1 because Paperclip `2026.916.1` has a current burst-wakeup/PostgreSQL-pool regression. Agents are invoked explicitly/on-demand. Paperclip budgets are useful telemetry but are not the only financial guardrail; model/provider limits remain enforced in LiteLLM/provider accounts.

Kubernetes sandbox execution is deliberately deferred until the first-party Paperclip Kubernetes plugin and Agent Sandbox API are stable enough for this cluster. V1 tests the Paperclip control plane and local OpenCode adapter first.

## Company

`company/` is the portable Agent Companies definition. Import it only after the Paperclip instance is healthy and claimed. Git remains the canonical copy of the company package.
