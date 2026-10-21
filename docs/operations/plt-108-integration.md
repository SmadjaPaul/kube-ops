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
| `SmadjaPaul/kube-ops` | `main` | `fc66104d68e0afdd8f89ee6660e6403e7eeb723f` | O0 checkout contains pre-existing untracked `.yml` and `tests/e2e/test-results/`; preserve them. |
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
| PLT-108 | O0 `codex/plt-108-integration` | `647af9730d4094897a0401917db72bc3b2c45db2` | STATIC: inventory passed; `just check` failed in pre-existing `backup-audit-contract-test.sh` | Pending independent reviews | Not applicable | UNKNOWN | Baseline backup contract failure must be triaged separately; no O0 desired-state mutation |
| PLT-114 | O1 reserved | UNKNOWN | UNKNOWN | Pending | Not eligible | UNKNOWN | Audit first; PLT-100 stays OFF |
| PLT-27 | O1 reserved | UNKNOWN | UNKNOWN | Pending | Not eligible | UNKNOWN | Native hook proof |
| PLT-29 | O1 reserved | UNKNOWN | UNKNOWN | Pending | Not eligible | UNKNOWN | Exact-HEAD independent review |
| PLT-100 | O1 reserved | UNKNOWN | UNKNOWN | Pending | Not eligible | UNKNOWN | Blocked by PLT-114/27/29/24 |
| PLT-109 | `codex/durable-sandbox-checkpoint` | `847a63c39420d178fa7a61f81635201fa2f3c4e4` (qualification reports; implementation under test at `01ceb742…`) | STATIC: TypeScript, 51 targeted and 263 core contracts PASS; live S3/claim-loss/GC not executed | Pending independent review on exact report SHA | Not eligible | UNKNOWN | Runtime S3 upload/download, disposable claim-loss restore and bounded GC remain open |
| PLT-24 | `codex/durable-sandbox-checkpoint` | `847a63c39420d178fa7a61f81635201fa2f3c4e4` | STATIC: replay/idempotency and concurrent adoption tests PASS | Pending independent review | Not eligible | UNKNOWN | Depends on PLT-109 live evidence; `pytest` unavailable for canonical factory check |
| PLT-74 | O3 reserved | UNKNOWN | UNKNOWN | Pending | Not eligible | UNKNOWN | Source-to-digest-to-GitOps proof |
| PLT-19 | O3 reserved | UNKNOWN | UNKNOWN | Pending | Not eligible | UNKNOWN | Deployed version and rollback proof |
| PLT-44 | O4 reserved | UNKNOWN | UNKNOWN | Pending | Not eligible | UNKNOWN | Reject false PASS/skipped/mock evidence |
| PLT-26 | O4 reserved | UNKNOWN | UNKNOWN | Pending | Not eligible | UNKNOWN | Issue→run→PR→digest→Argo receipt |
| PLT-67 | O4 reserved | UNKNOWN | UNKNOWN | Pending | Not eligible | UNKNOWN | Cost/duration/tokens and UNKNOWN semantics |
| PLT-112 | O0 recipe | UNKNOWN | Not started | Not started | Not eligible | UNKNOWN | PLT-74/24/27/29/100 gates |

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

## Next coordination step

O1 may audit independently while O2/O3/O4 proceed in their reserved paths.
O0 will collect exact branch/HEAD/test/review evidence, resolve only real
cross-boundary collisions, and prepare PLT-112 without claiming that its E2E
gate is complete before all dependencies qualify.
