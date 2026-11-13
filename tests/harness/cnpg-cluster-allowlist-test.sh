#!/usr/bin/env bash
# PLT-267: every CNPG Cluster in k8s/ must be listed in
# docs/operations/cnpg-cluster-inventory.md (shared cluster, written exception
# or consolidation candidate). A new Cluster is refused until a decision lists it.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
inventory="$repo_root/docs/operations/cnpg-cluster-inventory.md"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

list_clusters() {
  find "$repo_root/k8s" \( -name '*.yaml' -o -name '*.yml' \) | LC_ALL=C sort | while IFS= read -r f; do
    awk -v file="${f#"$repo_root"/}" '
      function flush() { if (kind == "Cluster" && api ~ /^postgresql\.cnpg\.io\// && name != "") print name " " file; kind = ""; api = ""; name = ""; inmeta = 0 }
      function val(v) { gsub(/^["\x27]|["\x27]$/, "", v); return v }
      /^---/ { flush(); next }
      /^kind:[ ]/ { kind = val($2) }
      /^apiVersion:[ ]/ { api = val($2) }
      /^metadata:/ { inmeta = 1; next }
      /^[^ #]/ { inmeta = 0 }
      inmeta && /^  name:[ ]/ && name == "" { name = val($2) }
      END { flush() }' "$f"
  done
}

# shellcheck disable=SC2016
declared() {
  sed -n 's/^| `\([^`]*\)` | .*/\1/p' "$inventory" | LC_ALL=C sort
}

# shellcheck disable=SC2016
# exceptions: at most 4 applications (Authentik, Immich, Matrix, Factory)
exc_apps="$(sed -n 's/^| `[^`]*` | \([^|]*\) | exception .*/\1/p' "$inventory" | sed 's/ *$//' | LC_ALL=C sort -u)"
if [ "$(printf '%s\n' "$exc_apps" | grep -c .)" -gt 4 ]; then
  echo "ERROR: more than 4 CNPG exception applications (a 5th needs a decision by Paul):" >&2
  printf '%s\n' "$exc_apps" >&2
  exit 1
fi

list_clusters >"$tmp/found"
declared >"$tmp/declared"
bad=0
while read -r name file; do
  if ! grep -qxF "$name" "$tmp/declared"; then
    echo "ERROR: CNPG Cluster '$name' ($file) is not in docs/operations/cnpg-cluster-inventory.md." >&2
    echo "       New databases go into the shared cluster pg-shared (D-2026-11-13-02); a 5th exception needs Paul's decision." >&2
    bad=1
  fi
done <"$tmp/found"
if [ "$bad" -ne 0 ]; then exit 1; fi
echo "CNPG_CLUSTER_ALLOWLIST=PASS ($(grep -c . "$tmp/found") clusters)"
