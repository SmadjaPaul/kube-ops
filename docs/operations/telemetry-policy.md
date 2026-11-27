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
disk writes in total. It is not the source of the NVMe bursts: the gains here are series count, ingestion, TSDB size and signal quality.

## Metrics policy

| Source | Interval | Policy |
|---|---|---|
| kubelet cAdvisor | 30s | chart default drops plus blkio, memory-failure, memory-accounting, pressure and OOM-event families |
| kubelet probes | default | probe latency buckets dropped, `prober_probe_total` kept |
| apiserver | 60s | duration buckets dropped, SLI histogram kept (burn-rate rules stay disabled, PLT-187/PLT-208) |
| kube-state-metrics | 45s | denylist of unread pod/replicaset families |
| node-exporter | default | Cilium `lxc*` interfaces excluded (per-pod traffic comes from cAdvisor) |
| Grafana | 60s | histograms and feature toggles dropped |

Revue 2026-11-23 (« Observabilité utile ») : further drops with no reader
(scheduler plugin and controller-manager informer histograms, workqueue
buckets, `kubernetes_feature_enabled`, Longhorn `longhorn_rest_client_*`,
Trivy config-audit/RBAC counters and controller-runtime histograms, Proxmox
`node_systemd_unit_state` except `state="failed"`): about 10k of 122k local
series. Golden-signal recording rules and critical alerts live in
`prometheus-stack/golden-signals-rules.yaml`; the Grafana Cloud export swaps
`longhorn_backup_state` (533 healthy series) for the problem-only
`longhorn:backup_not_completed:state` (Longhorn backup state stays complete in
the local Prometheus).

PLT-538 (lot 2a de PLT-460) : les familles cAdvisor et
`kubernetes_feature_enabled` sans lecteur sont retirees a la source, apres
recherche dans les regles, les alertes, les tableaux de bord, les autoscalers
et les scripts du depot (les regles embarquees du chart incluses) :
`container_memory_failcnt`, `container_pressure_{cpu,io}_{stalled,waiting}_seconds_total`,
`container_oom_events_total`, `container_memory_kernel_usage`,
`container_memory_total_inactive_file_bytes` (endpoint `/metrics/cadvisor` du
ServiceMonitor kubelet) et `kubernetes_feature_enabled` (kubelet `/metrics` et
apiserver). Le contrat `npm run check:monitoring-cardinality` verifie que ces
familles restent coupees et qu'aucun lecteur ne les cite dans le depot. Le gain
en series reste NOT_PROVEN tant qu'il n'est pas mesure apres deploiement.

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
- Remaining no-reader families: Loki and Prometheus self-histograms (about
  5k), apiserver workqueue buckets. `kubernetes_feature_enabled` is not one of
  them any more: PLT-538 lot 2a confirms the reader search and the family is
  dropped on every source that emits it (kubelet `/metrics`, apiserver,
  scheduler, controller-manager).
- GitHub runner logs (33 MB/6h, 382k lines): JSON dumps are split over many
  lines and cannot be filtered safely in Alloy; fix at the runner.
- CoreDNS NXDOMAIN bursts from search-path expansion (ndots:5) of one
  in-cluster client; the Corefile already logs errors only. Hypothesis: client
  uses a short service name; confirm before changing anything.

## Grafana Cloud export (PLT-306)

Alloy copies a bounded subset to Grafana Cloud (stack `smadja`) for agents.
Local Prometheus and Loki stay the full-fidelity store.

- Metrics: `prometheus.scrape "grafana_cloud_federate"` reads the local
  Prometheus `/federate` with an explicit `match[]` allowlist (nodes, pods,
  workloads, PVC, `up`, firing `ALERTS`, Argo CD, CNPG, Velero, Longhorn,
  cert-manager, ARC). `sample_limit = 8000` rejects a whole scrape above
  8,000 samples; it does not bound series churn over time, so the runtime
  budget check below is the authority. Label `cluster="homelab"`.
- Logs: warning/error lines of the allowlisted namespaces (a line with an
  parsed `level` field (logfmt or JSON; for CNPG JSON `record.error_severity` wins) of `info`/`debug`/`trace`/`log`/`notice` is dropped first), and Kubernetes
  events of type `Warning`. Ceilings: 5 lines/s (burst 200) for pods, 2
  lines/s (burst 100) for events. Label `cluster="homelab"`. The local
  SparkyFitness and noise filters run before the export.
- Credentials: Secret `alloy-grafana-cloud` (ExternalSecret, Doppler
  `cluster/prd`), write-only token. Egress: `alloy-grafana-cloud-egress`.
- Budget check (runtime): `count({cluster="homelab"})` in Grafana Cloud
  stays below 8,000.
