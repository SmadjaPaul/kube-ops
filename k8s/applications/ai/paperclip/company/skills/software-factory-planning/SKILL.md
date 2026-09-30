---
name: software-factory-planning
description: Convert a vague engineering objective into a minimal dependency-aware Paperclip task graph with explicit acceptance criteria, blockers and parallel-safe leaves.
---

# Software factory planning

1. Read the parent objective, repository instructions, related issues/PRs and current desired state.
2. Resolve only the uncertainty needed to plan; create a research child when external/current facts materially affect the design.
3. Create the smallest useful child-task graph. Each child records:
   - outcome and non-goals;
   - acceptance criteria;
   - expected files/systems;
   - blockers and intended owner;
   - required tests/runtime evidence;
   - risk class and any human gate.
4. Mark tasks parallel-safe only when they share no files, APIs, mutable services, database migrations or other state.
5. Do not assign a blocked task.
6. End with an integration/review task and a whole-feature QA task.

The work graph is control state. Git is desired state; runtime observations are evidence.
