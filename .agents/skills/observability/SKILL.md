---
name: observability
description: Read the state of the homelab and oracle-a1 clusters from Grafana Cloud (Prometheus and Loki) with bounded, read-only queries. Use first for "what is happening on the cluster / on OKE?", failing pods, backups, Argo sync, certificates.
---

# Observability (Grafana Cloud, read-only)

Grafana Cloud stack `smadja` holds a bounded copy of both clusters (PLT-306).
Label `cluster` is `homelab` or `oracle-a1`. Local Prometheus/Loki stay the
full-fidelity source; use them (`runtime-observer`) only when this copy lacks
the series.

## Access

- Endpoint: `https://smadja.grafana.net`, data source proxy, header
  `Authorization: Bearer $GRAFANA_AGENT_READ_TOKEN`.
- Token: Doppler `infrastructure/prd` key `GRAFANA_AGENT_READ_TOKEN`
  (service account `agent-read`, role Viewer, owner homelab-infra
  `terraform/grafana-cloud`). Inject it with
  `bash scripts/doppler-safe.sh run -- <cmd>`; never print it.
- Prometheus: `/api/datasources/proxy/uid/grafanacloud-smadja-prom/api/v1/query`
- Loki: `/api/datasources/proxy/uid/grafanacloud-smadja-logs/loki/api/v1/query_range`
- If a UID is wrong, list names and UIDs only:
  `/api/datasources` piped to `jq -r '.[]|.uid+" "+.type'`.

Run queries in the child shell that receives the token; `set -eo pipefail`
stops at the first failed request instead of printing nothing:

```bash
bash scripts/doppler-safe.sh run -- bash -c '
  set -eo pipefail
  q() { curl -fsS -G -H "Authorization: Bearer $GRAFANA_AGENT_READ_TOKEN" \
    "https://smadja.grafana.net/api/datasources/proxy/uid/grafanacloud-smadja-prom/api/v1/query" \
    --data-urlencode "query=$1" | jq -c ".data.result[]|[.metric,.value[1]]"; }
  q "count by (cluster) (up)"
  q "count by (cluster, alertname) (ALERTS{alertstate=\"firing\"})"'
```

## Token economy

- Always aggregate (`count by`, `sum by`, `topk`). Filter to non-zero only
  when zero is the healthy value; keep `== 0` results where zero means
  failure (Ready conditions, ready pods).
- One instant query per question; `query_range` only for a trend, step >= 5m.
- Loki: always `limit` <= 50 and a window <= 1h; select by `cluster` and
  `namespace` first.
- Print `jq -c` compact rows, never raw JSON.

## Standard queries (PromQL)

| Question | Query |
|---|---|
| Collectors alive | `count by (cluster) (up)` |
| Firing alerts | `count by (cluster, alertname, severity) (ALERTS{alertstate="firing"})` |
| Node not Ready | `kube_node_status_condition{condition="Ready",status="true"} == 0` |
| Node pressure | `kube_node_status_condition{condition=~".*Pressure",status="true"} == 1` |
| Pods not ready | `sum by (cluster, namespace, pod) (kube_pod_status_ready{condition="true"}) == 0` |
| Pods Pending/Failed/Unknown for 15 min | `sum by (cluster, namespace, pod, phase) (min_over_time(kube_pod_status_phase{phase=~"Pending\|Failed\|Unknown"}[15m])) > 0` |
| Waiting reasons | `count by (cluster, namespace, reason) (kube_pod_container_status_waiting_reason)` |
| Restarts (1h) | `topk(10, increase(kube_pod_container_status_restarts_total[1h]) > 0)` |
| Argo not Synced/Healthy | `count by (cluster, name, sync_status, health_status) (argocd_app_info{sync_status!="Synced"} or argocd_app_info{health_status!="Healthy"})` |
| CNPG last backup age (h) | `(time() - cnpg_collector_last_available_backup_timestamp) / 3600` |
| CNPG WAL archive failing | `cnpg_pg_stat_archiver_last_failed_time > cnpg_pg_stat_archiver_last_archived_time` |
| Velero last success age (h) | `(time() - velero_backup_last_successful_timestamp) / 3600` |
| Longhorn degraded volumes | `longhorn_volume_robustness > 1` |
| Certificates < 14 days | `(certmanager_certificate_expiration_timestamp_seconds - time()) / 86400 < 14` |
| PVC almost full | `kubelet_volume_stats_available_bytes / kubelet_volume_stats_capacity_bytes < 0.1` |
| Series budget (< 8,000) | `count by (cluster) ({cluster=~".+"})` |

## Standard queries (LogQL)

- Errors of one namespace: `{cluster="homelab", namespace="argocd"}` (only
  warning/error lines are exported).
- Warning events: `{cluster="oracle-a1", source="kubernetes-events"}`.
- Volume per namespace (1h): `sum by (namespace) (count_over_time({cluster="homelab"}[1h]))`.

## Limits

- Exported series are an allowlist: homelab `k8s/infrastructure/monitoring/alloy/values.yaml`
  (`grafana_cloud_federate`), oracle-a1 `k8s/clusters/oracle-a1/observability/alloy-values.yaml`.
  A missing series is a collection gap, not a healthy state.
- Logs below warning, and namespaces outside the homelab allowlist, are not exported.
- oracle-a1 has no node CPU/memory usage series.
- This is evidence level RUNTIME for the observed signal only; it does not
  prove Git reconciliation or user paths.
