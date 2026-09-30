---
name: verification-before-handoff
description: Require fresh executable evidence before claiming implementation, review or release work is complete.
---

# Verification before handoff

Run the relevant formatter/linter/unit/integration/render checks from the current tree. Capture exact failures rather than paraphrasing them away. For Kubernetes GitOps, a merged manifest is not runtime proof: verify Argo state, resource readiness and the user-visible path separately.

Never use cached success from an earlier commit as evidence for the current commit.
