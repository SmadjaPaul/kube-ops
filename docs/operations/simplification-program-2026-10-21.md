# Simplification program — operator approved, execution staged

All tasks are approved except **deletion choices for dormant app manifests**.
Avoid turning this document into another source of cluster desired state.

| Phase | Change | Qualification |
|---|---|---|
| A | `just inventory` via actual Argo roots + Kustomize imports; correct agent routing, one service recipe | Git-only fixture test; verify active/dormant source ownership |
| B | Review SearXNG KEDA #612, VPA #613, resource dashboard #614 without stacking overlapping edits | Existing PR review, static + live promotion |
| C | Full live CPU/RAM requests vs P95/P99, CPU throttling/OOM, ARC 0/1/3, PV/I/O, 7–30d Prometheus retention | PLT-53; distinct measured request and usage gains |
| D | Assess KEDA HTTP add-on cost vs fixed IT-Tools 1 replica, after identifying every scaled consumer | PLT-107; cold-start, endpoints and SLO checks |
| E | Docusaurus/Netlify retirement **only if** its runtime consumers and restore runbooks are migrated; evaluate Grafana JSON extraction and source-driven checks | No user-facing document deletion, no duplicate dashboards |
| F | Doppler Terraform split without changing resource addresses/state, followed by consumer-by-consumer secret audit | homelab-infra PR; no destroy/rotation |
| G | Mastra Factory patch and optional integration audit (GitLab/Jira/Slack/etc), simplify only with upstream parity/evals | factory-platform PR; preserve retry/leases/sandbox/security |

## Dormant candidates — NO deletion in this PR

- `ai/{perplexica,vllm-embed,pocket-tts}`
- `media/whisperasr`
- `automation/{zigbee2mqtt,matter-server}`
- `web/babybuddy`
- `catalog/{actual-budget,dawarich,metabase}`
- Additional unimported directory candidates detected by `just inventory` need owner/backup inspection, including media services.

Retained-only data owners `business/retained/{listmonk,twenty}` and `ai/paperclip` are **not** disposable dormant workloads. An absent Argo root `applications/restore` must be reconciled safely; auto-prune is enabled.

Review by Codex after PR checks, merge only if independent static qualification and relevant runtime safety proofs pass. Runtime mutation must remain Git → Argo; no direct kubectl changes.
