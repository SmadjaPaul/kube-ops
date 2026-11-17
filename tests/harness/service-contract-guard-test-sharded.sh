#!/usr/bin/env bash
# Self-test de la garde service-contract en shards paralleles : chaque shard execute un sous-ensemble
# des cas (service-contract-guard-test.sh, SC_SHARDS/SC_SHARD), dans son propre depot temporaire.
# Echec si un shard echoue. Nombre de shards : SC_SHARDS ou nombre de coeurs (plafond 4).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
n="${SC_SHARDS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)}"
if [ "$n" -gt 4 ]; then n=4; fi
logdir="$(mktemp -d)"
trap 'rm -rf "$logdir"' EXIT
pids=()
for ((k = 0; k < n; k++)); do
  SC_SHARDS="$n" SC_SHARD="$k" bash "$here/service-contract-guard-test.sh" > "$logdir/$k.log" 2>&1 &
  pids+=("$!")
done
rc=0
for ((k = 0; k < n; k++)); do
  if ! wait "${pids[$k]}"; then rc=1; fi
  echo "===== shard $k/$n ====="
  cat "$logdir/$k.log"
done
if [ "$rc" -eq 0 ]; then echo "SERVICE_CONTRACT_GUARD_TEST_SHARDED=PASS ($n shards)"; else echo "SERVICE_CONTRACT_GUARD_TEST_SHARDED=FAIL"; fi
exit "$rc"
