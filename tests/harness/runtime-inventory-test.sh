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

# The real script, reading only through an injected fake kubectl-ro.sh.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
mkdir -p "$tmp/bin"
cat >"$tmp/bin/kubectl" <<'SH'
#!/usr/bin/env bash
echo "DIRECT_KUBECTL $*" >&2
exit 99
SH
cat >"$tmp/kubectl-ro.sh" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "get applications.argoproj.io -n argocd -o json")
    echo '{"items":[{"metadata":{"name":"a"},"status":{"sync":{"status":"Synced"},"health":{"status":"Healthy"}}},{"metadata":{"name":"b"},"status":{"sync":{"status":"OutOfSync"},"health":{"status":"Degraded"}}}]}' ;;
  "get gateways.gateway.networking.k8s.io -A -o json")
    echo '{"items":[{"status":{"conditions":[{"type":"Programmed","status":"True"}]}}]}' ;;
  "get httproutes.gateway.networking.k8s.io -A -o json")
    echo '{"items":[{"status":{"parents":[{"conditions":[{"type":"Accepted","status":"False"}]}]}}]}' ;;
  "get pods -A -o json") cat "$INVENTORY_PODS" ;;
  "get pvc -A -o json") echo '{"items":[{"status":{"phase":"Bound"}},{"status":{"phase":"Pending"}}]}' ;;
  "get externalsecrets.external-secrets.io -A -o json") echo '{"items":[]}' ;;
  "get clusters.postgresql.cnpg.io -A -o json") exit 1 ;;
  *) echo "unexpected kubectl-ro call: $*" >&2; exit 1 ;;
esac
SH
chmod +x "$tmp/bin/kubectl" "$tmp/kubectl-ro.sh"
inventory="$(PATH="$tmp/bin:$PATH" INVENTORY_PODS="$tmp/pods.json" KUBECTL_RO_SCRIPT="$tmp/kubectl-ro.sh" \
  bash "$repo_root/scripts/runtime-inventory.sh")"
jq -e '
  .argo.total == 2 and .argo.outOfSync == 1 and .argo.degraded == 1 and
  .gateways.programmed == 1 and .routes.rejected == 1 and
  .workloads.pods == 6 and .workloads.notReady == 3 and
  .storage.pending == 1 and .externalSecrets.total == 0 and .cnpg.total == 0
' <<<"$inventory" >/dev/null || {
  printf 'ASSERTION_FAILED inventory=%s\n' "$inventory" >&2
  exit 1
}

printf '%s\n' 'RUNTIME_INVENTORY_KRO_TEST=PASS'
