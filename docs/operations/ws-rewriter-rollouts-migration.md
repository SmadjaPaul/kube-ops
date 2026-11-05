# PLT-140 — ws-rewriter progressive migration (GitOps)

## Shadow phase: this PR

- Retain `apps/v1 Deployment/ws-rewriter` unchanged and keep the external
  `HTTPRoute/gpt-researcher` pointing to legacy Service `ws-rewriter`.
- Introduce a new, **distinctly labelled** `Rollout/ws-rewriter-rollout`
  and two **internal-only** Services `ws-rewriter-rollout-active` and
  `ws-rewriter-rollout-preview`. The legacy Service selector
  `app.kubernetes.io/name=ws-rewriter` cannot match any new Pod.
- Copy the existing Caddy image/config, probes, limits, volumes, and runtime
  security context. No PVC, no KEDA, no new secrets or exposure.
- Add a narrowly scoped CiliumNetworkPolicy for the new Pods, preserve
  legacy policies, and allow the new label as a source in the backend ingress.
- `ws-rewriter-http` uses two internal `/healthz` HTTP Jobs per analysis,
  before and after switching the **shadow** active Service.
- Argo CD ApplicationSet ignores only the controller-owned
  `rollouts-pod-template-hash` selectors for these two Services.
- **No Renovate AUTO is enabled by this PR.**

## Tests to pass before a cutover PR

1. Helm/Kustomize root render, `kubeconform`, and GitHub
   `v1-contract`, `workflow-integrity`, `docs-required` on exact HEAD.
2. Compare effective NetworkPolicy in Hubble: probe Pod -> shadow preview
   TCP 8000 allowed; new Caddy -> gpt-researcher backend TCP 8000 allowed;
   DNS TCP/UDP 53 allowed. Verify no unexpected ingress widening.
3. Check old Deployment Pod Ready and old Service Endpoints unchanged.
   Check shadow Rollout Ready and both shadow Services have new ReplicaSet
   hash only, no legacy Pods.
4. Verify `/healthz` response and an actual backend-proxy route such as
   `/openapi.json` via shadow active Service (use a safe read-only endpoint).
   Check HTTPRoute still points to legacy.
5. Perform an image-only controlled update of shadow Rollout (or controlled
   AnalysisTemplate negative canary) to prove pre/post failure handling
   without touching production.
6. Check current active namespace resource headroom: old + shadow +
   temporary analysis Job (~50m CPU/32Mi memory requests additional for
   shadow, plus Job 5m/8Mi; no mandatory anti-affinity).
7. Abort on any missing evidence; leave legacy route unchanged.

## Cutover phase: separate PR only after those proofs

- Modify ONLY the seven ws-rewriter backendRefs in
  `k8s/applications/ai/gpt-researcher/http-route.yaml` from
  `ws-rewriter` to `ws-rewriter-rollout-active`. Keep frontend route
  and all other backendRefs unchanged.
- Run route/real-proxy smoke tests after Argo sync and monitor errors.
  An emergency Git revert of the cutover PR restores legacy routing.
- The old Deployment/Service remain provisioned for the first observation
  period. Plan their retirement separately after consumers are inventoried.
- Post-promotion rollback works on the shadow Rollout after cutover; it
  never changes Git, and is **not** a substitute for cutover rollback.

## Later Renovate admission

After live evidence of a normal blue/green update and a failing synthetic
update on the shadow Rollout, consider patch/minor image automerge only
for this file. Keep 14-day maturation when release timestamps are present,
strict required checks, and no automatic Git revert or extra controller.
Do not allow blanket image or Helm automerge.

Official migration guidance:
https://argoproj.github.io/argo-rollouts/migrating/
