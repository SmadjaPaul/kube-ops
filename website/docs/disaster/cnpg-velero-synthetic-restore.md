---
title: CNPG and Velero/Kopia synthetic restore qualification
sidebar_position: 12
---

# CNPG and Velero/Kopia synthetic restore qualification

This is an **unexecuted, human-gated** design for PLT-51. It proves two
different recovery paths in isolated namespaces: a CloudNativePG recovery from
the Barman object store and a Velero/Kopia filesystem restore of a small
synthetic PVC. It must not restore into a production namespace, production PVC,
production CNPG cluster or existing application database.

The checked-in plan is the offline fixture
`tests/fixtures/recovery/cnpg-velero-restore.yaml` plus the recovery
qualification contract. The fixture is descriptive only; it is not an Argo or
Kubernetes resource.

## Approval and isolation gates

The operator must approve a bounded window, fresh namespace names, the exact
backup identifiers and cleanup set before any temporary object is created. The
window must include a second operator able to stop the drill. Atlantis is not a
runtime dependency: the recovery package must be available from Git, the
canonical operator-access path in `homelab-infra`, and the off-cluster backup
services.

Stop before creating anything if the selected CNPG backup is not successful,
WAL continuity is unknown, the selected Velero backup is not `Completed`,
PodVolumeBackups are incomplete, or a target namespace/PVC name overlaps a
production resource. Do not use `PartiallyFailed`, `Failed` or `InProgress`
backups as sources.

## Synthetic data contract

The drill writes one small, unique sentinel in a temporary CNPG database and
one small checksum-bearing file in a temporary Longhorn PVC. The sentinel
contains a UTC timestamp, a random drill identifier and a deterministic
checksum. The original value, checksum and source backup timestamps are
recorded before recovery. No real application secret, route, DNS record or
external ingress is needed.

## CNPG recovery leg

| Gate | Evidence required |
|---|---|
| Source selection | Latest successful base backup and recoverable WAL point are recorded from CNPG metadata; secret values are never read |
| Target | Fresh temporary namespace, fresh CNPG cluster name and a newly provisioned PVC; no production PVC or PV is referenced |
| Recovery | The target uses the documented CNPG `bootstrap.recovery` / `externalClusters` path for the existing Barman object store |
| Cluster acceptance | CNPG reports `Ready=True`; the target accepts SQL connections locally; no public Service or HTTPRoute exists |
| Data acceptance | Sentinel row, row count and checksum match the recorded source value |
| Stop condition | Any WAL gap, unexpected source object, reused PVC, or checksum mismatch stops the drill |

The exact temporary manifest is generated only after approval because it
contains environment-specific object-store references. It is not committed as
desired state and it must not contain a secret value.

## Velero/Kopia filesystem leg

The existing [Longhorn fast/bulk qualification](./longhorn-tier-restore-qualification.md)
defines the synthetic source PVCs, checksum verification, PV claim checks and
the `restore-pvc-isolation` modifier. Reuse that contract with a fresh source
and target namespace. Require exactly the expected PodVolumeBackups and
PodVolumeRestores, fresh target PVs claimed by the drill namespace, preserved
`longhorn-fast`/`longhorn-bulk` classes and a successful checksum. A successful
Restore phase alone is insufficient.

The application-level restore procedure remains separate: an Invoice Ninja
restore must follow the isolated procedure in
`k8s/applications/business/invoice-ninja/RESTORE.md` and must not be substituted
by this storage-only proof.

## RPO and RTO measurement

Record monotonic UTC timestamps for `T0` (sentinel commit), `T1` (selected
backup/WAL recovery point), `T2` (restore request accepted), `T3` (target
ready), and `T4` (SQL and filesystem acceptance complete).

| Metric | Calculation | Interpretation |
|---|---|---|
| CNPG RPO | `T0 - T1` using the last recoverable WAL/source point | Potential data loss for the synthetic database |
| Velero/Kopia RPO | `T0 - T1` using the selected backup completion time | Potential data loss for the synthetic file |
| CNPG RTO | `T4 - T2` for SQL acceptance | End-to-end database recovery duration |
| Velero/Kopia RTO | `T4 - T2` for PVC/checksum acceptance | End-to-end filesystem recovery duration |

The thresholds are deliberately **proposed, not approved**. The first drill
must measure actual RPO/RTO before SLOs are declared. The report must preserve
source identifiers, timestamps, object counts, checksum results and failure
reasons without including credentials or secret data.

## Cleanup and result

Capture the Backup, Restore, PVB/PVR, CNPG status and checksum evidence before
cleanup. Cleanup is a separate operator-approved action naming the exact
temporary namespace, cluster, PVC, PV and backup objects. No cleanup command is
part of this documentation change.

`PASS` means both legs met their object-count, readiness, ownership, checksum
and timestamp gates. It does not prove a full-cluster recovery, a Proxmox/Talos
substrate rebuild or an application user journey. Until the drill is executed,
`RESTORE_PROOF` remains `NOT_PROVEN`.
