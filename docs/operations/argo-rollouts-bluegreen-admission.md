# PLT-141 — Argo Rollouts blue/green GitOps admission

## Scope and provenance

- Official `argo-rollouts` Helm chart **2.43.9** (appVersion **v1.10.2**).
- One controller replica, resource bounds, Prometheus ServiceMonitor, no dashboard.
- CRDs installed and retained by the chart; do **not** delete the CRDs on rollback.
- No user workload is converted by this controller PR. `it-tools` still uses KEDA
  `ScaledObject.scaleTargetRef.kind=Deployment` and must NOT be converted directly.
- No Prometheus analysis or Matrix delivery claims until verified with live evidence.

## CI admission (before merge)

1. Validate that the Helm chart really renders **v1.10.2**, including CRDs and
   the correct cluster RBAC; compare chart lock/checksum when available.
2. Render the controller via `kustomize build --enable-helm k8s/infrastructure/controllers/argo-rollouts`
   and the full `k8s/infrastructure/controllers` root. Apply `kubeconform`
   where schemas exist (skip CRDs only with explicit explanation).
3. Run `just check` and exact GitHub required checks: `v1-contract`,
   `workflow-integrity`, `docs-required`. Do not change branch protection.
4. Verify AppProject destination namespace `argo-rollouts` and permissions.
5. **Do not merge** if chart version, image provenance, or API compatibility
   cannot be demonstrated.

## Cluster admission (after explicit merge through normal protection)

1. Confirm `infra-controllers` Synced/Healthy on merged SHA; controller
   Deployment Available (1/1) and `rollouts.argoproj.io`,
   `analysistemplates.argoproj.io`, `analysisruns.argoproj.io`
   CRDs Established. Do not infer success from Git merge.
2. Check `ServiceMonitor` scraped in the existing Prometheus and quantify
   controller CPU/RAM at idle (and during one rollout).
3. Confirm `kubectl argo rollouts version` plugin matches the controller.
4. Use a separate **opt-in** demo fixture; do not migrate real apps yet.

## Demo admission

The opt-in demo lives under `k8s/optional/argo-rollouts-bluegreen-demo/`
in a separate PR. Keep it out of production ApplicationSet until the controller
has reconciled. It needs **one namespace**, **one Rollout**, active/preview
Services and lightweight AnalysisTemplates; no HTTPRoute, PVC, KEDA or secrets.

Demonstrate three states with revision / hash / endpoint evidence:
- healthy revision N followed by N+1: preview passes, then automatic switch;
- broken pre-promotion: active Service continues to serve N;
- broken post-promotion: controller switches Service back to N after a failed
  AnalysisRun. Confirm there is no Argo CD self-heal conflict on Service
  `rollouts-pod-template-hash`.

Argo Rollouts reverts **runtime traffic**, not the Git image reference. In the
aborted state, keep a visible failed rollout and notify an operator. Do not
introduce custom Git-revert automation for this bootstrap.

## Deferred by design

- Native Matrix/ntfy notifications: existing Argo CD notifications are disabled,
  Alertmanager-to-ntfy is staged/dormant; prove delivery separately with
  a synthetic failure and Doppler-managed credentials.
- Any `Rollout` migration of KEDA `minReplicaCount: 0` workloads.
- PVC applications, cluster networking, Authentik, CNPG, Longhorn, and
  automatic images/charts upgrades before the isolated canary passes.

References:
- https://github.com/argoproj/argo-helm/tree/main/charts/argo-rollouts
- https://argoproj.github.io/argo-rollouts/features/bluegreen/
- https://argoproj.github.io/argo-rollouts/features/analysis/
