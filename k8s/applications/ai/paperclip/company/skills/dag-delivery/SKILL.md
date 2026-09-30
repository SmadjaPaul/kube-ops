---
name: dag-delivery
description: Execute dependency-aware software work in isolated branches/worktrees, parallelizing only independent leaves and integrating reviewed results deliberately.
---

# DAG delivery

Select only leaves whose blockers are complete. Before parallel dispatch, compare touched files, interfaces, migrations, generated artifacts, ports and mutable resources. If independence cannot be proven, serialize the work.

Every concurrently writing leaf gets its own branch and worktree from the same verified base commit. No two workers share a Git index, branch, database, port or mutable service.

Each implementation returns commits plus verification evidence. Review each leaf before integration. Integrate approved branches one at a time, rerun affected checks after each integration, then run whole-feature checks after the wave.

Never force-push, bypass hooks, silently discard conflict resolutions, or mark a blocker complete solely because an agent reports success.
