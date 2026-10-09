#!/usr/bin/env bash

set -euo pipefail

tmp="$(mktemp -d "${TMPDIR:-/tmp}/runtime-inventory-harness.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

cat >"$tmp/pods.json" <<'JSON'
{
  "items": [
    {"status":{"phase":"Running","containerStatuses":[{"ready":true}]}},
    {"status":{"phase":"Running","containerStatuses":[{"ready":false}]}},
    {"status":{"phase":"Running","containerStatuses":[]}},
    {"status":{"phase":"Pending","containerStatuses":[]}},
    {"status":{"phase":"Succeeded","containerStatuses":[{"ready":false}]}},
    {"status":{"phase":"Failed","containerStatuses":[{"ready":false}]}}
  ]
}
JSON

actual="$(jq -c '
  {
    notReady: ([.items[] | select(
      .status.phase == "Pending" or
      (.status.phase == "Running" and (
        ((.status.containerStatuses // []) | length) == 0 or
        any(.status.containerStatuses[]?; .ready != true)
      ))
    )] | length),
    pending: ([.items[] | select(.status.phase == "Pending")]|length),
    failed: ([.items[] | select(.status.phase == "Failed")]|length),
    succeeded: ([.items[] | select(.status.phase == "Succeeded")]|length)
  }
' "$tmp/pods.json")"

expected='{"notReady":3,"pending":1,"failed":1,"succeeded":1}'
[[ "$actual" == "$expected" ]] || {
  printf 'ASSERTION_FAILED expected=%s actual=%s\n' "$expected" "$actual" >&2
  exit 1
}

printf '%s\n' 'RUNTIME_INVENTORY_PHASE_TEST=PASS'
