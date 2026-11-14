# Telemetry policy: metrics, logs, traces and retention

Owner: PLT-212 (Platform). Evidence date: 2026-11-12. Figures are live
measurements taken through the read-only Prometheus/Loki proxies unless marked
as a hypothesis.

## Principles

1. Reduce at the source first (exporter flags, `metricRelabelings`,
   `metricDenylist`, application log level), then filter in Alloy.
2. Never drop: errors and warnings, security events (Falco alerts outside CI
   runner pods, policy-engine and scanner findings), backup/restore evidence
   (Velero, Barman, Longhorn backup state), Kubernetes events.
3. Before any new filter, measure the matched volume over a bounded window and
   record it next to the filter. After the merge, measure again and keep or
   revert.
4. A metric family is dropped only if no active rule, alert, dashboard or
   script in this repository reads it (vendored chart rules included).
   Raw apiserver SLI histograms and `kube_pod_status_*` stay: they feed alerts.
5. Never put secrets, tokens, signed URLs or credentials in logs. An
   application that cannot avoid it is not ingested (see SparkyFitness in
   `alloy/values.yaml`).
6. No high-cardinality Loki labels. Allowed labels: `cluster`, `source`,
   `namespace`, `pod`, `container`, `node_name`, `job`. Everything else is
   parsed at query time.

## Baseline (2026-11-12, before PLT-212 changes)

| Item | Value |
|---|---|
| Prometheus head series | 177k to 213k (fluctuates with churn) |
| Prometheus ingestion | about 4.4k samples/s |
| Largest jobs (series) | apiserver 46k, kubelet 31k, kube-state-metrics 25k, longhorn 11k, node-exporter 8.5k, grafana 6.2k, trivy 6.1k |
| Series with no reader in repo or live rules | about 121k of 157k name/job pairs (upper bound, see principle 4) |
| TSDB | 7.5 GB blocks, retention 10d / 14 GB, PVC 20 Gi |
| Prometheus pod | 0.03 to 0.06 CPU core, 0.9 GiB RSS, 120 to 220 KB/s disk writes |
| Loki | 8.7 KB/s, 30 lines/s, 161 streams, 56 KB/s disk writes, retention 168h |
| Tempo | 1.9k spans in 24 h (0.02 spans/s), retention 168h |

The observability stack costs well under 0.2 CPU core and about 0.2 MB/s of
disk writes in total. It is not the source of the NVMe bursts or of the thermal
load: the gains here are series count, ingestion, TSDB size and signal quality.

## Metrics policy

| Source | Interval | Policy |
|---|---|---|
| kubelet cAdvisor | 30s | chart default drops plus blkio and memory-failure families |
| kubelet probes | default | probe latency buckets dropped, `prober_probe_total` kept |
| apiserver | 60s | duration buckets dropped, SLI histogram kept (burn-rate rules stay disabled, PLT-187/PLT-208) |
| kube-state-metrics | 45s | denylist of unread pod/replicaset families |
| node-exporter | default | Cilium `lxc*` interfaces excluded (per-pod traffic comes from cAdvisor) |
| Grafana | 60s | histograms and feature toggles dropped |

A new ServiceMonitor names its consumer (alert, dashboard or recording rule) in
the PR; otherwise `metricRelabelings` keeps only what is read.

## Log policy

| Severity or kind | Policy |
|---|---|
| error, warn, fatal, panic | always kept |
| info | kept unless a measured, repeated, no-decision line (healthcheck, per-connection, per-reconcile) |
| debug | not ingested on purpose; fix at the application |
| security (Falco) | kept, except "Executing binary not part of base image" from the `arc-runners` namespace |
| backup/restore (Velero, Barman, Longhorn) | always kept |

Filters in force (Alloy `loki.process "pods"`, each with a drop counter reason
exposed by Alloy as `loki_process_dropped_lines_total`):

| Reason | Measured over 6h |
|---|---|
| `falco_arc_runner_exec` | 153,857 events, about 390 MB of 626 MB total |
| `alloy_opened_log_stream` | 10.2 MB (symptom of a crash-looping pod, see backlog) |
| `mongodb_connection_chatter` | 17.8 MB of 18.9 MB |
| `argocd_controller_routine_info` | 6.3 MB of 17.5 MB |
| `argocd_repo_server_info` | 12.4 MB of 12.4 MB |

New workloads should emit JSON or logfmt with `level`, `msg` and a stable event
name, plus a request/correlation id where a request spans services.

## Retention

| Store | Retention | Note |
|---|---|---|
| Prometheus | 10d, 14 GB cap | alerts and dashboards use windows of 5m to 3d |
| Loki | 168h | enough for incident review; logs are reconstructible and not backed up |
| Tempo | 168h | candidate for removal, see backlog |

## Backlog (not delivered)

- Tempo: 1.9k spans per 24 h and no dashboard or alert reads traces. Proposal:
  remove the Tempo app and the Alloy OTLP pipeline once the owner confirms the
  Factory does not need traces. No data is deleted by this proposal.
- openclaw-operator is in CrashLoopBackOff (268 restarts in 32 h): root cause
  belongs to its own ticket; it feeds the Alloy log-stream loop above.
- Remaining no-reader families: Longhorn `longhorn_rest_client_*` and
  workqueue buckets, Trivy configaudit/RBAC/exposed-secret series (about 3k),
  Loki and Prometheus self-histograms (about 5k), `node_systemd_unit_state` of
  the Proxmox host (990). Kept for now because planned alerts (Phase 4) may
  read Longhorn state and Trivy results.
- GitHub runner logs (33 MB/6h, 382k lines): JSON dumps are split over many
  lines and cannot be filtered safely in Alloy; fix at the runner.
- CoreDNS NXDOMAIN bursts from search-path expansion (ndots:5) of one
  in-cluster client; the Corefile already logs errors only. Hypothesis: client
  uses a short service name; confirm before changing anything.
