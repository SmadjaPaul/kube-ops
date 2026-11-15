---
name: sre-triage
description: Triage a live service failure from signal to smallest Git repair. Read-only runtime observation by default; operation-scoped mutation per AGENTS.md Safety.
---

# SRE triage

Reproduce -> runtime inventory -> narrow app evidence -> first broken layer -> smallest Git fix -> checks -> PR -> Argo -> runtime/user retest.
To restore service, apply a safe fix (scale, restart, rollout, suspend) through `scripts/kubectl-rw.sh` inside the admitted scope (AGENTS.md Safety); with Argo selfHeal, merge the Git change first or the repair is reverted.
Do not combine unrelated root causes merely because they were discovered together.
