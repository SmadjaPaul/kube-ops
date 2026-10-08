# Factory workspace lifecycle qualification — SMA-31 (H1)

This is the Git-owned qualification contract for Paperclip task `SMA-31`.
It covers only execution workspace lifecycle: isolated workspaces, Git
worktrees, the `main` base ref, and task-specific branches.

## Desired policy

The reviewed post-import project policy is:

```json
{
  "enabled": true,
  "defaultMode": "isolated_workspace",
  "allowIssueOverride": false,
  "workspaceStrategy": {
    "type": "git_worktree",
    "baseRef": "main",
    "branchTemplate": "{{issue.identifier}}-{{slug}}"
  }
}
```

The policy remains outside the portable safe-import `.paperclip.yaml`; the
supported project update in `company/README.md` is the Git-owned application
contract.

## Acceptance evidence

SMA-31 may be marked `PASS` only when one authenticated, read-only evidence
capture for the same task/run observes every field below. The workspace must
be created or attached before the model process starts; the model must receive
the resolved worktree cwd and must not discover the repository.

| Invariant | Required observation |
| --- | --- |
| Workspace realization | `currentExecutionWorkspace != null` before model invocation |
| Isolation | `mode=isolated_workspace` |
| Strategy | `workspaceStrategy.type=git_worktree` |
| Working directory | agent cwd is the resolved task worktree, not the project primary checkout |
| Branch | `git branch --show-current` matches the task-specific `{{issue.identifier}}-{{slug}}` derivation |
| Base | resolved worktree is based on `main` |
| Ordering | workspace create/attach event precedes model invocation |

Any missing, inferred, or cross-run evidence is `NOT_OBSERVED`, not `PASS`.

## Current evidence status

`NOT_OBSERVED` in this Git change. No SMA-31 agent invocation or Paperclip
database mutation is performed here, and no Secret value is read. Cluster
runtime observation is separate evidence and does not prove Paperclip
workspace realization.
