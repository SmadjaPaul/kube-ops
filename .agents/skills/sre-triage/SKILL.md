---
name: sre-triage
description: Triage a live service failure from signal to smallest Git repair. Read-only runtime observation by default; operation-scoped mutation per AGENTS.md Safety.
---

# SRE triage

Reproduce -> runtime inventory -> narrow app evidence -> first broken layer -> smallest Git fix -> checks -> PR -> Argo -> runtime/user retest.
Within the admitted scope (AGENTS.md Safety) a safe imperative fix (scale, restart, rollout, suspend) may be applied to restore service (for an application with automated Argo selfHeal, merge the Git change first or the repair is reverted), then verified at runtime and reconciled into Git the same day. Write access comes from the PLT-237 identity; until it is deployed, stay read-only by default and repair through Git or the bounded recovery commands (AGENTS.md Safety).
Do not combine unrelated root causes merely because they were discovered together.
