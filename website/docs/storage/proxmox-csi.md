# Proxmox CSI — compatibility / staged

:::warning V1 storage role
Proxmox CSI is **compatibility/staged only** on the Smadja V1 platform. The V1 application storage plane is Longhorn with `longhorn-fast` and `longhorn-bulk` (see `../../AGENTS.md` and `../../../k8s/infrastructure/storage/`). Do not make `proxmox-csi` the default storage class for new V1 workloads.
:::

This guide documents the Proxmox CSI plugin integration that remains available for legacy PVCs and for the post-V1 multi-node topology. It is not a description of the active V1 default storage path.

## Overview

The cluster exposes the [Proxmox CSI Plugin](https://github.com/sergelogvinov/proxmox-csi-plugin) (`csi.proxmox.sinextra.dev`) alongside Longhorn for compatibility with existing PVCs and for use as a non-default provisioner. Volumes are created on the Proxmox `tank-vm` ZFS datastore.

**Current Storage Classes:**
- `longhorn-fast` — V1 latency-sensitive storage (Longhorn, single replica)
- `longhorn-bulk` — V1 capacity-oriented storage (Longhorn, single replica)
- `proxmox-csi` — Compatibility/staged provisioner; not the V1 default
- `longhorn` — Disabled upstream class; not created by the Longhorn Helm values

For day-to-day application PVCs in V1, use `longhorn-fast` or `longhorn-bulk`. Use `proxmox-csi` only for existing PVCs that have not yet been migrated.

## How Dynamic Provisioning Works

The Proxmox CSI plugin provides **fully automatic storage provisioning**. You don't need to pre-create volumes, manually attach disks, or configure storage backends. Just create a PVC and the CSI plugin handles everything.

### The Process (Completely Automatic)

1. **You create a PVC:**
   ```yaml
   apiVersion: v1
   kind: PersistentVolumeClaim
   metadata:
     name: my-app-data
   spec:
     storageClassName: proxmox-csi  # References the StorageClass
     resources:
       requests:
         storage: 10Gi
   ```

2. **CSI Controller sees the PVC and automatically:**
   - Calls Proxmox API to create a new virtual disk: `vm-XXXX-pvc-<uuid>`
   - Attaches the disk to the appropriate Proxmox node
   - Formats the disk with ext4 (or specified filesystem)
   - Creates a PersistentVolume (PV) in Kubernetes
   - Binds the PVC to the PV

3. **Done!** Your pod can now mount the volume. The entire process is automatic - no manual intervention needed.

### Key Benefits

- **Zero manual steps**: No need to SSH into Proxmox or run `pvesm` commands
- **Automatic placement**: Volumes are created on the same node where the pod is scheduled (WaitForFirstConsumer)
- **Direct ZFS access**: Volumes are ZFS datasets on Nvme1, providing high performance
- **Volume expansion**: Resize PVCs dynamically without recreating them
- **Clean lifecycle**: When you delete a PVC, the volume is retained (Retain policy) for data safety

## Why Not Pre-Provision Volumes?

Unlike older storage systems, **you should never pre-create volumes manually**. The CSI plugin is designed for dynamic provisioning - it creates volumes on-demand as applications request them.

The `bootstrap/volumes` Terraform module exists only for migrating pre-existing Proxmox volumes into Kubernetes, not for creating new storage.

## Bootstrap Configuration

The Proxmox CSI bootstrap is owned by `homelab-infra`. `kube-ops` must not contain a `tofu/` tree; the runtime token reaches Kubernetes via ESO from the `cluster/prd` Doppler store. The chart values rendered by kube-ops live at [`k8s/infrastructure/storage/proxmox-csi/`](../../../k8s/infrastructure/storage/proxmox-csi/).

### Proxmox CSI Plugin Setup

`homelab-infra` is the sole owner of the Proxmox user, role and API token. It configures:

1. **Proxmox User & Role**: Creates a `kubernetes-csi@pve` user with minimal CSI permissions
2. **API Token**: Generates a secure API token with `privileges_separation = true`
3. **Kubernetes Resources**:
   - Creates `csi-proxmox` namespace with PodSecurity privileged labels
   - Stores Proxmox credentials in a Kubernetes secret

**Command to deploy:**

```bash
cd tofu
tofu apply
```

**Terraform Module Reference:**

```hcl
# From tofu/bootstrap.tf
module "proxmox-csi-plugin" {
  source = "./bootstrap/proxmox-csi-plugin"

  proxmox = {
    cluster_name = var.proxmox_cluster
    endpoint     = var.proxmox.endpoint
    insecure     = var.proxmox.insecure
  }
}
```

### Security Configuration

The CSI plugin uses a **least-privilege security model**:

| Setting | Value | Purpose |
|---------|-------|---------|
| Role Privileges | `Sys.Audit`, `VM.Audit`, `VM.Config.Disk`, `Datastore.*` | Minimal required for CSI operations |
| Token | `privileges_separation = false` | Token inherits full user privileges, enabling storage/volume access |
| Namespace | `pod-security.kubernetes.io/enforce: privileged` | Required for CSI node plugins |

**Why `privileges_separation = false`?**

- Token needs full access to Proxmox resources (storage allocation, VM disk operations)
- With `privileges_separation = true`, the token is restricted to CSI role only, causing "not authorized" errors
- Full user privileges are required for the CSI plugin to manage volumes across nodes

## Using Storage in Applications

### Dynamic Provisioning Example

Most applications should use dynamic provisioning:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-data
  namespace: default
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: proxmox-csi
  resources:
    requests:
      storage: 20Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres
spec:
  template:
    spec:
      containers:
      - name: postgres
        image: postgres:15
        volumeMounts:
        - name: data
          mountPath: /var/lib/postgresql/data
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: postgres-data
```

### That's It!

Notice what you **didn't** have to do:
- No manual volume creation in Proxmox
- No SSH into Proxmox nodes
- No `pvesm alloc` commands
- No manual PV creation
- No volume attachment configuration

The CSI plugin handles all of this automatically when you create the PVC. This is the power of dynamic provisioning!

## StorageClass Configuration

The Proxmox CSI plugin typically provides a default StorageClass. You can create additional StorageClasses for different storage backends or performance tiers:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: proxmox-ssd
provisioner: csi.proxmox.sinextra.dev
parameters:
  storage: local-zfs
  cache: writethrough
  ssd: "true"
reclaimPolicy: Delete
volumeBindingMode: Immediate
allowVolumeExpansion: true
```

## Volume Binding Mode

The `proxmox-csi` StorageClass uses `volumeBindingMode: WaitForFirstConsumer` so the volume is provisioned on the same node that schedules the consuming pod. This matches the value rendered by [`k8s/infrastructure/storage/proxmox-csi/values.yaml`](../../../k8s/infrastructure/storage/proxmox-csi/values.yaml) and is enforced by `scripts/check-v1-active-contract.sh`.

Longhorn uses its own StorageClasses (`longhorn-fast`, `longhorn-bulk`); their binding mode is governed by Longhorn itself, not by this chart.

## Volume Management

### Listing Volumes

View all persistent volumes:

```bash
kubectl get pv
kubectl get pvc -A
```

### Expanding Volumes

If the StorageClass allows expansion (`allowVolumeExpansion: true`), you can resize volumes:

```bash
kubectl patch pvc my-app-data -p '{"spec":{"resources":{"requests":{"storage":"20Gi"}}}}'
```

### Deleting Volumes

The reclaim policy determines what happens when a PVC is deleted:
- `Delete`: Volume is automatically deleted from Proxmox
- `Retain`: Volume is kept in Proxmox for manual recovery

```bash
kubectl delete pvc my-app-data
```

## Access Mode Limitations

### ReadWriteMany (RWX) Not Supported

Proxmox CSI **only supports ReadWriteOnce (RWO)** access mode. The plugin does not support ReadWriteMany (RWX) or ReadOnlyMany (ROX) access modes.

**Why RWX doesn't work:**
- Proxmox CSI creates dedicated virtual disks on ZFS datastores
- Each disk can only be attached to one VM/node at a time
- There is no shared filesystem backend (like NFS or CephFS) to support multi-node access

**If your application requires RWX:**
1. **Verify actual need**: Many applications claim RWX but work fine with RWO when pods are scheduled on the same node
2. **Use RWO with pod scheduling**: Deploy pods using `podAntiAffinity` rules to ensure all pods requiring shared storage run on the same node
3. **Re-evaluate the topology**: Cross-node shared storage is a post-V1 concern; do not reintroduce NFS or a parallel NAS path on V1.

**Longhorn is the V1 storage plane** (see `../../AGENTS.md`). Proxmox CSI remains available for existing PVCs only; do not migrate Longhorn PVCs to Proxmox CSI as part of V1 work.

## Troubleshooting

### Access Mode Limitations

Proxmox CSI **only supports ReadWriteOnce (RWO)** access mode. See the [Access Mode Limitations](#access-mode-limitations) section for details.

### CSI Plugin Not Provisioning Volumes

1. Check the CSI plugin is running:
   ```bash
   kubectl get pods -n csi-proxmox
   ```

2. Check CSI controller logs:
   ```bash
   kubectl logs -n csi-proxmox -l app=proxmox-csi-controller
   ```

3. Verify the Proxmox credentials secret:
   ```bash
   kubectl get secret -n csi-proxmox proxmox-csi-plugin -o yaml
   ```

### Volume Stuck in Pending

Check PVC events:
```bash
kubectl describe pvc <pvc-name>
```

Common issues:
- Insufficient storage on Proxmox datastore
- Network connectivity between Kubernetes and Proxmox
- Invalid storage backend name
- CSI plugin not running

### Permission Errors

Verify the CSI user has correct permissions in Proxmox:
```bash
pveum user list | grep kubernetes-csi
pveum acl list | grep kubernetes-csi
```

## References

- [Proxmox CSI Plugin Documentation](https://github.com/sergelogvinov/proxmox-csi-plugin)
- [Kubernetes CSI Documentation](https://kubernetes-csi.github.io/docs/)
- [Proxmox Storage Documentation](https://pve.proxmox.com/wiki/Storage)
