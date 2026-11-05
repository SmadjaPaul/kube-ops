# PLT-129 / PLT-131 — Renovate service promotion and automerge classes

Status: **policy draft only**. As of 2026-11-04, `kube-ops` has no required
`main` status-check ruleset and Renovate automerge is disabled. This document
does not authorize merging or deploying any service update.

The required V1 check keeps global invariants on every pull request but selects
only the affected Kustomize roots for the render. Unknown or shared
control-plane changes fail closed to the complete 17-root render, while the
complete render also runs daily. This prevents an unrelated remote-chart outage
from blocking an independent application or policy PR without weakening the
global contract.

The effective Renovate configuration has global `automerge: false`, but six
narrow rules explicitly configure automerge: commitlint, Remark tooling,
TypeScript documentation tooling, Docusaurus patch updates, documentation UI
library patches, and the qualified `ws-rewriter` Caddy patch/minor lane. A
configured rule is not proof of qualification or an observed merge: the
commitlint lane is the only lane with a previously observed real auto-merge;
the other lanes still require their stated checks and runtime evidence before
being treated as qualified. Stateful and core platform dependencies remain
manually admitted.

## Principle

Renovate proposes versioned immutable dependency changes; GitHub admits
changes only after mandatory, trusted checks; Argo reconciles desired state;
monitoring verifies the new runtime image ID and service health. A passing
static manifest check is **not** equivalent to working application behavior.
No LLM belongs on the normal deterministic patch path.

## Evidence-based candidate classification

| Existing workload | Observed GitOps state | Future eligibility |
| --- | --- | --- |
| `tools/it-tools` | Deployment, no PVC; GET `/` readiness and liveness, Docker tag `2024.10.22-7ca5933` | Tier A stateless canary; tag is date/hash, **not SemVer**; require image identity + HTTP smoke before allowing digest changes |
| `catalog/searxng` | Deployment with ConfigMap/emptyDir, no PVC; date/hash Docker tag; policy limits ingress; no explicit Pod readiness/liveness probe in `app.yaml` | Tier A after synthetic query + readiness + route/network test; do not assume date/hash is a patch |
| `catalog/stirling-pdf` | Deployment and Longhorn 2-Gi config PVC; immutable semver-like tag currently `3.0.0` | Tier B, patch only after config backup/restore and smoke; not in Tier A |
| `catalog/ntfy` | Longhorn PVC with SQLite auth/cache DB; init bootstrap changes credentials; used in alerting path | Tier C; preserve alert delivery and restore; not automatically merged based on SemVer |
| `catalog/paperless` | Longhorn data/media PVCs + PostgreSQL; image `paperless-ngx:3.2.1` | Tier C: migrations + DB/files consistency and restore must be qualified |
| `media/jellyfin` | StatefulSet, local data, OIDC plugin downloaded and checksum-verified during init | Tier C: plugin compatibility, auth, playback and rollback not just version check |
| `media/jellyseerr` | StatefulSet with config PVC and custom preview OIDC image; app init updates settings | Tier C: preview digest can change semantics; no automatic merge |
| `media/decypharr` | PVC + shared media mount + TorBox/Radarr/Sonarr integration; pinned digest | Tier C: end-to-end download/Arr side-effects require tests |
| `platform/agentgateway` | PVC + credentials, model routing and budget/security controls; pinned digest | Tier C: critical dependency of the software factory, not a disposable stateless service |
| `infrastructure/{network,storage,database,auth,controllers}` | Cilium, Longhorn, CNPG, Authentik, Argo, ESO etc. | Tier D: explicit operator admission for CRDs, upgrade compatibility, recovery and maintenance window |

These classifications are based on the manifests on `main`, **not** on a live
cluster inspection or a proof that an Argo application is currently enabled.
Workloads inside a rendered `resources:` list are candidates, not proof of
Synced/Healthy runtime. Disabled/retired component folders are excluded.

## Merge admission — mandatory for every automated candidate

1. Public-repo `main` ruleset/branch protection requires `v1-contract` from
   GitHub Actions (verified check issuer App ID 15368) on every PR and a strict
   up-to-date base; no unsigned/unchecked direct pushes or bypass actors.
2. PR is non-draft; author is expected Renovate installation; files are an
   exact allowlist and the PR does not modify Actions, gate scripts, IAM, RBAC,
   NetworkPolicies, CI config, secrets, Argo applications, CRDs, databases or
   deployment policy as a side effect of a package bump.
3. Complete check suite on final HEAD SHA: Renovate validated config,
   rendered Kustomize/Helm diff, kubeconform, app-specific checks and no
   skipped/absent/failed/cancelled required checks. Changes to check workflows
   require separate review; GitHub technically accepts neutral/skipped checks
   as passing unless the control is designed to prevent this.
4. Version and artifact are immutable and traceable: expected tag/version,
   digest, provenance/SBOM/Trivy per existing promotion policy; prevent
   tag-only mutable deployments. A Docker digest change is never implicitly
   classified as a SemVer patch.
5. `minimumReleaseAge: 14 days` for third-party dependencies only when the
   datasource has a trustworthy release timestamp; for GHCR most images lack
   timestamps, so do not bypass age by setting timestamp-optional. Treat
   unknown as not eligible for the automated lane or use a separately
   qualified Github release reference.
6. Prefer small **ungrouped** application PRs for GitOps so the root cause
   and revert scope are obvious. Limit concurrent automated deployments
   (start with one at a time) and honor an incident/backup freeze switch.

## Additional gate to allow a Tier A service

- Test its real application HTTP endpoint or function before a merge in a
  disposable/preview environment, or document an equivalent proven test
  covering the exact runtime artifact. Manifest validation alone is not enough.
- Prove an alert and post-merge watcher: Argo Synced/Healthy, expected live
  Pod `imageID`, endpoint smoke, Cilium route health and relevant error/latency
  SLO within 5–15 min. Only claim E2E PASS from observed runtime evidence.
- For stateless Tier A only, a `git revert`/reconcile may be a valid rollback.
  Test it on a canary before activation and pause the lane if verification
  fails. A failing postdeploy check cannot retroactively block a merge.

## Additional gate for Tier B/C/D

- Tier B: prove data and configuration snapshot/restore; patch-only opt-in
  after repeated successful qualifications; a migration or schema change
  upgrades the PR to Tier C.
- Tier C: no general automerge. App-level maintenance, backup consistency,
  external integration/OIDC, migration reversibility, data/queue semantics
  need explicit operator-level admission. A green Pod readiness probe is not
  evidence of playback, authentication or correct database state.
- Tier D: no generic automerge even for a patch: check CRD/storage/network
  compatibility, single-node Talos recovery, Argo sequencing, rollback plan.

## Rollout sequence and negative canaries

1. First merge `kube-ops#867` (done), activate/verify a **real** public GitHub
   required-check ruleset via staged `homelab-infra#231` (still not active).
   Keep the development-dependency pilot `kube-ops#868` as draft until then.
2. Verify missing CI, failed CI, stale branch, forged check name, PR modifying
   its own workflow, and untrusted author cannot merge. Then prove a real
   auto-merged dependency PR on the approved npm devDependencies lane.
3. Qualify `it-tools` and `searxng` independently with exact image versions,
   staging smoke and runtime health + safe rollback; start with **patch**
   equivalents only if tags are truly semantically versioned. Date/hash and
   digest-only updates require dedicated evidence, not a fake SemVer mapping.
4. Expand to other stateless applications only after inspection of their
   actual current manifests and live dependencies. Keep stateful and core
   infra proposals automated but merges manually admitted.

Related tickets: PLT-127 (overall), PLT-128 (Renovate), PLT-129 (postdeploy),
PLT-131 (generic PR admission). This is a reusable policy, not a new merge bot.

Documentation:
- https://docs.renovatebot.com/upgrade-best-practices/
- https://docs.renovatebot.com/docker/
- https://docs.renovatebot.com/key-concepts/minimum-release-age/
- https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets
- https://argoproj.github.io/argo-rollouts/best-practices/
