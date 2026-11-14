#!/usr/bin/env bash
# Contract test of scripts/verify-delivery.sh with a fake curl (no network, no token).
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/verify-delivery-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

# Fake curl: answers by the PromQL text found after "query=". Fixtures: $FX_APP, $FX_PODS.
cat >"$tmp/bin/curl" <<'SH'
#!/usr/bin/env bash
q=""
while [[ $# -gt 0 ]]; do
  case "$1" in --data-urlencode) q="$2"; shift 2 ;; *) shift ;; esac
done
cat >/dev/null || true
case "$q" in
  *"timestamp(argocd_app_info"*) cat "$FX_APP" ;;
  *"count(kube_pod_status_ready"*) cat "$FX_ANY" ;;
  *"kube_pod_status_ready"*) cat "$FX_PODS" ;;
  *) echo '{"status":"error"}' ;;
esac
SH
chmod +x "$tmp/bin/curl"

app_json() { # sync health age ns [name]
  printf '{"status":"success","data":{"result":[{"metric":{"name":"%s","sync_status":"%s","health_status":"%s","dest_namespace":"%s"},"value":[1,"%s"]}]}}' "${5:-media}" "$1" "$2" "$4" "$3"
}
pods_json() { # list of ready values
  local first=1 i=0 out='{"status":"success","data":{"result":['
  for v in "$@"; do i=$((i+1)); [[ $first == 1 ]] || out+=','; first=0; out+="{\"metric\":{\"pod\":\"p$i\"},\"value\":[1,\"$v\"]}"; done
  printf '%s]}}' "$out"
}

run() { # expected_exit, then args; env FX_* set by caller
  local want=$1; shift
  set +e
  out=$(PATH="$tmp/bin:$PATH" GRAFANA_AGENT_READ_TOKEN=test-token-never-printed-0123456789 FX_APP="$tmp/app.json" FX_PODS="$tmp/pods.json" FX_ANY="$tmp/any.json" \
    bash "$repo_root/scripts/verify-delivery.sh" "$@" 2>&1)
  got=$?
  set -e
  [[ $got -eq $want ]] || { echo "FAIL: exit $got, want $want for: $*"; echo "$out"; exit 1; }
  [[ $out != *test-token-never-printed* ]] || { echo "FAIL: token printed"; exit 1; }
}
expect() { [[ $out == *"$1"* ]] || { echo "FAIL: output lacks '$1'"; echo "$out"; exit 1; }; }

echo '{"status":"success","data":{"result":[{"metric":{},"value":[1,"40"]}]}}' >"$tmp/any.json"
app_json Synced Healthy 20 media >"$tmp/app.json"; pods_json 1 1 1 >"$tmp/pods.json"
run 0 oracle-a1 media;  expect "VERIFY=PASS"; expect "ARGO=Synced/Healthy"; expect "PODS=3/3"; expect "REVISION=NOT_PROVEN"
run 0 homelab media;    expect "CLUSTER=homelab"

pods_json 1 0 >"$tmp/pods.json"
run 1 oracle-a1 media;  expect "VERIFY=FAIL"; expect "pods not Ready: p2"

pods_json 1 >"$tmp/pods.json"; app_json OutOfSync Healthy 20 media >"$tmp/app.json"
run 1 homelab media;    expect "Argo OutOfSync/Healthy"

app_json Synced Progressing 20 media >"$tmp/app.json"
run 1 homelab media;    expect "Synced/Progressing"

app_json Synced Healthy 900 media >"$tmp/app.json"
run 1 homelab media;    expect "stale sample"

echo '{"status":"success","data":{"result":[]}}' >"$tmp/app.json"
run 1 oracle-a1 nothere; expect "no argocd_app_info series"

app_json Synced Healthy 20 media >"$tmp/app.json"
run 1 oracle-a1 media --since "$(date +%s)"; expect "settling"

app_json Synced Healthy 20 "" >"$tmp/app.json"
run 0 oracle-a1 media;  expect "PODS=n/a"

# Empty namespace is fine when the cluster has pod telemetry; a telemetry gap is FAIL.
app_json Synced Healthy 20 media >"$tmp/app.json"; pods_json >"$tmp/pods.json"
run 0 oracle-a1 media;  expect "PODS=0/0"
echo '{"status":"success","data":{"result":[]}}' >"$tmp/any.json"
run 1 oracle-a1 media;  expect "pod telemetry gap"

echo '{"status":"error"}' >"$tmp/app.json"
run 2 oracle-a1 media;  expect "VERIFY=BLOCKED"

run 2 mars media
run 2 oracle-a1 'x;y'
run 2 oracle-a1

# Doppler failure on the first pass (missing binary): BLOCKED, exit 2.
set +e
out=$(env -u GRAFANA_AGENT_READ_TOKEN -u VERIFY_DELIVERY_INNER DOPPLER_SAFE_BIN=/nonexistent bash "$repo_root/scripts/verify-delivery.sh" oracle-a1 media 2>&1); got=$?
set -e
[[ $got -eq 2 && $out == *"VERIFY=BLOCKED"* ]] || { echo "FAIL: Doppler failure not BLOCKED (exit $got)"; echo "$out"; exit 1; }

# Missing token and Doppler already tried: BLOCKED, never a hang or a PASS.
set +e
out=$(env -u GRAFANA_AGENT_READ_TOKEN VERIFY_DELIVERY_INNER=1 bash "$repo_root/scripts/verify-delivery.sh" oracle-a1 media 2>&1); got=$?
set -e
[[ $got -eq 2 && $out == *"VERIFY=BLOCKED"* ]] || { echo "FAIL: missing token not BLOCKED"; exit 1; }
echo "verify-delivery contract test: PASS"
