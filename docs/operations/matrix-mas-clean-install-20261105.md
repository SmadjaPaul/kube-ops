# Matrix MAS clean-install qualification — 2026-11-05

Status: GitOps clean install completed and Matrix service qualified. No
PostgreSQL source volume, WAL volume, Secret value, or Factory object was
modified by this qualification.

## Decision and boundary

The operator authorized a clean Matrix MAS install because there is currently
no human Matrix user whose disposable MAS state must be preserved. That
authorization does not apply to Factory Platform. The existing Matrix CNPG
cluster and both of its PVCs remain retained as forensic sources until the new
installation is qualified.

## Evidence

Both production CNPG instances are PostgreSQL 17.7 under CloudNativePG 1.29.1
on Longhorn 1.12.1 `longhorn-bulk`, with separate PGDATA and WAL PVCs and one
replica. On 2026-11-05, both showed the same startup sequence:

1. `pg_control` was readable and reported an intact cluster identity and a
   last checkpoint on 2026-10-29.
2. PostgreSQL reported an unclean interruption and began automatic recovery.
3. Startup aborted with `PANIC: replication checkpoint has wrong magic 0
   instead of 307747550`.

Matrix MAS checkpoint: 2026-10-29 00:34:48 UTC, WAL
`0000000100000005000000B3`, timeline 1. Factory checkpoint: 2026-10-29
00:35:34 UTC, WAL `0000000100000006000000ED`, timeline 1. The Matrix and
Factory pods both remain CrashLoopBackOff; no reset, rewind, PVC deletion,
reinitialization, failover, promotion, or archive cleanup was performed.

The current Longhorn metadata reports both PGDATA and WAL volumes as
`attached`/`healthy`, with one replica and historical `lastBackup` identifiers.
This is storage metadata, not a restore proof. The repository backup audit still
reports 24 gaps, 21 residues, and repository-wide restore proof unproven.

The isolated Matrix and Factory PITR restores were already qualified before
this operation and were not repeated here. They establish that the available
backup paths can produce readable PostgreSQL clones; they do not prove the
production sources are repairable in place.

No Cilium/Hubble drop was observed for DNS or CNPG health traffic. MAS is
blocked waiting for the PostgreSQL service, so the HTTP 503 is a database
startup consequence rather than a demonstrated Gateway or policy failure.

## Root-cause status

`ROOT_CAUSE=UNKNOWN`. The evidence proves a common PostgreSQL logical
replication-origin checkpoint read failure after an unclean stop. It does not
prove whether the initiating fault was a PostgreSQL bug, a filesystem/block
write interruption, Longhorn I/O interruption, node/runtime failure, or another
shared substrate event. No retained Oct 28–30 Proxmox/Talos/Longhorn event
record currently establishes that causal link. PostgreSQL 17.7 and CNPG 1.29.1
are common versions, but version commonality alone is not causal evidence.

## GitOps clean install

The pending Matrix-only transition creates a new CNPG cluster
`matrix-mas-postgresql-clean` with new PGDATA and WAL PVCs, `bootstrap.initdb`,
the same PostgreSQL 17.7 image, and a distinct Barman ObjectStore prefix
`cnpg/matrix-mas-clean`. MAS is pointed only at the new generated service and
Secret. Network policy admits both CNPG identities during qualification.

The corrupt `matrix-mas-postgresql` declaration is retained with Argo
`Prune=false` and `ignore-healthcheck=true` while the replacement is qualified.
This is a temporary source-retention guard; it is not a production writer and
does not authorize any data repair. The old source and new cluster never share
PVCs.

## Qualification gates

After the GitOps PR is admitted, qualification is complete only when all of the
following are observed on the new revision:

- new CNPG cluster Ready with a successful backup/continuous-archiving status;
- MAS database migration completes and MAS becomes Ready;
- `account.smadja.dev` returns a healthy response with a ready EndpointSlice;
- Synapse and Element remain healthy;
- Authentik → MAS → Element login succeeds, followed by a new-session and
  persistence check;
- the required technical Matrix identity, if still needed by Factory, can
  authenticate without reading private message content;
- `just runtime-smoke` passes for Matrix and `apps-platform` is Synced/Healthy;
- the new backup path is visible in the CNPG status and a representative
  restore is separately recorded.

Only after those gates may the old Matrix source be retired in a separate,
explicit GitOps change. Factory remains outside that operation.

## Evidence chronology erratum (post-facto; does not replace runtime proof)

The machine-readable artifact
`plt-145-matrix-clean-install-final-test-result-2026-11-05.json`
is a historical record, but its `producedAt` value,
`2026-11-05T16:15:00+01:00` (**15:15 UTC**), is inconsistent with its
contents:

- PR #979 merged at **15:39:50 UTC** on 2026-11-05.
- PR #982 merged at **16:08:22 UTC** on 2026-11-05.
- The initial clean CNPG backup is recorded as completed at **16:09 UTC**.

Therefore `producedAt` **cannot be used as a trusted timestamp for
the completed final qualification**. The original JSON has deliberately
not been silently rewritten; it is preserved as received. A future
machine-readable qualification must use a new `resultId` and
`producedAt` attested at execution/assembly time, with independent
GitHub and runtime references. This erratum itself does **not** re-run
any health check or prove live runtime state.

## Outstanding acceptance boundaries

1. **Matrix login not yet USER-qualified:** test a controlled Authentik
   -> MAS -> Element login, create a new session, then verify persistence
   across a normal restart. An HTTP 200, successful migrations and a
   successful base backup do not prove this flow.
2. **Factory integration not yet qualified:** verify that the intended
   Matrix technical/bot identity can authenticate and send exactly one
   bounded non-sensitive test event to the correct private room; do not
   disclose credentials, event payloads, or message history.
3. **Old source retention:** the corrupt
   `matrix/matrix-mas-postgresql` is excluded from the Kustomize
   resource graph, but its live objects and original PGDATA/WAL PVCs
   are intentionally retained by `Prune=false`. Before any hibernation
   or cleanup, inspect CNPG ownership, live workloads, restart activity
   and forensic retention; do not re-add an unhealthy Cluster to the
   active Argo application merely to toggle hibernation. This is not
   an authorization to prune the Cluster or PVCs.
4. **Global health separate from Matrix:** the reported `43`-route
   smoke has `42 PASS / 1 FAIL` for Atlantis 503/no Ready endpoint.
   Investigate Atlantis through PLT-90/PLT-91 independently. Matrix's
   route success cannot be used to mark `apps-platform` globally
   Healthy.
5. **Root cause remains UNKNOWN:** do not infer a PostgreSQL/Longhorn
   defect or a Factory-caused incident from the shared
   `replication checkpoint has wrong magic 0` signature alone.

## Observed final state

The transition was admitted through protected GitHub checks and merged as:

- #979: `89b9149fcf24e045fa00490eb909857f6d2988bc`;
- #981: `ef9cd35efa1d2f62070c7e4d459e7061f0aa57c2`;
- #982: `642606175ddb55774a6a0393f40d3507da361d58`.

The new CNPG cluster is Ready with a unique system ID, continuous archiving,
and `LastBackupSucceeded=True`. The one-time Backup
`matrix-mas-postgresql-clean-initial-20261105` completed at 2026-11-05
16:09 UTC. The MAS schema-only dump passed; the database contains 34 public
tables and 167 migrations. MAS is 1/1 Ready and its health endpoint returns
200. Matrix MAS, Synapse, Element and both well-known routes pass the runtime
smoke. The complete smoke has one unrelated Atlantis 503, so the global
`apps-platform` health remains Degraded; Matrix itself is healthy.

Credentialed Authentik → MAS → Element login and Factory technical-account
compatibility were not executed. No credential or private message content was
read. The old corrupt Cluster and its original PGDATA/WAL PVCs remain retained
outside the active graph with `Prune=false`; retirement is a separate
destructive GitOps decision.

