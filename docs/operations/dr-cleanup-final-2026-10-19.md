# DR cleanup final plan — 2026-10-19

The live inventory is in
`docs/operations/dr-cleanup-live-inventory-2026-10-19.md` and is hashed by the
two executable manifests. All manifests are nominative and use the existing
`scripts/dr-synth-cleanup.sh` engine. Dry-run is the default; apply requires
the exact manifest digest, the exact engine digest and the engine's approval
token.

## Lots

| Lot | Manifest | Current decision |
| --- | --- | --- |
| Longhorn proof | `dr-synth-proof-cleanup-manifest-2026-10-19.json` | DELETE candidate after the live dry-run. It contains one dedicated namespace, four PV/Longhorn chains and preserves the four completed remote backups. |
| CNPG/Barman | `dr-synth-cnpg-cleanup-manifest-2026-10-19.json` | DELETE candidate for the two Kubernetes drill namespaces after the Barman gate. The six CRs are enumerated and metadata is captured without secret values. No S3 API is called. |
| Historical PVCs | `dr-synth-historical-review-manifest-2026-10-19.json` | REVIEW, no delete list. The 17 PVCs are still in active restore-drill namespaces; several Pods, StatefulSets, Jobs and Argo tracking annotations remain. |

The current engine digest is
`f9dff8061b69d9fdcf8b424477ce25a611df3dcc1bb98c3221fb61400c67e413`.
The proof manifest dry-run digest is recorded by the command output and must
be recomputed immediately before any apply. The CNPG manifest has a separate
digest and a separate apply token.

## CNPG/Barman and S3 policy

The six CNPG/Barman CRs are drill-local, have no finalizers, and the source
Backup is `completed`. The three ObjectStores use one-day retention. Two
ObjectStores reference the same drill source prefix, so no S3 prefix is
deleted by either cleanup lot. The E2E evidence, checksums, SQL result and
RPO/RTO records remain outside the namespaces. Any later S3 deletion requires
a distinct manifest and additional operator validation; it is not implied by
deleting Kubernetes CRs.

## Required apply gates

Before each apply, rerun the exact manifest's dry-run from the canonical
operator kubeconfig and confirm Factory/Mastra health. The engine revalidates
UIDs, labels, claimRefs, CSI handles, PVC references, VolumeAttachments,
Released PVs and Detached Longhorn volumes. It stops on timeout, identity
drift, a finalizer, a missing preservation object or an ambiguous prior
deletion. No force detach, finalizer removal, wildcard or bucket deletion is
permitted.

The proof lot can be applied only with its own token. The CNPG lot additionally
requires `DR_CLEANUP_ALLOW_BARMAN_CR_DELETE=true`; that flag authorizes only
the exact Kubernetes namespace cascade in its manifest and never authorizes
S3 deletion. Historical resources have no apply path in this mission.

After each lot, verify the target objects are absent, preserved backups remain
`Completed`, the other drill lot is unchanged, and Factory/Mastra and Argo
health show no new regression. Keep the JSONL journal and secret-free metadata
snapshots as the evidence archive.

## Execution result

The two eligible lots were executed on 2026-10-19 from the merged tree
`51744568d92f51f16d47379084725023068627c6`:

- Longhorn proof: one namespace, four PVs and four Longhorn volumes deleted;
  four remote Longhorn backups remained `Completed`.
- CNPG/Barman: two namespaces, six drill CRs, two PVs and two Longhorn volumes
  deleted. No S3 or Velero delete API was called. The Barman metadata and the
  source completed-backup evidence were captured before apply.
- Historical: zero deleted. All 17 PVCs remain REVIEW because active
  restore-drill workloads and/or Argo references still exist.

Execution journals are retained at:

- `/tmp/dr-pvc-proof-20261019193651-cleanup-20261019.journal.jsonl`, SHA-256
  `563be25d18a438a7a48f7037a3791e4a5686c654b092e90fae91131c9b550b8e`;
- `/tmp/dr-synth-20261019170700-cnpg-cleanup-20261019.journal.jsonl`, SHA-256
  `467910fd92a36e82444b2d5c355cee0ce737b5fe4e0d460fb0a88273cc7bb1a9`.

Post-cleanup checks found 21/21 Argo applications Synced, 17 Healthy and 4
pre-existing Degraded; `infra-database` remained Healthy/Synced and both
Mastra Factory pods were Running/Ready. The backup audit still fails on
pre-existing gaps: 5 unverified PVCs, CNPG configuration 12/12, restore proof
still unproven and 17 historical residues. The lower PVC denominator is a
mechanical consequence of removing six drill PVCs, not proof of improved
production coverage.

Synthetic Barman S3 data was not enumerated or deleted. The source prefix is
shared by two drill ObjectStores and remains subject to the one-day retention
policy; a separate S3 qualification and approval is still required for any
object deletion.
