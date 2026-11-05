# PLT-141 — Opt-in blue/green demo fixture

**Not connected to Argo CD or any live workload.** This fixture is a separate
opt-in resource tree. Never merge its path into `k8s/applications/kustomization.yaml`
without completing the controller admission from PR #942.

## Preconditions

1. Argo Rollouts controller **v1.10.2** with CRDs established.
2. `kustomize build k8s/optional/argo-rollouts-bluegreen-demo` and
   `kubeconform` pass against the same source commit.
3. Argo CD Project allows this demo namespace **only when opted in**.
4. Register `rollout-demo-active` and `rollout-demo-preview` as special
   Services with Argo CD `ignoreDifferences` **only** for
   `/spec/selector/rollouts-pod-template-hash` (the controller-owned key).
   Do not ignore the whole Service and do not modify global differences.
5. No need for a Gateway HTTPRoute, KEDA, Secrets, PVC or external endpoint.

## Validation (never run negative tests on a real service)

- **Baseline:** one ready `Rollout`, active service endpoints and a successful
  AnalysisRun; wait for healthy.
- **Positive:** update `spec.template.spec.containers[0].image` from
  `argoproj/rollouts-demo:blue` to `:green`. Observe new ReplicaSet
  Ready, two pre HTTP probes pass, active Service hash change, two post HTTP
  probes pass, and old replica scales down.
- **Negative pre-promotion:** introduce a deliberately broken preview
  response or AnalysisTemplate only inside this isolated demo, with a
  reversible change; ensure active Service hash DOES NOT change.
- **Negative post-promotion:** a demo-only, reversible post-analysis
  failure after a healthy pre-analysis should trigger Rollout abort and
  active Service revert to the last stable hash. Preserve AnalysisRun
  failure evidence. Do not fake an abort with a Git revert.
- Check controller and canary pod memory/CPU while old+new replicas
  overlap. Validate Cilium allows the analysis Job to reach preview and
  active ClusterIP Services.

## Important operational caveats

- The first revision may not exercise all AnalysisRuns; use a real revision
  update after baseline.
- Git remains at N+1 after an abort; runtime traffic can revert to N.
  Argo CD may report Degraded; this is expected, not a perpetual
  auto-sync loop. Subsequent repair of desired state is separate.
- The status of an aggregate Argo Application like `apps-tools` does not
  prove this particular rollout is ready. Observe the Rollout and Services.
- Do not enable Renovate AUTO for any real service on the basis of static
  YAML checks alone: demonstrate the isolated success and failure paths.
