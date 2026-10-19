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
