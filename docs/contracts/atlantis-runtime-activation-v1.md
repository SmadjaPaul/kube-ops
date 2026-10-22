# Atlantis pilot: declared versus runtime

**Evidence date:** 2026-10-22
**Status:** activation candidate for `terraform/atlantis-pilot`; runtime
qualification is intentionally pending the GitOps merge and live execution.

## Declared activation

The infrastructure ApplicationSet reconciles
`k8s/poc/atlantis-plan-only`. The candidate pins Atlantis `v0.48.1` by digest,
Helm chart `6.16.1`, OpenTofu `1.13.1`, the dedicated ESO backend secret and
the dedicated OCI endpoint. It enables the native Conftest policy check and
the Atlantis apply command only for the exact `homelab-infra` / `main` /
`terraform/atlantis-pilot` / `default` mapping. `disableApplyAll` remains true.

The server-side policy is outside the tested PR and is mounted read-only. The
post-apply hook verifies the exact repository, base branch, project, toolchain,
workspace and `terraform_data.pilot` state address. Production roots remain
denied by the catch-all rule and have no apply capability through this mapping.

## Runtime gates

| Gate | Status before merge | Required evidence |
| --- | --- | --- |
| Static render and security contract | PASS | `tests/harness/atlantis-plan-only-test.sh` |
| Repository and workflow audit | PASS | `docs/contracts/atlantis-server-config-v0.48.1.md` |
| Argo Synced/Healthy | NOT_EXECUTED | application status at the activation SHA |
| ESO credentials available | NOT_EXECUTED | ExternalSecret condition and Pod env names, never values |
| Backend init and pilot bucket access | NOT_EXECUTED | Atlantis log plus dedicated bucket metadata |
| Cross-state denial | NOT_EXECUTED | dedicated identity denied on `homelab-tfstate` |
| Policy verdict | NOT_EXECUTED | Atlantis policy check on the exact SHA |
| Plan/apply/verification/lock | NOT_EXECUTED | Atlantis comments, logs, saved-plan digest and OCI state metadata |
| Automerge | NOT_EXECUTED | GitHub merge event after successful plan, policy, apply and hook |

`NOT_EXECUTED` is not a functional failure. No runtime gate is promoted to
PASS until its concrete evidence is collected. No privileged Atlantis apply is
authorized for any other root.

## Negative evidence required

The qualification run must preserve evidence of rejection for an unadmitted
root, fork or non-allowlisted repository, stale SHA, changed/expired plan,
policy violation, delete/replace/import/state mutation, cross-state access,
concurrent lock, custom workflow, arbitrary comment arguments, broad
credentials and merge after an uncertain or failed apply hook.
