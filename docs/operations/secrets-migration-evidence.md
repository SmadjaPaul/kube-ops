# Secrets migration: runtime evidence

Plan: `docs/architecture/secrets-migration-spec.md`. One section per lot, filled only after a real run. No secret value ever appears here: only statuses, conditions, ages, sizes and functional results.

## Lot 1: `pg-shared-homelab` role passwords

| Drill | Procedure | Status | Verdict |
| --- | --- | --- | --- |
| D1 rotation of a role | `docs/operations/secrets-drill-d1-pg-shared-role.md` | NOT_RUN | NOT_PROVEN |
| D1b Barman restore + new Secret (before any real data) | `docs/operations/pg-shared-app-restore-drill.md`, section D1b | NOT_RUN | NOT_PROVEN |

Evidence: none yet. Until D1b is PASS, no real data goes into `pg-shared-homelab` and no existing database is migrated to a generated role password.
