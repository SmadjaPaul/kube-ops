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
   so nothing writes between the last archived WAL and the cutover. Synapse
   stays up; sign-in is unavailable for the duration (expected RTO).
2. **Preserve the source.** Keep the failed cluster and both PVCs as immutable
   incident sources: rename the Git resource out of the active kustomization
   without deleting it (`argocd.argoproj.io/sync-options: Delete=false`).
   Never `pg_resetwal`, never delete PVCs.
3. **Recover under a new name** in `matrix` (bootstrap.recovery, new
   `serverName`, own ObjectStore prefix; never archive into the source prefix).
   Wait for `Ready`, then run the read-only control query.
4. **Repoint MAS**: in `values.yaml`, change
   `matrixAuthenticationService.postgres.host` and `password.secret` to the
   new cluster `-rw` service and `-app` secret. One-line PR; Argo rolls MAS.
5. **Verify** (RUNTIME): MAS `Ready`, `https://account.smadja.dev` answers,
   an Authentik-backed sign-in works, Synapse delegation still resolves,
   new cluster `ContinuousArchiving` true with a successful base backup.
6. **Rollback**: revert the step 4 PR (MAS points back to the preserved
   source). Possible only while the source is intact, hence step 2.

## Targets

- RTO: restore about 30 min plus about 10 min cutover and verification.
- RPO: up to 5 min of MAS writes (sessions, OIDC grants); no user data lost
  since MAS currently holds `users=0` (production comparison in PLT-145).
- Hetzner copy only; the R2 variant needs its own drill (PLT-248).
