#!/usr/bin/env bash
# Advisory check: WARN when GitHub Actions runs stay queued longer than
# QUEUED_MAX_MINUTES (default 15). Never fails; missing gh/jq/auth is a WARN.
set -uo pipefail

max_minutes="${QUEUED_MAX_MINUTES:-15}"

for cmd in gh jq; do
  command -v "$cmd" >/dev/null || { echo "WARN: $cmd absent, queued-runs check skipped"; exit 0; }
done

if ! runs="$(gh run list --status queued --limit 100 --json databaseId,workflowName,createdAt 2>/dev/null)" ||
  ! jq -e 'type == "array"' >/dev/null <<<"$runs"; then
  echo "WARN: gh run list indisponible, queued-runs check skipped"
  exit 0
fi

now="$(date -u +%s)"
stale="$(jq -r --argjson now "$now" --argjson max "$max_minutes" '
  [.[] | select(($now - (.createdAt | fromdateiso8601)) > ($max * 60))]
  | .[] | "\(.databaseId)\t\(.workflowName)\t\(.createdAt)"' <<<"$runs")"

if [[ -n "$stale" ]]; then
  count="$(wc -l <<<"$stale" | tr -d ' ')"
  echo "WARN: $count run(s) GitHub Actions en file depuis plus de ${max_minutes} min"
  printf '%s\n' "$stale"
else
  echo "OK: aucun run GitHub Actions en file depuis plus de ${max_minutes} min"
fi
exit 0
