# SparkyFitness v1.11.0 — confidential Authentik pilot

Status: **STAGED / NOT DEPLOYED / NO-GO for family onboarding until tested**.
The candidate in `k8s/optional/sparkyfitness` is outside live Argo roots.

Upstream contract:
- https://github.com/CodeWithCJ/SparkyFitness/blob/v1.11.0/helm/README.md
- https://github.com/CodeWithCJ/SparkyFitness/blob/v1.11.0/SparkyFitnessServer/auth.ts
- https://github.com/CodeWithCJ/SparkyFitness/blob/v1.11.0/SparkyFitnessServer/utils/oidcEnvConfig.ts

## Authentik

Staged Blueprint `authentik-blueprint.staged.yaml`: confidential authorization-code
client ID `sparkyfitness`, issuer
`https://auth.smadja.dev/application/o/sparkyfitness/`, exact redirect
`https://fitness.smadja.dev/api/auth/sso/callback/authentik`.
This is the Better Auth server callback; `/oidc-callback` is only a
frontend page. Map `openid email profile groups`; only
`authentik-admins` becomes admin. Keep email/password login as local
breakglass during testing.

Staged auth-side secret `APP_SPARKYFITNESS_OIDC_CLIENT_SECRET` must
be wired to the Authentik blueprint worker. The same secret is used
by wellness ESO to populate `sparkyfitness-oidc` (keys
`client_id`, `client_secret`). Its client ID must be exactly
`sparkyfitness`. No secret values are in Git and no Doppler key
existence has been verified.

## Critical upstream limitation — signup

In v1.11.0 `SparkyFitnessServer/auth.ts` the `user.create.before` hook
rejects **all** new users when `SPARKY_FITNESS_DISABLE_SIGNUP=true`,
before it checks `SSO auto_register`. Thus it is NOT valid to combine
`disableSignup=true` with `oidc.autoRegister=true` and claim new family
members can sign in on first use.

The staged target intentionally uses **both toggles false for registration**
(`disableSignup=true`, `oidc.autoRegister=false`), to fail closed.
First create the initial trusted local admin and pre-provision/link any
family accounts in a **separately admitted bootstrap** before switching
to the closed target. The configured `SPARKY_FITNESS_ADMIN_EMAIL`
is taken from Doppler's existing `APP_AUTHENTIK_ADMIN_EMAIL`; this
grants admin to an account matching the address, not an account
bootstrap itself. Do not bypass this by leaving public email signup open.
For self-service OIDC family onboarding without email signup, an
upstream change or a separately tested admission control is required.

## Database and secrets

- CNPG `sparkyfitness-db` owns DB/user `sparky_admin` with
  `CREATEROLE`; app runtime `sparky_app` is different and RLS-limited.
  Prove the role reconciliation works under CNPG managed.roles, then
  verify tenant isolation by actual cross-user queries.
- ESO runtime keys: `APP_SPARKYFITNESS_API_ENCRYPTION_KEY` must be
  64 hex characters (AES-256); `APP_SPARKYFITNESS_BETTER_AUTH_SECRET`
  must decode to >=32 bytes from base64; do not rotate either blindly.
- Ensure `APP_SPARKYFITNESS_DB_APP_USERNAME=sparky_app` and
  `APP_SPARKYFITNESS_DB_APP_PASSWORD` match the runtime restricted role.
  The CNPG `sparkyfitness-db-app` secret provides migration owner
  credentials separately.
- Barman (PLT-147): the Cluster archives WAL and takes a weekly base
  backup through the `barman-cloud.cloudnative-pg.io` plugin into
  `s3://smadja-dev-homelab-backups/cnpg/sparkyfitness`, with the shared
  `HETZNER_S3_*` keys like the other CNPG clusters (polyfin model).
  The dedicated `APP_SPARKYFITNESS_CNPG_S3_*` keys never existed in
  Doppler `cluster/prd`; a scoped key remains a hardening follow-up, not a
  precondition for having a backup. Full CNPG restore and uploads PVC
  Velero/Kopia restore are still REQUIRED before family use.
- The upstream chart resolves the server and frontend to these immutable
  GHCR references; keep both digests in the Argo values and re-check them
  when the chart revision changes:
  `ghcr.io/codewithcj/sparkyfitness-server:v1.11.0@sha256:51a2d7c19bd99b50ea17e579fe8d9d4febed895595356b1ddafe0fa808caf75e`
  and
  `ghcr.io/codewithcj/sparkyfitness-frontend:v1.11.0@sha256:5eb77135ccd8e58492ee9bd19b8714ea4a73a99623b863a9287ccecb0557cd17`.
  Existence of the image is not runtime qualification; the chart remains
  staged until bootstrap, RLS, ESO and restore tests pass.
- Disable Garmin until API egress and health-data retention are qualified.
  Keep internal Gateway HTTPS only; never world egress for OIDC.
- Test iOS/Android SSO, HealthKit/Health Connect sync permission boundaries,
  data deletion/export, 2FA fallback, admin restriction and restore.

STATIC render/CI, RECONCILED, RUNTIME and USER proofs are separate gates.

## Isolated CNPG restore scenario (PLT-92, not executed)

Prerequisites: `ScheduledBackup` or an on-demand `Backup` is `completed`,
`Cluster` condition `ContinuousArchiving=True` and
`status.firstRecoverabilityPoint` is set. Run it only inside an approved
PLT-92 window.

1. Branch `claude/plt92-sparkyfitness-restore`: add a dormant root
   `k8s/optional/sparkyfitness-restore/` modelled on
   `k8s/optional/personal-ai-2026/hindsight-restore/`: namespace
   `sparkyfitness-restore-<date>` labelled
   `backup.smadja.dev/restore-drill: "true"`, ExternalSecret
   `HETZNER_S3_*`, ObjectStore pointing at the same `destinationPath`
   **without** a WAL archiver Cluster or ScheduledBackup.
2. `Cluster sparkyfitness-db-restore`: `bootstrap.recovery.source:
   sparkyfitness-source`, `externalClusters[0].plugin` =
   `barman-cloud.cloudnative-pg.io` with `barmanObjectName` = restore
   ObjectStore and `serverName: sparkyfitness-db`. Use a `recoveryTarget`
   (`backupID` or `targetTime`) to measure RPO. Do not declare `plugins`
   with `isWALArchiver` on the restored cluster: it must never write into
   the source prefix.
3. CiliumNetworkPolicy: no application ingress; operator only.
4. Proof (read-only): restored Cluster `Ready`, `pg_restore`-free row
   counts on a few key tables (users, food entries, exercise entries)
   compared with the source at the recovery target, timestamps and UIDs.
   Record `RESTORE=PASS`, RPO (target vs last archived WAL) and RTO
   (Cluster creation to Ready).
5. Teardown in the same window: remove the root from Git; Argo prunes the
   namespace. The S3 source prefix is never deleted or rewritten.

Until then: `CNPG_RESTORE_PASS=NOT_PROVEN`.
