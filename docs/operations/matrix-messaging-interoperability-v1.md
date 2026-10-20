# Matrix messaging V1 — interoperability-first decision (2026-10-19)

Status: **proposal / no runtime deployment**. This document is preparatory only; merging it does not enable a messaging service.

## Goal

Provide a standards-based human/agent communications channel for the homelab and Software Factory, with an extensible path to notifications, GitHub and Linear events, bots, additional La Suite numérique services, federation and optional bridges. Keep Mastra as the agent orchestrator; Matrix is transport/UI, not another task orchestrator.

## Source survey

- Tchap source is under [tchapgouv](https://github.com/tchapgouv), notably [tchap-web-v4](https://github.com/tchapgouv/tchap-web-v4), a soft fork of Element Web. It is **not** a standalone server stack. Tchap server architecture is based on Matrix/Synapse/Element; don't deploy an old Tchap web fork as the core server.
- [La Suite numérique](https://github.com/suitenumerique) contains multiple independent collaboration products. Its `messages` repository is a **collaborative inbox**, not the Matrix/Tchap homeserver.
- Prefer the maintained [Element Server Suite Community Edition (ESS Community)](https://github.com/element-hq/ess-helm) chart as the initial upstream Kubernetes reference. It includes Synapse, Matrix Authentication Service (MAS), Element Web/Admin, optional RTC, well-known delegation and Hookshot integration. Confirm chart version and compatibility from upstream releases **at implementation time**, never a floating latest tag. Community terms: noncommercial and up to 100 users; reassess before commercial use.
- Alternative: independently pinned [Synapse](https://github.com/element-hq/synapse) + Element Web if ESS cannot fit the existing CNPG/ESO/Gateway API model without excess complexity. Avoid writing a custom messaging distribution.
- Optional future bridges: [mautrix-whatsapp](https://github.com/mautrix/whatsapp) (community integration; third-party platform and privacy/ToS considerations). Do **not** enable a bridge in V1.

## Decisions / constraints

1. Identity is durable: select Matrix `server_name` and `.well-known/matrix/{client,server}` delegation *before* first real accounts. The server name cannot be casually renamed after user creation. Do not infer it from provisional hostnames.
2. Use native Matrix Client-Server APIs and room/event semantics for human and machine integration; service accounts/appservices/bots have explicit identities, minimal scoped credentials, and audit. Do not send raw secrets or private code into public rooms.
3. Existing **Git -> Argo CD -> Kubernetes** desired state is authoritative. Infrastructure external to cluster (DNS/public tunnel) remains in `homelab-infra`. For in-cluster state use CNPG/Postgres, ESO/SOPS, approved storage and existing backup/DR conventions, subject to upstream chart support.
4. Reuse the existing Cilium Gateway API / cert-manager / Cloudflare architecture. Explicitly verify Matrix federation needs (public HTTPS, `/.well-known`, server discovery and required endpoints) before enabling federation. A cloudflared HTTP tunnel may satisfy HTTPS routes but is not evidence that federation actually works.
5. Authentication: assess ESS MAS and its supported upstream OIDC integration with existing Authentik; no assumption that Synapse legacy OIDC can simply be wired into MAS. Confirm recovery/account lifecycle and E2EE client experience.
6. Launch a minimal, internal-first pilot: homeserver, login, Element-compatible web/mobile client, persistent messages, basic room and client API, backup/restore proof. No RTC, large bridges, federation or bots by default unless required for the pilot.
7. Follow up with a single **outbound** notification producer from Factory, then optional **inbound** bot (authenticated, narrowly authorized command surface). Matrix notifications never become a prerequisite for Factory PR creation, review or merge.
8. Agent PR policy is distinct from messaging: allow autonomous merge **after** an independent review and deterministic quality gates at the exact head SHA. Escalate to a human only for defined high-risk/ambiguous cases. No blind merge merely because a previous agent wrote an approval narrative; enforce via native supported integration/policy.

## Implementation batches

**Batch 0 — this PR:** document provenance, boundaries and decision gates. Inventory any dormant messaging deployments in runtime/old refs before choosing upgrade versus fresh install. No new Argo Application and no changes to production state.

**Batch 1 — minimal Matrix GitOps PR:** decide canonical Matrix ID domain, validate upstream ESS chart version and license/requirements; add version-pinned chart source, CNPG/ESO integration, HTTPRoutes with restricted exposure, readiness/smoke and backup design. Review Kubernetes manifests locally. Keep registration controlled, avoid publishing federation prematurely.

**Batch 2 — runtime validation:** Argo Synced/Healthy; create test account, login, send/read a room message from two independent clients; restart and persistence; verify backups; document version and rollback. Declare federated messaging `NOT_TESTED` unless verified.

**Batch 3 — Factory notifications:** register a dedicated least-privilege bot identity; send one message for PR opened and one for failed independent review using existing Factory events. Avoid introducing a parallel task queue. Record event ID and delivery proof. Extend to Linear/Argo/alerting through existing adapters once justified.

**Batch 4 — optional interop:** federation, Element Call/MatrixRTC, carefully selected bridges such as WhatsApp, and connectors to La Suite products. Independently assess each bridge and encryption/key-management implications.

## Acceptance / blockers

```text
UPSTREAM_CHOICE=ESS_COMMUNITY_CANDIDATE_NOT_DEPLOYED
TCHAP_SOURCE=tchapgouv/tchap-web-v4
EXISTING_MATRIX_RUNTIME=NOT_FOUND_IN_KUBE_OPS_MAIN_OR_HOMELAB_INFRA_MAIN
HISTORICAL_BRANCHES_AND_CLUSTER=NOT_AUDITED
SERVER_NAME=NOT_DECIDED
OIDC_MAS_AUTHENTIK=NOT_QUALIFIED
FEDERATION=NOT_ENABLED
MATRIX_DEPLOYED=NO
FACTORY_NOTIFICATIONS=NOT_ENABLED
```
