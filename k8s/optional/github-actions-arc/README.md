# GitHub Actions Runner Controller — staged GitOps pilot

**Deployment is explicit.** The live cluster reconciles this directory through the root ApplicationSet; changes still require the normal PR, Argo and runtime gates below. No direct `helm install` is part of the operating model.

Upstream reference: https://github.com/actions/actions-runner-controller (official `gha-runner-scale-set-controller` and `gha-runner-scale-set` charts, pinned to 0.15.0). Legacy RunnerDeployment is intentionally not used.

## Components

- `arc-systems` namespace: Helm controller, chart-managed service account and cluster RBAC. The 0.15.0 controller render creates `arc-gha-rs-controller`.
- `arc-runners` namespace: repository-scoped ephemeral runner scale sets. `factory-ci-arc` remains min=0/max=3 with its existing PostgreSQL sidecar; `homelab-infra-ci-arc` is a separate min=0/max=2 scale set with no service container. Factory runner manifests are not modified by the homelab addition. `factory-ci-arc-light` (PLT-56) is a third Factory scale set, min=0/max=2, same image and hardening but **no PostgreSQL sidecar**: Factory jobs that never connect to a database (static checks, CI scope selection) run there; integration/dbt jobs stay on `factory-ci-arc`. Its egress is `arc-runners-factory-light-download-egress`, a subset of the Factory download policy without Cloud SDK, dbt or DuckDB hosts. The namespace ResourceQuota is unchanged and still bounds total concurrent CI pods.
- ESO secret `arc-github-app`: dedicated GitHub App credentials, provisioned through existing Doppler ClusterSecretStore; keys `APP_GITHUB_ARC_ID`, `APP_GITHUB_ARC_INSTALLATION_ID`, `APP_GITHUB_ARC_PRIVATE_KEY`.
- ESO secret `arc-factory-ghcr-pull`: separate *kubelet-only* `kubernetes.io/dockerconfigjson` pull credential in `arc-runners`, backed by Doppler key `APP_FACTORY_ARC_GHCR_READ_TOKEN`. Provision a dedicated **read:packages-only** GHCR classic PAT with access to the private `factory-ci-arc` package; it must not have `repo`, `write:packages` or other unnecessary scopes. Do not reuse the GitHub App private key or the general Factory/Mastra GHCR token. Only the Factory runner template references this pull secret; other scale sets remain unchanged. This pull secret is not mounted into runner containers.
- Runner pods: non-privileged, no mounted Kubernetes API token, pinned runner image, cpu/memory/ephemeral-storage limits. `factory-ci-arc` uses the PLT-56 prebuilt image digest; the other scale sets remain on the official runner digest. The optional Cilium policies allow only DNS and the GitHub HTTPS domains required by the pilot.

## Pinned artifacts and GitHub App contract

- Controller chart `0.15.0`: `sha256:20a369215b8c2ed981c4c0c75e56e6009564d51fffcbbd314d5da0ef82de253a`.
- Runner scale-set chart `0.15.0`: `sha256:bdfdad17cf8e45ae064c73ed6764f0c75d4bf71a6e2912e6363a43d6dfc787de`.
- Factory runner image `ghcr.io/smadjapaul/factory-ci-arc` (PLT-56 release for source `a263844966b6299017fd47a953f912fd933c4978`): `sha256:17ea282d02b71da140ee6b6aa25793fb7c8d02fd44429769861ac8752b27a27f`.
- Rollback runner image `ghcr.io/actions/actions-runner:2.338.0`: `sha256:4ffadc0002b2581327e06101fc8c06cd189232baf79fe561fac9caeb76f5e807`.
- PostgreSQL image `18-alpine` (multi-architecture index): `sha256:77f585114c32fbca283dc835b0596f4e52b51b4c6662d7810b2f4084f60a1873`.
- The official image currently has no OCI `USER` field; the pod therefore sets `runAsUser: 70` and `runAsGroup: 70`, matching the image's Alpine `postgres` account. `PGDATA` remains the image default `/var/lib/postgresql/18/docker` on the pod's disposable container filesystem; no PVC is mounted.
- For repository-scoped registration, the dedicated GitHub App needs Repository `Administration: Read and write` and `Metadata: Read-only`. Organization `Self-hosted runners: Read and write` is only needed for organization-scoped registration. The existing ARC App is acceptable only after its installation is restricted to `factory-platform` and `homelab-infra`; the Atlantis, IaC, Factory source-control and Codex Connector Apps are never reused.

## GHCR private-image pull gate (PLT-56)

The promoted Factory runner image is private in GHCR and failed to pull with `401 Unauthorized` during canary run `43031793529`. Do not make it public or retry the canary as a workaround. The pull credential is referenced by the Kubernetes *pod template*, not supplied through `githubConfigSecret` (which is exclusively for ARC registration).

1. Owner provisions `APP_FACTORY_ARC_GHCR_READ_TOKEN` in the existing Doppler environment with the minimum `read:packages` permission and confirmed access to `ghcr.io/smadjapaul/factory-ci-arc`. Never print the token or registry auth data in CI, logs, PRs or Linear. Check the token's actual scopes without disclosing its value.
2. Confirm `ExternalSecret/arc-factory-ghcr-pull` is Ready, and its target Secret exists in `arc-runners` with `type=kubernetes.io/dockerconfigjson`. Do not print or decode `.dockerconfigjson`.
3. Confirm ARC Helm renders `template.spec.imagePullSecrets` into the ephemeral runner pod (not only the ARC listener/controller). On a single deliberate pilot run, verify pod image pull and `runner` readiness before running a trusted workflow.
4. Bound the canary to one trusted workflow/job; the current `maxRunners: 3` and PR triggers do not themselves enforce single-runner isolation. Keep the existing thermal stop and rollback to the official pinned digest. Do not claim CPU/IO improvements until the workflow actually runs and comparable before/after windows are captured.

## Blocking gates before activation

1. Ensure pinned chart 0.15.0 exists and Helm renders with pinned release names: the actual generated controller ServiceAccount is `arc-gha-rs-controller`, matching `controllerServiceAccount.name` in the scale set.
2. Review AppProjects `applications` and `infrastructure` for permissions to install these namespaced and cluster-scoped resources. CRDs must be installed before the scale set.
3. Verify Pod Security admission: the *runner* should be restricted. The controller chart might need separately reviewed security permissions.
4. Inspect Talos node capacity and deployment disruption risk on this single-node cluster. The three-runner setting requires 1.05 CPU/2.3Gi requests and 9 CPU/9Gi limits across three pods; keep the quota and node headroom aligned with those bounds.
5. Restrict the existing ARC App installation to exactly `factory-platform` and `homelab-infra`, then verify the live permissions and installation ID. If that cannot be done, provision a separate ARC App instead. Never reuse the Factory source-control GitHub App or store keys in Git.
6. Design/test egress policy for GitHub endpoints and DNS. The controller and listener need GitHub API outbound access. The staged policies are narrow FQDN policies and must be observed in Cilium audit mode before enforcement.
7. Fully qualify non-privileged runner image and version pinning, chart values, and the behavior of `automountServiceAccountToken: false` with the chosen template.
8. After the scale set is live, change only the homelab-infra static workflow to `runs-on: homelab-infra-ci-arc` and confirm the private-repository job can be scheduled despite the Hosted runner billing block. Factory workflows and required checks are **not** modified.
9. Test one disposable no-secret job, exact SHA check, scale 0→1→0 and verify cleanup/no worktree residue; then discuss service-container support.
10. Qualify Cilium/Talos isolation: do not run untrusted PR contributions against production until escape and RBAC exposure risks are assessed. Even nonprivileged runners share the Talos kernel.

## Known restrictions

- GitHub Actions `services:` are Docker-specific here. `factory-platform/.github/workflows/ci.yml` uses the runner pod's PostgreSQL 18 sidecar instead; the workflow waits for PostgreSQL and verifies the major version before qualification.
- Neither DinD privileged nor `ACTIONS_RUNNER_REQUIRE_JOB_CONTAINER=false` in Kubernetes mode is acceptable in this pilot.
- ARC scales runner pods to zero, **not** the controller and listener.
- The host is an existing single-node Talos cluster; do not confuse pod autoscaling with machine autoscaling.
- OCI/Cloud Build remain options for external builders and cluster disaster-recovery CI.
- The Oracle pilot PR `SmadjaPaul/homelab-infra#141` remains independent and draft.

## Steps for qualification

Run Helm/Kustomize offline validation and a security review; capture the exact chart digests. After the dedicated app is installed, Doppler keys are Ready, and network policy is observed, review the explicit activation PR wiring this root to Argo. No direct `helm install`, no uncontrolled credentials, no forced merge, no GitOps bypass.

Report `ARC_CHART_RENDER`, `CONTROLLER_SA_MATCH`, `POD_SECURITY`, `ARC_GITHUB_APP_READY`, `NETPOL`, `TALOS_CAPACITY`, `PRIVATE_JOB_CHECK_SHA`, `SCALE_TO_ZERO`, `FIRST_DEPLOYMENT_AUTHORIZED`.
