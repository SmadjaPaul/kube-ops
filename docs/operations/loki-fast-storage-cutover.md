# Loki: disposable move from HDD bulk to NVMe fast

Status: **staged; not applied**. The operator explicitly accepts loss of **Loki log history only**.
This runbook and the accompanying change in `k8s/infrastructure/monitoring/loki/values.yaml`
must **not** be merged into an automatically reconciling Argo CD application
before a coordinated StatefulSet/PVC cutover is ready.

## Why

Loki is a single-binary filesystem-backed deployment. Its current persistent
volume is provisioned on `longhorn-bulk`, a HDD-backed tier. The new requested
StorageClass is `longhorn-fast`. This reduces one known source of routine
HDD writes; it **does not** prove that physical drives can enter standby.
The previous read-only measurements attributed roughly 34 KiB/s to Loki through
an indirect metric and about 90.6 KiB/s ZFS logical writes to the VM101 bulk
virtual disk. These numbers measure different layers and must not be added.

## Mandatory preflight (read-only)

1. Identify the **live** Helm release, generated StatefulSet name,
   `volumeClaimTemplates[].metadata.name`, pod, PVC, bound PV, Longhorn
   volume name, PV reclaim policy, and Argo CD application owning them.
   Capture the UID and other stable identifiers; do not infer names from docs.
2. Verify Loki currently ingests and queries logs, and record its effective
   7-day retention; do not change that working policy as part of migration.
3. Inspect Longhorn fast **physical free capacity**, **schedulable** capacity,
   `storageOverProvisioningPercentage`, existing scheduled replicas and
   snapshots. Keep replica count at one.
4. Inspect the rendered chart version `grafana-community/loki` `18.13.7`
   with the changed values. Verify no other workloads or PVCs change.
5. Review Helm/Argo CD prune, finalizer, StatefulSet orphan/adoption, and
   Retain reclaim behavior. Ensure an Argo auto-sync cannot race the
   PVC/StatefulSet replacement. Plan a maintenance window.
6. Confirm the old Loki volume identity **twice**, from PV/PVC ownership and
   Longhorn labels/attachments. Abort on ambiguity.

## Cutover procedure (operator-controlled, log loss approved)

1. Stop Loki writer(s) and pause only the relevant Argo CD reconciliation
   during maintenance; record how to re-enable it. Brief ingestion loss is accepted.
2. Remove the existing **Loki StatefulSet** through a version-appropriate,
   controlled sequence (or orphan it if required by the chart), avoiding
   uncontrolled recreation of its immutable volumeClaimTemplate.
3. Delete **only** the verified Loki PVC, subject to its Retain policy.
   Confirm the associated PV/Longhorn volume is detached and preserved
   until the new Loki instance passes acceptance. Never target a PVC by
   wildcard or delete all PVCs in a namespace.
4. Apply the GitOps desired state with `storageClass: longhorn-fast`.
   Let the chart/StatefulSet create a brand-new PVC. Verify its bound PV is
   actually scheduled to the Longhorn `fast` disk tag, not merely named fast.
5. Resume the approved Argo reconciliation. Prove Loki and gateway Ready,
   Alloy log delivery, a fresh uniquely identified log line searchable in Loki,
   and existing Grafana log dashboards querying correctly.
6. Confirm the new fast PV and old bulk PV have **different identities**.
   Only after the new service is healthy, explicitly remove the detached
   original **Loki-owned** PV/Longhorn volume with the correct reclaim
   procedure. Verify no other PV references that volume and bulk capacity
   is returned. `Retain` means deletion of a PVC alone may leave storage behind.
7. Compare matched-window *physical* Proxmox HDD I/O before/after.
   Lower I/O is evidence, **not proof** of drive motor standby.

## Rollback

Before deleting the old Longhorn volume: stop the new Loki and its Argo
reconciliation, restore the original `longhorn-bulk` values, perform a
controlled StatefulSet/PVC replacement that rebinds the retained original
Longhorn volume by its verified identity, then validate gateway and queries.

After the old volume is deleted, rollback means **fresh empty Loki on bulk**;
the historical logs cannot be restored. Keep this distinction explicit.

## Hard boundaries

- Do not delete or mutate other PVCs, CNPG, Paperclip, Prometheus, Tempo,
  Proxmox disks, or Longhorn settings.
- Do not change physical disk power controls or poll SMART to force diagnosis.
- No new services, external cost, or GitHub runner.
- Do not claim success from a Git-only PR or Argo Synced state alone.
- On missing live access or unclear identity, stop before any destructive step.

## Final evidence

```text
LOKI_OLD_PVC_UID=
LOKI_OLD_PV=
LOKI_OLD_LONGHORN_VOLUME=
LOKI_NEW_PVC_UID=
LOKI_NEW_PV=
LOKI_NEW_STORAGECLASS=longhorn-fast
LOKI_NEW_DISK_TAG=fast
LOKI_READY=
ALLOY_TO_LOKI=
GRAFANA_LOG_QUERY=
LOKI_RETENTION_7D=
OLD_BULK_VOLUME_REMOVED=
HDD_WRITES_BEFORE=
HDD_WRITES_AFTER=
ARGO_SYNC=
OTHER_DATA_CHANGED=NO
```
