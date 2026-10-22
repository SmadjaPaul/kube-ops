# Atlantis pilot: declared versus runtime

**Evidence date:** 2026-10-22
**Status:** terraform/atlantis-pilot qualified for autonomous
plan/policy/apply/verification/automerge. Production roots remain excluded.

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

| Gate | Result | Evidence |
| --- | --- | --- |
| Static render and security contract | PASS | `tests/harness/atlantis-plan-only-test.sh` |
| Repository and workflow audit | PASS | `docs/contracts/atlantis-server-config-v0.48.1.md` |
| Argo Synced/Healthy | PASS | infra-atlantis-plan-only, revision b2b864b195e850426e89a6b4ee60bb4635d05896, Synced/Healthy; Pod Ready 1/1, restart 0 |
| ESO credentials available | PASS | both ExternalSecrets SecretSynced=True; Pod exposes only dedicated AWS credential names, values not read |
| Backend init and pilot bucket access | PASS | Atlantis tofu1.13.1 init; plan/apply logs use the pilot backend; state list contains terraform_data.pilot |
| Cross-state denial | PASS | dedicated pilot identity denied access to production homelab-tfstate (PLT-90 evidence) |
| Policy verdict | PASS | native policy set atlantis-pilot-bounded-change: 12 tests, 12 passed |
| First plan/apply | PASS | PR #161 SHA 8c564a8947e91f3d9790b248d14bf19a73562962; digest f2dfc7e5c3c6bd9ad73e32f421a69cf210ef174eb6e0cb2f8fe20daaef3f8c4e; 1 add / 0 change / 0 destroy |
| Post-apply idempotence | PASS | current SHA c85dd28a87ab4b5a273c92ce12a45b5c39187577; no-op plan and no-op apply; post-hook SUCCESS |
| State and locking | PASS | state serial 1, lineage 3058cc4d-c2c4-b951-42ed-eb69bacd6898, only terraform_data.pilot; Atlantis lock acquired and deleted on merge |
| Automerge | PASS | Atlantis automatically merged PR #161 in commit 4b9090bd675e996fb3651d975dc2c8177e060066 |

The GitHub Actions check remains blocked by account billing and is not an
Atlantis functional gate. No privileged Atlantis apply is authorized for any
other root.

## Negative evidence

The qualification retained rejection evidence for the non-pilot
terraform/cloudflare request, prior stale/changed plan and approval
requirements, and the server-side deny catch-all. The native policy and
workflow statics deny fork/non-allowlisted repositories, stale current
checkout, changed/expired plan, delete/replace/import/state mutation, custom
workflow, arbitrary arguments and broad credentials. A failed post-apply hook
left the first apply unmergeable; after the corrected hook, merge occurred only
on the successful no-op apply. A live non-pilot apply command was not executed
against a production root: ATLANTIS_APPLY_DENIED is PASS for the deployed
technical policy and NOT_EXECUTED for a production mutation attempt.
