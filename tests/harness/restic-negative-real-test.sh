#!/usr/bin/env bash
# PLT-286: negative test with the REAL restic binary (the contract test uses a
# stub). A failing pg_dump must leave NO snapshot in the repository; a
# successful one must leave exactly one. Throwaway local repository, no
# network, no production data. Skipped when restic is not installed.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if ! command -v restic >/dev/null 2>&1; then
  echo "SKIP restic-negative-real-test: restic not installed"
  exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/fail" "$tmp/ok" "$tmp/repo"
printf '#!/bin/sh\nprintf PGDMP-partial\nexit 1\n' >"$tmp/fail/pg_dump"
printf '#!/bin/sh\nprintf PGDMP-complete\nexit 0\n' >"$tmp/ok/pg_dump"
chmod +x "$tmp/fail/pg_dump" "$tmp/ok/pg_dump"

export RESTIC_REPOSITORY="$tmp/repo" RESTIC_PASSWORD="throwaway-test-password"
export RESTIC_HOST=negtest APP=negtest SCRIPTS_DIR="$root/k8s/components/restic-backup"
restic init >/dev/null 2>&1

count() { restic snapshots --json | grep -o '"short_id"' | wc -l | tr -d ' '; }

if PATH="$tmp/fail:$PATH" bash "$SCRIPTS_DIR/backup-db.sh" >/dev/null 2>&1; then
  echo "ASSERTION_FAILED backup-db.sh succeeded although pg_dump failed" >&2
  exit 1
fi
[[ "$(count)" == 0 ]] || { echo "ASSERTION_FAILED a failed dump created a snapshot" >&2; exit 1; }

PATH="$tmp/ok:$PATH" bash "$SCRIPTS_DIR/backup-db.sh" >/dev/null 2>&1
[[ "$(count)" == 1 ]] || { echo "ASSERTION_FAILED the successful dump did not create one snapshot" >&2; exit 1; }
echo "restic-negative-real-test: PASS"
