# PLT-108 — Factory V1 integration ledger

Updated: 2026-10-21 (Europe/Paris)

This is the O0 coordination ledger for PLT-108. GitHub, Linear, Mastra and
Argo remain authorities for their own state. A local or agent report is not
external proof until the exact SHA, executed check and external observation
are recorded.

## Baseline inventory

| Repository | GitHub default branch | Verified remote HEAD | Local checkout note |
| --- | --- | --- | --- |
| `SmadjaPaul/factory-platform` | `main` | `e6c30965766d787c5f89326d717597cf4d770eb1` | Local checkout is on `codex/prevent-sandbox-claim-expiry`, ahead/behind and has untracked checkpoint files; do not use as an agent worktree. |
| `SmadjaPaul/kube-ops` | `main` | `b835e41e0ed7f6c70b0994575e895a6d4e91f4c9` (PR #617 squash) | O0 checkout contains pre-existing untracked `.yml` and `tests/e2e/test-results/`; preserve them. |
| `SmadjaPaul/homelab-infra` | `main` | Not in scope for desired-state changes | Read-only authority boundary only. |

Fixtures and historical evidence reserved read-only: factory-platform PR #130,
PR #134, PLT-105 recovery artefacts, and the merged historical PRs #133, #135,
#137. No agent may mutate or close the two open fixture PRs.

## Ownership reservation

The owner is the only agent allowed to modify the listed paths. Reading across
boundaries is allowed; a boundary change requires an O0 decision and a new
reservation before edits.

| Orchestrator | Tickets | Repository | Exclusive write set | Explicit exclusions |
| --- | --- | --- | --- | --- |
| O1 | PLT-114, 27, 29, 100 | `factory-platform` | `mastra-factory/src/mastra/index.ts`; `mastra-factory/src/mastra/autonomous/{board,config,contracts,evidence,index,linear-rules,observability,observability-route,policy,repository-resolution,state-machine,storage}.ts`; `mastra-factory/docs/autonomous-loop.md`; `mastra-factory/docs/operator-activation-gates.md`; new native-first ADR; autonomous tests only | O2 checkpoint/recovery paths; O4 harness/evidence paths; package lock; runtime activation flags; fixtures #130/#134 |
| O2 | PLT-109, 24, recovery part of 22 | `factory-platform` | `mastra-factory/src/mastra/sandbox/{git-checkpoint,recovery}.mjs`; `mastra-factory/src/mastra/sandbox/{kubernetes,runtime,operating-mode,process-manager}.ts` only when required by recovery; `mastra-factory/tests/{git-checkpoint,sandbox-recovery,kubernetes-sandbox}.test.mjs`; new PLT-109 evidence under `mastra-factory/docs/operations/` | O1 autonomous state/storage; PLT-105 volume/commit; no destructive SQL/PVC/S3 GC |
| O3 | PLT-74, 19 | `factory-platform` + `kube-ops` | Factory `.github/workflows/{ci,factory-static-arc,image,cloud-build,mastra-factory}.yml`, `cloudbuild.yaml`, `scripts/cloud-build.sh`, Dockerfiles; kube-ops `k8s/applications/platform/mastra-factory/{deployment,README}.yaml` and `scripts/promote-mastra-factory-digest.sh` | No Factory autonomy code; no other kube-ops application; no paid hosted Actions or unapproved Cloud Build |
| O4 | PLT-44, 26, 67 | `factory-platform` | `mastra-factory/src/harness/{evidence,delivery-policy,delivery-context}.mjs`; `mastra-factory/docs/observability-contract.md`; harness/evidence quality tests; new quality-evidence reports under `mastra-factory/docs/operations/` | O1 autonomous tests/state; O2 recovery; O3 workflows/build manifests; no new persistent evidence store |
| O0 | PLT-108, PLT-112 | `kube-ops` coordination worktree | This ledger, merge/review matrix, cross-repo qualification records and final PLT-112 recipe | No runtime controller, second scheduler, or imperative production repair |

Delegations started 2026-10-21 in parallel:

| Orchestrator | Agent id | Initial state |
| --- | --- | --- |
| O1 | `01a15f4f-ca80-7cb0-932d-ab79987627c1` (Galileo) | Running audit; no O0 dependency |
| O2 | `01a15f4f-caf3-79b2-9f67-a410b6813713` (Kuhn) | Running recovery audit/tests |
| O3 | `01a15f4f-cb71-79a0-9821-ac1e133dac86` (Dirac) | Running CI/build audit |
| O4 | `01a15f4f-cc08-7ec2-a760-77e060389f3f` (Rawls) | Running evidence audit |

## Permanent delivery matrix

Status values are deliberately evidence-levelled: STATIC, RECONCILED, RUNTIME,
USER or UNKNOWN. `UNQUALIFIED` is not a pass.

| Ticket | Branch | HEAD | Tests | Review | Merge | Runtime | Blocker |
| --- | --- | --- | --- | --- | --- | --- | --- |
| PLT-108 | O0 `codex/plt-108-integration` / PR #618 | `9bff4c30aa0890f7cb55c307a39690ed15871d1e` | STATIC: inventory passed; `just check` FAIL preserved at `tests/harness/backup-audit-contract-test.sh:82` (`CNPG_RESTORE_PROOF=PASS`) | O0 COMMENT on prior exact HEAD; new journal commit pushed; Claude status for new HEAD pending/unknown | Withheld | UNKNOWN | Isolated Longhorn/CNPG fixture assertion; no O0 desired-state mutation |
| PLT-114 | `codex/o1-plt114` / PR #143 | `f855ab9f463ac4fc79a4731cf8a4bfad1ac5be65` (docs; audited source `e6c3096…`) | STATIC: 35/35 targeted PASS; native 0.22.0/1.77.0 probe PASS; GitHub `test` and `static-arc` PASS; full TypeScript/core contract fail outside O1 | O2 independent review: BLOCKED exact HEAD | Pending correction/review | UNKNOWN | KEEP decision valid, but four docs contain a stored `.env` shell-error line and test-result targets audited source not PR HEAD; no merge |
| PLT-27 | `codex/o1-plt114` | `ae6cdff` | STATIC: workflow invariants PASS; no runtime activation | Pending | Not eligible | UNKNOWN | Native hook proof and external checks |
| PLT-29 | `codex/o1-plt114` | `ae6cdff` | STATIC: stale/self-review refusals PASS | Pending | Not eligible | UNKNOWN | Exact-HEAD independent review and CI |
| PLT-100 | `codex/o1-plt114` | `ae6cdff` | STATIC: admission/policy PASS | Pending | Forbidden | OFF / UNKNOWN | Blocked by PLT-24/27/29/112; do not activate |
| PLT-109 | `codex/plt-109-qualification-o0` / PR #145 | `f2fbf00e7aa0eccc5d0dff89af751b5a02272eca` (reports; implementation under test at `01ceb742…`) | STATIC: TypeScript, 51 targeted and 263 core contracts PASS; live S3/claim-loss/GC not executed | O0 COMMENT on exact HEAD | Not eligible | UNKNOWN | Runtime S3 upload/download, disposable claim-loss restore and bounded GC remain open |
| PLT-24 | `codex/durable-sandbox-checkpoint` | `847a63c39420d178fa7a61f81635201fa2f3c4e4` | STATIC: replay/idempotency and concurrent adoption tests PASS | Pending independent review | Not eligible | UNKNOWN | Depends on PLT-109 live evidence; `pytest` unavailable for canonical factory check |
| PLT-74 | `codex/o3-ci-delivery-factory` / PR #144 | `01f3df705161ce815c365ea8cddecd379a30c823` (source code `f1d4a33…`) | STATIC: 30 contracts, digest/input/YAML/shell checks PASS; GitHub `test` and `static-arc` PASS; no build | O0 COMMENT + blocking correction request on exact HEAD; new review required after correction | Not eligible | UNKNOWN | Blocked on docs-only Cloud Build trigger, durable post-execution dedup, and qualified API/dbt alternative; no paid build |
| PLT-19 | `codex/o3-ci-delivery-factory` | `01e77449598e35f44cc3fe75a7039c9a8fbe2caf` | STATIC only; source SHA pinned in changes | Pending | Not eligible | UNKNOWN | Deployed version and rollback not observed |
| PLT-74 / kube promotion | `codex/o3-ci-delivery` / PR #617 | `6c883f111eec6415ad6151c207ca5ddb560d559b` (source code `2a071443…`) | STATIC: Kustomize/digest path report recorded; full kube check fails at existing backup contract | O0 COMMENT on exact HEAD; `validate` SUCCESS | Merged squash `b835e41e0ed7f6c70b0994575e895a6d4e91f4c9` | UNKNOWN | No Argo revision or smoke; docs-only merge proves no runtime level |
| PLT-44 | `codex/plt-44-quality-evidence-o4` / PR #142 | `d0f7f639cdaf32aaa2ad3cd2669ae95fb8108585` (source tests `e97e1f3…`) | STATIC: targeted 14/14 and harness 41/41 PASS; GitHub `test` and `static-arc` PASS; full check/core contract fail | O0 COMMENT + blocking correction request on exact HEAD; new review required after correction | Not eligible | UNKNOWN | Blocked on PR-head vs post-merge/build source provenance and STATIC `eligible=true` fail-closed semantics; runtime evidence absent |
| PLT-26 | `codex/plt-44-quality-evidence-o4` / PR #142 | `d0f7f639cdaf32aaa2ad3cd2669ae95fb8108585` | STATIC receipt chain/refusal tests PASS | No review | Not eligible | UNKNOWN | OCI/Argo/user evidence absent |
| PLT-67 | `codex/plt-44-quality-evidence-o4` / PR #142 | `d0f7f639cdaf32aaa2ad3cd2669ae95fb8108585` | STATIC: UNKNOWN metrics preserved; cost live not observed | No review | Not eligible | UNKNOWN | Live cost/duration/tokens not observed |
| PLT-112 | O0 recipe | UNKNOWN | Prepared only; no pilot/workflow launched | Not started | Not eligible | UNKNOWN | PLT-74/24/27/29/100 gates; PLT-100 remains OFF |

## Merge gate

O0 may merge a PR only after the PR head is recorded, tests are actually
executed, an independent review is anchored to that exact head, required
checks are present and successful, no production mutation is hidden in the
change, and rollback/GitOps implications are explicit. Any new commit requires
fresh checks and a fresh independent review. CI or a merged PR alone never
upgrades evidence to RECONCILED, RUNTIME or USER.

## Decisions log

| Date | Decision | Reason / evidence |
| --- | --- | --- |
| 2026-10-21 | Preserve Factory extensions until equivalence is proven | PLT-103 claim-loss incident, PLT-105 unpublished commit, and #133/#135/#137 establish historical guarantees. |
| 2026-10-21 | Keep PLT-100/autonomous flags OFF | Linear dependencies require PLT-114, 27, 29 and 24 qualification first. |
| 2026-10-21 | No second queue, scheduler, database or Kubernetes reconciler | Canonical architecture assigns state to Mastra/CNPG, events/leases to existing Redis, bytes checkpoint to private S3, and desired state to GitOps. |
| 2026-10-21 | Preserve #130/#134 and PLT-105 artefacts | They are no-merge fixtures and historical recovery evidence, not cleanup candidates. |
| 2026-10-21 | Do not merge or repair through O0 for the initial `just check` failure | `npm run check` and the Grafana contract pass; the next recipe step `tests/harness/backup-audit-contract-test.sh` exits non-zero against the existing fixture contract. This is recorded as failed evidence, not silently converted to skipped/pass. |
| 2026-10-21 | Isolate and preserve kube-ops contract FAIL | `bash -x tests/harness/backup-audit-contract-test.sh` reaches line 82 in the synthetic Longhorn/CNPG scenario: `grep -F 'CNPG_RESTORE_PROOF=PASS' "$output"` fails. Fixtures remain untouched; no repair or rerun of active workflows. |
| 2026-10-21 | Block Factory #142 pending targeted O4 correction | Both external checks PASS on exact `d0f7f639…`, but OCI/Argo provenance is coupled to PR HEAD instead of the post-merge/build source and STATIC can expose `eligible=true` without review/merge. O4 was messaged on its existing task; GitHub self-review restriction prevents formal `REQUEST_CHANGES`, so a blocking top-level comment was recorded. |
| 2026-10-21 | Block Factory #144 pending targeted O3 correction | Both external checks PASS on exact `01f3df70…`, but docs-only Cloud Build, missing durable post-execution dedup, and removal of API/dbt without qualified replacement violate PLT-74. O3 was messaged on its existing task; no paid build launched. GitHub self-review restriction prevents formal `REQUEST_CHANGES`, so a blocking top-level comment was recorded. |
| 2026-10-21 | Keep PLT-100 OFF and PLT-112 unlaunched | PLT-24, 27, 29, 74 and 100 lack the required end-to-end qualification; #145 remains static/synthetic and its test is still active. No autonomous flag, pilot session, lease or external operation was restarted. |
| 2026-10-21 | Do not merge Factory #143 despite PASS checks | Independent O2 review found a stored `.env` shell-error line at the beginning of all four documentation files, invalidating the JSON evidence, and the test-result revision is `e6c3096…` rather than the PR HEAD. O1 must correct the existing branch and obtain fresh CI/review. |

## Next coordination step

Immediate executable lot: O1 removes the stored shell-error lines, binds its
test-result to a new exact HEAD, and obtains fresh CI plus independent review.
In parallel, observe (do not restart) the already-running `test` on PR #145.
O3/O4 continue only on their existing branches after the targeted corrections
above; every new HEAD needs fresh CI and review. O0 will re-fetch every PR
head after any merge to detect base/conflict drift, and will prepare PLT-112
without claiming its E2E gate is complete before all dependencies qualify.
