---
name: sre-triage
description: Triage a live service failure from signal to smallest Git repair. Read-only runtime observation by default.
---

# SRE triage

Reproduce -> runtime inventory -> narrow app evidence -> first broken layer -> smallest Git fix -> checks -> PR -> Argo -> runtime/user retest.
Do not combine unrelated root causes merely because they were discovered together.
