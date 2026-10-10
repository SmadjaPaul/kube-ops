# Paperclip — 10 October 2026 recovery / upstream reconciliation

Status: **READ-ONLY PLANNING AND STATIC SAFETY CHECKS**. This document and its
companion contract DO NOT install the Agent Sandbox controller, activate a
Paperclip plugin/environment, grant RBAC, start a model, or trigger SMA-31.

## Current sources and dependencies

- Fork: `SmadjaPaul/paperclip:master` @ `64ae540df892e3a13d20d49b88de162c92ba0518`.
- Upstream: `paperclipai/paperclip:master` @ `2a2071340d39e7ec9eeeec8615191df365b4dbac`.
- Git compare on 2026-10-10: upstream **169 ahead**, fork **12 ahead**; diverged.
- Stable upstream release at inspection: `v2026.1005.0`. Master contains later unpublished changes. Do not equate upstream `master` to a tested release.
- Live desired state `k8s/applications/ai/paperclip/instance.yaml`: fork image
  `ghcr.io/smadjapaul/paperclip:sha-64ae540df892e3a13d20d49b88de162c92ba0518`,
  digest `sha256:aa46b347c8e9e6375bce384373d5cf410ad34775ac82963ce1e68c7442b34e90`;
  authenticated private ClusterIP HTTPRoute, heartbeat **disabled**.
- Kubernetes plugin code in **fork master and upstream master** still uses
  `agents.x-k8s.io/v1alpha1` for `sandbox-cr`; Agent Sandbox v1.0.5+
  serves only `v1beta1`. The Job fallback does not provide the required
  multi-command exec and workspace lifecycle.
- `SmadjaPaul/paperclip#11` is the existing v1beta1 adaptation PR, not merged.
  The exact PR head `f0f0ebcdcaea140e7d12ec5f5ac5661399589eb5` had
  PR workflow **SUCCESS** on 2026-10-10; 48 targeted tests were reported.
- `SmadjaPaul/kube-ops#397` contains the **non-live** execution candidate,
  proposed image pin, RBAC diagnostic and plugin manifest checks.
- `SmadjaPaul/kube-ops#400` is stacked onto #397 and depends on #11;
  it is a **non-live** activation draft. Both KubeOps PRs previously suffered
  CI red due to Docker Hub Bitnami Redis HTTP 429; they were not merged.
- `SMA-31_ACCEPTANCE.md` still says PREPARED_NOT_EXECUTED. No live sandbox
  or coding task has been observed by this recovery effort.

## Previously encountered failures — do not regress

1. **GitHub identity:** self-hosted Paperclip managed-GitHub flow was blocked
   by Cloud enrollment, app permissions and reauthorization. The fork added
   native GitHub App runtime credentials and lease-scoped token handling.
   Previous successful E2E commit/push/PR evidence exists; requalify after sync.
   Never reuse a generic PAT or expose a runtime token in diagnostics.
2. **Secret exposure:** a Paperclip board/API key was leaked in earlier logs
   and a master encryption key needed remediation. Confirm rotation/revocation
   and retain the patched redaction tests before any new agent run.
3. **Workspace correctness:** #5 fixed isolated workspace fallback to shared
   checkout, corrected materialization errors and cleanup on retry. Do not
   overwrite the fork's changes with upstream versions unless equivalent
   tests prove their replacement. Worktree identity, git base `main`, branch
   reuse and cwd timing must be observed on the SAME run.
4. **Operational environment:** PVC/Longhorn issues, executor readiness,
   Cloud Connector managed-GitHub coupling and mismatched operator/plugin
   config have previously blocked execution. Do not patch running pods,
   install packages at runtime or turn on heartbeats while debugging.
5. **Factory CI:** restrict the fork to relevant PR/typecheck/runtime tests
   and a post-merge immutable GHCR image. Do not enable nightly paid campaigns,
   upstream-only publication or enterprise/evaluation jobs.
6. **Agent Sandbox:** controller absent in previous live snapshot, server
   ServiceAccount lacked Kubernetes provisioning/exec RBAC, and runtime image
   executable and plugin dist were not proven. The upstream OpenCode image
   provenance is documented but does not substitute for `opencode --version`
   in an ephemeral pod.

## Critical fix needed before merging Paperclip #11

`packages/plugins/sandbox-providers/kubernetes/src/sandbox-cr-orchestrator.ts`
in PR #11 currently interprets ANY `Finished=True` as
`Succeeded`, including `Finished.reason=PodFailed` (false success).

Strengthen #11 with regression tests:

- `Finished=True/PodFailed` must map to Failed, never Succeeded;
- `Ready=True` must not count when `observedGeneration` is behind
  `metadata.generation`;
- `Ready=False/DependenciesNotReady` is a pending state, not a failure;
- a transient `ReconcilerError` should not silently pass nor be mistaken for
  an irreversible terminal failure without an explicit policy;
- `Ready=False/SandboxExpired`, `Finished=True/PodFailed`, suspended and
  terminating workloads must stop readiness waits promptly and accurately;
- `findPodForSandbox` must resolve the pod from the controller's
  `status.selector` or deterministic name, **verify Sandbox owner UID**, and
  reject prefix collisions and unrelated pods (v1beta1 has no `status.podName`);
- pod readiness, command exec, teardown, per-run secret cleanup, quota and
  Cilium egress need real disposable `kind`/Talos probes before promotion.

Official API: https://github.com/kubernetes-sigs/agent-sandbox/blob/main/docs/api.md
and https://agent-sandbox.sigs.k8s.io/docs/sandbox/conditions/.

## Upstream sync — do not flatten the fork

1. Fetch fork `master` and `upstream/master`; generate a report of the
   **169 upstream / 12 fork commits** against precise SHAs above.
2. Prefer merging/rebasing against the latest **stable release** first,
   then evaluate unreleased master commits as a separate step. The 169-commit
   comparison is against upstream master, not all necessarily new since stable.
3. Retain the 12 fork-specific fixes for GitHub App broker, redaction,
   workspace/heartbeat policies, fork-controlled CI and GHCR publication.
   For each patch, classify `UPSTREAM_EQUIVALENT`, `KEEP`, `REWORK`,
   or `DROP_WITH_TEST` (only with a passing regression).
4. Merge conflicts in execution and GitHub credential ownership explicitly,
   never by selecting all of one side.
5. Retest all affected packages (adapter-utils, server, Kubernetes plugin,
   CLI, CI images, migration scripts). Ensure the fork does not accidentally
   re-enable upstream publication on a fork.
6. Build and publish an image containing **installed and compiled plugin
   dist/**, not just the Paperclip server image. Verify immutable OCI digest
   and `opencode --version` inside a disposable pod.

## Sequenced go/no-go gates

A. Correct and merge #11 with its PR CI green and independent review.
B. Sync with stable upstream, preserving local patches and CI security.
C. Rebase/requalify kube-ops #397 then stacked #400. Verify the source
   runtime image, operator schema and served Agent Sandbox API against exact
   GitOps versions. Never treat upstream main as an OCI image.
D. Discrete, reviewed installation of Agent Sandbox v1beta1 and minimal
   namespaced paperclip server RBAC; agent worker has no K8s API token.
E. One **disposable**, resource/egress-limited agent checks create → ready →
   multi-command exec → authenticated callback → secret isolation → cleanup.
F. Single test Issue → delegation → workspace → code → PR → CI → review;
   capture actual LiteLLM cost/time/result and try restart/retry without
   duplication.
G. Only after H1-H3 pass, approve and execute SMA-31. Missing live evidence
   is `NOT_OBSERVED`, never `PASS`.

This file is an evidence handoff, not authorization for database writes,
Company imports, cluster-controller installation or live production changes.
