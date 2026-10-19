# Synthetic DR partial cleanup inventory — 2026-10-19

This is a read-only inventory for the non-CNPG cleanup plan of run
`dr-synth-20261019170700`. It is intentionally separate from the full cleanup
manifest. The inventory was refreshed against Kubernetes before this plan was
written.

## Scope

The delete set contains only these dedicated namespaces:

| Namespace | UID | Labels |
|---|---|---|
| `dr-synth-20261019170700-velero-src` | `c9872e04-9f36-4962-b761-2b221cd1041c` | `dr.smadja.dev/purpose=synthetic-recovery`, `dr.smadja.dev/run=dr-synth-20261019170700` |
| `dr-synth-20261019170700-velero-tgt` | `93286195-37c1-4414-bb82-c6abca6b2a97` | `dr.smadja.dev/purpose=synthetic-recovery`, `dr.smadja.dev/run=dr-synth-20261019170700` |
| `dr-synth-20261019170700-velero-tgt-v2` | `c7be4bfe-eaa7-4990-b74a-e73fc98120e6` | `dr.smadja.dev/purpose=synthetic-recovery`, `dr.smadja.dev/run=dr-synth-20261019170700` |
| `dr-synth-20261019170700-stop` | `ed5d2bf4-d849-4bb3-a080-1ddcf7964526` | `dr.smadja.dev/purpose=synthetic-recovery`, `dr.smadja.dev/run=dr-synth-20261019170700` |

The temporary modifier ConfigMaps are:

| Namespace | Name | UID | Label |
|---|---|---|---|
| `velero` | `dr-synth-20261019170700-pvc-isolation` | `36665f5f-0c53-44e6-b8fb-791a948aa811` | `dr.smadja.dev/run=dr-synth-20261019170700` |
| `velero` | `dr-synth-20261019170700-pvc-isolation-v2` | `fb11af08-86b7-47d3-9073-9ea41c197a3b` | `dr.smadja.dev/run=dr-synth-20261019170700` |

## Exclusive storage set

All six PVs are `Retain`, currently `Bound`, and have the exact claimRef,
claim UID and CSI volumeHandle below. Their Longhorn volumes identify the same
namespace/PVC and are the only PVC references for these PVs.

| PV | PV UID | ClaimRef | Claim UID | VolumeHandle | Longhorn UID | Current state |
|---|---|---|---|---|---|---|
| `pvc-c8efe26b-fc83-4410-b606-fe370f15029e` | `c8d94fc2-7cb5-43a1-b425-9b326773596c` | `dr-synth-20261019170700-velero-src/bulk-data` | `c8efe26b-fc83-4410-b606-fe370f15029e` | `pvc-c8efe26b-fc83-4410-b606-fe370f15029e` | `dd5d0204-4e81-42f7-8f60-d643df6323db` | attached |
| `pvc-d4f55404-f4ab-4d86-8cf9-53dfe0a1f633` | `d60c279f-1d4f-45b4-ac79-b841b3371e71` | `dr-synth-20261019170700-velero-src/fast-data` | `d4f55404-f4ab-4d86-8cf9-53dfe0a1f633` | `pvc-d4f55404-f4ab-4d86-8cf9-53dfe0a1f633` | `f4699d06-dbf8-4a11-8101-0437d7f917b0` | attached |
| `pvc-9c7057f3-bc2a-4844-bf6e-210c4dd78e90` | `2f04dd83-00e2-4a50-aaca-cb16cf0c1071` | `dr-synth-20261019170700-velero-tgt/bulk-data` | `9c7057f3-bc2a-4844-bf6e-210c4dd78e90` | `pvc-9c7057f3-bc2a-4844-bf6e-210c4dd78e90` | `910b603e-e8fd-4f8c-af7b-634db444f21b` | attached |
| `pvc-53d528eb-82a6-4cdd-88ac-64ae292819d4` | `565c0a2d-df51-4b9d-b792-ac1f8a337297` | `dr-synth-20261019170700-velero-tgt/fast-data` | `53d528eb-82a6-4cdd-88ac-64ae292819d4` | `pvc-53d528eb-82a6-4cdd-88ac-64ae292819d4` | `b820829b-eec8-47c3-80ab-b3732a6e607d` | attached |
| `pvc-00d57f78-8be8-4084-9df7-92197ff1e5f1` | `0bf0dac6-e9c1-4794-8c88-9e80a1cde286` | `dr-synth-20261019170700-velero-tgt-v2/bulk-data` | `00d57f78-8be8-4084-9df7-92197ff1e5f1` | `pvc-00d57f78-8be8-4084-9df7-92197ff1e5f1` | `63926431-1370-4737-a896-16a436506c86` | attached |
| `pvc-db227530-6dfb-475b-b7bd-ef36a3dafd31` | `ddc7a7ec-6378-4fdc-b519-99a17a9f641c` | `dr-synth-20261019170700-velero-tgt-v2/fast-data` | `db227530-6dfb-475b-b7bd-ef36a3dafd31` | `pvc-db227530-6dfb-475b-b7bd-ef36a3dafd31` | `19218702-09c7-4597-93df-bcffea198cec` | attached |

All six volumes currently have `restoreRequired=false`. The live preflight
found a `VolumeAttachment` for each; apply must therefore wait for Detached
and no attachment before deleting any Longhorn volume.

## Explicit exclusions

The following are not in the delete set:

- `dr-synth-20261019170700-cnpg-src` (UID `1c5deb49-e9c5-4ad2-bbe2-f107f9413113`)
- `dr-synth-20261019170700-cnpg-tgt` (UID `9f6c1f6c-279f-4481-b53f-501c669e7079`)
- all six CNPG/Barman CRs and their two CNPG PVC/PV/Longhorn chains;
- all Velero Backup, Restore, PodVolumeBackup and PodVolumeRestore CRs;
- the four qualified Longhorn `Backup` CRs and their remote S3 data;
- the 17 historical PVCs, Factory/Mastra and all production resources.

The four qualified Longhorn backups are `dr-proof-20261019193651-agentgateway`,
`-atlantis`, `-listmonk` and `-twenty`; they remain `Completed` and are
preserved by the manifest.

## Execution contract

The wrapper delegates deletion to `scripts/dr-synth-cleanup.sh` from PR #564,
pinned to SHA-256
`f90f034e3ce7ae9e88ee400d43f765138933e98a682f4f5914470565ae01306a`.

Order is ConfigMaps, four namespaces, PVs after `Released`, then Longhorn
volumes after `Detached` and no `VolumeAttachment`. Each identity is checked
again immediately before deletion. Dry-run is the only mode allowed by this
PR; apply requires a separate operator approval using the exact manifest and
engine digests.

## Evidence and rollback

Qualification evidence remains outside the namespaces in:

- `/tmp/dr-synth-20261019170700-evidence.md`
- `/tmp/dr-synth-20261019170700-agent-test-result.json`
- `/tmp/dr-synth-20261019170700-cleanup-inventory.md`

The qualified S3 data is not a rollback mechanism for Kubernetes deletion.
There is no in-cluster rollback after PV or Longhorn volume deletion; an
operator must retain the evidence and perform a new restore if recovery is
required.
