#!/usr/bin/env bash
# PLT-286 / PLT-264: restore drill of one restic repository into a throwaway
# directory, then integrity checks. Prints counts only, never a secret.
#
# Usage: RESTIC_REPOSITORY=... RESTIC_PASSWORD=... AWS_ACCESS_KEY_ID=... \
#        AWS_SECRET_ACCESS_KEY=... scripts/restic-drill.sh <app> [sample]
# The caller exports the variables (read-only R2 key, password from Doppler
# cluster/prd RESTIC_BACKUP_PASSWORD); this script reads the repository with
# --no-lock and never writes to it. Needs restic and pg_restore.
set -euo pipefail

app="${1:?usage: restic-drill.sh <app> [sample]}"
sample="${2:-50}"
# Defaults match the CronJobs (sources under /, manifest at /manifest);
# overridable only so the script can be tested against a local repository.
files_root="${FILES_ROOT:-}"
manifest_path="${MANIFEST_PATH:-/manifest/SHA256SUMS}"
: "${RESTIC_REPOSITORY:?}" "${RESTIC_PASSWORD:?}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }

for tag in "$app-postgres" "$app-files"; do
  id="$(restic snapshots --no-lock --json --latest 1 --tag "$tag" | grep -o '"short_id":"[0-9a-f]*"' | head -n 1 | cut -d '"' -f 4)"
  [ -n "$id" ] || { echo "FAIL tag=$tag snapshot=none"; exit 1; }
  echo "tag=$tag snapshot=$id"
done

# 1. PostgreSQL dump: restore, then list its table of contents.
restic restore --no-lock --quiet latest --tag "$app-postgres" --target "$tmp/pg"
dump="$(find "$tmp/pg" -type f -name "$app-postgres.dump")"
[ -s "$dump" ] || { echo "FAIL postgres dump missing or empty"; exit 1; }
entries="$(pg_restore --list "$dump" | grep -vc '^;')"
tables="$(pg_restore --list "$dump" | grep -c ' TABLE DATA ')"
echo "postgres: dump_bytes=$(wc -c <"$dump" | tr -d ' ') toc_entries=$entries table_data=$tables PASS"

# 2. Files: restore the manifest, then verify a random sample (all if the
# manifest is smaller than the sample) restored from the snapshot.
restic restore --no-lock --quiet latest --tag "$app-files" --target "$tmp/files" --include "$manifest_path"
manifest="$(find "$tmp/files" -type f -name SHA256SUMS)"
total="$(wc -l <"$manifest" | tr -d ' ')"
[ "$total" -gt 0 ] || { echo "FAIL manifest empty"; exit 1; }
sort -R "$manifest" | head -n "$sample" >"$tmp/sample"
checked=0
while IFS= read -r line; do
  path="${line#*  }"
  restic restore --no-lock --quiet latest --tag "$app-files" --target "$tmp/files" --include "$files_root/$path"
done <"$tmp/sample"
(cd "$tmp/files$files_root" && sha -c --strict --quiet "$tmp/sample") || { echo "FAIL checksum mismatch"; exit 1; }
checked="$(wc -l <"$tmp/sample" | tr -d ' ')"
echo "files: manifest_entries=$total verified=$checked PASS"
