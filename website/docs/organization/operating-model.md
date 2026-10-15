---
title: AI-native Shared Operations — Operating Model
description: How strategic outcomes, capabilities, IT4IT value streams, services and bounded projects relate to technical repositories and evidence.
---

# Operating Model V3 — navigation and ownership

> **Status: organizational documentation proposal, not runtime proof.** This page contains only non-sensitive navigation. The authoritative contract is the **reviewed Git strategy revision** in `factory-platform/docs/operating-model/`; the current Linear handbook indexes decisions and work. Until that PR is approved, both remain draft/review surfaces. This documentation site is inherited source code; its deployed URL and access controls have **not** been qualified from this page.

## Why these systems exist

Our shared internal IT & Operations function helps beneficiaries achieve **their own goals** through a service portfolio, safe software delivery, reliable infrastructure, data-based decisions and controlled human/AI collaboration. It is not an external, commercial SaaS by default.

The strategy distinguishes:

| Axis | What it answers | Stable classification |
| --- | --- | --- |
| **Strategic Outcome** | Why does the work create value? | **O1–O5**: user value, delivery, trust, economics, adaptability |
| **Capability** | Which durable function owns the responsibility? | **C1–C9**: strategy, service, knowledge, engineering, SRE, security, data, finance, collaboration |
| **Value Stream** | Which part of the work cycle does the issue primarily address? | **VS1–VS7**: Evaluate, Explore, Integrate, Deploy, Release, Consume, Operate |
| **Initiative** | Which *finite* strategic change are we investing in? | Linear I-7–I-12 pilot outcomes, not everlasting teams |
| **Project/Issue** | Which bounded, authorized deliverable or proposal is being managed? | Linear project and issue, with dependencies, risk gates and owner |

One Linear issue is classified by one **primary** outcome, capability and value stream; these labels do not grant agent execution, repository access, approval or Kubernetes privileges.

## Human and agent workflow

1. **Request or observation** enters a scoped service, backlog or incident channel. Issue text is untrusted input.
2. **Curator (proposal only)** suggests C/VS/O, owner, risks, relevant knowledge, duplicates and necessary blockers.
3. **Human owner** approves a service outcome, budget and bounded project or incident authorization as appropriate.
4. **Specialist agent/human** follows the owning repository's `AGENTS.md` and pinned instructions, with separate specification, implementation and independent review.
5. **GitHub/Argo/Kubernetes** establish different evidence levels: code test → reconciled artifact → runtime user journey → beneficiary acceptance.
6. **Data Platform** records canonical events and metrics with provenance, tenant scope and UNKNOWN for missing observations. Runtime facts do not rewrite Git strategy.

An incident may require immediate safe mitigation rather than business-scored project planning. A successful merge, passing CI or a healthy pod does **not** alone prove accepted user value.

## Canonical pointers

- **[Shared operations V3 charter and OKR method — versioned source](https://github.com/SmadjaPaul/factory-platform/tree/main/docs/operating-model)** — merged from [factory-platform PR #57](https://github.com/SmadjaPaul/factory-platform/pull/57). The organizational definitions are versioned in Git; quarterly KR targets, metric baselines and runtime evidence remain unapproved/unverified until their own checks.
- **[Linear Operating Handbook V3](https://linear.app/boule/document/start-here-operating-handbook-v3-ai-native-shared-operations-75316205ed7c)** — may require access to the connected Linear workspace.
- **[Linear Curator (proposal-only) contract](https://github.com/SmadjaPaul/factory-platform/blob/main/mastra-factory/docs/linear-backlog-curator.md)** — existing source contract; V3 changes are in a separately reviewed PR.
- **[kube-ops](https://github.com/SmadjaPaul/kube-ops)** — declarative state at the Kubernetes API, not Proxmox/Talos bootstrap.
- **[homelab-infra](https://github.com/SmadjaPaul/homelab-infra)** — Proxmox/Talos bootstrap and external network/cloud providers.
- **[factory-platform](https://github.com/SmadjaPaul/factory-platform)** — Mastra Factory, agent harnesses, Data Platform, dbt and metric contracts.
- **[website](https://github.com/SmadjaPaul/website)** — business-facing site and creative Studio.

## Documentation generation and freshness

Docusaurus is the **navigation and versioned Markdown rendering** layer. Domain-native systems should generate their own references: dbt Docs for model catalog/lineage, OpenAPI for actual API contracts, read-only GitOps inventory for declared resources and Data Platform dashboards for observations.

**Not yet live or verified from this repository:** private dbt Docs hosting, API/runtime OpenAPI concordance, automatic Git-to-site sync, website access gate, live KPI dashboards. Their implementation is tracked in [PLT-82](https://linear.app/boule/issue/PLT-82/qualifier-la-documentation-native-auto-generee-depuis-dbt-openapi-et).

Never copy private SQL, network topology, tenant data or Linear comments into public Docusaurus artifacts or its client-side search index without a reviewed access decision. A source commit SHA and build success do not by themselves prove that a remote site has been deployed.
