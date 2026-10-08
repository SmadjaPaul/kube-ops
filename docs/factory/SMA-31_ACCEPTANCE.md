# SMA-31 acceptance contract

Status: `PREPARED_NOT_EXECUTED`

This contract prepares acceptance evidence for SMA-31. It does not create or
trigger SMA-31, start an agent run, change Paperclip state, or change runtime
state.

## Execution gate

SMA-31 may be created or triggered only after all H1-H3 fixes are merged and
the orchestrator has explicitly validated those prerequisites. This H4 change
does not satisfy either prerequisite and must remain preparation-only.

The contract contains no workstation path. Repository, branch, and workspace
are identified only by the execution context supplied to the run.

## Contractual prompt

```text
Use exclusively the execution workspace supplied by Paperclip. Fail closed if repository, branch or workspace invariants are wrong.
```

The prompt above is exact, including punctuation and capitalization.

## Required measures

Each measure is recorded from observed run events. An absent, unavailable, or
ambiguous value is `NOT_OBSERVED`; it is never converted to `PASS`.

### `workspace_prepare_ms`

Elapsed milliseconds from the accepted workspace-preparation start event to
the corresponding workspace-ready event for the supplied execution workspace.
Record the event timestamps and the resulting non-negative integer.

### `model_start_to_first_repo_command_ms`

Elapsed milliseconds from the model-start event to the first command that
operates on the supplied repository. Record both event timestamps and the
resulting non-negative integer. A command that only inspects unrelated machine
state does not qualify as the first repository command.

### `repo_discovery_tool_calls`

Count of repository-discovery tool calls made before the supplied repository
was identified. Record the ordered tool-call evidence and the resulting
non-negative integer. Calls after repository identification are excluded.

### `branch_reused`

Boolean indicating that the run reused the supplied branch identity rather
than creating or selecting another branch. `true` is accepted only when the
before/after branch identities are observed and equal; otherwise the measure
is `NOT_OBSERVED` or `FAIL`.

### `workspace_reused`

Boolean indicating that the run reused the supplied workspace identity rather
than creating or selecting another workspace. `true` is accepted only when
the before/after workspace identities are observed and equal; otherwise the
measure is `NOT_OBSERVED` or `FAIL`.

## Prepared measurement record

No SMA-31 run is authorized in this H4 preparation turn, so every measure is
currently unobserved:

```text
workspace_prepare_ms=NOT_OBSERVED
model_start_to_first_repo_command_ms=NOT_OBSERVED
repo_discovery_tool_calls=NOT_OBSERVED
branch_reused=NOT_OBSERVED
workspace_reused=NOT_OBSERVED
```

## Acceptance outcome

The acceptance record must retain the task/run correlation, event timestamps,
tool-call evidence, repository identity, branch identity, and workspace
identity without including credential or sensitive-value material.

Before SMA-31 is authorized and observed, the outcome is:

```text
SMA31_ACCEPTANCE=NOT_OBSERVED
SMA31_EXECUTION=BLOCKED_PENDING_H1_H3_AND_ORCHESTRATOR_VALIDATION
```

`PASS` may be declared only for an individual measure whose evidence is
actually observed and satisfies its definition. A merged PR or a static CI
success does not prove SMA-31 execution, reuse, or any runtime/user outcome.
