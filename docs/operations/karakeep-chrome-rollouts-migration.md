# PLT-140 — Karakeep Chrome shadow blue/green (opt-in)

## Motivation and eligibility

Karakeep web StatefulSet uses `BROWSER_WEB_URL=http://chrome:9222`.
The Chrome Deployment is stateless (only `emptyDir:/tmp`) and does NOT use
KEDA; unlike GPT Researcher this Chrome is an explicit dependency of the
retained application. The Karakeep web and Meilisearch workloads remain
stateful and are **out of the Rollouts policy**.

## This draft PR — not ready for runtime admission

- Keep the existing `Deployment/chrome`, `Service/chrome`, and
  `BROWSER_WEB_URL=http://chrome:9222` **unchanged**.
- Create an independent `Rollout/chrome-rollout` with selector
  `app: chrome-rollout`, distinct from the legacy selector `app: chrome`.
- Add new ClusterIP Services `chrome-rollout-active` and
  `chrome-rollout-preview`. No application will connect to them until an
  explicit separate cutover PR.
- Preserve original container flags, probes and resource limits.
- AnalysisTemplate checks a real Chrome DevTools Protocol endpoint:
  `GET /json/version` returns JSON containing `webSocketDebuggerUrl`.
  **This does not validate browser navigation or Karakeep screenshots.**
- Allow Argo CD to ignore only the two controller-owned Service selector
  hash keys. No new HTTPRoute, secrets, PVC, KEDA, networkpolicy, or external exposure.
- **STOP before merging:** legacy image uses mutable `:release` tag. Pin
  the exact current multi-arch OCI digest and qualify the provenance; don't
  claim a stable SemVer release or 14-day maturity from a floating tag.

## Admission (requires live cluster)

1. Validate `kustomize build --enable-helm k8s/applications/ai/karakeep`,
   `kubeconform`, `just check`, required GitHub checks on exact HEAD.
2. Confirm Karakeep itself is Healthy and links/screenshots are actually
   being ingested (avoid enhancing a dormant service).
3. Check RAM headroom on mono-node: legacy+shadow need ~512Mi memory requests;
   when shadow blue/green runs both old/new, up to ~768Mi memory requests
   and 1.5Gi sum of memory limits for all three Chrome Pods.
4. Confirm both shadow Services EndpointSlices select only Rollout Pods,
   all pre/post AnalysisRuns succeed and `/json/version` serves correct JSON.
5. Ensure Karakeep web->shadow Chrome DevTools (CDP and WebSocket upgrade)
   works from the actual Karakeep pod, not only from a Job. An authorized,
   non-sensitive test bookmark must produce an actual screenshot/archive.
6. Only after all evidence, prepare a **separate** PR changing
   `BROWSER_WEB_URL` from `chrome:9222` to
   `chrome-rollout-active:9222`, with a clear Git revert plan.
7. Keep legacy Chrome Deployment/Service initially, retire later in a
   separate PR after confidence. Do not enable Renovate native automerge
   until a real version/digest update and successful cutover have been
   observed. A mutable release tag is not a patch/minor policy.

## Control

If Karakeep has no real users or the browser is dormant, close this pilot
without deploying it; preserve low homelab resource use over another
controller-managed workload.

Sources: https://argoproj.github.io/argo-rollouts/migrating/
and https://argoproj.github.io/argo-rollouts/best-practices/
