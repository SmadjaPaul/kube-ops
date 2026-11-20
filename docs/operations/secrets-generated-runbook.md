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

Rename the source ExternalSecret (`oidc-<ns>` becomes `oidc-<ns>-r2`) and keep `target.name`. ESO treats it as new, generates a new value and updates the existing Secret in place. The copy follows within `refreshInterval` (1 h); to be immediate, rename the copy ExternalSecret in a second commit. Reloader restarts the consumers. The old Password generator may be renamed with it. Never edit a Secret by hand.

## Loss of a generated Secret (MANDAT)

`Orphan` means a deleted source Secret is not recreated (the status is already filled): consumers fail visibly and `ExternalSecretNotReady` fires, instead of a silent new value. Recovery is a rotation by renaming (section above). Deleting an ExternalSecret or a Secret is outside `scripts/kubectl-rw.sh` (policy `agent-operator-guard`): Paul or an operator does it. A Velero restore of a generated Secret is overwritten by ESO as soon as a new ExternalSecret reconciles; there is no S3 backup of generated secrets by design (disposable).

## Read the proofs without a value

Allowed: `bash scripts/kubectl-ro.sh get clustersecretstore k8s-auth k8s-databases` (`Ready=True`), `get externalsecret -n <ns> <name> -o yaml` (conditions, `refreshTime`), `get secret -n <ns> <name>` without `-o` (age, size), a functional result (login works), or a 12-character SHA-256 prefix computed inside the cluster by a Job. A 403 `forbidden` on a key outside `resourceNames` proves the RBAC layer. Never read or print `data`.

## Drill D0 (operator, after merge)

Proves that `CreatedOnce` is stable, that a rename rotates, that RBAC refuses a name outside the list and that the alert fires. Steps and expected results are in the PR description of lot 0; they use a temporary namespace `eso-drill` and the source `oidc-eso-drill` (added to `resourceNames`, then removed by a cleanup PR that keeps the sentinel). Do not run it before the operator has read the PR.
