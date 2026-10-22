# Historical Kubernetes debt closure — 2026-10-22

This is the latest bounded evidence for `kube-ops`. It distinguishes Git
desired state (STATIC), Argo acceptance (RECONCILED), live behavior (RUNTIME),
blocked actions and checks that were not executed. It does not promote a
static contract or an Argo revision into runtime proof.

## Decision summary

| Lot | Status | Evidence | Decision |
| --- | --- | --- | --- |
| `apps-media` Jellyseerr/Seerr | **BLOCKED_EXTERNAL_CREDENTIAL** | Runtime ESO reports the authoritative Doppler key `APP_JELLYSEERR_JELLYFIN_API_KEY` absent; Jellyseerr remains Ready | No placeholder, rotation, duplicate authority or GitOps change |
| CNPG `sure` RPO boundary | **PASS — RUNTIME, synthetic and bounded** | Native CNPG/Barman backup, named restore point, marker present before the point and absent after it on an isolated target | Record a per-fixture transaction boundary only; do not generalize to the other 13 clusters |
| CNPG application client | **PASS — RUNTIME, isolated** | PostgreSQL client Job used the target CNPG application Secret by reference and returned the expected marker counts | Client proof is for this synthetic `sure` target only |
| OpenClaw runtime decommission | **BLOCKED_OWNER** | No instance, Service or route; live operator is Ready but has no current Argo Application or desired manifest owner | No direct delete; owner/source-of-truth decision required |
| Historical restore residues | **REVIEW** | Backup audit remains `RESTORE_RESIDUE_COUNT=21`; all listed resources retain unresolved ownership or utility | No deletion; PLT-105 remains intact |

No Factory, Atlantis, Proxmox, OpenTofu state or production CNPG object was
modified. No Secret value was read or printed. No hosted GitHub Actions build
or other paid build was launched.

## Lot A — apps-media

The retained deployment is the existing `media/jellyseerr` StatefulSet using
the Seerr image digest already in Git. Its `JELLYFIN_URL` is the in-cluster
plain URL `http://jellyfin:8096`, not a Secret. The existing bootstrap Job
targets Jellyfin and Seerr internally and reads mounted Secret files without
printing them.

Both existing ExternalSecrets project the same authoritative Doppler key into
the expected `JELLYFIN_API_KEY` field:

- `media/jellyseerr-secrets` → `APP_JELLYSEERR_JELLYFIN_API_KEY`;
- `media/seerr-first-run` → `APP_JELLYSEERR_JELLYFIN_API_KEY` plus the existing
  bootstrap-admin reference.

The inspected authoritative source is Doppler `cluster/prd`, through the
existing `doppler-cluster` ClusterSecretStore. The name-only inspection of
`homelab-infra` found no alternate Jellyfin API-key name and no existing
authoritative key. Runtime evidence remains `SecretSyncedError` for both
ExternalSecrets while the Jellyseerr workload is Ready and Argo is
`Synced/Degraded` with 25 orphans. The key must be generated or renewed by an
operator through Jellyfin's official administration path, then provisioned in
the same Doppler authority. That operator access was not available here.

Status: **BLOCKED_EXTERNAL_CREDENTIAL**. No PR was created. Functional
Jellyfin access, first-run completion and Argo `Healthy` remain **NOT_EXECUTED**
because creating or testing the missing credential would require the blocked
operator action.

## Lot B — OpenClaw/Paperclip boundary

The live metadata-only inventory found:

- zero `OpenClawInstance` objects;
- no OpenClaw Service or active HTTPRoute;
- no current Argo Application or Helm release owning the operator;
- Invoice Ninja remains active and healthy, while its MCP manifests are
  dormant and excluded from the active Kustomization;
- `openclaw-operator-system/openclaw-operator` still exists with UID
  `1a67f709-7ca4-4967-8cf1-2f1be59bb15b`, one replica and one available pod,
  plus a stale Argo tracking annotation.

This proves absence of an active OpenClaw consumer, but not a safe GitOps
deletion path: the live deployment is not represented by a current desired
manifest or discoverable Argo owner. References in old acceptance material,
generic runtime-smoke fixtures and dormant MCP documentation are not runtime
consumers, but they still require owner attribution before deleting the
orphaned operator or its CRDs. The retained Paperclip/CNPG data safeguards and
all restore/drill namespaces remain untouched.

Status: **BLOCKED_OWNER**; no direct deletion and no PR. A future change must
first establish the owning source and a reviewed prune set.

## Lot C — isolated synthetic RPO qualification

The production source was only inspected: `sure/sure-postgresql` UID
`c3ba9da8-c7d5-4944-b94a-3c797a3eb3ce` remained healthy with one primary, and
the completed source Backup `sure-postgresql-gap-remediation-20261019` UID
`21d51ead-1b60-45de-8a73-598cc7ea91a5` retained backup ID `20261019T153211`.

The qualification used two temporary namespaces with Cilium egress restricted
to DNS and the Hetzner endpoint, target ingress restricted to the client Job,
and no production service, PVC or Secret copied into the drill:

1. `sure-rpo-source` recovered from the pinned production backup.
2. A transaction committed marker `rpo-20261022-1556` at
   `2026-10-22 15:56:07.390803+00`, LSN `0/40007238`, transaction ID `1606`.
3. `pg_create_restore_point('rpo-qual-20261022-1556')` returned LSN
   `0/40041958`; the WAL containing the point was archived as
   `000000020000000000000040`.
4. A native CNPG/Barman Backup completed with ID `20261022T155631`.
5. A second marker committed after the named restore point was not present on
   `sure-rpo-target`; the pre-point marker was present.
6. An isolated PostgreSQL client Job connected through
   `sure-rpo-target-rw` using `sure-rpo-target-app` by `secretKeyRef`/mounted
   keys only. It returned database `sure`, `in-recovery=false`, one pre-point
   marker and zero post-point markers.

Observed synthetic RPO boundary: **0 committed markers lost at the named
restore point**. This is a transaction-boundary result, not a time-based RPO
SLO and not a claim for production `sure` outside this fixture or for the
other 13 CNPG clusters. The source remained healthy and unchanged. The three
negative probes all exited `124` (source→target, target→source and
target→public), proving the intended isolation for this run.

The unique S3 prefix was first listed, then checked with Barman's
`--dry-run`, deleted with the native `barman-cloud-backup-delete` for backup
ID `20261022T155631`, and listed again with no backup rows. The following
temporary identities were then removed after UID verification:

- namespaces `cnpg-rpo-source-20261022` UID
  `433f2339-a40e-42f0-be06-1e3fcb4a4fc4` and
  `cnpg-rpo-target-20261022` UID
  `42551b62-3aaa-4f33-a08e-c6efb44379af`;
- PVs `pvc-51ae0dab-36aa-47b1-9308-eae469c7a381`,
  `pvc-27723a1f-08e7-4563-99c4-e6397f0dd6f5`,
  `pvc-c041c251-948d-4d35-bdb3-2b1e67afd0e3` and
  `pvc-c5790ee2-d529-416d-b51a-52de01b729bc`;
- corresponding Longhorn volumes with UIDs
  `72c14daa-558b-4455-95db-828efd437487`,
  `a43fc710-7977-408b-a4e9-bcfd278b6ae6`,
  `3859fcd3-7582-43d2-ac15-27c3c583b97d` and
  `458c77ba-4e9a-41d1-8b3f-ab6f31588178`.

The earlier isolated `sure` restore remains valid as a separate one-cluster
RTO/SQL proof: Ready 66s, SQL sentinel 192s, 152 tables, 456 rows and the
recorded checksum. It does not become a 14-cluster restore proof.

## Lot D — historical residues

The backup audit remains:

```text
PRODUCTION_PVC_COVERAGE=PASS (56/56)
CNPG_BACKUP_CONFIGURATION=PASS (14/14)
CNPG_RESTORE_PROOF=UNPROVEN
RESTORE_DRILL_SUCCESS=FAIL
RESTORE_RESIDUE_COUNT=21
BACKUP_AUDIT_GAPS=21
```

The 21 resources remain the three `dr-protect` synthetic PVCs, eight Invoice
Ninja drill PVCs, nine OpenClaw drill PVCs and the single
`plt105-recovery-20261020/plt105-recovery-pvc` (UID
`95e7eaa9-c966-4825-8977-18ca351c1`). They remain **REVIEW** because owner,
retention purpose or correlated backup identity is not proven for each item.
PLT-105 was not deleted, mounted, patched or otherwise changed.

## Reusable admission boundary

For each of the 14 CNPG clusters, admission requires the same per-cluster
evidence shape: pinned completed Backup ID, isolated namespace and network,
native Barman restore, source-preservation check, SQL/application sentinel,
negative access probes, measured Ready/SQL times and exact cleanup identities.
The `sure` synthetic run satisfies that shape for its own fixture only.
Missing any marker, client, source-preservation or cleanup check is
`NOT_EXECUTED`/`BLOCKED`, never a pass inferred from static configuration.
