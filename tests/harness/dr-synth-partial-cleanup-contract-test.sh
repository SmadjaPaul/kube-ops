#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
wrapper="$repo_root/scripts/dr-synth-partial-cleanup.sh"
manifest="$repo_root/docs/operations/dr-synth-partial-cleanup-manifest-2026-10-19.json"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

[[ -x "$wrapper" ]]
jq empty "$manifest"
jq -e '.scope == "partial-non-cnpg"' "$manifest" >/dev/null
jq -e '([.namespaces[].name] | any(test("-cnpg-"))) | not' "$manifest" >/dev/null
jq -e '([.pvs[].claimRef.namespace] | any(test("-cnpg-"))) | not' "$manifest" >/dev/null
jq -e 'all(.configMaps[]; .namespace == "velero")' "$manifest" >/dev/null

if DR_CLEANUP_MANIFEST="$tmp/other.json" "$wrapper" --dry-run >"$tmp/override.out" 2>"$tmp/override.err"; then
  echo "expected partial wrapper rejection for manifest override" >&2
  exit 1
fi
grep -F 'manifest override is not allowed' "$tmp/override.err" >/dev/null

echo "dr-synth-partial-cleanup scope contract: PASS"
