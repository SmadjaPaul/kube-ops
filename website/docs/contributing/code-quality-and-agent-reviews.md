---
title: Code quality and agent review policy
description: Measurable, reviewable continuous improvement for human and agent changes.
---

# Code quality and agent review policy

**Status:** proposed operating contract, 2026-10-15; neither an enabled scheduled job nor a validated metric pipeline.

## Goal and authority

Improve accepted, maintainable changes without rewarding lines written, PR count, or an agent's self-declared success. GitHub owns code/reviews, Mastra owns agent execution, the Data Platform owns analytical events and models, Linear owns actionable backlog, and Argo CD owns Kubernetes reconciliation.

Use the **existing** Mastra Meta Loop: `candidate → independent evaluation → human review → promotion`. Do not create a second orchestrator, collector database or shadow scorecard. Candidate changes to harnesses/skills/policies must be tested on a pinned dataset and approved; the author is not their sole reviewer.

## Baseline (first 30 days, per repository)

| Metric | Definition | Evidence source |
| --- | --- | --- |
| First-pass acceptance | Accepted tasks without material rework / accepted tasks | Linked task, review, CI and run attempts |
| Escaped defects | Regressions/rollback within a declared 30/90-day observation window | Reverts, incident links, deployment events |
| Human rework | Minutes of manual revision per accepted change, where reported | Reviewed human-intervention events |
| Cost per accepted task | Model + build cost / independently accepted tasks, separating unknown costs | Traced run costs, release/build evidence |
| Change failure rate | Changes deployed that required recovery / observed deployments | Deployment and recovery events |
| Lead time | Commit to verified deployment or explicitly report commit-to-merge instead | GitHub SHAs and Argo observations |
| Hotspot candidates | Changed frequently AND complex/high-coupling code, not LOC alone | Git history plus deterministic analyzers |
| Finding precision | Actionable findings confirmed / reviewed findings | Findings and human adjudication |

Unknown and unobserved values are **N/A**, never zero. Never compare repositories with different deploy cycles as if their DORA metrics were equivalent. Publish numerator, denominator, time window, dataset/source revision, and known gaps with each value.

Existing [factory-platform/dbt](https://github.com/SmadjaPaul/factory-platform/tree/main/dbt) fact and mart models are the starting point; preserve historical data and data contracts, then add gaps under a separate Data Platform change.

## Evidence and workflow

1. **On each PR:** typecheck, build, tests, static analyzer findings scoped to the diff, and security gates. Broken CI that did not execute is UNAVAILABLE, not PASS.
2. **Weekly, where execution is available:** collect deterministic findings (Knip for JS/TS with correct entrypoints, Semgrep, link checks, dbt reference graph, Kustomize/OpenTofu validations) and compare only *new* or changed findings against the baseline.
3. **Monthly:** the read-only Quality Curator inspects Git history/hotspots, code ownership, docs drift and verified runtime evidence. Deduplicate actionable proposals against Linear before filing. Limit model calls.
4. **For each candidate:** record repo, source SHA, path, rule, evidence, consumers, risk, reproducible test and a proposed smallest vertical change. Labels: `SAFE_CANDIDATE`, `REVIEW_REQUIRED`, `ARCHITECTURE_DECISION`.
5. **Before a PR:** an independently reviewed spec and acceptance tests. For experiments on harnesses preserve `runId`, `caseId`, `role`, `harnessDigest` and `datasetVersion`; compare against the pinned baseline and retain rollback.
6. **After merge:** measure effect on regressions, review effort and the original hotspot. Close only with independent acceptance evidence.

**Never automatically remove** Kubernetes resources, PVCs, database state, Terraform state, credentials, public web assets or historical analytics based only on static findings. Destructive changes need observed ownership, dry-run/diff and explicit approval.

## Public references and tools

- [Google Engineering Practices — code review](https://google.github.io/eng-practices/review/reviewer/standard.html)
- [DORA software delivery performance metrics](https://dora.dev/guides/dora-metrics/)
- [SPACE framework](https://doi.org/10.1145/3454122.3454124)
- [Knip configuration guidance](https://knip.dev/guides/configuring-project-files)
- [reviewdog](https://github.com/reviewdog/reviewdog) for deterministic diff annotations
- [PR-Agent](https://github.com/The-PR-Agent/pr-agent) as a reference for AI PR review, **not** as a second production orchestrator
- [Mastra human-in-the-loop approval](https://mastra.ai/docs/agents/human-in-the-loop)

Track rollout and any changes to this policy in [PLT-48](https://linear.app/boule/issue/PLT-48) and documentation drift in [PLT-42](https://linear.app/boule/issue/PLT-42).
