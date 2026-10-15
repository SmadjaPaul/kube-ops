---
sidebar_position: 4
title: Velero Backup Strategy
description: V1 Velero/Kopia disaster-recovery strategy using Hetzner Object Storage.
---

# Velero Backup Strategy

## V1 decision

Velero remains enabled to preserve the upstream architecture with minimal divergence, but the storage topology is simplified to one offsite backend:

```text
Velero node-agent / Kopia
        |
        +--> https://fsn1.your-objectstorage.com
             bucket: smadja-dev-homelab-backups
             prefix: velero/
```

There is no local MinIO/TrueNAS tier and no Backblaze B2 tier.

## Why Kopia instead of CSI snapshots

Proxmox CSI is used for Kubernetes block storage, but V1 does not grant broad Proxmox snapshot privileges merely for backup. Velero filesystem backup remains storage-class agnostic and streams filesystem data to S3 through Kopia.

This keeps the desired state close to upstream while avoiding:

- a local S3 service that shares the same failure domain;
- Proxmox root-level snapshot credentials;
- duplicate local + offsite backup schedules;
- a second object-storage provider.

## Hetzner contract

```text
location: fsn1
endpoint: https://fsn1.your-objectstorage.com
bucket: smadja-dev-homelab-backups
prefix: velero/
visibility: private
versioning: disabled for V1
object lock: disabled for V1
```

Hetzner documents Falkenstein as `fsn1.your-objectstorage.com`. Upload traffic and S3 API calls are free, so the main cost driver is retained object volume rather than backup frequency.

The runtime credentials are delivered by Doppler through `ClusterSecretStore/doppler-cluster`:

```text
HETZNER_S3_ACCESS_KEY_ID
HETZNER_S3_SECRET_ACCESS_KEY
HETZNER_S3_VELERO_REPOSITORY_PASSWORD
```

The Kopia repository password must remain stable. Rotating it without a migration makes existing repositories unreadable.

## Schedule and cost controls

V1 keeps a single backup tier:

```text
frequency: daily
TTL: 14 days
uploader: Kopia
parallelFilesUpload: 2
secondary weekly B2 tier: none
```

Kopia deduplicates and compresses filesystem content. Daily execution therefore does not imply a full additional copy of every PVC each day.

Schedules for workloads disabled in V1 (for example Frigate, Minecraft and Kubernetes UniFi) are not included in the active schedule root.

CNPG databases are protected separately by Barman Cloud. Velero should not be treated as the PostgreSQL PITR mechanism.

## Runtime verification

```bash
kubectl -n velero get backupstoragelocation
kubectl -n velero get schedules
velero backup get
```

The default BackupStorageLocation must be `Available`.

Create a bounded smoke backup:

```bash
velero backup create v1-smoke \
  --include-namespaces <small-test-namespace> \
  --default-volumes-to-fs-backup \
  --wait
```

Then restore into an isolated namespace and verify file integrity.

## Cost review

After the first two weeks, record:

- bucket bytes retained by the `velero/` prefix;
- daily changed bytes;
- restore-test egress;
- backup duration.

If retained size is higher than expected, first exclude reproducible/cache/download data before reducing protection for unique user data.

## References

- Velero File System Backup / Kopia documentation
- Velero AWS plugin for S3-compatible providers
- Hetzner Object Storage S3 documentation
