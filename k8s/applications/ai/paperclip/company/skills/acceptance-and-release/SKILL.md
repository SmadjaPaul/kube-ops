---
name: acceptance-and-release
description: Perform whole-feature QA, create/update the pull request, and verify GitOps/runtime acceptance without self-merging.
---

# Acceptance and release

1. Re-read the objective and every child acceptance criterion.
2. Run whole-feature checks from a clean state.
3. Confirm required review findings are resolved.
4. Create or update one pull request with scope, tests, risks, rollback and runtime test plan.
5. Never self-merge. When the task is R1 and independent review, QA and required CI gates all pass, mark the release gate satisfied for the external release authority.
6. R2 remains human-only regardless of review or QA.
7. After an authorized merge, verify Argo reconciliation and runtime behavior separately before declaring success.
