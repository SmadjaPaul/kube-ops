# Atlantis V2 target executors — PLT-89
Status: **staged only**. Companion [homelab-infra#261](https://github.com/SmadjaPaul/homelab-infra/pull/261).

This PR prepares **two** production trust domains, Apps and Infra, separate from the existing Pilot. The Helm values are not referenced by Argo/Kustomize and explicitly deny plan and apply. They mount no state/provider credentials and configure no webhook. Do not activate either until its dedicated signed GitHub webhook, isolated ESO backend/provider identities, network policy, state/recovery proof and policy checks have passed.

## Components
- `values-apps.yaml` and `values-infra.yaml`: server-owned exact allowlist, no overrides, no custom workflows, deny-by-default, reference the generated project configs in #261.
- `scripts/guard-project.sh`: generic project-boundary check, replacing arbitrary SHA-per-normal-HCL pins; denies cross-root edits, provider/backend/lockfile mutations and unregistered roots. This is not a Terraform sandbox.
- `policies/plan-safety.rego`: baseline native Conftest policy refusing deletes/replacements, imports and sensitive outputs. Cost, drift, root identity and supply-chain provenance still require independent gates.
- `tests/harness/atlantis-target-contract-test.sh`: positive and adversarial guard fixtures; run in existing Atlantis harness.

## Production acceptance (Codex to implement directly)
1. Two genuinely separate Atlantis releases with distinct GitHub Apps/webhooks or verified signed event fanout. Separate app-level and infra-level ESO secrets, service accounts, dedicated PVCs and Cilium egress. No pod inherits all credentials; split critical roots further if residual cross-root access exists.
2. Bind only the generated 16-root project registry, with pinned compatible Terraform/OpenTofu versions and module/provider source policy. No unknown root autodiscovery.
3. Server-owned `init/plan/show/policy_check/apply` workflow, immutable PR+plan+backend lineage+policy revision identity, proper native state lock, no implicit replan, no destructive drift.
4. Fail-closed preplan code admission (signed provenance or protected reviewed code): this guard alone must never be considered sufficient for privileged HCL.
5. Separate PLAN_READY, APPLY_READY, RUNTIME_VERIFIED live qualification per root, provider tests including BadgerOps UniFi, post-apply state + external runtime observations, second convergence plan and off-cluster recovery.
6. Autoscale plan concurrency only where roots/states are independent. Infra automerge disabled by default, Apps selectively enabled only after policy PASS and blocking post-apply verifier; do not confuse green plan with autoapply.
7. Remove old SHA fingerprints and duplicate root checks after live proof; keep branch protection, security workflow checks and a single PR per ordinary HCL edit.

No live config, webhook, privilege, backend or runtime state is changed by this staged PR.
