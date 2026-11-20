---
name: deploy-a-service
description: Golden path to add a service to the cluster. Decision tree Q0-Q7 an AI follows from "does it exist" to a verified delivery.
---

# Deploy a service — golden path

Authority: `AGENTS.md`, `k8s/CLAUDE.md`, decisions in `homelab-infra/docs/decisions-active.md`. Answer Q0 to Q7 in order; each answer is written in the PR description. Detail lives in `docs/operations/service-onboarding.md`.

**Who may do this.** Paul's AI merges after a green CI. A relative's AI (friend or family member) opens a PR and **never merges**. Authentik accounts and groups, Doppler values and Cloudflare Access remain Paul's; propose them in the PR, do not create them.

## Q0 — Does it already exist?
Run `just inventory` and search the name. Found: extend or fix it, stop here. Retired or dormant manifest: ask in the PR, never revive silently.

## Q1 — Who uses it? (this sets the Authentik group)
- Admin only -> `authentik-admins`.
- Costs Paul money (AI per request, storage, accounts created at first login) -> `family`.
- Marginal cost zero, same for 5 or 150 users -> `friends` (family inherits it).
Access is **always by group, never per user**. Model: `docs/operations/authentik-access-model.md`.

## Q2 — Where does it run?
- Night use or access from outside the LAN -> **OKE** (`k8s/clusters/oracle-a1`). Stateless, or a `pg-shared` database only once restore is proven outside Oracle (`docs/operations/pg-shared-oke-backup-drill.md`). Deliver with `bash scripts/scaffold-oke-app.sh BASE NAME NAMESPACE`, then `just verify-delivery oracle-a1 NAME`.
- Heavy or LAN-bound -> **homelab**, run by day. Total CPU requests stay <= 70 % of node allocatable; stop the load at 75 °C.

## Q3 — State
- None: preferred.
- Database: one `Database` in `pg-shared`. **Never a new `Cluster`** (`just check` refuses it; `docs/operations/cnpg-cluster-inventory.md`).
- Files: PVC `longhorn-fast` or `longhorn-bulk`, Velero -> R2; add restic if irreplaceable. Large media is not backed up as a volume.
- A restore must be proven before the data counts as safe. No PVC is ever removed as incidental cleanup.

## Q4 — Identity
- App has native OIDC: Authentik blueprint (`k8s/infrastructure/auth/authentik/extra/blueprints/`), **confidential client**, secret `APP_<APP>_OIDC_CLIENT_SECRET` in Doppler delivered by ESO. Keep the local login until the first admin OIDC login works (`.agents/skills/oidc-integration`).
- No OIDC: forward-auth through the Authentik outpost.
- Policy binds a group (Q1), never a user.

## Q5 — Exposure
- Default: HTTPRoute on `Gateway/internal`.
- Public: `Gateway/external` **only** with Cloudflare Access restricted by group. WARNING: a wildcard `*.smadja.dev` points to `external`, so an external route is public the moment it is merged.
- Admin or home services: NetBird only, no route on `external`.

## Q6 — Baseline (every item, `k8s/CLAUDE.md` has the exact fields)
- Pod/container securityContext (non-root, no privilege escalation, drop ALL, read-only root fs), emptyDir size limits.
- CPU and memory requests and limits on every container.
- CiliumNetworkPolicy default-deny ingress and egress, then explicit allows.
- ExternalSecret `external-secrets.io/v1`, store `doppler-cluster`, UPPER_SNAKE_CASE keys.
- ServiceMonitor and at least one alert.
- Image pinned to a fixed tag, never `latest`.

## Q7 — Delivery
PR -> `just check` (and `kustomize build --enable-helm <root>`) -> CI green -> merge without `--admin` -> `just verify-delivery <cluster> <app>`. Report four proofs separately: STATIC (render/tests), RECONCILED (Argo Synced/Healthy), RUNTIME (pods, route answer), USER (a real login by the right group, if applicable).

## Real example: Mealie (`k8s/applications/catalog/mealie`)
Q1 `family`; Q2 homelab; Q3 one `longhorn-fast` PVC (Velero), no database; Q4 native OIDC with `APP_MEALIE_OIDC_CLIENT_SECRET` through ESO; fixed image tag, Cilium policy, requests/limits, non-root.
Known gaps, do not copy: no `readOnlyRootFilesystem`, no ServiceMonitor or alert, and its route also targets `Gateway/external` (legacy, to review under Q5). Do not copy the dedicated CNPG `Cluster` of paperless or RomM either: they are "to consolidate" into `pg-shared`.
