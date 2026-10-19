# Grafana catalogue consolidation

Status: PR #551 review candidate; Argo reconciliation and Grafana browser
rendering remain post-merge gates.

## Provisioning contract

The installed `kube-prometheus-stack` chart is `88.3.0` and bundles Grafana
chart `12.10.4`. Its values documentation explicitly supports using
`sidecar.dashboards.folderAnnotation` together with
`sidecar.dashboards.provider.foldersFromFilesStructure`. The rendered templates
turn the former into the sidecar `FOLDER_ANNOTATION` environment variable and
the latter into the Grafana file-provider option; when the latter is enabled,
the provider does not use one fixed `folder`/`folderUid`.

This catalogue therefore has one folder authority: the
`metadata.annotations.grafana_folder` annotation on each curated ConfigMap.
The seven folder names below are rendered into the sidecar filesystem and are
not duplicated by a provider-level folder setting. `defaultDashboardsEnabled:
false` disables only the chart's upstream dashboard ConfigMaps. The Prometheus,
Loki, Tempo and Alloy metric collection, recording rules and alerts remain
enabled.

Datasource references are deliberately explicit: PromQL panels use the
Grafana datasource UID `prometheus`; the Loki panel uses the `DS_LOKI` variable
whose selected datasource is `Loki`; Tempo is an Explore link using the
configured `tempo` datasource. No panel relies on a generated datasource UID.

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

The pre-merge Prometheus audit evaluated 81 unique PromQL expressions (94
panel usages): there were no query errors. Before the blackbox relabel fix,
the only empty results were the user-ready probe selector and the OOMKilled
selector. The former was a real label propagation defect: target labels were
present only on ServiceMonitor metadata, so the probe metric did not carry
`v1_user_ready`; the catalogue change adds the supported
`additionalMetricsRelabels` entry to the eight user-ready targets and preserves
the existing alert intent. OOMKilled remains a legitimate empty result while
no container has recorded that termination reason. Factory/dbt queries retain
their natural No Data behavior for intermittent executions; they do not turn
absence into a false zero.

### Exact upstream dashboard retirement inventory

After reconcile, these upstream dashboard ConfigMaps are expected to disappear
from Grafana provisioning:

- kube-prometheus-stack: `alertmanager-overview`, `apiserver`,
  `cluster-total`, `controller-manager`, `etcd`, `grafana-overview`,
  `k8s-coredns`, `k8s-resources-cluster`, `k8s-resources-multicluster`,
  `k8s-resources-namespace`, `k8s-resources-node`,
  `k8s-resources-nodes-overview`, `k8s-resources-pod`,
  `k8s-resources-workload`, `k8s-resources-workloads-namespace`, `kubelet`,
  `namespace-by-pod`, `namespace-by-workload`, `node-cluster-rsrc-use`,
  `node-rsrc-use`, `nodes`, `nodes-aix`, `nodes-darwin`,
  `persistentvolumesusage`, `pod-total`, `prometheus`, `scheduler`,
  `workload-total`.
- Loki: `bloom-build`, `bloom-gateway`, `chunks`, `deletion`, `logs`,
  `recording-rules`, `operational`, `reads`, `reads-resources`, `retention`,
  `thanos-object-storage`, `writes`, `writes-resources`.

The four former local ConfigMap names are also replaced by curated resources,
but their operational UIDs remain stable: `homeops-operations`,
`homeops-edge-boot-io`, `homeops-logs-efficiency` and
`factory-data-platform-v2`. This is a dashboard-resource replacement, not a
metric, alert or data-retention deletion.

## Rollback

Revert the merged PR #551 commit(s) and let Argo reconcile. The revert restores
the previous four local ConfigMaps, re-enables chart-provided dashboard
ConfigMaps, restores the Loki dashboard chart setting and removes the
blackbox metric relabel addition. No Prometheus scrape, alert, rule, PVC or
application data is deleted by this catalogue refactor; the blackbox change
restores the intended label on an existing probe series and does not change
probe targets or retention.

Before merging, verify the four preserved UIDs and the replacement rendering in
Grafana. After merge, verify `infra-monitoring` is `Synced/Healthy`, the
sidecar reports the seven folders, and the live dashboard count is 11 curated
views plus no AIX/MacOS/Bloom ConfigMaps.
