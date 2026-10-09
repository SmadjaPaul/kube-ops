# Agent and QA harness

The harness makes repository navigation and runtime evidence deterministic enough that a fresh agent does not need chat history.

## Per-run test result contract

Coding agents must report planned checks as JSON using
[`agent-test-result-v1.schema.json`](contracts/agent-test-result-v1.schema.json).
The checked-in [example](contracts/agent-test-result-v1.example.json) shows the
minimum handoff shape. A result is incomplete unless every planned check is
classified as `passed`, `failed`, `skipped`, `unavailable`, or
`not-applicable`, with explicit `execution`, `reason`, `risk`, and
`expectedCi` values. `not-executed` is not a pass and must not be inferred from
the absence of a hook artifact.

The `transmission` object is a stable, append-only projection for the separate
`factory-platform` consumer: `agent.test.result` plus the schema version,
idempotency key, and a credential-free payload. This repository defines the
shape only; it does not send telemetry or change the factory-platform runtime.

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

When `ARTIFACT_DIR` is set, results are JSONL in that directory. Without it,
the report is temporary and removed when the smoke command exits.

## Kubernetes access preflight

Every live-runtime recipe requires an operator-provided `KUBECONFIG`. The
recipe fails closed with `KUBE_ACCESS=BLOCKED` when the file, context, or API
is unavailable; it never falls back to the client default or
`localhost:8080`. The infrastructure repository owns the canonical temporary
kubeconfig broker (`just kube-access-check` and `just kubectl ...`). Export its
temporary `KUBECONFIG` when invoking these kube-ops runtime scripts; kube-ops
does not duplicate the Doppler broker.

By default, runtime smoke artifacts are created in a temporary directory and
removed at exit. Set `ARTIFACT_DIR` explicitly when a persisted report is
needed. Argo evidence includes both the desired target revision and any active
operation revision so a stale or blocked operation is visible.

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


## Backup classification

Every persisted application volume must be one of:

- protected by an offsite Velero/Kopia schedule; or
- explicitly labelled `backup.smadja.dev/strategy=rebuildable`.

The rebuildable label is reserved for caches or reproducible downloaded datasets.
It is currently appropriate for the vLLM model cache and other reproducible
downloaded datasets.
User-generated data must never use this exemption.

## Multi-agent capability model

The repository keeps shared operational knowledge in `.agents/skills/*`.
Paperclip role files define delegation and authority, not a second copy of
Kubernetes/GitOps runbooks. The canonical role matrix is
`k8s/applications/ai/paperclip/company/CAPABILITIES.md`.

A prompt is not a security boundary. The target enforcement layers are:

- GitHub App permissions for branch/PR write access;
- Kubernetes RBAC for read-only runtime evidence;
- LiteLLM virtual keys for logical-model/budget access;
- network policy for reachable services;
- Paperclip connector/tool policies only after the installed Paperclip version
  has been qualified to support them.

The Implementation Engineer may write a feature branch and open a pull request,
but it never self-merges. R1 release can still be autonomous when a separate
release authority sees independent review, QA and required CI gates pass. R2
always remains human-only.
