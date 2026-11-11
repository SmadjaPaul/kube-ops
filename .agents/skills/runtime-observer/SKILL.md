---
name: runtime-observer
description: Collect read-only post-merge evidence from Argo, Kubernetes, Gateway API, DNS/TLS and backups.
---

# Runtime observer

Use `just runtime-inventory`, `just runtime-smoke`, `just status-app`, `just diagnose-app`, then `just backup-audit`.
The smoke harness discovers internal HTTPRoutes automatically and separates route, endpoint, DNS and TLS/HTTP failures.
Runtime evidence is not authority; repair proven defects in Git.

## Current platform

- Talos 1.13.10 / Kubernetes 1.36.3, one schedulable node for V1.
- Cilium + Gateway API; `Gateway/internal` LAN VIP is `10.0.20.192`.
- private ExternalDNS derives application names from internal HTTPRoutes and publishes them into UniFi DNS.
- UniFi DNS is the private application authority; AdGuard is filtering/cache only.
- Argo CD is the only steady-state Kubernetes reconciler.
- Longhorn `longhorn-fast` / `longhorn-bulk`.
- CNPG/Barman and Velero/Kopia -> Hetzner Object Storage.
- Doppler -> ESO for runtime secrets; never inspect Secret values.
- Authentik is the identity authority.
- public access is Cloudflare Tunnel -> Gateway/external.

## Runtime evidence order

```
Git desired state
  -> Argo Application/ApplicationSet
  -> controller resource status
  -> Kubernetes workload / Service / EndpointSlice
  -> Gateway / DNS / TLS
  -> user journey
```

For HTTP failures distinguish DNS, TLS, HTTPRoute status, ready EndpointSlices and the application response. Do not debug OAuth while DNS/TLS/backend routing is unproven.


## Coding-agent test results

Every PR body lists, in a few lines, the checks that were run (with result) and the checks that were not run (with reason). A missing check is never reported as a pass.

The machine-readable record in `docs/contracts/agent-test-result-v1.schema.json` is required only when the handoff is consumed by the `factory-platform` evidence pipeline (Factory runs). Interactive and orchestrator agents do not produce it (decision D-2026-11-11-12, token budget).

