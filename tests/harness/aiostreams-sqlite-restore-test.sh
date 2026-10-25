#!/usr/bin/env bash
set -euo pipefail

# Synthetic file-level qualification only. This intentionally never reads a
# Kubernetes PVC, kubeconfig, Secret, Doppler project or production database.
command -v sqlite3 >/dev/null

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

source_db="$work_dir/source.db"
backup_db="$work_dir/backup.db"
restore_db="$work_dir/restore.db"

sqlite3 "$source_db" <<'SQL' >/dev/null
PRAGMA journal_mode=WAL;
CREATE TABLE synthetic_sentinel (id INTEGER PRIMARY KEY, value TEXT NOT NULL);
INSERT INTO synthetic_sentinel(value) VALUES ('AIOSTREAMS-SYNTHETIC-RESTORE-SENTINEL');
SQL

# SQLite's online backup API is represented by the CLI .backup command. The
# production runbook must invoke the equivalent operation only after writes
# are quiesced, then copy the resulting artifact into an isolated restore PVC.
sqlite3 "$source_db" ".backup '$backup_db'"
sqlite3 "$backup_db" 'PRAGMA integrity_check;' | grep -Fxq ok
sqlite3 "$backup_db" \
  "SELECT value FROM synthetic_sentinel WHERE id = 1;" | \
  grep -Fxq 'AIOSTREAMS-SYNTHETIC-RESTORE-SENTINEL'

sqlite3 "$restore_db" ".restore '$backup_db'"
sqlite3 "$restore_db" 'PRAGMA integrity_check;' | grep -Fxq ok
sqlite3 "$restore_db" \
  "SELECT value FROM synthetic_sentinel WHERE id = 1;" | \
  grep -Fxq 'AIOSTREAMS-SYNTHETIC-RESTORE-SENTINEL'

printf '%s\n' 'AIOSTREAMS_SQLITE_RESTORE_SYNTHETIC=PASS (NO_PRODUCTION_DATA)'
