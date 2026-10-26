# Synthetic DR cleanup and persistent PVC protection

Status: cleanup implementation is merged only as a dry-run-capable tool. The live
dr-synth-20261019170700 drill is not approved for deletion by this change.

## Cleanup contract

The cleanup script is deliberately tied to an external, immutable manifest. The
manifest contains the exact namespace, ConfigMap, PVC, PV, Longhorn volume,
claimRef and UID inventory plus the SHA-256 of the evidence inventory.

    scripts/dr-synth-cleanup.sh \
      --dry-run \
      --manifest /tmp/dr-synth-20261019170700-cleanup-manifest.json

Dry-run is the default. It performs all identity, claimRef, volume attachment,
Longhorn ownership, CNPG/Barman and preservation checks and writes:

- an append-only JSONL execution journal;
- a JSONL per-resource report;
- secret-free CNPG/Barman metadata snapshots.

Apply is a separate operator action and requires the exact manifest and script digests:

    manifest=/tmp/dr-synth-20261019170700-cleanup-manifest.json
    sha256sum "$manifest"
    DR_CLEANUP_APPROVAL="APPROVE:dr-synth-20261019170700:<manifest-digest>:<script-digest>" \
    DR_CLEANUP_ALLOW_BARMAN_CR_DELETE=true \
    scripts/dr-synth-cleanup.sh --apply --manifest "$manifest"

The Barman flag is required because deleting the drill namespaces deletes the
drill-local CNPG Cluster, Backup and ObjectStore CRs. The script never calls
S3, Barman or Velero deletion APIs. It blocks when an ObjectStore has no
retention policy, a CNPG Backup is not completed, or a finalizer is present.
External backup retention remains a separate storage-owner decision. Manifests
for proof and CNPG cleanup may pin an explicit `identityLabels` map when the
namespace does not carry the default `dr.smadja.dev/run` label; every listed
label is still revalidated before each applicable deletion.

Each deletion is sequential and revalidates the UID immediately before the
delete. PVs must be Retain, match the exact claimRef and CSI volumeHandle,
and have no other PVC or VolumeAttachment reference. Longhorn volumes must
still identify the expected PVC and become detached within the bounded
timeout. No force deletion, wildcard, finalizer removal or automatic
ignore-not-found behavior is used.

### Absent namespace and released orphan storage

An orphan-storage manifest may use `absentNamespaces` only for a namespace
whose old UID is present in a SHA-256-pinned durable evidence file. The tool
then requires a Kubernetes `NotFound` response; an existing namespace with
the same name is always a block, regardless of its UID. This is a per-manifest
exception, not a global identity bypass. A PV row must separately opt into
`allowAbsentClaim` and `requireReleasedDetached`; the latter also rechecks
the Released PV phase, Detached Longhorn state, Pod/VolumeAttachment/PVC
references and Argo Application references before a dry-run can pass.

The Matrix qualification at
`docs/operations/matrix-orphan-cleanup-manifest-2026-10-26.json` carries an
explicitly blocked `absentNamespaces` row with a null UID: the live namespace
is absent, but the old namespace UID was not found in a durable repository
proof. The cleanup engine rejects that row before any deletion planning. The
four PV and Longhorn identities are recorded for review; no deletion is
authorized until the missing proof and the nominative authorization are
added.

A failed run leaves its journal. A retry requires --resume and the same
manifest digest. An absent object is accepted only when the journal records a
successful deletion of the same UID. An interruption before that record
blocks resume until an operator performs an independent revalidation and adds
an explicit journal record.

## PVC protection findings

The current Velero deployment is v1.18 with Kopia/node-agent. The cluster has
no active Velero DataUpload/DataDownload objects, CSI Data Mover or usable
Longhorn backup target. Repository schedules already set
defaultVolumesToFsBackup: true.

Therefore:

- a running Pod with a mounted claim can be covered by Velero/Kopia, but this
  still requires a completed PVB and a restore proof;
- a Pending Pod or an unmounted retained PVC is not covered by the current
  filesystem-backup path;
- a local Longhorn snapshot is not an off-site backup;
- adding a schedule or annotation alone does not create coverage.

Current decisions:

| PVC | Decision | Blocking evidence |
|---|---|---|
| agentgateway/agentgateway-state | PROTECT | SQLite is mounted by a running Pod, but the observed backup had no completed PVB; a hot filesystem backup needs a consistency/restore proof |
| atlantis-system/atlantis-pilot-data | PROTECT | Pod is Pending and its GitHub App ExternalSecret is not ready |
| listmonk/listmonk-uploads | PROTECT | Claim is retained and currently unmounted; no PVB exists |
| twenty/twenty-storage | PROTECT | Claim is retained and currently unmounted; no PVB exists |

No Git-only correction can establish real coverage for the three latter
conditions without either making the workload mount the claim or enabling and
qualifying an upstream volume-data movement path. No custom controller or
backup framework is introduced here.

Immich Redis remains a separate recoverability policy: loss of AOF can lose
queued jobs, transient sessions and in-flight work, while PostgreSQL and the
media library are separate. The current omission is not explicitly declared
as an intentional Git policy and must not be reported as a verified backup.

## Rollback

The cleanup is destructive and has no in-cluster rollback after a PV or
Longhorn volume deletion. Before apply, retain the evidence files, the
secret-free CNPG/Barman metadata export and the exact manifest. If any
precondition diverges, stop and do not retry with a changed manifest.
