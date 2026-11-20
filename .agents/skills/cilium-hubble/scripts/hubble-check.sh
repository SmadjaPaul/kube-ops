#!/usr/bin/env bash
# Usage: hubble-check.sh <namespace> [namespace2 ...]
# Checks for Cilium-dropped flows in one or more namespaces via Hubble relay.
# Verifies connectivity before trusting empty DROPPED results.
#
# Cluster access goes through scripts/lib/kube-preflight.sh (canonical kubeconfig
# from Doppler, SHA-256 and TLS checked, removed on exit). A port-forward is not a
# verb of scripts/kubectl-ro.sh, so this is the one investigation script that runs
# kubectl itself: it opens a tunnel and reads no resource and no Secret.

set -euo pipefail

NAMESPACES=("$@")
if [[ ${#NAMESPACES[@]} -eq 0 ]]; then
  echo "Usage: hubble-check.sh <namespace> [namespace2 ...]" >&2
  exit 1
fi
for ns in "${NAMESPACES[@]}"; do
  [[ $ns =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || { echo "hubble-check: invalid namespace '$ns'" >&2; exit 2; }
done
for t in kubectl jq hubble; do command -v "$t" >/dev/null || { echo "hubble-check: $t required" >&2; exit 2; }; done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
# shellcheck source=../../../../scripts/lib/kube-preflight.sh
source "$ROOT/scripts/lib/kube-preflight.sh"
require_kube_access_quiet || exit 2

HUBBLE_PORT=4245
RELAY_SVC=hubble-relay
RELAY_NS=kube-system
PF_LOG="$(mktemp "${TMPDIR:-/tmp}/hubble-pf.XXXXXX")"

# Start port-forward (the preflight kubeconfig is exported in KUBECONFIG)
kubectl -n "$RELAY_NS" port-forward "svc/$RELAY_SVC" "${HUBBLE_PORT}:80" &>"$PF_LOG" &
PF_PID=$!
# Keep the preflight cleanup (kubeconfig removal) in the exit trap.
trap 'kill $PF_PID 2>/dev/null || true; rm -f "$PF_LOG"; kube_access_cleanup' EXIT
trap 'exit 130' INT TERM

sleep 3

# Sanity check: confirm Hubble is reachable and returning flows
echo "=== Hubble status ==="
hubble --server "localhost:${HUBBLE_PORT}" status 2>&1

for NS in "${NAMESPACES[@]}"; do
  echo ""
  echo "=== Dropped flows: $NS ==="
  hubble --server "localhost:${HUBBLE_PORT}" observe --namespace "$NS" --verdict DROPPED --last 100 2>&1

  echo ""
  echo "=== Recent flows (sanity check): $NS ==="
  hubble --server "localhost:${HUBBLE_PORT}" observe --namespace "$NS" --last 5 2>&1
done
