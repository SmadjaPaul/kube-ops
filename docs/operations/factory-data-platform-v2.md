# Data Platform V2 — coordinated cutover

This branch must merge in lockstep with SmadjaPaul/factory-platform PR #21.
Existing Grafana/Prometheus/Loki/Alloy are reused. Tempo is the only new
telemetry server and stores *disposable* traces on bounded emptyDir (7-day
retention is best effort; a pod restart clears history). Do not back this up.

## Pre-merge gates
1. Factory PR #21 CI green, real build/publish of both images, digests captured.
2. Replace **all temporary sha-tag image references** in this PR with the
   resulting immutable GHCR digests and verify image manifest linux/amd64.
3. Validate kustomize/Helm rendered Alloy and monitoring stack, CNP schema.
4. Validate a real OTLP span Factory -> Alloy -> Tempo -> Grafana.
5. Run disposable DB qualification twice; validate the mart after each run.
6. Ensure imagefs >= kubelet thresholds, and keep Docker/container image sizes bounded.
7. Deploy both PRs together; avoid simultaneous API/job image version mismatch.

## PostgreSQL source isolation

The dbt job uses the `factory_source_ro` role for DuckDB source reads. The
role is reconciled by CloudNativePG's `spec.managed.roles`, inherits only the
PostgreSQL `pg_read_all_data` predefined role, and has `LOGIN` enabled with
`SUPERUSER`, `CREATEDB`, and `CREATEROLE` disabled. Its password is generated
once by External Secrets into a separate `kubernetes.io/basic-auth` Secret;
the application publication URL continues to use the CNPG application Secret.
The disposable qualification must include a rejected `INSERT` through the
source role before this PR is considered ready.

## Rollback
Revert the kube-ops commit to restore previous pinned images and dbt Core
CronJob. No source-schema or customer-data migration occurs in this release.
Tempo can be disabled independently. Factory staging/marts are rebuildable.

## Operator acceptance
No manual or partial deploy from a PR branch. Merge only with green gates, pin
images to SHA256 digests and allow Argo to reconcile. Check DBT job exit codes,
mart published_at freshness (where exposed), Alloy queue/drop metrics, Tempo
query health, Prometheus targets, and Grafana traces. No test that was skipped
or not observed counts as passing.

## GitHub Actions environment blocker
As of 2026-10-12, private factory-platform workflows fail before runner allocation
(runner_id=0, steps=[]). The candidate is therefore qualified on the disposable
Linux/amd64 Docker/BuildKit environment documented in the handoff; this does not
turn the failed Actions jobs into passes. The PR remains draft until the GHCR
push, immutable digests, and runtime LGTM evidence are present.

Fusion dbt v2 native per-model/test OTLP telemetry is enabled by the dbt runner's
`--export-to-otlp` build flag when `OTEL_EXPORTER_OTLP_ENDPOINT` is present.
Validation requires a real trace found in Tempo, not just successful Python
wrapper export.
