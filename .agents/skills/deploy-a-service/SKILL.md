---
name: deploy-a-service
description: Golden path to add a service to the cluster. Decision tree Q0-Q7, proven by `just app-test`, a PR preview and the post-merge check (auto-revert of a broken deployment).
---

# Deploy a service — golden path

Authority: `AGENTS.md`, `k8s/CLAUDE.md`, decisions in `homelab-infra/docs/decisions-active.md`. Answer Q0 to Q7 in order; each answer is written in the PR description. Detail lives in `docs/operations/service-onboarding.md`.

**Who may do this.** Paul's AI merges after a green CI. A relative's AI (friend or family member) opens a PR and **never merges**. Authentik accounts and groups and Cloudflare Access remain Paul's; propose them in the PR, do not create them. Internal secrets need no manual gesture: they are generated in the cluster (Q4, Q6); Doppler values exist only for the external and root classes (T6 to T9) and are Paul's.

## Q0 — Does it already exist?
Run `just inventory` and search the name. Found: extend or fix it, stop here. Retired or dormant manifest: ask in the PR, never revive silently.

## Q1 — Who uses it? (this sets the Authentik group)
- Admin only -> `authentik-admins`.
- Costs Paul money (AI per request, storage, accounts created at first login) -> `family`.
- Marginal cost zero, same for 5 or 150 users -> `friends` (family inherits it).
Access is **always by group, never per user**. Model: `docs/operations/authentik-access-model.md`.

## Q2 — Where does it run?
- Night use or access from outside the LAN -> **OKE** (`k8s/clusters/oracle-a1`). Stateless, or a `pg-shared` database only once restore is proven outside Oracle (`docs/operations/pg-shared-oke-backup-drill.md`). Deliver with `bash scripts/scaffold-oke-app.sh BASE NAME NAMESPACE`, then `just verify-delivery oracle-a1 NAME`.
- Heavy or LAN-bound -> **homelab**, run by day.

## Q3 — State
- None: preferred.
- Database: one `Database` in `pg-shared`. **Never a new `Cluster`** (`just check` refuses it; `docs/operations/cnpg-cluster-inventory.md`).
- Files: PVC `longhorn-fast` or `longhorn-bulk`, Velero -> R2; add restic if irreplaceable. Large media is not backed up as a volume.
- A restore must be proven before the data counts as safe. No PVC is ever removed as incidental cleanup.

## Q4 — Identity
- App has native OIDC: Authentik blueprint (`k8s/infrastructure/auth/authentik/extra/blueprints/`), **confidential client**. Its secret is generated in the cluster (class T3, `oidc-<namespace>` in `auth`, copy `<app>-oidc` through store `k8s-auth`); nothing goes to Doppler, the client id is a Git literal. Run `bash scripts/scaffold-app-secrets.sh APP --namespace NS --oidc CLIENT_ID` (dry-run, then `--write`). Keep the local login until the first admin OIDC login works (`.agents/skills/oidc-integration`).
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
- Secrets by class (`docs/architecture/secrets-migration-spec.md` section 4.1, runbook `docs/operations/secrets-generated-runbook.md`). Run `bash scripts/scaffold-app-secrets.sh APP --namespace NS [--oidc CLIENT_ID] [--pg-shared] [--local-key USAGE] [--external cloudflare-dns|r2-writer]` (dry-run by default, `--write` to apply; refuses an existing file; prints names only):
  - T1 `pg-shared-homelab` role password, T3 OIDC client secret, T4 session or cookie key that encrypts nothing persisted, T5 secret shared in one namespace: **generated in the cluster** (`Password` + ExternalSecret `CreatedOnce`/`Orphan`), disposable, no Doppler value, no manual step. The copy in the app namespace uses store `k8s-auth` or `k8s-databases` (`refreshInterval: 1h`) and the Deployment carries `secret.reloader.stakater.com/reload`.
  - T6 key that encrypts stored data (`--data-key USAGE`): never generated in the cluster; the script prints the homelab-infra PR (OpenTofu `random_bytes` + `doppler_secret`, `prevent_destroy`) and the `doppler-cluster` ExternalSecret. Doubt means T6.
  - T7 roots, T8 external API tokens (reuse the existing Cloudflare or R2 keys with `--external`), T9 tokens issued by an app: Doppler through `doppler-cluster`, Paul's.
  - T10 non-secret (URL, client id): literal in Git.
  - UPPER_SNAKE_CASE keys.
- ServiceMonitor and at least one alert.
- Image pinned to a fixed tag, never `latest`.

## Q7 — Prove it: `just app-test`, preview, post-merge
The questions are the guide; `just app-test` is the guarantee (7 checks: `oidc exposure backup renovate observability selfheal network`; output `CHECK <id> PASS|FAIL|SKIP|BLOCKED`, then `APP_TEST=`).
1. Branch `claude/<ticket>-<app>`. `just app-test <app> <ns> --phase static` until `APP_TEST=PASS`, plus `kustomize build --enable-helm k8s/applications/<domain>/<app>` and `just check`. A new app is judged strictly; never extend `policy/app-test-baseline.tsv` or `policy/baseline.tsv` by hand (`--no-ratchet` shows raw debt).
2. PR (draft while red) with labels `preview` and `preview:<app>` (one app per PR). Argo deploys it in namespace `pr-<n>-<app>`, host `<app>-<n>-preview.smadja.dev` on `Gateway/internal` (LAN only; `Gateway/external` refuses preview namespaces, Cloudflare Access is not the guard today). The preview admits only a fixed list of kinds (no CiliumNetworkPolicy, RBAC, GRPCRoute). Preview secrets are **generated in the preview namespace** (form C only): no production store (`doppler-cluster`, `k8s-auth`, `k8s-databases`), no `pg-shared` database, no real third-party token. When Healthy: `just app-test <app> pr-<n>-<app> --phase runtime --chaos` (deletes one pod, `pr-*` only). Runbook: `docs/runbooks/preview-environments.md`.
3. Merge (Paul's AI only, never `--admin`) when CI and preview are green; PR body lists checks run with result and checks not run with reason.
4. After merge, the `Post-merge verify` workflow (`docs/operations/post-merge-verify.md`) waits for the Argo revision, runs `app-test --phase runtime` and **reverts only a broken deployment** (`DEPLOY_HEALTH=FAIL`: pods not Ready or recent restarts). Golden-path debt (oidc, network, backup...) or `BLOCKED` sends a ntfy notification, no revert: read it and fix. Replay without risk: `gh workflow run post-merge-verify.yaml -f sha=<sha>` (dry-run).
5. Report STATIC, CI, RECONCILED, RUNTIME (and USER when a real login matters) separately.

**Exceptions.** Only when the app cannot comply, in `app-test.yaml` next to the app, each with a non-empty reason (format: header of `scripts/app-test.sh`): `exceptions.observability` (no `/metrics`), `backup: none` + `exceptions.backup`, `exceptions.rootfs`, `auth: none` + `exceptions.auth` (Paul decides), `admin: true` (internal-only admin app). OIDC apps declare `auth: oidc` and `auth_probe: <protected path>`. An exception is a decision stated in the PR, not a way to turn the test green.

**Limits.** A revert restores manifests, not data or a migration: back up and prove one restore before merging an app with a PVC or database (`.agents/skills/backup-restore`). A KEDA scale-to-zero app has no pod to judge (`selfheal` SKIP). Cluster or Argo trouble: `.agents/skills/cluster-investigation`.

## Real example: Mealie (`k8s/applications/catalog/mealie`)
Q1 `family`; Q2 homelab; Q3 one `longhorn-fast` PVC (Velero), no database; Q4 native OIDC with `APP_MEALIE_OIDC_CLIENT_SECRET` through ESO from Doppler (legacy: a new app generates its secret, see Q4); fixed image tag, Cilium policy, requests/limits, non-root.
Known gaps, do not copy: no `readOnlyRootFilesystem`, no ServiceMonitor or alert, and its route also targets `Gateway/external` (legacy, to review under Q5). Do not copy the dedicated CNPG `Cluster` of paperless or RomM either: they are "to consolidate" into `pg-shared`.
