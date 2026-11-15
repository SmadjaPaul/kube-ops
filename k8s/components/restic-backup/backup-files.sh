#!/bin/sh
# PLT-286: step 2 of a cycle, after the dump. Backs up the read-only source
# mounts and a SHA-256 manifest of every file (SHA256SUMS, relative to /,
# checkable with `sha256sum -c` from the restore target).
# The manifest is incremental: a file whose size and mtime match the previous
# snapshot's INDEX.tsv keeps its hash, so a cycle reads only new or changed
# files. Nothing is written to a disk: /manifest and the work files live in
# memory-backed emptyDirs.
# Environment: SOURCES (absolute directories), EXCLUDES (absolute paths,
# optional), MANIFEST_DIR, WORK_DIR.
set -eu

restic_bin="${RESTIC_BIN:-restic}"
# shellcheck source=/dev/null # restic-lib.sh, mounted next to this script
. "${SCRIPTS_DIR:-/scripts}/restic-lib.sh"

: "${SOURCES:?SOURCES is required}"
manifest_dir="${MANIFEST_DIR:-/manifest}"
work="${WORK_DIR:-/tmp/work}"
root="${SOURCE_ROOT:-/}"
root="${root%/}/"
tab="$(printf '\t')"
nl='
'

mkdir -p "$work" "$manifest_dir"
ensure_repository

# 1. Current files: size<TAB>mtime<TAB>path, path relative to the root.
: >"$work/current.tsv"
for src in $SOURCES; do
  test -d "$src" || {
    log "source=$src missing"
    exit 1
  }
  set --
  for ex in ${EXCLUDES:-}; do
    case "$ex" in "$src"/*) set -- "$@" -path "${ex#"$root"}" -prune -o ;; esac
  done
  (cd "$root" && find "${src#"$root"}" "$@" -type f ! -name "*$nl*" \
    -exec stat -c "%s$tab%Y$tab%n" {} +) >>"$work/current.tsv"
  if (cd "$root" && find "${src#"$root"}" -type f -name "*$nl*" | grep -q .); then
    log "source=$src warning=file-names-with-newline-not-in-manifest"
  fi
done

# 2. Previous index (absent on the first cycle: every file is hashed).
"$restic_bin" dump --host "$RESTIC_HOST" --tag "${APP}-files" latest \
  "$manifest_dir/INDEX.tsv" >"$work/previous.tsv" 2>/dev/null || : >"$work/previous.tsv"

# 3. Reuse unchanged hashes; list the files to hash.
awk -F '\t' -v OFS='\t' -v known="$work/known.tsv" -v tohash="$work/tohash.tsv" '
  FILENAME == ARGV[1] {
    p = $0; sub(/^[^\t]*\t[^\t]*\t[^\t]*\t/, "", p)
    hash[p] = $1; size[p] = $2; mtime[p] = $3; next
  }
  {
    p = $0; sub(/^[^\t]*\t[^\t]*\t/, "", p)
    if ((p in hash) && size[p] == $1 && mtime[p] == $2) { print hash[p], $1, $2, p > known }
    else { print $1, $2, p > tohash }
  }
' "$work/previous.tsv" "$work/current.tsv"
touch "$work/known.tsv" "$work/tohash.tsv"

# 4. Hash new or changed files (paths without newline, see step 1).
cut -f 3- "$work/tohash.tsv" | tr '\n' '\0' |
  (cd "$root" && xargs -0 -r sha256sum) >"$work/hashed.txt"
awk -F '\t' -v OFS='\t' '
  FILENAME == ARGV[1] { h = substr($0, 1, 64); p = substr($0, 67); sum[p] = h; next }
  {
    p = $0; sub(/^[^\t]*\t[^\t]*\t/, "", p)
    if (!(p in sum)) { print "missing hash for a listed file" > "/dev/stderr"; exit 1 }
    print sum[p], $1, $2, p
  }
' "$work/hashed.txt" "$work/tohash.tsv" >>"$work/known.tsv"

# 5. Publish the manifest next to the data in the same snapshot.
LC_ALL=C sort -t "$tab" -k 4 "$work/known.tsv" >"$manifest_dir/INDEX.tsv"
awk -F '\t' '{ p = $0; sub(/^[^\t]*\t[^\t]*\t[^\t]*\t/, "", p); print $1 "  " p }' \
  "$manifest_dir/INDEX.tsv" >"$manifest_dir/SHA256SUMS"
log "step=manifest files=$(wc -l <"$manifest_dir/INDEX.tsv" | tr -d " ") hashed=$(wc -l <"$work/tohash.tsv" | tr -d " ")"

# 6. Files snapshot. A partial snapshot (exit 3, unreadable file) fails the job.
set --
for ex in ${EXCLUDES:-}; do set -- "$@" --exclude "$ex"; done
log "step=files tag=${APP}-files start"
# shellcheck disable=SC2086 # SOURCES is a list of directories without spaces
run_throttled "$restic_bin" backup \
  --limit-upload "${LIMIT_UPLOAD_KIB:-4096}" \
  --host "$RESTIC_HOST" \
  --tag "${APP}-files" \
  --retry-lock 30m \
  --read-concurrency 1 \
  "$@" $SOURCES "$manifest_dir"
log "step=files tag=${APP}-files done"
