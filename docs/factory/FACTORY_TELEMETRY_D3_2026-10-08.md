# Factory F1 D3 — Paperclip correlation capture

Date: 2026-10-08 (UTC)

This is a read-only observation report for the bounded D2 execution. No agent
run was started by D3, no Paperclip state was changed, no Kubernetes write was
performed, no Secret or credential value was read, and no merge was attempted.
The work is unrelated to kagent.

## Observed execution

| Link | Observed value | Evidence status |
| --- | --- | --- |
| Company | `0c4afe5a-c044-4b3d-86a2-14a64a063d18` | OBSERVED |
| Paperclip task | `SMA-30` / `855e89b1-1bfc-481f-86c6-209a933c7b87` | OBSERVED |
| Project | `kube-ops` / `d2af4131-113c-48e1-a4aa-648a1f2f4956` | OBSERVED |
| Primary project workspace | `2351ff38-cc59-4606-97eb-65958f433605` | OBSERVED |
| Assigned agent | `a8f202c8-5e61-4df9-afa1-8b0f62ab4e74` — Senior Implementation Engineer | OBSERVED |
| Run / heartbeat run | `24dfb6b2-0795-4ac5-8afc-950f90809593` | OBSERVED |
| Adapter / model | `opencode_local` / `litellm/factory/code` | OBSERVED |
| Invocation | `assignment` | OBSERVED |
| Attempt | `1` of `3` | OBSERVED |
| Started | `2026-10-08T09:45:59.915Z` | OBSERVED |
| Finished | `2026-10-08T09:46:14.327Z` | OBSERVED |
| Terminal result | `cancelled`; operator cancellation was acknowledged | OBSERVED |
| Run usage / token payload | `usageJson=null` | NOT_AVAILABLE |
| Run cost | not exposed; company summary reported `spendCents=0` | NOT_AVAILABLE |
| Human intervention | operator cancellation | OBSERVED |

The run's workspace lease was `d0423f46-5c92-4c93-b5c8-85ccf165490d` and its
execution workspace was `c5e1547b-b9db-4667-aef3-a7184360627c`. The only
workspace operation observed was `5209158e-ad38-4697-882a-4b5ad4813c68`, phase
`workspace_finalize`, status `succeeded`, with zero recorded log bytes. Its
observed working directory was Paperclip's managed checkout under `/paperclip/`.

## Correlation chain and gaps

The requested D2 target was `/Users/paul/.codex/worktrees/f1-d2-proof/kube-ops`
on `codex/f1-d2-proof`. The API evidence does not prove that path or branch
was used; it proves only the managed Paperclip workspace above.

| Stage | Expected correlation | Observed result |
| --- | --- | --- |
| Paperclip task | `SMA-30` → task UUID | `SMA-30` and task UUID observed |
| Agent execution | task UUID → run UUID → agent UUID | run, agent, adapter, attempt, status and timestamps observed |
| Checkout | run UUID → execution workspace / checkout | execution workspace and finalize operation observed; requested local checkout not observed |
| File write | run UUID → exact file path and write event | NOT_OBSERVED; no file write was proven |
| Commit | run UUID → commit SHA | NOT_OBSERVED |
| Branch | run UUID → `codex/f1-d2-proof` | NOT_OBSERVED; `git ls-remote` returned no branch |
| Pull request | commit/branch → exact PR URL | NOT_OBSERVED; GitHub PR query returned `[]` |
| GitHub workflow | PR/commit → workflow run ID and conclusion | NOT_OBSERVED; workflow query for `codex/f1-d2-proof` returned `[]` |
| Outcome | task/run → accepted change | NOT_OBSERVED; task returned to `todo` and run ended `cancelled` |

GitHub REST checks also returned 404 for the requested remote branch and for
`docs/factory/FACTORY_AGENT_E2E_PROOF_SMA-30.md`. These are negative checks,
not evidence that a missing artifact was successfully created elsewhere.

## Factory Platform mapping assessment

The existing Factory Platform V0 contract was inspected through its published
`main` source. It currently models `paperclip.run` with task, agent, status,
attempt, model, human-intervention, cost and start/finish fields. The current
`github.pull_request` and `github.workflow_run` facts retain repository, SHA,
PR/run and workflow status facts, but the dbt models expose no join key linking
those facts to a Paperclip task or run. Checkout/workspace, file-write, commit,
branch, PR URL and workflow-to-PR correlation fields are therefore absent from
the current end-to-end evidence and from the current `fct_paperclip_runs`
projection.

The raw-event idempotency contract is observed as
`(tenant, source, event_type, source_id, schema_version)`. No idempotency defect
was exercised by this cancelled run, so no Factory Platform mapping or
idempotency change was made from this worktree. Any implementation change in
the external `SmadjaPaul/factory-platform` repository must be a separate PR
after a successful chain supplies a real fixture; it must not be mixed with
this kube-ops proof report.

## D3 delivery and CI observation

| Delivery stage | Observed value | Evidence status |
| --- | --- | --- |
| Worktree branch | `codex/f1-d3-telemetry` | OBSERVED |
| Proof commit | `a75ebf488cb10f19d20c1a5128ed47eb2bd579b6` | OBSERVED |
| Pull request | [kube-ops#358](https://github.com/SmadjaPaul/kube-ops/pull/358) | OBSERVED; OPEN/CLEAN |
| CI observation at `2026-10-08T09:49:02Z` | check-runs `0`, commit statuses `0`, combined status `pending` | NOT_TERMINAL |

The PR was opened without merge or auto-merge. `gh run list` for
`codex/f1-d3-telemetry` returned no workflow run, and the GitHub check-runs
and statuses APIs returned no entries. CI is therefore not a PASS and has no
terminal conclusion at this observation point.

## Verdict

```text
FACTORY_F1_D3_TASK=OBSERVED
FACTORY_F1_D3_RUN=OBSERVED
FACTORY_F1_D3_AGENT=OBSERVED
FACTORY_F1_D3_CHECKOUT=PARTIAL
FACTORY_F1_D3_FILE_WRITE=NOT_OBSERVED
FACTORY_F1_D3_COMMIT=NOT_OBSERVED
FACTORY_F1_D3_BRANCH=NOT_OBSERVED
FACTORY_F1_D3_PR=NOT_OBSERVED
FACTORY_F1_D3_CI=NOT_OBSERVED
FACTORY_F1_D3_OUTCOME=BLOCKED
FACTORY_F1_D3_TOKENS=NOT_AVAILABLE
FACTORY_F1_D3_COST=NOT_AVAILABLE
FACTORY_F1_D3_HUMAN_INTERVENTION=OBSERVED
FACTORY_F1_D3_CORRELATION=PARTIAL
```

No PASS is declared for file write, commit, branch, PR, CI, or end-to-end
outcome because none was observed.
