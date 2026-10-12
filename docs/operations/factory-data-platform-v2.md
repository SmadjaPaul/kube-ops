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
(runner_id=0, steps=[]). Do not infer application failures or success; deployment
is BLOCKED until usable runners build and qualify both images.
