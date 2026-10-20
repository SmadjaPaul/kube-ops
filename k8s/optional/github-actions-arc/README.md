# GitHub Actions Runner Controller — staged GitOps pilot

**NOT DEPLOYED.** This folder is deliberately **not** referenced by the live Argo root or ApplicationSets. No controller/runner/Secret is created merely by merging this directory. To activate, a separate reviewed change must attach this kustomization to the appropriate Argo path after the gates below.

Upstream reference: https://github.com/actions/actions-runner-controller (official `gha-runner-scale-set-controller` and `gha-runner-scale-set` charts, pinned to 0.15.0). Legacy RunnerDeployment is intentionally not used.

## Components

- `arc-systems` namespace: Helm controller, chart-managed service account and cluster RBAC. The 0.15.0 controller render creates `arc-gha-rs-controller`.
- `arc-runners` namespace: one repository-scoped ephemeral runner scale set; min=0, max=1, no Docker/Kubernetes container mode.
- ESO secret `arc-github-app`: dedicated GitHub App credentials, provisioned through existing Doppler ClusterSecretStore; keys `APP_GITHUB_ARC_ID`, `APP_GITHUB_ARC_INSTALLATION_ID`, `APP_GITHUB_ARC_PRIVATE_KEY`.
- Runner pods: non-privileged, no mounted Kubernetes API token, pinned runner image, cpu/memory/ephemeral-storage limits. The optional Cilium policies allow only DNS and the GitHub HTTPS domains required by the pilot.

## Pinned artifacts and GitHub App contract

- Controller chart `0.15.0`: `sha256:20a369215b8c2ed981c4c0c75e56e6009564d51fffcbbd314d5da0ef82de253a`.
- Runner scale-set chart `0.15.0`: `sha256:bdfdad17cf8e45ae064c73ed6764f0c75d4bf71a6e2912e6363a43d6dfc787de`.
- Runner image `2.338.0`: `sha256:4ffadc0002b2581327e06101fc8c06cd189232baf79fe561fac9caeb76f5e807`.
- For repository-scoped registration, the dedicated GitHub App needs Repository `Administration: Read and write` and `Metadata: Read-only`. Organization `Self-hosted runners: Read and write` is only needed for organization-scoped registration. The Factory GitHub App is never reused.

## Blocking gates before activation

1. Ensure pinned chart 0.15.0 exists and Helm renders with pinned release names: the actual generated controller ServiceAccount is `arc-gha-rs-controller`, matching `controllerServiceAccount.name` in the scale set.
2. Review AppProjects `applications` and `infrastructure` for permissions to install these namespaced and cluster-scoped resources. CRDs must be installed before the scale set.
3. Verify Pod Security admission: the *runner* should be restricted. The controller chart might need separately reviewed security permissions.
4. Inspect Talos node capacity and deployment disruption risk on this single-node cluster. Keep concurrency at 1 until spare resources are proven.
5. Provision a **dedicated** GitHub App installation with the minimal ARC permissions documented upstream. Never reuse the Factory source-control GitHub App or store keys in Git.
6. Design/test egress policy for GitHub endpoints and DNS. The controller and listener need GitHub API outbound access. The staged policies are narrow FQDN policies and must be observed in Cilium audit mode before enforcement.
7. Fully qualify non-privileged runner image and version pinning, chart values, and the behavior of `automountServiceAccountToken: false` with the chosen template.
8. Confirm a private-repository GitHub workflow with `runs-on: factory-ci-arc` can be scheduled despite the hosted runner billing block. Existing required checks are **not** modified.
9. Test one disposable no-secret job, exact SHA check, scale 0→1→0 and verify cleanup/no worktree residue; then discuss service-container support.
10. Qualify Cilium/Talos isolation: do not run untrusted PR contributions against production until escape and RBAC exposure risks are assessed. Even nonprivileged runners share the Talos kernel.

## Known restrictions

- The existing `factory-platform/.github/workflows/ci.yml` provisions a PostgreSQL **service container** and cannot be migrated to the plain pilot runner unchanged.
- Neither DinD privileged nor `ACTIONS_RUNNER_REQUIRE_JOB_CONTAINER=false` in Kubernetes mode is acceptable in this pilot.
- ARC scales runner pods to zero, **not** the controller and listener.
- The host is an existing single-node Talos cluster; do not confuse pod autoscaling with machine autoscaling.
- OCI/Cloud Build remain options for external builders and cluster disaster-recovery CI.
- The Oracle pilot PR `SmadjaPaul/homelab-infra#141` remains independent and draft.

## Steps for qualification

Run Helm/Kustomize offline validation and a security review; capture the exact chart digests. After the dedicated app is installed, Doppler keys are Ready, and network policy is observed, review the explicit activation PR wiring this root to Argo. No direct `helm install`, no uncontrolled credentials, no forced merge, no GitOps bypass.

Report `ARC_CHART_RENDER`, `CONTROLLER_SA_MATCH`, `POD_SECURITY`, `ARC_GITHUB_APP_READY`, `NETPOL`, `TALOS_CAPACITY`, `PRIVATE_JOB_CHECK_SHA`, `SCALE_TO_ZERO`, `FIRST_DEPLOYMENT_AUTHORIZED`.
