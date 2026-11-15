#!/bin/bash
# PLT-286: step 1 of a cycle. PostgreSQL custom-format dump straight into
# restic, no file on disk. `--stdin-from-command` makes restic discard the
# snapshot when pg_dump exits non-zero; a `pg_dump | restic backup --stdin`
# pipe is forbidden (it records a truncated dump as a success).
# Environment: PGHOST, PGPORT, PGDATABASE, PGUSER, PGPASSWORD (CNPG <cluster>-app).
set -euo pipefail

restic_bin="${RESTIC_BIN:-restic}"
# shellcheck source=/dev/null # restic-lib.sh, mounted next to this script
. "${SCRIPTS_DIR:-/scripts}/restic-lib.sh"

ensure_repository

log "step=postgres-dump tag=${APP}-postgres start"
run_throttled "$restic_bin" backup \
  --limit-upload "${LIMIT_UPLOAD_KIB:-4096}" \
  --host "$RESTIC_HOST" \
  --tag "${APP}-postgres" \
  --retry-lock 30m \
  --stdin-filename "${APP}-postgres.dump" \
  --stdin-from-command -- \
  pg_dump --format=custom --no-password
log "step=postgres-dump tag=${APP}-postgres done"
