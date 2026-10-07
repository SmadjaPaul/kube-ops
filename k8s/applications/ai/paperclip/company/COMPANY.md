---
name: Smadja Software Factory
description: Git-first software engineering company for infrastructure, product delivery and continuous factory improvement using plan, research, implementation, review and evidence-driven delivery.
slug: smadja-software-factory
schema: agentcompanies/v1
version: 1.0.0
license: MIT
goals:
  - Turn vague engineering goals into explicit dependency-aware work graphs.
  - Deliver small reviewed pull requests with reproducible verification evidence.
  - Keep Git and runtime evidence authoritative; agent memory is never desired state.
  - Build Factory Intelligence as the first vertical of a reusable commercial data platform.
  - Improve autonomy, automation, quality, cost and lead time through measurable inner, outer and meta loops.
---

# Smadja Software Factory

A deliberately small engineering company inspired by Paperclip's **Superpowers Dev Shop**, the **GStack** delivery loop, Teck-Lab's Paperclip DAG delivery, and Compound Engineering's **Plan → Work → Review → Compound** discipline.

## Operating model

1. **Engineering Manager** receives the objective, researches enough context to bound it, and creates a dependency-aware child-task graph with acceptance criteria.
2. **Researcher** handles focused external/repository research without changing production state.
3. **Implementation Engineer** works only on unblocked implementation leaves, using isolated branches/worktrees and producing tests plus evidence.
4. **Reviewer** performs an independent spec/code/security review and sends actionable changes back to implementation when needed.
5. **QA & Release Engineer** runs final acceptance checks, creates or updates the pull request, and reports runtime evidence. It does not self-merge. A separate release authority may merge an R1 change only after independent review, QA and required CI gates pass.
6. **Data Platform & Factory Engineering** owns the product primitives and improvement harness: it measures factory outcomes, turns recurring evidence into bounded improvements, and evolves `factory-platform` without making the production factory depend on unfinished product layers.

## Authority

- Git repositories are the engineering source of truth.
- Argo CD remains the only normal Kubernetes mutation path.
- Runtime evidence is required before claiming a deployment is healthy.
- Paperclip stores work state, ownership and decisions; it is not desired state.
- Destructive actions, public exposure, privilege escalation, identity/root rotation and irreversible migrations require human approval.
