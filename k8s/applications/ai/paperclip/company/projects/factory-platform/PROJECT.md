---
kind: project
name: factory-platform
slug: factory-platform
description: Factory Intelligence vertical and reusable commercial Data Platform primitives.
owner: factory-platform-lead
---

The canonical repository is `SmadjaPaul/factory-platform`.

## Objective

Deliver immediate metrics and improvement loops for Smadja Software Factory while building
the product around stable, commercially reusable primitives:

- tenant / principal boundary;
- connection and source contracts;
- versioned idempotent events;
- canonical entities and metrics;
- auditable policy-gated actions.

## Current vertical

Factory Intelligence:

`Paperclip + GitHub + CI + Argo -> events -> canonical models -> metrics -> improvement loop`

The current implementation is intentionally PostgreSQL + FastAPI + dbt Core. Future
components such as Nango, OpenTelemetry/Phoenix, object storage or DuckLake are added only
when the roadmap reaches a use case that justifies them.

## Delivery constraints

- preserve multi-tenant contracts even while the first tenant is internal;
- prefer delta/incremental ingestion over full refresh;
- do not duplicate source data unless a canonical/derived representation saves meaningful
  compute, latency or downstream complexity;
- every third-party dependency must be compatible with the commercial product strategy;
- no product-layer experiment may block the main software factory;
- all runtime changes follow Git -> CI -> Argo -> evidence.
