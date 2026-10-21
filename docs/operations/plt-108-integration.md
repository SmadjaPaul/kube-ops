# PLT-108 — Factory V1 integration ledger

Updated: 2026-10-21 20:55+02:00 (source observations; see checks/commits for authoritative times)

This is the O0 coordination ledger for PLT-108. GitHub, Linear, Mastra and
Argo remain authorities for their own state. A local or agent report is not
external proof until the exact SHA, executed check and external observation
are recorded.

## Baseline inventory

| Repository | GitHub default branch | Verified remote HEAD | Local checkout note |
| --- | --- | --- | --- |
| `SmadjaPaul/factory-platform` | `main` | `21b9c7dad3ac2a08bc0f96ae48feb9dedb12983f` (includes Factory #142/#143/#144/#145 merges) | Local checkout is on `codex/prevent-sandbox-claim-expiry`, ahead/behind and has untracked checkpoint files; do not use as an agent worktree. |
| `SmadjaPaul/kube-ops` | `main` | `457edc64bc7654e0730043f6b24ffc78da26989d` (newer commits exist beyond #618; snapshot at audit) | O0 checkout contains pre-existing untracked `.yml` and `tests/e2e/test-results/`; preserve them. |
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
| PLT-108 | `codex/plt-108-post-merge-ledger` / kube-ops #620 | #618 squash `2eecaad88b76e01fc5ebb71fedb01bcc3fed39de`; #620 HEAD must be reverified | Prior local `just check` FAILED at CNPG fixture line 82; #618 fixes synthetic freshness, `validate` PASS on its head; full local `just check` post-fix UNKNOWN | GitHub #618 reviewed as content/comment by owner; #620 review pending | #618 MERGED; #620 OPEN | N/A | #620 documentation-only outside V1 contract workflow path filter; no check attached, must not claim runtime validation |
| PLT-114 | `codex/o1-plt114` / PR #143 | merge `02e484b4c231d00d6190eebf51ca0747b7794966` (PR HEAD `d413301e…`) | STATIC: docs KEEP; `test` + `static-arc` PASS; no runtime activation | O2 independent content review identified/fixed artifact pollution; operator-authorized merge; no fabricated GitHub APPROVE | Merged squash `02e484b4c231d00d6190eebf51ca0747b7794966` | UNKNOWN | PLT-114 Done / KEEP; PLT-27/29/100 remain open gates; PLT-100 OFF |
| PLT-27 | `codex/o1-plt114` | `ae6cdff` | STATIC: workflow invariants PASS; no runtime activation | Pending | Not eligible | UNKNOWN | Native hook proof and external checks |
| PLT-29 | `codex/o1-plt114` | `ae6cdff` | STATIC: stale/self-review refusals PASS | Pending | Not eligible | UNKNOWN | Exact-HEAD independent review and CI |
| PLT-100 | `codex/o1-plt114` | `ae6cdff` | STATIC: admission/policy PASS | Pending | Forbidden | OFF / UNKNOWN | Blocked by PLT-24/27/29/112; do not activate |
| PLT-109 | `codex/plt-109-qualification-o0` / PR #145 | merge `55fc2512f4fa43ec81b91ae5be76c01362d96109` (PR HEAD `56da1bca…`) | STATIC: 51 targeted and 263 core contracts documented; live S3/claim-loss/GC not executed | O0 COMMENT; documentation merge only | Merged squash `55fc2512f4fa43ec81b91ae5be76c01362d96109` | UNKNOWN | PLT-109 remains open; do not qualify PLT-24 from synthetic evidence |
| PLT-24 | `codex/durable-sandbox-checkpoint` | `847a63c39420d178fa7a61f81635201fa2f3c4e4` | STATIC: replay/idempotency and concurrent adoption tests PASS | Pending independent review | Not eligible | UNKNOWN | Depends on PLT-109 live evidence; `pytest` unavailable for canonical factory check |
| PLT-74 | `codex/o3-ci-delivery-factory` / Factory #144 | PR HEAD `8c9446d3453408050be82758ca1a8e4fd285b3f9`; squash main `21b9c7dad3ac2a08bc0f96ae48feb9dedb12983f` | PR checks `test` / `static-arc` PASS; post-merge main `test` / `static-arc` PASS; Cloud Build `delegate` FAILED BEFORE SUBMIT because WIF provider variable empty | O4 independent content review on PR HEAD | MERGED `21b9c7dad3ac2a08bc0f96ae48feb9dedb12983f` | UNKNOWN | No BUILD_ID/digest/GitOps/Argo; GCP_WIF_PROVIDER missing in workflow context, budget approval/gate must precede OIDC. Factory #146 opens narrow fix. |
| PLT-19 | Factory #144 / PLT-74 post-merge delivery | `21b9c7dad3ac2a08bc0f96ae48feb9dedb12983f` | `test/static-arc` PASS; Cloud Build delegate FAILED before image build | static/review only | #144 MERGED | UNKNOWN | OCI digest, GitOps commit, Argo/health, smoke and rollback remain UNKNOWN |
| PLT-74 / kube promotion | `codex/o3-ci-delivery` / PR #617 | `6c883f111eec6415ad6151c207ca5ddb560d559b` (source code `2a071443…`) | STATIC: Kustomize/digest path report recorded; full kube check fails at existing backup contract | O0 COMMENT on exact HEAD; `validate` SUCCESS | Merged squash `b835e41e0ed7f6c70b0994575e895a6d4e91f4c9` | UNKNOWN | No Argo revision or smoke; docs-only merge proves no runtime level |
| PLT-44 | `codex/plt-44-quality-evidence-o4` / PR #142 | merge `99e14ef094d2b02275fa178bf44238983772a4f0` (PR HEAD `6dea1d42…`) | STATIC: `test` + `static-arc` PASS; receipt tests and JSON/schema validation PASS; no OCI/Argo runtime evidence | O4 agent `01a15f4f-cc08-7ec2-a760-77e060389f3f` read-only qualification; operator user authorization; no GitHub APPROVE fabricated | Merged squash `99e14ef094d2b02275fa178bf44238983772a4f0` | UNKNOWN | Static contract only; literal `\\n` documentation sequences are non-blocking; no runtime promotion |
| PLT-26 | Factory #142 | HEAD `6dea1d4205859536c87bdfb0733c419357518288`, merged `99e14ef094d2b02275fa178bf44238983772a4f0` | PR `test/static-arc` PASS, pure receipt contract only | O4 independent content qualification as recorded by O0 | #142 MERGED | UNKNOWN | No observed delivery receipt from real GitHub/OCI/Argo adapters; production source fields unknown |
| PLT-67 | Factory #142 | HEAD `6dea1d4205859536c87bdfb0733c419357518288`, merged `99e14ef094d2b02275fa178bf44238983772a4f0` | Static test of nullable UNKNOWN metrics PASS | O4 independent content qualification as recorded by O0 | #142 MERGED | UNKNOWN | Actual token/duration/provider costs not measured; analytics gate open |
| PLT-112 | O0 recipe | UNKNOWN | Prepared only; no pilot/workflow launched | Not started | Not eligible | UNKNOWN | PLT-74/24/27/29/100 gates; PLT-100 remains OFF; PLT-114/143 and PLT-109/145 documentation merges do not qualify the pilots |

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

| 2026-10-21 | Merge Factory #142 after exact-head O4 qualification | O4 agent `01a15f4f-cc08-7ec2-a760-77e060389f3f` independently verified PR HEAD `6dea1d420…`, provenance separation, GitHub checks for RECONCILED, STATIC refusal, and parse/schema cleanliness. The user explicitly authorized progressive squash merge; no GitHub APPROVE identity was fabricated. Merge commit: `99e14ef094d2b02275fa178bf44238983772a4f0`. |
| 2026-10-21 | Keep Factory #144 unmerged after main advanced | Exact HEAD `91ab2d431…` has green PR checks but remains architecturally unsafe: ARC cannot run Docker/Buildx and Cloud Build may submit before successful main CI. Rebase only after O3 correction and only if required by the new base `99e14ef…`. |

| 2026-10-21 | Keep PLT-109/PLT-24 blocked after O2 read-only qualification | No dedicated Factory checkpoint S3 endpoint/credentials are present; only CNPG S3 identities exist. Warm pool is zero and the sole SandboxClaim is tied to an active session, so it was preserved. S3 live upload/download, claim-loss restore and RPO/RTO remain NOT EXECUTED. |

## Latest reconciliation — 21 October 2026 after #144 merge

1. Factory main `21b9c7dad3ac2a08bc0f96ae48feb9dedb12983f`: main `test` and `static-arc` PASS, but Cloud Build delegation is a **real FAILURE** at `google-github-actions/auth`, with empty `GCP_WIF_PROVIDER`. No build was submitted. Explicitly do not mark delivery PASSED.
2. Factory PR #146: proposes a pre-OIDC approval+budget+authorization gate with WIF configuration preflight. It is not a substitute for configuring the WIF provider or qualifying a real build. CI/review and merge remain separate.
3. Factory #142/#143/#144/#145 are merged; O1/O2/O4 static qualification is not Factory E2E runtime. PLT-109/24/27/29/100/112 remain blocked at their respective acceptance levels. Never touch historical PR #130/#134 or PLT-105 objects.
4. Kube-ops #618 merged fixture freshness correction at `2eecaad…`; the earlier local `just check` failure remains historical evidence, and a new local full validation is not claimed.
5. Kube-ops #620 is a documentation-only journal PR and does not match the V1 Contract workflow `pull_request.paths`. An absent CI check is **NOT** a PASS and not necessarily a runtime failure. Do not artificially modify unrelated tests to trigger a check; review the documentation change and its source SHA.
6. O3 next: verify WIF identity without revealing credentials, requalify source-SHA/build scope + cost authorization, obtain genuine GCP BUILD_ID and OCI digest only with the operator's approved budget, then create GitOps PR and verify Argo/smoke/rollback. O2 next: dedicated private S3 + disposable claim-loss drill; O1: builder/reviewer post-push re-review contract.

## Next coordination step

Close only the explicitly qualified documentation/contract PRs. Keep delivery runtime, claim-loss recovery and autonomous end-to-end qualification UNKNOWN until proven by owning systems. No new scheduler, queue, privileged runner or unapproved paid build.
