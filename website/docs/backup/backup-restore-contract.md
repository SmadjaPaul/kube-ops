# Backup, Restore, and Disaster Recovery Contract

Status: canonical V1 contract.

## Principles

- Git + Argo CD reconstruct Kubernetes desired state.
- Doppler is the recovery authority for runtime credentials required by Kubernetes.
- OCI Object Storage remains the OpenTofu state backend and is not used for application backups.
- Hetzner Object Storage stores CloudNativePG/Barman backups and Velero Kubernetes-resource backups.
- Hetzner Storage Box stores selected non-database PVC backups through VolSync + Restic.
- Longhorn is runtime storage only. Longhorn replicas and local snapshots are not offsite backups.
- A backup mechanism is not considered proven until a non-destructive restore has passed.

## Ownership

| Data | Backup owner | Backend | V1 policy |
| --- | --- | --- | --- |
| PostgreSQL | CloudNativePG + Barman Cloud plugin | Hetzner Object Storage | continuous WAL + daily base backup, 30-day recovery window |
| Kubernetes API resources not trivially reconstructed | Velero | Hetzner Object Storage | daily, 14-day TTL, resource-only |
| Selected user-generated PVC data | VolSync Restic | Hetzner Storage Box | daily, 7 daily + 4 weekly + 3 monthly |
| Caches, downloads, derived indexes | none | none | rebuild |
| Git/Doppler/OCI state | external authorities | provider-native | must be reachable without the lost Kubernetes cluster |

Velero MUST NOT be used as a second bulk-PVC backup system. CNPG volumes MUST NOT be protected by generic filesystem backup jobs.

## Service levels

| Tier | Data | RPO | RTO target | Retention | Restore exercise |
| --- | --- | --- | --- | --- | --- |
| 0 | Git, recovery credentials, OpenTofu state | on change / provider durability | 2-4 h to bootstrap platform | provider/version history | quarterly DR bootstrap |
| 1 | PostgreSQL | <= 5 min target from WAL archive | 1-2 h per current small DB | 30-day recovery window | monthly mechanism smoke; each DB at least quarterly |
| 2 | user-generated PVC data | 24 h | <4 h for small volumes; up to 24-72 h for TB-class volumes | 7 daily + 4 weekly + 3 monthly | monthly rotating restore; each protected PVC at least quarterly |
| 3 | reconstructible/cache/download data | no backup | rebuild time | none | redeploy/rebuild only |

RTO for TB-class data is dominated by the recovery link throughput and is a planning target, not a storage-provider guarantee.

## Restore acceptance

A backup path is PASS only when all of the following are true:

1. the backup completed successfully;
2. the repository/object is readable without the original application pod;
3. restore creates a new temporary cluster, namespace, or PVC without modifying production;
4. an application-level integrity probe succeeds;
5. restored content is deleted after verification;
6. backup age remains within the declared RPO.

### CNPG smoke

1. trigger or select a completed Barman backup;
2. bootstrap a temporary CNPG Cluster from the ObjectStore;
3. run a SQL probe against the temporary database;
4. delete the temporary Cluster and PVCs.

Use the Barman plugin for both backup and recovery. Do not restore over the production Cluster.

### Velero smoke

1. back up a disposable namespace with resource-only policy;
2. set the BackupStorageLocation to ReadOnly during the DR restore exercise;
3. restore into a disposable/renamed namespace where practical;
4. validate expected resource kinds and a simple application probe;
5. delete the restored namespace and return the BackupStorageLocation to ReadWrite.

Velero is an insurance copy for Kubernetes resource state. Argo/Git remains the preferred reconstruction path.

### VolSync smoke

1. run a ReplicationSource backup from a protected PVC;
2. restore the latest Restic snapshot through a temporary ReplicationDestination into a new PVC;
3. compare a deterministic checksum/sample set with the source;
4. delete the temporary destination PVC.

## Disaster recovery: AOOSTAR lost

1. From an admin workstation, verify access to GitHub, Doppler, OCI OpenTofu state, Hetzner Object Storage, and Hetzner Storage Box.
2. Recreate Proxmox/Talos prerequisites from homelab-infra.
3. Bootstrap Talos/Kubernetes.
4. Bootstrap Argo CD from kube-ops.
5. Let Argo recreate networking, storage, External Secrets, CNPG/Barman, Velero, VolSync, and monitoring.
6. Let ESO recreate Kubernetes credentials from Doppler.
7. Restore PostgreSQL clusters from their Barman ObjectStores.
8. Restore selected user PVCs from Storage Box into newly created Longhorn PVCs.
9. Start dependent applications and run application probes.
10. Use Velero selectively only for resource state that Git/operators do not reconstruct.
11. Re-enable backup schedules only after production integrity checks pass.

## Circular-dependency rules

The following MUST exist outside Kubernetes:

- Git repositories and access path needed for bootstrap;
- Doppler recovery access;
- OCI OpenTofu backend access;
- Hetzner S3 credentials;
- Storage Box SSH private key, Restic password, endpoint/user, and pinned SSH host key;
- the operator procedure for bootstrapping Argo CD.

No only-copy-of-a-recovery-secret may live inside the cluster being protected.

## S3 policy

Canonical prefixes:

- `cnpg/<cluster>/`
- `velero/`

The current bucket remains private with versioning and Object Lock disabled for V1. Do not add versioning merely to duplicate CNPG/Velero retention. If immutable S3 protection is later required, create a separate Object-Lock-enabled bucket and migrate deliberately; Hetzner Object Lock cannot be enabled retroactively on the existing bucket.

## Storage Box policy

Canonical repository layout:

- `kubernetes/restic/<namespace>/<pvc>/`

One Restic repository per PVC.

The Kubernetes backup identity uses a Storage Box subaccount, SSH key authentication, external reachability, port 23, and a pinned server host key. The hcloud API token and main Storage Box credentials stay outside Kubernetes.

Storage Box automatic snapshots are a provider-side rollback layer, not an independent backup. They may protect against accidental repository deletion, but they share the same Storage Box failure/admin domain.

## Application classification

| Application/data | Current size hint | Reconstructible | V1 action |
| --- | ---: | --- | --- |
| Authentik PostgreSQL | CNPG | no | CNPG -> S3 |
| LiteLLM PostgreSQL | CNPG | no | CNPG -> S3 |
| Immich PostgreSQL | CNPG | no | CNPG -> S3 |
| Immich library | 100Gi PVC | no | VolSync Restic -> Storage Box; current PVC is backed up whole |
| Pinepods PostgreSQL | 60Gi requested CNPG storage | no | CNPG -> S3 |
| Pinepods downloads | 30Gi PVC | usually yes | no offsite backup |
| Home Assistant data | 5Gi PVC | no | VolSync Restic -> Storage Box |
| Zigbee2MQTT data | 400Mi PVC | no | VolSync Restic -> Storage Box |
| Jellyfin config | 10Gi PVC | inconvenient to rebuild | VolSync Restic -> Storage Box |
| Jellyfin cache | 10Gi PVC | yes | no backup |
| shared media | 2Ti PVC | yes by default | no offsite backup unless reclassified as authoritative |
| SABnzbd incomplete downloads | 100Gi PVC | yes | no backup |
| Audiobookshelf config/metadata | 5Gi + 20Gi PVCs | no/inconvenient | VolSync Restic -> Storage Box |
| Audiobooks/podcasts | 100Gi + 50Gi PVCs | depends on acquisition source | protect only when classified as authoritative |
| Frigate config | 5Gi PVC | no/inconvenient | VolSync Restic -> Storage Box |
| Frigate media | 50Gi PVC | normally yes | no backup by default |
| Paperless | not deployed on current main | n/a | future: DB -> S3; documents -> Storage Box |
| Dawarich | not deployed on current main | n/a | future: DB -> S3; irreplaceable uploads only -> Storage Box |

## Monitoring contract

Required alerts/signals:

- CNPG/Barman last successful base backup age;
- CNPG/Barman backup failures and WAL archive failures;
- Velero backup failure/partial failure and last successful schedule age;
- VolSync ReplicationSource last successful sync age;
- first-class recorded result/date for restore smoke tests.

Capacity monitoring for Storage Box should initially use Hetzner's provider view/manual check rather than introducing a custom exporter. Add an exporter only if capacity becomes operationally actionable at higher scale.
