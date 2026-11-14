---
name: argocd-debug
description: Diagnose Argo CD sync, comparison, health and ApplicationSet failures before descending to Kubernetes.
---

# Argo CD debugging

Evidence order: Git revision -> ApplicationSet -> Application sync/health/conditions -> first failing resource -> Kubernetes.
Use `just status-app <app>` then `just diagnose-app <app>`.
Do not use sync/reconcile as a deployment mechanism; stuck syncs use `scripts/argo-terminate-stuck-sync.sh` per AGENTS.md Safety. Distinguish cosmetic resource health from a real unhealthy workload.

## Deliver on either cluster (homelab or oracle-a1)

Two independent Argo CD instances, one workflow (`docs/operations/two-argo-one-workflow.md`). The agent never opens an Argo CD interface.

1. Branch `claude/plt-<n>-<slug>`. Change the shared base `k8s/applications/<group>/<app>`.
2. Homelab: the base folder is the application (ApplicationSet `applications`, name `apps-<app>`). Nothing else to add.
3. OKE: `just scaffold-oke-app <group>/<app> <name> <namespace>` creates `k8s/clusters/oracle-a1/<name>/`, `apps/<name>.yaml` and the root entry. Put OKE-only differences in patches in that folder. The scaffold refuses data (PVC, CNPG) before PLT-190.
4. `just check`, then PR and merge (CI green, CodeRabbit handled). Argo reconciles by itself; never sync by hand.
5. Verify: `just verify-delivery <homelab|oracle-a1> <app> --since <merge epoch> --timeout 1200`. Cloud session: no cluster access needed (Grafana Cloud, `GRAFANA_AGENT_READ_TOKEN`).
6. `VERIFY=PASS` is RUNTIME for Synced/Healthy/pods Ready; `REVISION=NOT_PROVEN`. FAIL: read `LAST_ERROR`, then `observability` queries; with cluster access `just diagnose-app <app>`.
7. Absent series = FAIL, not health. First check the Application name and that it exists in Git (a typo gives the same result). Only then suspect a collection gap and fix the Alloy allowlist (homelab `monitoring/alloy/values.yaml`, OKE `clusters/oracle-a1/observability/alloy-values.yaml`) and check the series budget (< 8,000).
