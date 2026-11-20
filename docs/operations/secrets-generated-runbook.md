# Secrets generated inside the cluster — runbook

Authority: [AGENTS.md](../../AGENTS.md) and homelab-infra `docs/decisions.md`. Plan: `docs/architecture/secrets-migration-spec.md` (PR #1660, lots 0 to 3). This page is the short usage guide of lot 0. No secret value ever appears in Git, a PR, a log or a report.

## What exists

| Brick | Where | Role |
| --- | --- | --- |
| ClusterSecretStore `k8s-auth`, `k8s-databases` | `k8s/infrastructure/controllers/external-secrets/k8s-stores.yaml` | ESO provider `kubernetes`, one source namespace each (`auth`, `databases`), ServiceAccount `eso-k8s-<ns>-reader` |
| Role + RoleBinding `eso-k8s-<ns>-reader` | next to the sources: `auth/authentik/extra/eso-k8s-reader-rbac.yaml`, `database/pg-shared-homelab/eso-k8s-reader-rbac.yaml` | `get` on a list of Secret names. The name `eso-k8s-sentinel-none` stays: an empty `resourceNames` would grant every Secret of the namespace |
| Admission rule `eso-k8s-store-guard` | `k8s/infrastructure/security/policies/eso-k8s-store-guard.yaml` | Deny with `failurePolicy: Ignore`: an ExternalSecret reads only `oidc-<its namespace>` (`k8s-auth`) or `pg-<its namespace>` (`k8s-databases`), plus `--<usage>` suffixes |
| CI rules | `policy/static/repo-contract.yaml` (`repo-contract-externalsecret-contract`, `repo-contract-eso-k8s-store-own-namespace`), `tests/harness/eso-generated-secrets-contract-test.sh` | Same rule in CI; generator and Role contract |
| Metrics and alert | ESO `ServiceMonitor` (`values.yaml`), `prometheusrule.yaml` | `ExternalSecretNotReady`: `externalsecret_status_condition{condition="Ready",status="False"} == 1` for 15 minutes |

Three ExternalSecret forms are valid (`repo-contract-externalsecret-contract`): (A) `doppler-cluster`, (B) `k8s-auth` or `k8s-databases`, both `ClusterSecretStore` with `refreshInterval: 1h`, (C) a generated source: no `secretStoreRef`, no `data`, every `dataFrom[]` is a `sourceRef.generatorRef`, `refreshPolicy: CreatedOnce`, `target.creationPolicy: Orphan`.

## Which secret may be generated

Only internal secrets: database role passwords (T1), OIDC client secrets (T3), session or cookie keys that encrypt nothing persisted (T4), secrets shared between pods of one namespace (T5). A key that encrypts stored data (T6), a root (T7) and external tokens (T8, T9) stay in Doppler and are never generated. The test refuses a generator whose template key matches `ENCRYPT|KEY_BASE|APP_KEY|MASTER_KEY|RESTIC|REPOSITORY_PASSWORD|SECRET_KEY`. Exception: class `T4` plus the annotation `kube-ops.io/not-data-key: "<why nothing persisted is encrypted with it>"`. When in doubt, it is a T6.

## Add a generated source and its consumer (one app per PR)

1. In the source namespace folder, add a `Password` and an ExternalSecret named `oidc-<ns>` (`auth`) or `pg-<ns>` (`databases`), form (C), annotation `kube-ops.io/secret-class: T1|T3|T4|T5`, `creationPolicy: Orphan`. Use `symbols: 0` for URL and DSN safety. Pattern: `k8s/applications/platform/factory-platform/database-source-credentials.yaml`.
2. In the Role `eso-k8s-<ns>-reader` of that folder, add the source name to `resourceNames`. Keep the sentinel.
3. In the app namespace, add an ExternalSecret form (B): `secretStoreRef: {kind: ClusterSecretStore, name: k8s-auth}`, `refreshInterval: 1h`, `target.creationPolicy: Owner`, `data[].remoteRef.key: oidc-<app namespace>`. No `dataFrom`. Non-secret values (OIDC client id, user name) are literals in `target.template.data`.
4. Consumers reload with `secret.reloader.stakater.com/reload: <copy name>`. A consumer that cannot start without the Secret (Authentik `envFrom`) references it with `optional: true`.
5. `just check`, then `kustomize build --enable-helm` on each touched root.

Adding a key to an existing `CreatedOnce` source does nothing (no refresh): use a new source, or rotate by renaming.

## Rotate

Rename the source ExternalSecret and keep `target.name`. The new name must still follow the source naming rule `oidc-<ns>` or `oidc-<ns>--<usage>` (`pg-<ns>`, `pg-<ns>--<usage>` for databases): `oidc-<ns>-r2` is REFUSED by `repo-contract-eso-k8s-store-own-namespace`. Rotation by renaming uses the double dash: `oidc-<ns>--r2`. Add the new name to `resourceNames` if it is also a new `target.name` (a rotation that keeps `target.name` needs no Role change). ESO treats it as new, generates a new value and updates the existing Secret in place. The copy follows within `refreshInterval` (1 h); to be immediate, rename the copy ExternalSecret in a second commit. Reloader restarts the consumers. The old Password generator may be renamed with it. Never edit a Secret by hand.

### Argo applications and wave order

The real Argo Applications: `infra-auth` (`k8s/infrastructure/auth`: sources, Role `eso-k8s-auth-reader`, Authentik), `apps-platform` (overlay `k8s/applications/platform/rustical-pilot`, which includes `k8s/optional/rustical`), `infra-controllers` (`k8s/infrastructure/controllers`: ESO, stores, Velero, ...). They are separate Applications, so sync waves do not order them against each other. A copy ExternalSecret that reaches the cluster before the Role of `infra-auth` is applied (a new name added to `resourceNames`) takes a transient `403 forbidden` on the store, then retries and becomes `Ready` once the Role exists. This is expected: check again after the next reconcile before calling it a failure, and keep a real, persistent 403 for a name that is not in `resourceNames`.

## Loss of a generated Secret (MANDAT)

`Orphan` means a deleted source Secret is not recreated (the status is already filled): consumers fail visibly and `ExternalSecretNotReady` fires, instead of a silent new value. Recovery is a rotation by renaming (section above). Deleting an ExternalSecret or a Secret is outside `scripts/kubectl-rw.sh` (policy `agent-operator-guard`): Paul or an operator does it. A Velero restore of a generated Secret is overwritten by ESO as soon as a new ExternalSecret reconciles; there is no S3 backup of generated secrets by design (disposable).

## Read the proofs without a value

Allowed: `bash scripts/kubectl-ro.sh get clustersecretstore k8s-auth k8s-databases` (`Ready=True`), `get externalsecret -n <ns> <name> -o yaml` (conditions, `refreshTime`), `get secret -n <ns> <name>` without `-o` (age, size), a functional result (login works), or a 12-character SHA-256 prefix computed inside the cluster by a Job. A 403 `forbidden` on a key outside `resourceNames` proves the RBAC layer. Never read or print `data`.

## Drill D0 (operator, after merge)

Proves that `CreatedOnce` is stable, that a rename rotates, that RBAC refuses a name outside the list and that the alert fires. Status: DONE on 2026-11-20 (FP#1 = FP#2 = `6ff2efa1dedc`, rotation by renaming FP#3 = `41cf5cc63ed2`); the manifests are removed by the cleanup PR `claude/secrets-d0-cleanup`. Procedure and history: `docs/operations/secrets-drill-d0-createdonce.md` (rotation source `oidc-eso-drill--r2`, double dash). Read-only commands and PASS/FAIL criteria: `docs/operations/secrets-migration-evidence.md`, section lot 0. The rotation is the second step (two commits, separate PR).

## Database role passwords of `pg-shared-homelab` (lot 1)

A NEW application database no longer needs a Doppler key created by hand: follow `k8s/infrastructure/database/pg-shared-homelab/app-database.example.tmpl` (managed role `passwordSecret: pg-<ns>`, generated source `pg-<ns>` in `databases` class `T1`, allow-list entry in `eso-k8s-reader-rbac.yaml`, copy `<app>-db` in the application namespace through `k8s-databases`). Existing databases are not migrated: migrating a secret to a generator is a rotation (spec F3a), and needs D1b first. Rotation: rename the source ExternalSecret `pg-<ns>` to `pg-<ns>--r2` (keep `target.name`); CNPG applies the new value immediately (`cnpg.io/reload`, condition `PasswordSecretChange` changes), the copy follows within 1 h or by renaming the copy in a second commit, Reloader restarts the application. Drills, not run: D1 `docs/operations/secrets-drill-d1-pg-shared-role.md`; D1b (before any real data) `docs/operations/pg-shared-app-restore-drill.md`.

## Drill D2: OIDC rotation, RustiCal pilot (operator, after merge of lot 2, NOT run)

Proves that a T3 secret is disposable: the OIDC login works before and after a rotation by renaming. Pilot: RustiCal (`rustical-pilot`, synthetic data only, no PostgreSQL). Source `oidc-rustical-pilot` (namespace `auth`), copy `rustical-oidc` (namespace `rustical-pilot`), key `RUSTICAL_OIDC_CLIENT_SECRET`. Read with `KUBECTL_RO_IDENTITY=agent bash scripts/kubectl-ro.sh`; never print `data`. Record each verdict in the PR of lot 2 (no value).

1. **State after merge.** `get externalsecret -n auth oidc-rustical-pilot` and `-n rustical-pilot rustical-oidc`: both `Ready=True`; `get secret -n auth oidc-rustical-pilot` and `-n rustical-pilot rustical-oidc` exist (age, size). Argo CD applications `infra-auth` (Authentik, Role, source) and `apps-platform` (RustiCal overlay) are `Synced`/`Healthy`.
2. **Authentik restarted by Reloader.** Authentik server and worker pods are newer than the merge and `Running`. `get pods -n auth`. Then `tests/e2e/specs/authentik.spec.ts` passes (no SSO regression).
3. **Blueprint.** `logs -n auth <worker pod>`: no error for `Apps - RustiCal` (blueprint `k8s/infrastructure/auth/authentik/extra/blueprints/apps-rustical.yaml`) (check after each Authentik restart, here and in step 6).
4. **Baseline login (replaces "login before rotation").** Generation went live on 2026-11-20 at 19:15 UTC, so a login with the previous (Doppler) value can no longer be measured. The test of the day, on the generated value, is the baseline: on `https://calendar.smadja.dev`, sign in through Authentik as `qa-e2e-user` (QA user, not a family account), then one synthetic CalDAV operation (contract `PILOT_GO`). Verdict `PASS`/`FAIL`, with the time.
5. **Rotation (commit 1).** Rename the source ExternalSecret `oidc-rustical-pilot` to `oidc-rustical-pilot--r2` (double dash, rule `oidc-<ns>--<usage>`) in `k8s/infrastructure/auth/authentik/extra/oidc-rustical-pilot.yaml`, keep `target.name: oidc-rustical-pilot` (the generator may be renamed with it). The `Password` generator referenced by `generatorRef` must be renamed in the same commit. Merge. Expect: the renamed source is new (empty status), generates a new value and updates the Secret `oidc-rustical-pilot` in place (F3). Evidence without value: `get externalsecret -n auth oidc-rustical-pilot-r2` is `Ready=True` with a recent `refreshTime`; the Secret `resourceVersion` changed (`get secret -n auth oidc-rustical-pilot -o jsonpath='{.metadata.resourceVersion}'` is allowed, a version is not a value).
6. **Rotation (commit 2, optional, immediate copy).** Rename the copy `rustical-oidc` to `rustical-oidc-r2` in `k8s/optional/rustical/external-secret.yaml` (rendered in namespace `rustical-pilot` by the `apps-platform` overlay; keep `target.name: rustical-oidc`). Without it the copy follows within 1 h (`refreshInterval`). Expect both sides restarted by Reloader: Authentik pods (watching `oidc-rustical-pilot`) and the `rustical` Deployment (watching `rustical-oidc`); pods newer than the commit and `Running`; blueprint log of step 3 clean again.
7. **Login AFTER rotation.** Same sign-in and same CalDAV operation as step 4, in a new private window (old session dropped). Verdict `PASS`/`FAIL`.
8. **Verdict D2.** `PASS` only if steps 4 and 7 are `PASS` and steps 3 and 6 have no blueprint error. Consign in the PR of lot 2. Step 7 is compared with the step 4 baseline (generated value, not the Doppler one). Step 5 is the starting point of the 7 days before homelab-infra PR H3 (exit of the RustiCal keys from Doppler).

Rollback: `git revert` of the lot 2 PR; the Doppler ExternalSecret returns with the old value, still present in Doppler until H3. If the copy stays stale after a rotation, rename it (step 6). If the source Secret was lost (`Orphan`, not recreated), it is a rotation by renaming (MANDAT section above).
