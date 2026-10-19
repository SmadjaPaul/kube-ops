#!/usr/bin/env bash
# Narrow wrapper for the non-CNPG portion of one synthetic DR drill.
#
# The deletion engine remains scripts/dr-synth-cleanup.sh. This wrapper pins
# that engine and rejects any manifest that could reach CNPG namespaces or
# CNPG-owned storage.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
engine="$repo_root/scripts/dr-synth-cleanup.sh"
manifest="$repo_root/docs/operations/dr-synth-partial-cleanup-manifest-2026-10-19.json"
expected_engine_sha="f90f034e3ce7ae9e88ee400d43f765138933e98a682f4f5914470565ae01306a"

die() {
  printf 'DR_PARTIAL_CLEANUP=BLOCKED\nREASON=%s\n' "$*" >&2
  exit 1
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

[[ -s "$manifest" ]] || die "manifest missing: $manifest"
if [[ -n "${DR_CLEANUP_MANIFEST:-}" && "$DR_CLEANUP_MANIFEST" != "$manifest" ]]; then
  die "manifest override is not allowed through the pinned wrapper"
fi
[[ -x "$engine" ]] || die "cleanup engine missing or not executable: $engine"
command -v jq >/dev/null 2>&1 || die "jq is required"

[[ "$(sha256_file "$engine")" == "$expected_engine_sha" ]] || \
  die "cleanup engine digest mismatch"

jq -e '.scope == "partial-non-cnpg"' "$manifest" >/dev/null || \
  die "manifest scope is not partial-non-cnpg"
jq -e '([.namespaces[].name] | any(test("-cnpg-"))) | not' "$manifest" >/dev/null || \
  die "CNPG namespace present in partial manifest"
jq -e '([.pvs[].claimRef.namespace] | any(test("-cnpg-"))) | not' "$manifest" >/dev/null || \
  die "CNPG claimRef present in partial manifest"
jq -e 'all(.configMaps[]; .namespace == "velero")' "$manifest" >/dev/null || \
  die "non-Velero ConfigMap present in partial manifest"
jq -e '([.namespaces[].name] | sort) == [
  "dr-synth-20261019170700-stop",
  "dr-synth-20261019170700-velero-src",
  "dr-synth-20261019170700-velero-tgt",
  "dr-synth-20261019170700-velero-tgt-v2"
] | not' "$manifest" >/dev/null && die "unexpected namespace set"
jq -e '([.excludedNamespaces[].name] | sort) == [
  "dr-synth-20261019170700-cnpg-src",
  "dr-synth-20261019170700-cnpg-tgt"
]' "$manifest" >/dev/null || die "CNPG exclusion set is incomplete"

for arg in "$@"; do
  case "$arg" in
    --manifest|--manifest=*) die "manifest override is not allowed through the pinned wrapper" ;;
  esac
done

cd "$repo_root"
exec "$engine" "$@" --manifest "$manifest"
