---
name: cluster-investigation
description: Investigate the live clusters (homelab, oracle-a1) read-only - Argo sync/health, failing workloads, Gateway/DNS/TLS, backups, incident triage, post-merge proof - then deliver and verify. Use for any "what is happening / why is X down / did it deploy?" question.
---

# Cluster investigation

Transverse entry (any repo, plugin `homelab-ops` of SmadjaPaul/agent-harness): skills `cluster-investigate` and `access-preflight` carry the access recipe and the Argo -> pods -> events -> logs tree; this skill stays the kube-ops detail.

One entry for every runtime question. Evidence is RUNTIME for the observed signal only: it proves neither Git reconciliation nor a user path. Repair proven defects in Git.

## Start here

`just investigate <app> [homelab|oracle-a1] [summary|errors|full]` (`bash scripts/investigate.sh app <name> [--cluster homelab|oracle-a1]`): one read-only call returning `=== ARGO ===` (sync, health, revision, last error), `=== WORKLOADS ===` (pods Ready, warning events) and `=== METRICS ===` (Grafana Cloud, `METRICS=UNAVAILABLE` when absent: not a failure), then `VERIFY=PASS|FAIL`, `EVIDENCE_SCOPE=RUNTIME` and a private `EVIDENCE=` file. Takes the app name or its `apps-`/`infra-` name. `just status-app` and `just diagnose-app` remain as its internal modules for one section only.

## Tool order (go further only when `just investigate` does not answer)

1. **Argo CD MCP (`argocd`, read-only)**: Application state, conditions, resources (11 read-only tools). Local bridge `scripts/argocd-mcp-stdio.sh`.
2. **`bash scripts/kubectl-ro.sh [--cluster homelab|oracle-a1] <get|describe|logs|top|events|...>`**: the only kubectl read path (no Secret data, limited identity, preflight); every investigation script reads through it. Never run `kubectl` directly to read; never `kubectl get secret -o ...`.
3. **`bash scripts/observe.sh [--local] summary|alerts|backups|app <name>`**: bounded Grafana Cloud (both clusters) or in-cluster Prometheus/Loki (`--local`, homelab). Queries and limits: `queries.md` here; runbook `docs/runbooks/observability-for-agents.md`.
4. Broad checks: `just runtime-inventory`, `just runtime-smoke` (routes, endpoints, DNS, TLS/HTTP), `just backup-audit`; cluster snapshot `docs/state/cluster-reality.md`.
5. Network policy drops: `.agents/skills/cilium-hubble`.

Never read a Secret value: names, keys and references only (`get secret -o name`, `describe secret`). Never print `GRAFANA_AGENT_READ_TOKEN` or any Doppler value. Absent series are a collection gap, not health.

## Method

Reproduce -> first broken layer -> smallest Git fix -> `just check` -> PR -> Argo -> runtime/user retest. Do not merge unrelated root causes found together.

Layers (follow the evidence order, do not skip):

```
Git revision -> ApplicationSet -> Application sync/health/conditions
  -> first failing resource -> Kubernetes workload / Service / EndpointSlice
  -> Gateway / DNS / TLS -> user journey
```

- HTTP failure: HTTPRoute Accepted/ResolvedRefs -> Service selector/port -> EndpointSlice ready endpoints -> Pod readiness -> logs. Distinguish DNS, TLS, route status, endpoints and the application response; do not debug OAuth while those are unproven.
- Startup failure (CrashLoopBackOff, ImagePullBackOff): compare Kubernetes command/args with the image OCI ENTRYPOINT/CMD before adding shell wrappers.
- Distinguish cosmetic resource health from a real unhealthy workload.
- Never sync or reconcile as a deployment mechanism. A stuck sync: `scripts/argo-terminate-stuck-sync.sh` (AGENTS.md Safety).
- Restoring service (scale, restart, rollout, suspend) goes through `scripts/kubectl-rw.sh` in the admitted scope; a manual run of a CronJob listed in `k8s/infrastructure/security/agent-operator/cronjob-run.tsv` is `kubectl-rw.sh run-cronjob <ns> cronjob/<name>` (Home Assistant and Music Assistant, PRD-88); with Argo selfHeal, merge the Git change first or the repair is reverted.

## Deliver on either cluster (homelab or oracle-a1)

The delivery steps (worktree, branch, `just check`, PR, merge, `just verify-delivery`, rollback) are the plugin skill `homelab-ops:gitops-deploy`; follow it. Two independent Argo CD instances, one workflow (`docs/operations/two-argo-one-workflow.md`); the agent never opens an Argo CD interface. kube-ops specifics for reading the result:

- Descriptors: homelab needs `argocd-app.yaml` in the app folder (ApplicationSet `apps`, Application `app-<name>`; a folder without descriptor generates no Application). OKE uses `argocd-app.oracle-a1.yaml` next to the app's `kustomization.yaml` (`docs/operations/argo-app-descriptor.md`). No data (PVC, CNPG) on OKE before PLT-190.
- `just verify-delivery` needs no cluster access in a cloud session (Grafana Cloud, `GRAFANA_AGENT_READ_TOKEN`).
- `VERIFY=PASS` is RUNTIME for Argo sync/health and pods Ready only (see `EVIDENCE_SCOPE`: no route, DNS, TLS); `REVISION=NOT_PROVEN`. FAIL: read `LAST_ERROR`, then `queries.md`; with cluster access `just investigate <app>`.
- Absent series = FAIL, not health. First check the Application name and that it exists in Git (a typo gives the same result). Only then suspect a collection gap and fix the Alloy allowlist (homelab `monitoring/alloy/values.yaml`, OKE `clusters/oracle-a1/observability/alloy-values.yaml`) and check the series budget (< 8,000).

## Current platform (for interpreting results)

- Talos / Kubernetes, one schedulable node for V1. Cilium + Gateway API; `Gateway/internal` LAN VIP `10.0.20.192`.
- Private ExternalDNS publishes internal HTTPRoute names into UniFi DNS (the private authority; AdGuard is filtering/cache only). Public access is Cloudflare Tunnel -> Gateway/external.
- Argo CD is the only steady-state reconciler. Longhorn `longhorn-fast` / `longhorn-bulk`; CNPG/Barman, Velero/Kopia and Longhorn backups -> Cloudflare R2.
- Doppler -> ESO for runtime secrets. Authentik is the identity authority.

PR test reporting rules: AGENTS.md Evidence.
