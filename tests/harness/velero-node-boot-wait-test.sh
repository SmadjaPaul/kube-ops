#!/usr/bin/env bash
# PLT-505: the velero server waits for a freshly booted node before it starts
# the overdue Schedules.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
values="$repo_root/k8s/infrastructure/controllers/velero/values.yaml"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

init='.initContainers[] | select(.name == "wait-node-boot")'
script="$(yq -r "$init | .command[2]" "$values")"
settle="$(yq -r "$init | .env[] | select(.name == \"NODE_SETTLE_SECONDS\") | .value" "$values")"
test -n "$script"
# Slowest pod observed after the 2026-11-25 boot: Ready at 605 s.
test "$settle" -ge 900

printf '#!/bin/sh\necho "$1" > "%s/slept"\n' "$tmp" >"$tmp/sleep"
chmod +x "$tmp/sleep"

run() { # <uptime> : prints the requested sleep, or "none"
  rm -f "$tmp/slept"
  echo "$1 0.00" >"$tmp/uptime"
  PATH="$tmp:$PATH" UPTIME_FILE="$tmp/uptime" NODE_SETTLE_SECONDS="$settle" \
    sh -ec "$script" >/dev/null
  if [ -f "$tmp/slept" ]; then cat "$tmp/slept"; else echo none; fi
}

test "$(run 125.42)" = "$((settle - 125))"
test "$(run "$settle.00")" = none
test "$(run 86400.10)" = none
echo "VELERO_NODE_BOOT_WAIT_CONTRACT=PASS"
