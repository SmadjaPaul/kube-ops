# Proxmox host NVMe endurance: alerts and runbook (PLT-216)

The Proxmox host stores the Talos VM disks on one consumer NVMe SSD (Crucial
P310 1 TB, model CT1000P310SSD8, QLC, no DRAM, rated **220 TBW** and five years;
source: Tom's Hardware P310 review specification table). The SMART health is
exported by the `proxmox_node_exporter` role of homelab-infra
(`proxmox_node_exporter_enable_nvme_health`) as `nvme_*` metrics in the
`proxmox-host` job. Until that role is converged on the host, only the
`NvmeWriteRateAboveBudget` alert has data and `NvmeHealthTelemetryMissing` is
expected to fire (info): the absence of NVMe alerts is not a sign of health.

## Alerts (rules in `k8s/infrastructure/monitoring/prometheus-stack/nvme-endurance-rules.yaml`)

| Severity | Alert | Meaning |
|---|---|---|
| critical | `NvmeCriticalWarning` | the controller raised a critical warning bit |
| critical | `NvmeSpareBelowThreshold` | available spare at or below the drive's threshold |
| critical | `NvmeWearCritical` | `percentage_used` >= 90 % |
| warning | `NvmeWearHigh` | `percentage_used` >= 50 % |
| warning | `NvmeMediaErrors` | new media and data-integrity errors in 24 h |
| warning | `NvmeTemperatureHigh` | drive above 70 C for 15 min |
| info | `NvmeWriteRateAboveBudget` | host NVMe writes above 0.5 TB/day (5.8 MB/s) over 24 h |
| info | `NvmeWearProjectionUnder90Days` | linear projection of `percentage_used` reaches 100 % within 90 days |
| info | `NvmeUnsafeShutdown` | unsafe shutdown counter increased in 24 h |
| info | `NvmeHealthTelemetryMissing` | no fresh `nvme.prom` file from the host |

Alert delivery is not yet active (see `homeops-observability-alerting.md`): treat
these rules as visible in Grafana and Alertmanager only.

## Reading the numbers

- `nvme_data_units_written_total`: one unit is 512 000 bytes; the TBW rating
  counts host writes, so it is the right numerator. Daily volume:
  `increase(nvme_data_units_written_total[1d]) * 512000`.
- `percentage_used` is the drive's own estimate and may reach 100 % before or
  after the TBW figure; it is the authoritative wear signal. The TBW is a
  warranty limit, not a failure date.
- Without the SMART export, `node_disk_written_bytes_total{job="proxmox-host",device="nvme0n1"}`
  is a close proxy for the host writes since the exporter started.
- 220 TBW over five years is about 0.12 TB/day (1.4 MB/s). The 2026-11-12 baseline
  (PLT-211) was 1.3 to 1.9 TB/day.

## First steps

1. Read the drive on the host: `nvme smart-log /dev/nvme0n1` (percentage_used,
   available_spare, media_errors, unsafe_shutdowns, temperature, data units).
2. `zpool status -v nvme`: a nonzero `CKSUM` count is not proof of a failing SSD (memory, cabling or controller faults give the same symptom); investigate corruption, correlate with the NVMe error log and media errors, and scrub.
3. Confirm the latest backups (Velero, CNPG) before any replacement.
4. Reduce the writers first (runners, containerd, logs: PLT-214, PLT-216 ZFS
   `logbias` study in homelab-infra `docs/operations/zvol-logbias-validation.md`).
5. Replacement is a physical operation that needs Paul.
