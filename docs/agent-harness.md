# Agent and QA harness

The harness makes repository navigation and runtime evidence deterministic enough that a fresh agent does not need chat history.

## Layers

```
AGENTS.md                         routing/safety
.agents/skills/*                 progressive disclosure
just inventory/check             STATIC evidence
just runtime-inventory           RECONCILED/runtime inventory
just runtime-smoke               Gateway/DNS/TLS/backend evidence
just backup-audit                persistence protection evidence
tests/e2e                        curated USER journeys
```

Argo CD is the workload inventory and reconciliation authority. Gateway API HTTPRoutes are the web-endpoint inventory. There is no second application registry for testing.

## Automatic web smoke discovery

`runtime-smoke.sh` selects every HTTPRoute attached to `Gateway/internal` and checks independently:
- Route Accepted/ResolvedRefs;
- Service-backed ready EndpointSlices;
- UniFi DNS via `DNS_SERVER` (default `10.0.20.1`);
- valid TLS and HTTP directly against `10.0.20.192` while preserving SNI/Host.

A route can refine the generic probe:

```yaml
metadata:
  annotations:
    qa.smadja.dev/path: /health
    qa.smadja.dev/expected-status: "200,204"
    # qa.smadja.dev/probe: "false"
```

HTTP 404 is a failure by default because it frequently signals a Gateway hostname mismatch. Apps whose root intentionally returns 404 should declare a better probe path.

Results are JSONL under `.artifacts/runtime-smoke/`.

## Continuous monitoring

The existing Prometheus blackbox-exporter remains the continuous critical-surface monitor. It is not the canonical app inventory: Prometheus Operator `Probe` can discover Ingress resources but not Gateway API HTTPRoutes. Runtime discovery therefore queries HTTPRoutes directly.

## Integration tests

Kyverno Chainsaw is the preferred disposable-cluster scenario runner when apply/assert/cleanup semantics add value. It remains a test CLI, not a production controller or reconciler.

## Acceptance

- STATIC: `just check`
- RECONCILED: Argo desired revision + controller status
- RUNTIME: runtime smoke/app diagnostics/backup audit
- USER: Playwright or documented manual journey

Never promote lower-level evidence to a higher level.
