---
name: acceptance-and-release
description: Perform whole-feature QA, create/update the pull request, and verify GitOps/runtime acceptance without self-merging.
---

# Acceptance and release

1. Re-read the objective and every child acceptance criterion.
2. Run whole-feature checks from a clean state.
3. Confirm required review findings are resolved.
4. Create or update one pull request with scope, tests, risks, rollback and runtime test plan.
5. Do not merge in V1.
6. After an authorized merge, verify Argo reconciliation and runtime behavior separately before declaring success.
