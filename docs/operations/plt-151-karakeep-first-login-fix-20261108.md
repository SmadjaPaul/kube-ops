# Karakeep PLT-151 — first-login OAuth exception recovery

**Symptom:** OIDC Authentik first user login reaches /dashboard/bookmarks but Next.js reports `Digest: 4237581454`, and the server emits `[TRPCError]: User settings not found`. Confirmed upstream [#1583](https://github.com/karakeep-app/karakeep/issues/1583) fixed by release [v0.26.0](https://github.com/karakeep-app/karakeep/releases/tag/0.26.0). Similar reproduced [#1604](https://github.com/karakeep-app/karakeep/issues/1604). This exact match is strong evidence but not sufficient to assume that all persistence and credentials are healthy.

## Actual desired-state version before this PR

- `k8s/applications/ai/karakeep/web-statefulset.yaml` declared `ghcr.io/karakeep-app/karakeep:0.32.0`, plus redundant explicit `KARAKEEP_VERSION=0.28.0`.
- `k8s/applications/ai/karakeep/kustomization.yaml` replaces the *effective container image tag* from `KARAKEEP_VERSION=0.25.0`. Thus `kustomize build` selected **0.25.0**, which predates the upstream OAuth-fix. This is not three simultaneously running versions.
- This PR sets the Kustomize single source of image tag to **0.32.0** (already declared in StatefulSet) and removes redundant `KARAKEEP_VERSION` env. `envFrom` retains the ConfigMap and supplies the canonical value.

## Admission and rollback gates

1. **Before merge/rollout:** inspect actual running Pod image ID, DB schema migration history, `/data` PVC status and a completed offsite backup. Verify a **disposable restore** containing a known bookmarks/settings sentinel. Current fleet-wide backup audit is NOT green (22/49 protected; Karakeep-specific recovery must be checked). No reinitialize/delete/blank DB, no handwritten SQL mutations.
2. Execute `kustomize build k8s/applications/ai/karakeep`; assert exactly one web image `ghcr.io/karakeep-app/karakeep:0.32.0` and only one `KARAKEEP_VERSION` config source. Run `just check` and relevant CI without bypass.
3. Verify upgrade migration path `0.25.0 → 0.32.0` against upstream release notes; if an intermediate migration or special upgrade is required, stage it in a **separate reversible PR**, not by destructive trial. Given latest upstream v0.34.1 (2026-10-22), a further upgrade is a separate change after the first login is restored and backups prove recoverability.
4. Merge normally once accepted; Argo Synced+Healthy, correct Pod image and migrations complete. Watch logs for missing user-settings, SQLite errors and OIDC callback failures.
5. USER test via an authorized Authentik user (and an existing local user if any): first-login auto provisioning, settings present, /dashboard/bookmarks loads, bookmarks persist after refresh/restart, nonmember denied. Preserve existing user IDs/bookmarks. Verify policy for `OAUTH_ALLOW_DANGEROUS_EMAIL_ACCOUNT_LINKING=true` and disable **only after** confirming account association works; do not leave unsafe email linking as a permanent workaround.
6. If migration fails, preserve original PVC and rollback with a **verified data restore** as necessary. Downgrading code on a DB migrated by a newer schema may be unsafe; do not claim image rollback is enough.

**Status:** STATIC PR ONLY. No live secrets, backup, runtime change or successful user login is claimed. No production state mutation is authorized by publishing this draft.
