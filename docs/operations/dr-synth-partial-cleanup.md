# Synthetic DR partial cleanup and Barman lifecycle

This change prepares, but does not execute, the non-CNPG cleanup of
`dr-synth-20261019170700`.

## Partial cleanup

The exact plan is the machine-readable
`dr-synth-partial-cleanup-manifest-2026-10-19.json`. It contains only four
dedicated Velero/stop namespaces, two temporary Velero ConfigMaps and six PV /
Longhorn chains owned exclusively by those namespaces.

The CNPG source and target namespaces, their six CNPG/Barman CRs, their PVCs,
PVs and Longhorn volumes are excluded. Velero Backup/Restore CRs and the four
qualified Longhorn `Backup` CRs are explicit preservation entries.

The wrapper `scripts/dr-synth-partial-cleanup.sh` pins the existing safe
engine from PR #564. It rejects CNPG namespaces, CNPG claimRefs, non-Velero
ConfigMaps, any unexpected namespace set and every manifest override before invoking the engine. The
engine retains the existing UID, claimRef, PV `Released`, Longhorn `Detached`,
VolumeAttachment, journal and resume gates.

Only this is permitted during a future approved run:

```text
scripts/dr-synth-partial-cleanup.sh --dry-run
```

Apply is intentionally not authorized by this PR. A future operator approval
must use the exact manifest digest and the pinned engine digest. No force
detach, finalizer removal, wildcard deletion or ignore-not-found behavior is
allowed.

## Synthetic Barman data policy

The E2E result is the durable qualification artifact. It records the Velero
and CNPG checksums, backup IDs, SQL acceptance and measured RPO/RTO in the
existing evidence and machine-readable test-result files.

The synthetic Barman ObjectStores currently use a one-day retention policy.
That is a deliberate short-lived data policy, not durable DR coverage. The
reports and checksums are retained independently of the object storage data.
The four qualified Longhorn remote backups remain preserved and are outside
this partial cleanup.

Deleting a Kubernetes `Backup` CR is not a substitute for deleting or
retaining Barman data. The Barman plugin's periodic retention process is the
component that calls the Barman backup-delete operation. Therefore the CNPG
namespaces remain untouched until the operator has decided that the synthetic
S3 data is no longer useful and has approved a separate CNPG cleanup scope.

That future scope must explicitly cover the two CNPG namespaces and these six
CRs:

- source Cluster and Backup;
- source ObjectStore;
- recovered Cluster;
- recovered source and target ObjectStores.

It must also acknowledge the cascade of CNPG-owned Pods, PVCs, Secrets,
Services, Roles and RoleBindings. The current partial cleanup does not make
that decision and cannot delete those parents.

## Evidence and rollback

The source evidence remains outside the namespaces. A cleanup journal is
append-only and must be retained. There is no in-cluster rollback after a PV
or Longhorn volume is deleted; recovery requires the already-qualified
external backup and a new isolated restore.
