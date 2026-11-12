#!/usr/bin/env bash
# Shared OUTPUT=summary|errors|full handling for diagnostic scripts.
# Direct script callers (tests, CI) get "full" when OUTPUT is unset; the just
# recipes pass OUTPUT=summary by default. Never print secret values.
resolve_output_mode() {
  local mode="${1:-${OUTPUT:-full}}"
  case "$mode" in
    summary|errors|full) printf '%s\n' "$mode" ;;
    *) echo "ERROR: OUTPUT must be summary|errors|full (got: $mode)" >&2; return 2 ;;
  esac
}

# Create a private (0600) evidence file outside the repo.
evidence_file() {
  local f
  f="$(umask 077; mktemp "${TMPDIR:-/tmp}/kube-ops-$1.XXXXXX")"
  chmod 600 "$f"
  printf '%s\n' "$f"
}

# One-line, bounded, redacted message for LAST_ERROR.
sanitize_line() {
  tr '\r\n\t' '   ' | sed -E 's/((token|password|passwd|secret|apikey|api_key|authorization|bearer)[A-Za-z_-]*[=: ]+)[^ ,;"]+/\1<redacted>/Ig' | cut -c1-200
}

# Redact secret-looking values in multi-line output (errors mode).
sanitize_line_block() {
  sed -E 's/((token|password|passwd|secret|apikey|api_key|authorization|bearer)[A-Za-z_-]*[=: ]+)[^ ,;"]+/\1<redacted>/Ig'
}
