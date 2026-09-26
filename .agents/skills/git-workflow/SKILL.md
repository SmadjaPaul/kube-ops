---
name: git-workflow
description: Keep agent work isolated, reviewable and Git-first.
---

# Git workflow

Start from current `main`, use one short-lived branch per coherent task, keep commits atomic, validate before review, and use PRs as the mutation gate. Avoid force-push/reset/clean destructive operations. After squash merge, refresh from `origin/main` before the next task.
