# Matrix MAS — switchover to a restored CNPG cluster (procedure, not executed)

Ticket: PLT-145 (follow-up of PLT-202). **Draft procedure; never executed.**
It must be rehearsed in a drill before any production use, and every step that
mutates production data needs operator approval (PLT-145 constraints).

## Preconditions

- Production `matrix/matrix-mas-postgresql-clean` is unrecoverable or corrupt
  (a healthy cluster is fixed in place, not replaced).
- A restored cluster exists and is `Ready` (see `plt-202-matrix-mas-restore-drill.md`;
  RTO measured 29 min 22 s, RPO at most about 5 min by WAL archive timeout).
- Control query on the restored database matches the last production
  read-only counts (tables, `_sqlx_migrations`, `oauth2_clients`,
  `upstream_oauth_*`).
- `matrix-generated` signing/encryption keys are untouched; `server_name`
  stays `smadja.dev`.

## Steps (all through Git, one PR each)

1. **Freeze writers.** Scale MAS to 0 (`matrixAuthenticationService` replicas)
   so nothing writes between the last archived WAL and the cutover; record the
   prior replica count. Synapse stays up; sign-in is unavailable for the
   duration (expected RTO).
2. **Preserve the source.** Keep the failed cluster and both PVCs as immutable
   incident sources: first merge and reconcile `argocd.argoproj.io/sync-options: Prune=false,Delete=false`
   on the cluster, and verify the PVC reclaim policy keeps the volumes
   (`Delete=false` alone does not stop pruning when the manifest leaves Git).
   Only then take it out of the active graph. Never `pg_resetwal`, never
   delete PVCs.
3. **Recover under a new name** in `matrix` (bootstrap.recovery, new
   `serverName`, own ObjectStore prefix; never archive into the source prefix).
   Recovery keeps the database credentials stored in the backup: set the
   recovery database and owner to `mas`, name the application secret
   explicitly, and verify a connection with it before cutover. Configure the
   WAL archiver on the new prefix. Wait for `Ready`, then run the read-only
   control query.
4. **Repoint MAS**: in `values.yaml`, change
   `matrixAuthenticationService.postgres.host` and `password.secret` to the
   new cluster `-rw` service and the verified `-app` secret, and restore the
   replica count recorded in step 1. Argo rolls MAS.
5. **Verify** (RUNTIME): MAS `Ready`, `https://account.smadja.dev` answers,
   an Authentik-backed sign-in works, Synapse delegation still resolves,
   new WAL objects appear in the new prefix (the `ContinuousArchiving`
   condition alone is not evidence, see PLT-202) and a base backup succeeds.
6. **Rollback**: only while MAS has not written to the restored cluster and
   the source passes a health check (it may itself be corrupt). After MAS has
   written to the new cluster, reverting discards those writes: freeze MAS
   and decide with the operator how to reconcile them first.

## Targets

- RTO: restore about 30 min plus about 10 min cutover and verification.
- RPO: the 5 min archive timeout bounds loss only if archiving was healthy.
  Before cutover, establish the latest archived and replayed WAL and report
  the actual loss window. MAS currently holds `users=0` (PLT-145).
- Hetzner copy only; the R2 variant needs its own drill (PLT-248).
