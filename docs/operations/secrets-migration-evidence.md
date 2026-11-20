# Secrets migration: runtime evidence

Plan: `docs/architecture/secrets-migration-spec.md`. One section per lot, filled only after a real run. No secret value ever appears here: only statuses, conditions, ages, sizes and functional results.

## Lot 0: common bricks, drill D0 (`CreatedOnce`)

Procedure and temporary manifests: `docs/operations/secrets-drill-d0-createdonce.md` (PR `claude/secrets-d0-drill`). Cleanup: same document, section "Nettoyage". Read-only commands: `bash scripts/kubectl-ro.sh` with `KUBECTL_RO_IDENTITY=agent`, run by an agent after the merge and the Argo sync. The agent identity cannot read Secrets: a Secret age or `uid` is MANDAT (operator), the ExternalSecret status is the agent-readable evidence. No value is ever read or recorded; `FP` is a 12-character SHA-256 prefix computed in the cluster.

| # | Proof | Status | Verdict |
| --- | --- | --- | --- |
| 0 | Argo state of the drill | RECONCILED, 2026-11-20 ~18:25 UTC | PASS |
| 1 | Stores `k8s-auth`, `k8s-databases` Ready | RECONCILED, 2026-11-20 ~18:25 UTC | PASS |
| 2 | Source and copy Ready | RECONCILED, 2026-11-20 ~18:25 UTC | PASS |
| 3 | `eso-drill-forbidden` refused by RBAC (403) | RECONCILED, 2026-11-20 ~18:25 UTC | PASS |
| 4 | `CreatedOnce` stable after a forced sync (F1) | RECONCILED: FP#1 = FP#2 = `6ff2efa1dedc` after reconciliation of the copy (18:49:58Z); source `refreshTime` unchanged (CreatedOnce behaviour: an already created source is not resynchronised) | PASS with reservation |
| 5 | Rotation by rename changes the value (F3c), PR `claude/secrets-d0-rotation-rename` | IN PROGRESS (PR draft, not merged) | NOT_PROVEN |
| 6 | Alert `ExternalSecretNotReady` firing for `eso-drill-forbidden` | RECONCILED, 2026-11-20 ~18:25 UTC | PASS |
| 7 | Kyverno negative layer (static `kyverno test` only; optional runtime `--dry-run=server` by Paul: MANDAT) | REMAINING | NOT_PROVEN |

Reading of 2026-11-20 ~18:25 UTC (read-only, level RECONCILED, after the merge of #1671 at 18:06 UTC): proofs 0 to 3 and 6 PASS (Applications Synced/Healthy, both stores Ready, source `auth/oidc-eso-drill` and copy `eso-drill/eso-drill-oidc` Ready with `CreatedOnce`, `eso-drill-forbidden` refused with a 403 by the RBAC, alert `ExternalSecretNotReady` firing). Remaining: 4, 5, 7.

Finding: the last Argo operation of `infra-controllers` was `Failed` because `eso-drill-forbidden` failed to sync (`could not get secret data from provider`); `ignore-healthcheck` does not prevent that, so the PostSync hooks (Job `eso-drill-fingerprint`) never ran and proof 4 could not be taken. Fix: `eso-drill-forbidden` removed (PR `claude/secrets-d0-step2-stability`); proofs 3 and 6 stay PASS from the reading above. Proof 4 sequence: merge of the fix, sync succeeds, hook gives FP#1 (BEFORE); second PR touching only a documentation annotation on the source `oidc-eso-drill` forces an ESO reconciliation, next sync gives FP#2; PASS if FP#2 = FP#1 and the source `refreshTime` is unchanged.

Proof 4, BEFORE values (read-only, 2026-11-20 ~18:35 UTC, after #1674): FP#1 = `6ff2efa1dedc` (PostSync Job `eso-drill-fingerprint`); source `auth/oidc-eso-drill` `refreshTime=2026-11-20T18:08:12Z`, `syncedResourceVersion=1-aed6d1a71a9ab9f8c1122e8ffa69fa4521b1a1b12bfee04e64abcaeb`; copy `eso-drill/eso-drill-oidc` `refreshTime=2026-11-20T18:08:12Z`, `syncedResourceVersion=1-b9aa3634afd0ad8ad8298385b4fc79cbc17d6d06d3ffcdc67d0b71da`. Neither has resynchronised since 18:08. Step 2b (PR `claude/secrets-d0-step2b-reconcile`): annotation `kube-ops.io/drill-reconcile` on `spec.target.template.metadata` of source and copy (generation change, no rotation). PASS: FP#2 = FP#1 = `6ff2efa1dedc` AND source `refreshTime` later than 18:08:12Z. FAIL: FP#2 differs (CreatedOnce regenerated: stop, secrets migration to be reviewed).

### Commands and criteria (to run after the merge; rotation excluded from this PR)

Proof 0, drill present and reconciled (RECONCILED level):
```
bash scripts/kubectl-ro.sh get application -n argocd infra-controllers infra-auth
bash scripts/kubectl-ro.sh get ns eso-drill
bash scripts/kubectl-ro.sh get externalsecret,job,ciliumnetworkpolicy -n eso-drill
```
PASS: both Applications `Synced` at the merge revision, namespace `Active`, the CiliumNetworkPolicy and the three ExternalSecrets present. FAIL: namespace or object missing after 10 minutes, or Application `OutOfSync` on a drill object. Argo `Healthy` is not required (`ignore-healthcheck` on the drill ExternalSecrets).

Proof 1:
```
bash scripts/kubectl-ro.sh get clustersecretstore k8s-auth k8s-databases
```
PASS: both `STATUS=Valid`, `READY=True`. FAIL: otherwise (read `describe`, never a value).

Proof 2:
```
bash scripts/kubectl-ro.sh get externalsecret -n auth oidc-eso-drill -o yaml
bash scripts/kubectl-ro.sh get externalsecret -n eso-drill eso-drill-oidc -o yaml
```
PASS: both `status.conditions` `Ready=True` (reason `SecretSynced`), `status.refreshTime` filled; the source has `spec.refreshPolicy: CreatedOnce`. Record `status.refreshTime` and `status.syncedResourceVersion` of the source as BEFORE values. FAIL: `SecretSyncedError` on either.

Proof 3 (taken 2026-11-20 before the object was removed; not repeatable afterwards):
```
bash scripts/kubectl-ro.sh get externalsecret -n eso-drill eso-drill-forbidden -o yaml
bash scripts/kubectl-ro.sh describe externalsecret -n eso-drill eso-drill-forbidden
```
PASS: `Ready=False`, reason `SecretSyncedError`, message containing `forbidden` / `403` (RBAC layer), and the target Secret not created. FAIL: `Ready=True` (the Role grants too much: stop and report, this is a security finding), or an error that is not a 403 (e.g. store not found: NOT_PROVEN).

Proof 4 (F1), BEFORE:
```
bash scripts/kubectl-ro.sh logs -n eso-drill job/eso-drill-fingerprint
```
record `FP=<12 hex>` and the source `refreshTime`. Force a sync without change (an operator-approved Argo refresh/sync of `infra-controllers`, or `bash scripts/kubectl-rw.sh restart external-secrets deployment/external-secrets` if the namespace is in `scope.tsv`; otherwise BLOCKED, ask Paul). AFTER: wait for the `PostSync` Job to rerun (`get job -n eso-drill eso-drill-fingerprint`, new `startTime`), read `logs` again. PASS: `FP` identical AND source `refreshTime` unchanged. FAIL: `FP` or `refreshTime` differs (CreatedOnce is not stable: the whole generator pattern is NOT usable). BLOCKED: no way to force a sync, or the Job did not rerun.

Proof 5 (F3c), PR `claude/secrets-d0-rotation-rename` (draft), IN PROGRESS. Variant of the procedure: the old source `oidc-eso-drill` is KEPT (Orphan, cleanup PR removes it) and the rotation uses a NEW source `oidc-eso-drill--r2` (named with the `--<usage>` suffix because the admission/CI rule `eso-k8s-store-own-namespace` only accepts `oidc-<ns>` or `oidc-<ns>--<usage>`; `oidc-eso-drill-r2` would be refused) (Password + ExternalSecret CreatedOnce/Orphan, class T3, `target.name: oidc-eso-drill--r2`, added to `resourceNames` with the sentinel kept); the copy `eso-drill/eso-drill-oidc` (same `target.name`, so the Job is unchanged) is repointed to `remoteRef.key: oidc-eso-drill--r2`. Order: commit 1 source + RBAC, commit 2 copy (sync-wave 0 then 1; the Role is in `infra-auth`, another Application: the copy retries until it is synced). Read `logs -n eso-drill job/eso-drill-fingerprint` (FP#3) after the copy is Ready with a new `syncedResourceVersion`; if the Job ran before the copy reconciled, force a new sync so the PostSync Job reruns. PASS: FP#3 different from `6ff2efa1dedc` (effective rotation), copy `Ready=True`, no ESO error, old source `oidc-eso-drill` untouched (Orphan, `refreshTime` unchanged). FAIL: FP#3 = `6ff2efa1dedc` or copy not Ready (record the exact condition message).

Proof 6 (taken 2026-11-20 before the object was removed; the alert resolves afterwards):
```
bash scripts/kubectl-ro.sh get --raw '/api/v1/namespaces/monitoring/services/kube-prometheus-stack-prometheus:9090/proxy/api/v1/query?query=ALERTS%7Balertname%3D%22ExternalSecretNotReady%22%2Cname%3D%22eso-drill-forbidden%22%7D'
```
PASS: a result with `alertstate="firing"` (at least 15 minutes after the sync) for `eso-drill-forbidden`. FAIL: empty result after 30 minutes while proof 3 is PASS (metric label names to check against `externalsecret_status_condition`). BLOCKED: Prometheus API not reachable through `kubectl-ro`.

Proof 7: `bash scripts/policy-check.sh --tests` (`kyverno test tests/policies`, STATIC, also run by `just check` and CI). Runtime refusal: MANDAT (Paul, `kubectl apply --dry-run=server` of a copy that reads another namespace).

Verdict D0: PASS only if 1 to 6 are PASS. A merged PR proves no runtime level; update this table with the evidence level (`RECONCILED` or `RUNTIME`) when each proof is read.

## Lot 1: `pg-shared-homelab` role passwords

| Drill | Procedure | Status | Verdict |
| --- | --- | --- | --- |
| D1 rotation of a role | `docs/operations/secrets-drill-d1-pg-shared-role.md` | NOT_RUN | NOT_PROVEN |
| D1b Barman restore + new Secret (before any real data) | `docs/operations/pg-shared-app-restore-drill.md`, section D1b | NOT_RUN | NOT_PROVEN |

Evidence: none yet. Until D1b is PASS, no real data goes into `pg-shared-homelab` and no existing database is migrated to a generated role password.
