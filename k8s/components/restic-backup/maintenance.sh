#!/bin/bash
# PLT-286: weekly maintenance of one application repository.
#   1. retention: forget per (host, tag) group, then prune;
#   2. integrity: `restic check --read-data-subset`;
#   3. dry restore ("à blanc"), in memory, never on a production volume:
#      the latest dump must decode end to end (pg_restore to /dev/null), and a
#      random sample of files must match the SHA-256 manifest of their snapshot.
set -euo pipefail

restic_bin="${RESTIC_BIN:-restic}"
# shellcheck source=/dev/null # restic-lib.sh, mounted next to this script
. "${SCRIPTS_DIR:-/scripts}/restic-lib.sh"

work="${WORK_DIR:-/tmp/work}"
sample="${RESTORE_SAMPLE:-20}"
root="${SOURCE_ROOT:-/}"
mkdir -p "$work"

rc=0
"$restic_bin" cat config >/dev/null 2>&1 || rc=$?
if [ "$rc" -ne 0 ]; then
  log "repository=unavailable rc=$rc; maintenance never initialises a repository"
  exit 1
fi

log "step=forget start"
"$restic_bin" forget \
  --host "$RESTIC_HOST" \
  --group-by host,tags \
  --keep-daily "${KEEP_DAILY:-7}" \
  --keep-weekly "${KEEP_WEEKLY:-5}" \
  --keep-monthly "${KEEP_MONTHLY:-12}" \
  --retry-lock 2h
log "step=prune start"
"$restic_bin" prune --max-unused "${PRUNE_MAX_UNUSED:-10%}" --retry-lock 2h

log "step=check subset=${CHECK_SUBSET:-5%} start"
"$restic_bin" check --read-data-subset "${CHECK_SUBSET:-5%}" --retry-lock 2h

log "step=dry-restore tag=${APP}-postgres start"
"$restic_bin" dump --host "$RESTIC_HOST" --tag "${APP}-postgres" latest "/${APP}-postgres.dump" |
  pg_restore --file=/dev/null
log "step=dry-restore tag=${APP}-postgres PASS"

log "step=dry-restore tag=${APP}-files start"
# One snapshot for the manifest and every sampled file: `latest` would be
# resolved again by each dump and could move under a concurrent backup.
snapshot="$("$restic_bin" snapshots --json --latest 1 --host "$RESTIC_HOST" --tag "${APP}-files" |
  grep -o '"id":"[0-9a-f]*"' | head -n 1 | cut -d '"' -f 4)"
if [ -z "$snapshot" ]; then
  log "step=dry-restore tag=${APP}-files snapshot=none"
  exit 1
fi
"$restic_bin" dump "$snapshot" "${MANIFEST_DIR:-/manifest}/SHA256SUMS" >"$work/SHA256SUMS"
total="$(wc -l <"$work/SHA256SUMS" | tr -d " ")"
if [ "$total" -eq 0 ]; then
  log "step=dry-restore tag=${APP}-files manifest=empty"
  exit 1
fi
checked=0
while IFS= read -r line; do
  expected="${line%% *}"
  path="${line#*  }"
  actual="$("$restic_bin" dump "$snapshot" "${root%/}/$path" | sha256sum)"
  if [ "${actual%% *}" != "$expected" ]; then
    log "step=dry-restore tag=${APP}-files FAIL entry=$((checked + 1))"
    exit 1
  fi
  checked=$((checked + 1))
done < <(shuf -n "$sample" "$work/SHA256SUMS")
log "step=dry-restore tag=${APP}-files PASS sampled=$checked total=$total"
