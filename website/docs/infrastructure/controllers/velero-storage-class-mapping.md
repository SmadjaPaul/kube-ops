---
title: Velero storage tier preservation
sidebar_position: 6
---

# Preserve Longhorn storage tiers on restore (V1)

**Current contract (2026-10-10):** `longhorn-fast` is NVMe and
`longhorn-bulk` is HDD. The prior cluster-wide mapping of both to
`proxmox-csi` was inherited from an obsolete Longhorn-to-Proxmox
migration and has been removed from desired state. There is **no default
StorageClass**; workloads must select their tier explicitly.

Velero/Kopia restores must preserve the PVC's original class unless an
explicit, restore-specific and reviewed migration is necessary.
A new restore into the same cluster must **not** reuse a PV already bound
to the production PVC. Exclude production PersistentVolumes, clear the
restored PVC's `spec.volumeName` with a restore modifier, and verify
that new PVCs bind to **fresh** Longhorn volumes on the same tier.
Successful Velero resource restore does not prove successful Kopia data
restore. Verify the PodVolumeRestore objects and restored bytes.

See `k8s/applications/business/invoice-ninja/RESTORE.md` for the
isolated restore runbook. Do not run that procedure against production.

## Historical backups

Backups that reference legacy `longhorn` or `proxmox-csi` require an
operator-reviewed, backup-specific mapping. Never blindly assume which
physical tier an old class should use. Confirm original workload intent,
backup contents, capacity, ownership and rollback first.

## Proxmox CSI retirement remains separate

The CSI driver is still declared as a compatibility component in
`k8s/infrastructure/storage`. Removing a legacy mapping **does not
authorize removing the CSI controller or StorageClass**.

Before a separate decommission PR, collect read-only live evidence:

```sh
just kube-access-check
just backup-audit
kubectl get pv -o json | jq '[.items[] | select(
  (.spec.storageClassName // "") == "proxmox-csi" or
  ((.spec.csi.driver // "") | contains("proxmox"))
) | {name:.metadata.name, phase:.status.phase,
     claim:.spec.claimRef, class:.spec.storageClassName}]'
kubectl get pvc -A -o wide
kubectl get volumeattachments.storage.k8s.io -o wide
kubectl get storageclass
kubectl -n velero get cm -l velero.io/change-storage-class=RestoreItemAction
```

Also inspect active restore jobs, Argo ownership and Proxmox ZVOL/PV
dependencies. Keep **all PVs/PVCs, ZVOLs and Secrets unchanged** until
an approved removal plan and a successful isolated restore test covering
both Longhorn classes are available. Mark decommission blocked when
live dependency proof is absent. After the mapping cleanup reconciles,
verify the old `change-storage-class-config` ConfigMap has been pruned
and no similarly labelled mapping is active.
