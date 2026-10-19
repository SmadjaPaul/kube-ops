# Grafana catalogue consolidation

Status: PR-ready GitOps change; Argo reconciliation and Grafana browser rendering
remain post-merge gates.

## Decision

The live cluster had 45 dashboard ConfigMaps in `monitoring`: four local
dashboards, 28 `kube-prometheus-stack` dashboards, 11 Loki dashboards and two
Loki Bloom dashboards. They were all imported into `General`, which made the
chart catalogue the operational interface.

This change disables only dashboard ConfigMaps from the two charts. Prometheus,
Loki, Tempo and Alloy metrics, ServiceMonitors, recording rules and alerts stay
enabled. Eleven versioned ConfigMaps become the GitOps catalogue:

| Folder | Dashboard | UID | Decision |
| --- | --- | --- | --- |
| 00 — Overview | Platform Overview | `homeops-operations` | merge local overview and health/capacity signals |
| 10 — Infrastructure | Host & Hardware | `homeops-edge-boot-io` | merge physical Proxmox and Talos guest diagnosis |
| 10 — Infrastructure | Storage & Backups | `storage-backups` | new PVC, storage-class and backup-job view |
| 20 — Kubernetes | Cluster & Workloads | `cluster-workloads` | merge Kubernetes resource and workload views |
| 20 — Kubernetes | Networking | `networking` | merge Cilium, DNS and route-probe views |
| 30 — Observability | Telemetry Pipeline | `homeops-logs-efficiency` | merge Prometheus/Loki/Tempo/Alloy operations |
| 40 — Software Factory | Factory Operations | `factory-operations` | new observed factory-platform operations view |
| 40 — Software Factory | Factory Performance | `factory-performance` | new view using existing CI/merge/collection metrics |
| 50 — Data Platform | dbt V2 Operations | `factory-data-platform-v2` | preserve existing UID and split quality concerns |
| 50 — Data Platform | Data Quality | `data-quality` | new dbt test/freshness/publication-gate view |
| 90 — Advanced Diagnostics | Prometheus & Scrape Diagnostics | `9fa0d141-d019-4ad7-8bc5-42196ee308bd` | preserve useful Prometheus Overview URL |

The first ten are the operational target. The eleventh is intentionally an
advanced diagnostic view, not another landing page.

## Keep / merge / advanced / disable matrix

| Source | Decision | Reason |
| --- | --- | --- |
| Existing HomeOps Operations | KEEP/MERGE | becomes Platform Overview; UID and links remain stable |
| Existing Boot, CPU & Guest I/O | KEEP/MERGE | becomes Host & Hardware; physical exporter target is live |
| Existing Logs & Collection Cost | KEEP/MERGE | becomes Telemetry Pipeline and gains Prometheus/Tempo signals |
| Existing Data Platform V2 | KEEP/SPLIT | becomes dbt V2 Operations; Data Quality gets its own focused view; Fusion references remain because V2 is active |
| kube-prometheus-stack Prometheus Overview | ADVANCED | retained as a curated Prometheus & Scrape Diagnostics URL |
| kube-prometheus-stack Kubernetes Networking/Compute/PV/Node views | MERGE | their useful signals are represented in Networking, Cluster & Workloads, Storage & Backups and Host & Hardware |
| kube-prometheus-stack AIX and MacOS | DISABLE | operating systems are not present in this Linux homelab |
| kube-prometheus-stack Scheduler, Controller Manager and etcd | DISABLE | no useful standalone operator workflow was proven for this single-node Talos topology; core signals remain in Cluster & Workloads |
| kube-prometheus-stack Alertmanager/Grafana/Kubelet detail | MERGE/DISABLE | health and alert counts belong on Platform Overview; specialist details are not a primary operational dashboard |
| Loki Logs, Reads, Writes, Retention, Chunks, Deletion and Operational | MERGE | consolidated into Telemetry Pipeline without disabling Loki collection or rules |
| Loki Bloom Build and Gateway | DISABLE | Loki Bloom planner, builder and gateway replicas are configured at zero |
| Loki Thanos Object Store | DISABLE | this installation uses filesystem storage on the Loki PVC, not Thanos object storage |
| Loki recording-rules dashboard | DISABLE | recording rules remain provisioned; the dashboard adds no operational decision beyond the curated views |

## Evidence gaps kept visible

The live Prometheus target `proxmox-host` is `up=1` and provides CPU modes,
iowait, load, memory and physical disk counters. The current scrape returned no
`node_hwmon_temp_celsius`, `node_hwmon_fan_rpm`, ZFS, native Longhorn, Velero or
Kopia metric series. The dashboards therefore show this as an explicit coverage
gap rather than displaying a fabricated zero. Adding thermal, SMART, ZFS or
backup-object-store metrics belongs in the owning `homelab-infra` exporter or
backup work, with its own security and cost review.

Likewise, the live factory exporter provides the metrics used by Factory
Operations, Factory Performance, dbt V2 Operations and Data Quality. It does
not currently expose token/cost-per-run or agentgateway/sandbox-specific
series, so those panels were not invented.

## Rollback

Revert this Git commit and let Argo reconcile. The revert restores the previous
four local ConfigMaps, re-enables chart-provided dashboard ConfigMaps and
restores the Loki dashboard chart setting. No Prometheus scrape, alert, rule,
PVC or application data is changed by this catalogue refactor.

Before merging, verify the four preserved UIDs and the replacement rendering in
Grafana. After merge, verify `infra-monitoring` is `Synced/Healthy`, the
sidecar reports the seven folders, and the live dashboard count is 11 curated
views plus no AIX/MacOS/Bloom ConfigMaps.
