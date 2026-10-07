---
name: Data Platform & Factory Engineering
description: Product and harness BU building Factory Intelligence while continuously improving the software factory from measured evidence.
slug: data-platform-factory-engineering
manager: ../../agents/factory-platform-lead/AGENTS.md
includes:
  - ../../agents/data-platform-engineer/AGENTS.md
  - ../../agents/harness-engineer/AGENTS.md
tags:
  - data-platform
  - factory-intelligence
  - harness-engineering
  - product
---

## Mission

Build `factory-platform` as the first production vertical of a reusable commercial data
platform, while using that vertical to make the software factory progressively more
autonomous, automated and reliable.

## Product objective

The BU must maintain a direct line between current internal value and the commercial target:

`sources -> tenant-aware events -> canonical context -> metrics/features -> policy-gated actions`

The implementation may remain deliberately small at each stage, but those primitives must
not be replaced by one-off internal-only abstractions.

## Factory objective

Measure and improve:

- first-pass success and retries;
- human interventions;
- time to PR / merge / deploy;
- review and QA findings;
- CI and post-deploy failures;
- model/tool cost per successful task;
- recurrent failure classes.

The first Meta Loop creates improvement tasks from evidence. It does not self-merge or
self-deploy.

Shared Reviewer and QA & Release Engineer roles provide independent gates across this BU.
