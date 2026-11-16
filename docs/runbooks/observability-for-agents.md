# Observability for agents: "what is happening?"

Read-only runbook (PLT-312). Evidence level of everything here is RUNTIME for the
observed signal only: it proves neither Git reconciliation nor a user path.

## Ask first

```bash
bash scripts/observe.sh summary      # both clusters, ~30 lines
bash scripts/observe.sh alerts       # firing alerts by cluster/alertname/severity
bash scripts/observe.sh backups      # CNPG, Velero, Longhorn, PVC, certificates
bash scripts/observe.sh app <name>   # one namespace: Argo, pods, restarts, error logs 1h
bash scripts/observe.sh --local ...  # in-cluster Prometheus/Loki, homelab only
```

Exit 0 = answered, 1 = at least one query failed (`ERR` line), 2 = token or
tool absent. A missing `GRAFANA_AGENT_READ_TOKEN` stops the script before any
query; fall back to `--local` (homelab) and say that oracle-a1 was not read.
Rows are capped (`OBSERVE_MAX`, default 12). The token is injected by
`scripts/doppler-safe.sh` and never printed.

## Where to look

| Need | Source |
|---|---|
| Both clusters, bounded history | Grafana Cloud via `observe.sh` (label `cluster`: `homelab`, `oracle-a1`) |
| Full fidelity, complete logs | homelab: local Prometheus/Loki via `observe.sh --local` or `kubectl-ro.sh get --raw` |
| oracle-a1 | Grafana only (it runs Alloy and kube-state-metrics, no local Prometheus/Loki); pods and events via `kubectl-ro.sh --cluster oracle-a1` |
| Argo state of one app | `just status-app`, `just diagnose-app` |

Local access identity (PLT-312): `kubectl-ro.sh` uses the `agent-operator` ServiceAccount.
Its Role `agent-operator-monitoring-query` (`monitoring` namespace, `k8s/infrastructure/security/agent-operator/rbac.yaml`)
grants `get` on `services/proxy`, limited by `resourceNames` to
`kube-prometheus-stack-prometheus:9090` and `loki-gateway:80`. No Secret, no write verb, no other service
(Grafana, Alertmanager). A `403` on `get --raw .../proxy/...` means the Role is not reconciled yet
(`just status-app infra-security`) or the token is expired (Paul renews it); do not fall back to the operator copy to read metrics.
`agent-operator-token.sh --verify` checks `can-i` yes on both services and no for `create`, `patch`, `delete`, other services, other namespaces and Secrets.
oracle-a1 has no local Prometheus/Loki, so it gets no such Role.

Series are an allowlist: no result is a collection gap, not proof of health.
oracle-a1 exports no `ALERTS`, `velero_*`, `longhorn_*`, `kubelet_volume_stats_*`.

## Thresholds

| Signal | Act when |
|---|---|
| Alert (no Watchdog/InfoInhibitor) | `critical` firing: report now. Target: alert visible in under 10 minutes (priority 3) |
| Targets down | any `job` with `up == 0` for more than one scrape cycle |
| Nodes | any not Ready, any Pressure condition |
| Pods | Pending, Failed or Unknown for 15 minutes; restarts increasing over 1h |
| Argo | not Synced, or not Healthy (Progressing right after a merge is normal) |
| Backups | age far beyond the schedule (daily: over about 26 h); any WAL archive failing |
| Certificates | under 14 days |
| PVC | under 10 percent available |
| Series budget | `homelab` + `oracle-a1` each under 8,000 |

## Active alerts (snapshot 2026-11-16, homelab)

`ArgoCDOrphanedResourcesPresent`, `TargetDown` (alloy, kube-controller-manager,
kube-scheduler), `KubeControllerManagerInstanceUnreachable`,
`KubeSchedulerInstanceUnreachable`, `KubeJobFailed`, `KubePdbNotEnoughHealthyPods`,
`KubePodNotReady`, and info-level `CPUThrottlingHigh`, `NvmeHealthTelemetryMissing`,
`NvmeWriteRateAboveBudget`. Re-run `observe.sh alerts`: this list ages quickly.
Known, not new: Talos control-plane scrape alerts, orphan inventory, ARC runner
pods Pending.

## Forbidden

- No alert silence, no Alertmanager or Grafana write, no rule or datasource edit.
- No write of any kind through these tools: GET queries only. Fixes go through a PR.
- Never print, log or paste `GRAFANA_AGENT_READ_TOKEN` or any Doppler value.
- Never read a value from `cluster/prd`; agents have no access to it.
- No raw JSON dumps: aggregate (`count by`, `topk`), Loki `limit` <= 50, window <= 1h.

## Dependencies

- Token `GRAFANA_AGENT_READ_TOKEN`: Doppler `infrastructure/prd`, Grafana service
  account `agent-read` (Viewer), owned by homelab-infra `terraform/grafana-cloud`.
- Pending (D-2026-11-15-13): a Viewer token in Doppler `cluster/prd` for
  executors that run in ARC. Doppler `cluster/prd` is not reachable by agents:
  provision it through OpenTofu with a Doppler reference. Until then
  `observe.sh` works only where `infrastructure/prd` is readable.
- Standard queries and limits: `.agents/skills/observability/SKILL.md`.
