---
title: Longhorn fast/bulk restore qualification
sidebar_position: 11
---

# Longhorn fast/bulk restore qualification

This is a human-gated, same-cluster Velero/Kopia drill. It validates the two
V1 storage tiers with synthetic data and an isolated namespace. It does not
touch production PVCs, PVs, namespaces, Secrets, Routes, or applications.

The drill is intentionally not an Argo resource. Do not add the synthetic
namespace, PVCs, Pod, Backup, or Restore objects to GitOps. Run it only after
an operator has approved the temporary resources and a cleanup window.

## Preconditions

```bash
just kube-access-check
kubectl get storageclass longhorn-fast longhorn-bulk
kubectl -n velero get backupstoragelocation default
kubectl -n velero get deploy/velero
```

Stop if either StorageClass is absent, the backup location is not `Available`,
Velero is not Ready, or another restore is in progress. Do not use a
`PartiallyFailed` or `Failed` backup as the source of this qualification.

The current `restore-pvc-isolation` resource modifier removes only the stale
`spec.volumeName` from PVCs in the synthetic source namespace. It does not
rewrite `spec.storageClassName`; this is the property being qualified.

## 1. Create synthetic source data

Use a fresh namespace and keep the payload small. The commands below create
two PVCs and one pod, with no Service or network route:

```bash
SRC_NS=longhorn-tier-dr-source
DRILL_NS=longhorn-tier-dr-$(date -u +%Y%m%d%H%M%S)
BACKUP_NAME=longhorn-tier-dr-backup-$(date -u +%Y%m%d%H%M%S)
RESTORE_NAME=longhorn-tier-dr-restore-$(date -u +%Y%m%d%H%M%S)

kubectl create namespace "$SRC_NS"
kubectl apply -n "$SRC_NS" -f - <<'YAML'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: fast-data
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: longhorn-fast
  resources:
    requests:
      storage: 256Mi
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: bulk-data
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: longhorn-bulk
  resources:
    requests:
      storage: 256Mi
---
apiVersion: v1
kind: Pod
metadata:
  name: tier-writer
spec:
  restartPolicy: Never
  containers:
    - name: writer
      image: busybox:1.36
      command: ["sh", "-c", "sleep 86400"]
      volumeMounts:
        - name: fast
          mountPath: /fast
        - name: bulk
          mountPath: /bulk
  volumes:
    - name: fast
      persistentVolumeClaim:
        claimName: fast-data
    - name: bulk
      persistentVolumeClaim:
        claimName: bulk-data
YAML

kubectl -n "$SRC_NS" wait --for=condition=Ready pod/tier-writer --timeout=5m
kubectl -n "$SRC_NS" exec tier-writer -- sh -c \
  'printf "longhorn-fast:%s\\n" "$(date -u +%FT%TZ)" >/fast/SENTINEL && sha256sum /fast/SENTINEL >/fast/SHA256SUM && cp /fast/SENTINEL /bulk/SENTINEL && sha256sum /bulk/SENTINEL >/bulk/SHA256SUM && sha256sum -c /fast/SHA256SUM && sha256sum -c /bulk/SHA256SUM'
```

Record the source PVC classes and the two checksum files before creating the
backup. Stop if either PVC is not `Bound` or either checksum does not verify.

## 2. Back up and restore into a fresh namespace

```bash
velero backup create "$BACKUP_NAME" \
  --include-namespaces "$SRC_NS" \
  --default-volumes-to-fs-backup=true \
  --wait

kubectl -n velero get podvolumebackups \
  -l "velero.io/backup-name=$BACKUP_NAME" -o json | jq -e '
    (.items | length == 2) and
    (all(.items[]; .status.phase == "Completed")) and
    ([.items[].spec.volume] | sort == ["bulk", "fast"])
  '

kubectl create namespace "$DRILL_NS"
velero restore create "$RESTORE_NAME" \
  --from-backup "$BACKUP_NAME" \
  --namespace-mappings "$SRC_NS:$DRILL_NS" \
  --include-cluster-resources=false \
  --restore-volumes=true \
  --resource-modifier-configmap restore-pvc-isolation \
  --exclude-resources "persistentvolumes,secrets,externalsecrets.external-secrets.io,services,httproutes.gateway.networking.k8s.io" \
  --wait
```

`Completed` on the Restore is not sufficient. Require exactly two completed
PodVolumeRestores, two Bound target PVCs, and fresh PVs whose claim namespace
is `$DRILL_NS`:

```bash
kubectl -n velero get podvolumerestores -o json |
  jq -e --arg restore "$RESTORE_NAME" --arg ns "$DRILL_NS" '
    [.items[] | select(.metadata.labels["velero.io/restore-name"] == $restore)]
    | length == 2 and
      all(.[]; .status.phase == "Completed" and .spec.pod.namespace == $ns)
  '

kubectl -n "$DRILL_NS" get pvc -o json | jq -e '
  (.items | length == 2) and
  (all(.[]; .status.phase == "Bound")) and
  (any(.[]; .metadata.name == "fast-data" and .spec.storageClassName == "longhorn-fast")) and
  (any(.[]; .metadata.name == "bulk-data" and .spec.storageClassName == "longhorn-bulk"))
'
```

## 3. Verify data integrity and tier identity

The restored pod must verify both sentinel checksums without connecting to a
production service:

```bash
kubectl -n "$DRILL_NS" wait --for=condition=Ready pod/tier-writer --timeout=5m
kubectl -n "$DRILL_NS" exec tier-writer -- sh -c \
  'sha256sum -c /fast/SHA256SUM && sha256sum -c /bulk/SHA256SUM'

kubectl -n "$DRILL_NS" get pvc fast-data bulk-data -o wide
kubectl get pv \
  "$(kubectl -n "$DRILL_NS" get pvc fast-data -o jsonpath='{.spec.volumeName}')" \
  "$(kubectl -n "$DRILL_NS" get pvc bulk-data -o jsonpath='{.spec.volumeName}')" \
  -o json | jq -e --arg ns "$DRILL_NS" '
    all(.items[]; .status.phase == "Bound" and .spec.claimRef.namespace == $ns)
  '
```

Acceptance is `PASS` only when the Backup and both PodVolumeBackups (PVBs) are
`Completed`, the Restore and both PodVolumeRestores (PVRs) are `Completed`, both target PVCs are `Bound` on their
original classes, both fresh PVs claim the drill namespace, and both checksum
commands exit zero. Record start/end timestamps for the observable RTO. The
last successful backup timestamp is the observable RPO; it is not a guarantee
of zero data loss.

## 4. Cleanup after recording evidence

Cleanup is a separate, human-approved action. Preserve the Backup, Restore,
PVB/PVR status and checksum output in the drill record before cleanup. Never
delete or alter a production namespace, PVC, PV, Secret, backup, or Longhorn
volume as part of this procedure.

```bash
# Only after the operator has approved cleanup of these named synthetic objects:
kubectl delete namespace "$DRILL_NS" "$SRC_NS"
velero backup delete "$BACKUP_NAME" --confirm
velero restore delete "$RESTORE_NAME" --confirm
```

## Interpretation

- A failed PVB or PVR is a backup/restore failure, even if the Restore phase is
  `Completed`.
- A checksum success with the wrong class is a tier-preservation failure.
- A PVC that remains Pending is a capacity, scheduler, or Longhorn failure.
- A successful drill qualifies backup recovery for these synthetic volumes;
  it does not qualify application-level recovery or authorize Proxmox CSI
  decommissioning.
