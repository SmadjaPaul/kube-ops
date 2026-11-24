# Secrets generated inside the cluster — runbook

Authority: [AGENTS.md](../../AGENTS.md) and homelab-infra `docs/decisions.md`. Plan: `docs/architecture/secrets-migration-spec.md` (PR #1660, lots 0 to 3). This page is the short usage guide of lot 0. No secret value ever appears in Git, a PR, a log or a report.

## What exists

| Brick | Where | Role |
| --- | --- | --- |
| ClusterSecretStore `k8s-auth`, `k8s-databases`, `k8s-agentgateway` (PLT-453: source ns `agentgateway`, prefix `llm-`, keys `pr-triage` for the agent-harness ARC runner and `incident-sentinel` (source `llm-agents`, copy created with PLT-455)) | `k8s/infrastructure/controllers/external-secrets/k8s-stores.yaml` | ESO provider `kubernetes`, one source namespace each (`auth`, `databases`), ServiceAccount `eso-k8s-<ns>-reader` |
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

Shortcut for a new app: `bash scripts/scaffold-app-secrets.sh APP --namespace NS [--oidc CLIENT_ID] [--pg-shared] [--local-key USAGE[:T5]] [--data-key USAGE] [--external cloudflare-dns|r2-writer]` writes steps 1 to 4 (dry-run by default, `--write` to apply, refuses an existing target file, prints names only). `--pg-shared` follows `app-database.example.tmpl` (`tests/harness/scaffold-app-secrets-test.sh` compares the two). `--data-key` writes nothing: it prints the OpenTofu PR and the `doppler-cluster` ExternalSecret of a T6 key.

## Rotate

Rename the source ExternalSecret and keep `target.name`. The new name must still follow the source naming rule `oidc-<ns>` or `oidc-<ns>--<usage>` (`pg-<ns>`, `pg-<ns>--<usage>` for databases): `oidc-<ns>-r2` is REFUSED by `repo-contract-eso-k8s-store-own-namespace`. Rotation by renaming uses the double dash: `oidc-<ns>--r2`. Add the new name to `resourceNames` if it is also a new `target.name` (a rotation that keeps `target.name` needs no Role change). ESO treats it as new, generates a new value and updates the existing Secret in place. The copy follows within `refreshInterval` (1 h); to be immediate, rename the copy ExternalSecret in a second commit. Reloader restarts the consumers. The old Password generator may be renamed with it. Never edit a Secret by hand.

### Argo applications and wave order

The real Argo Applications: `infra-auth` (`k8s/infrastructure/auth`: sources, Role `eso-k8s-auth-reader`, Authentik), `app-rustical-pilot` (overlay `k8s/applications/platform/rustical-pilot`, which includes `k8s/optional/rustical`), `infra-controllers` (`k8s/infrastructure/controllers`: ESO, stores, Velero, ...). They are separate Applications, so sync waves do not order them against each other. A copy ExternalSecret that reaches the cluster before the Role of `infra-auth` is applied (a new name added to `resourceNames`) takes a transient `403 forbidden` on the store, then retries and becomes `Ready` once the Role exists. This is expected: check again after the next reconcile before calling it a failure, and keep a real, persistent 403 for a name that is not in `resourceNames`.

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

1. **State after merge.** `get externalsecret -n auth oidc-rustical-pilot` and `-n rustical-pilot rustical-oidc`: both `Ready=True`; `get secret -n auth oidc-rustical-pilot` and `-n rustical-pilot rustical-oidc` exist (age, size). Argo CD applications `infra-auth` (Authentik, Role, source) and `app-rustical-pilot` (RustiCal overlay) are `Synced`/`Healthy`.
2. **Authentik restarted by Reloader.** Authentik server and worker pods are newer than the merge and `Running`. `get pods -n auth`. Then `tests/e2e/specs/authentik.spec.ts` passes (no SSO regression).
3. **Blueprint.** `logs -n auth <worker pod>`: no error for `Apps - RustiCal` (blueprint `k8s/infrastructure/auth/authentik/extra/blueprints/apps-rustical.yaml`) (check after each Authentik restart, here and in step 6).
4. **Baseline login (replaces "login before rotation").** Generation went live on 2026-11-20 at 19:15 UTC, so a login with the previous (Doppler) value can no longer be measured. The test of the day, on the generated value, is the baseline: on `https://calendar.smadja.dev`, sign in through Authentik as `qa-e2e-user` (QA user, not a family account), then one synthetic CalDAV operation (contract `PILOT_GO`). Verdict `PASS`/`FAIL`, with the time.
5. **Rotation (commit 1).** Rename the source ExternalSecret `oidc-rustical-pilot` to `oidc-rustical-pilot--r2` (double dash, rule `oidc-<ns>--<usage>`) in `k8s/infrastructure/auth/authentik/extra/oidc-rustical-pilot.yaml`, keep `target.name: oidc-rustical-pilot` (the generator may be renamed with it). The `Password` generator referenced by `generatorRef` must be renamed in the same commit. Merge. Expect: the renamed source is new (empty status), generates a new value and updates the Secret `oidc-rustical-pilot` in place (F3). Evidence without value: `get externalsecret -n auth oidc-rustical-pilot--r2` is `Ready=True` with a recent `refreshTime`; the Secret `resourceVersion` changed (`get secret -n auth oidc-rustical-pilot -o jsonpath='{.metadata.resourceVersion}'` is allowed, a version is not a value).
6. **Rotation (commit 2, optional, immediate copy).** Rename the copy `rustical-oidc` to `rustical-oidc-r2` in `k8s/optional/rustical/external-secret.yaml` (rendered in namespace `rustical-pilot` by the `apps-platform` overlay; keep `target.name: rustical-oidc`). Without it the copy follows within 1 h (`refreshInterval`). Expect both sides restarted by Reloader: Authentik pods (watching `oidc-rustical-pilot`) and the `rustical` Deployment (watching `rustical-oidc`); pods newer than the commit and `Running`; blueprint log of step 3 clean again.
7. **Login AFTER rotation.** Same sign-in and same CalDAV operation as step 4, in a new private window (old session dropped). Verdict `PASS`/`FAIL`.
8. **Verdict D2.** `PASS` only if steps 4 and 7 are `PASS` and steps 3 and 6 have no blueprint error. Consign in the PR of lot 2. Step 7 is compared with the step 4 baseline (generated value, not the Doppler one). Step 5 is the starting point of the 7 days before homelab-infra PR H3 (exit of the RustiCal keys from Doppler).

Rollback: `git revert` of the lot 2 PR; the Doppler ExternalSecret returns with the old value, still present in Doppler until H3. If the copy stays stale after a rotation, rename it (step 6). If the source Secret was lost (`Orphan`, not recreated), it is a rotation by renaming (MANDAT section above).

## Operator command sheet: D1 and D1b (NOT run; read-only commands, every write goes through a merged PR)

Prefix of every command: `KUBECTL_RO_IDENTITY=agent bash scripts/kubectl-ro.sh`. Never `-o yaml` on a Secret, never print `data`. Manifests of the drill PR: `docs/operations/secrets-drill-d1-pg-shared-role.md` (blocks 1 to 3). Rotation names use the double dash (`pg-eso-drill--r2`).

### D1 (role password generated in the cluster, rotation by renaming)

| # | Command or action | Expected output |
| --- | --- | --- |
| 0 | `get cluster -n databases pg-shared-homelab` ; `get clustersecretstore k8s-auth k8s-databases` ; `get secret -A \| grep -c eso-drill` | `Cluster in healthy state` ; both `Ready True` ; `0` |
| 1 | Open the drill PR (draft, separate from any lot), merge it, wait for Argo `infra-database` and `infra-controllers` Synced (and the AppProject destination for `eso-drill`) | |
| 2 | `get externalsecret -n databases pg-eso-drill` ; `get externalsecret -n eso-drill eso-drill-db` | both `SecretSynced True` |
| 3 | `get cluster -n databases pg-shared-homelab -o jsonpath='{.status.conditions[?(@.type=="PasswordSecretChange")].message}'` ; note it | a message with a `resourceVersion` (never a value) |
| 4 | `get job -n eso-drill eso-drill-db-connect` ; `logs -n eso-drill job/eso-drill-db-connect` | `Complete 1/1` ; `CONNECT=OK` (baseline PASS) |
| 5 | Commit 1: rename ExternalSecret AND Password `pg-eso-drill` to `pg-eso-drill--r2`, keep `target.name: pg-eso-drill`; merge | `get externalsecret -n databases pg-eso-drill--r2` `SecretSynced True`, fresh `refreshTime`; `get secret -n databases pg-eso-drill` keeps its age |
| 6 | Re-run the step 3 command | message DIFFERENT from step 3 (new `resourceVersion`); `get cluster` still healthy |
| 7 | Copy: wait 1 h, or commit 2 renaming `eso-drill-db` to `eso-drill-db-r2` (record any "owned by another ExternalSecret" error) | `get externalsecret -n eso-drill` `SecretSynced True` |
| 8 | Trigger the PostSync Job again (Argo sync of the owning app, or an empty commit); `logs -n eso-drill job/eso-drill-db-connect` | `CONNECT=OK` (after PASS) |

Verdict: PASS if steps 4 and 8 give `CONNECT=OK` and the step 6 message differs from step 3. Otherwise FAIL (consign time, CNPG condition, copy state; fix nothing by hand). Consign in `docs/operations/secrets-migration-evidence.md` (lot 1), no value.

Rollback and cleanup: `git revert` of the rotation commits restores the name `pg-eso-drill` (a new generated value again, still disposable). Cleanup in the two commits of the D1 document (`ensure: absent` first, wait until `eso_drill` leaves `status.managedRolesStatus`, then remove the files). The `Orphan` Secret is removed by the operator: `kubectl delete secret -n databases pg-eso-drill` (MANDAT). Verify: `git grep -n 'eso_drill\|pg-eso-drill' -- k8s` is empty.

### D1b (restore from Barman with a new role Secret)

Prerequisite: blockers B1 to B6 of `docs/operations/pg-shared-app-restore-drill.md` lifted by Paul (write identity, R2 read-only token, pinned image, PVC decision), and a test app created from `app-database.example.tmpl` with synthetic rows only.

| # | Command | Expected output |
| --- | --- | --- |
| 1 | `bash scripts/pg-shared-app-restore-proof.sh --app <db> --other-db <witness> --source-namespace <ns> --mode pitr --id d1b` (dry-run) | plan; last line `STATUS=NOT_TESTED RPO=NOT_MEASURED RTO=NOT_MEASURED`, exit 0 |
| 2 | Same command with `PG_PROOF_IMAGE='<image>@sha256:<digest>' PG_PROOF_DB_SECRET='<secret name>' PG_PROOF_OBJECTSTORE='<read-only store>'` and `--execute --confirm I-APPROVE-PG-SHARED-APP-RESTORE-DRILL` (operator only) | temporary Cluster `Ready` in a `*-drill` namespace; `STATUS=PASS`, `CLEANUP=OK` |
| 3 | In the drill namespace: `get externalsecret -n <ns>-drill pg-<ns>-drill` (new source, empty status before) ; `get cluster -n <ns>-drill <cluster> -o jsonpath='{.status.managedRolesStatus}'` | `SecretSynced True` ; role `<app>` `reconciled` ; condition `PasswordSecretChange` present |
| 4 | Connection Job: `psql -c 'select count(*) from restore_drill_marks'`, then `logs -n <ns>-drill job/<job>` | count >= 1 (synthetic rows restored) |

Verdict: PASS if steps 3 and 4 hold with a Secret generated AFTER the restore. Rollback: the script cleans the temporary Cluster on exit (`CLEANUP=LEFTOVER` means the operator removes it); the `Orphan` drill Secret is deleted by the operator (MANDAT). The source cluster is touched only by the marks table agreed in B2.
