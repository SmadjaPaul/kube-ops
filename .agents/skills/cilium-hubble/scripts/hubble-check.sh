#!/usr/bin/env bash
# Usage: hubble-check.sh <namespace> [namespace2 ...]
# Checks for Cilium-dropped flows in one or more namespaces via Hubble relay.
# Verifies connectivity before trusting empty DROPPED results.
#
# Every call goes through `scripts/kubectl-ro.sh hubble` (PRD-88): agent identity
# agent-operator, tunnel to kube-system/hubble-relay only, filters allowlisted.
# This script runs no kubectl itself and reads no resource and no Secret.

set -euo pipefail

NAMESPACES=("$@")
if [[ ${#NAMESPACES[@]} -eq 0 ]]; then
  echo "Usage: hubble-check.sh <namespace> [namespace2 ...]" >&2
  exit 1
fi
for ns in "${NAMESPACES[@]}"; do
  [[ $ns =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || {
    echo "hubble-check: invalid namespace '$ns'" >&2
    exit 2
  }
done
command -v hubble >/dev/null || {
  echo "hubble-check: hubble required" >&2
  exit 2
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
KRO="$ROOT/scripts/kubectl-ro.sh"
# One preflight for every call (scripts/lib/kube-read.sh); removed on exit.
SESSION_PARENT="$(mktemp -d "${TMPDIR:-/tmp}/hubble-check.XXXXXX")"
trap 'rm -rf "$SESSION_PARENT"' EXIT
# shellcheck source=../../../../scripts/lib/kube-read.sh
source "$ROOT/scripts/lib/kube-read.sh"
kro_session_begin "$SESSION_PARENT"

# Sanity check: confirm Hubble is reachable and returning flows
echo "=== Hubble status ==="
bash "$KRO" hubble status 2>&1

for NS in "${NAMESPACES[@]}"; do
  echo ""
  echo "=== Dropped flows: $NS ==="
  bash "$KRO" hubble observe --namespace "$NS" --verdict DROPPED --last 100 2>&1

  echo ""
  echo "=== Recent flows (sanity check): $NS ==="
  bash "$KRO" hubble observe --namespace "$NS" --last 5 2>&1
done
