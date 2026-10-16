#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/runtime-smoke-harness.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/artifacts"

cat >"$tmp/routes.json" <<'JSON'
{
  "items": [
    {
      "metadata": {"namespace": "smoke", "name": "active-healthy", "ownerReferences": [{"apiVersion": "openclaw.rocks/v1alpha1", "kind": "OpenClawInstance", "uid": "active-healthy"}]},
      "spec": {"parentRefs": [{"name": "internal"}], "hostnames": ["active-healthy.example.test"], "rules": [{"backendRefs": [{"name": "active-healthy"}]}]},
      "status": {"parents": [{"parentRef": {"name": "internal"}, "conditions": [{"type": "Accepted", "status": "True"}, {"type": "ResolvedRefs", "status": "True"}]}]}
    },
    {
      "metadata": {"namespace": "smoke", "name": "active-no-endpoint", "ownerReferences": [{"apiVersion": "openclaw.rocks/v1alpha1", "kind": "OpenClawInstance", "uid": "active-no-endpoint"}]},
      "spec": {"parentRefs": [{"name": "internal"}], "hostnames": ["active-no-endpoint.example.test"], "rules": [{"backendRefs": [{"name": "active-no-endpoint"}]}]},
      "status": {"parents": [{"parentRef": {"name": "internal"}, "conditions": [{"type": "Accepted", "status": "True"}, {"type": "ResolvedRefs", "status": "True"}]}]}
    },
    {
      "metadata": {"namespace": "smoke", "name": "suspended-by-spec", "ownerReferences": [{"apiVersion": "openclaw.rocks/v1alpha1", "kind": "OpenClawInstance", "uid": "suspended-by-spec"}]},
      "spec": {"parentRefs": [{"name": "internal"}], "hostnames": ["suspended-by-spec.example.test"], "rules": [{"backendRefs": [{"name": "suspended-by-spec"}]}]},
      "status": {"parents": [{"parentRef": {"name": "internal"}, "conditions": [{"type": "Accepted", "status": "True"}, {"type": "ResolvedRefs", "status": "True"}]}]}
    },
    {
      "metadata": {"namespace": "smoke", "name": "suspended-by-phase", "ownerReferences": [{"apiVersion": "openclaw.rocks/v1alpha1", "kind": "OpenClawInstance", "uid": "suspended-by-phase"}]},
      "spec": {"parentRefs": [{"name": "internal"}], "hostnames": ["suspended-by-phase.example.test"], "rules": [{"backendRefs": [{"name": "suspended-by-phase"}]}]},
      "status": {"parents": [{"parentRef": {"name": "internal"}, "conditions": [{"type": "Accepted", "status": "True"}, {"type": "ResolvedRefs", "status": "True"}]}]}
    },
    {
      "metadata": {"namespace": "smoke", "name": "absent-indeterminate", "ownerReferences": [{"apiVersion": "openclaw.rocks/v1alpha1", "kind": "OpenClawInstance", "uid": "missing"}]},
      "spec": {"parentRefs": [{"name": "internal"}], "hostnames": ["absent-indeterminate.example.test"], "rules": [{"backendRefs": [{"name": "absent-indeterminate"}]}]},
      "status": {"parents": [{"parentRef": {"name": "internal"}, "conditions": [{"type": "Accepted", "status": "True"}, {"type": "ResolvedRefs", "status": "True"}]}]}
    },
    {
      "metadata": {"namespace": "smoke", "name": "resumed", "ownerReferences": [{"apiVersion": "openclaw.rocks/v1alpha1", "kind": "OpenClawInstance", "uid": "resumed"}]},
      "spec": {"parentRefs": [{"name": "internal"}], "hostnames": ["resumed.example.test"], "rules": [{"backendRefs": [{"name": "resumed"}]}]},
      "status": {"parents": [{"parentRef": {"name": "internal"}, "conditions": [{"type": "Accepted", "status": "True"}, {"type": "ResolvedRefs", "status": "True"}]}]}
    }
  ]
}
JSON

cat >"$tmp/openclawinstances.json" <<'JSON'
{
  "items": [
    {"metadata": {"uid": "active-healthy"}, "spec": {"suspended": false}, "status": {"phase": "Running"}},
    {"metadata": {"uid": "active-no-endpoint"}, "spec": {"suspended": false}, "status": {"phase": "Running"}},
    {"metadata": {"uid": "suspended-by-spec"}, "spec": {"suspended": true}, "status": {"phase": "Running"}},
    {"metadata": {"uid": "suspended-by-phase"}, "spec": {"suspended": false}, "status": {"phase": "Suspended"}},
    {"metadata": {"uid": "resumed"}, "spec": {"suspended": false}, "status": {"phase": "Running"}}
  ]
}
JSON

cat >"$tmp/interceptorroutes.json" <<'JSON'
{
  "items": [
    {"spec": {"rules": [{"hosts": ["active-healthy.example.test"]}]}}
  ]
}
JSON

cat >"$tmp/bin/kubectl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

args="$*"
case "$args" in
  config\ view\ *)
    if [[ "$args" == *jsonpath* ]]; then
      printf '%s\n' 'https://operator.example.test'
    else
      printf '{}\n'
    fi
    ;;
  *'get --raw=/version'*)
    printf '%s\n' '{"gitVersion":"v1.36.3"}'
    ;;
  *'get namespace/default'*)
    printf '%s\n' 'namespace/default'
    ;;
  *'get openclawinstances.openclaw.rocks -A -o json'*)
    cat "$SMOKE_FIXTURE_DIR/openclawinstances.json"
    ;;
  *'get interceptorroutes -A -o json'*)
    cat "$SMOKE_FIXTURE_DIR/interceptorroutes.json"
    ;;
  *'get httproutes.gateway.networking.k8s.io -A -o json'*)
    cat "$SMOKE_FIXTURE_DIR/routes.json"
    ;;
  *'get endpointslices.discovery.k8s.io'*)
    service="${args##*kubernetes.io/service-name=}"
    service="${service%% *}"
    case "$service" in
      active-healthy|resumed)
        printf '%s\n' '{"items":[{"endpoints":[{"conditions":{"ready":true}}]}]}'
        ;;
      *)
        printf '%s\n' '{"items":[]}'
        ;;
    esac
    ;;
  *)
    printf 'unexpected kubectl call: %s\n' "$args" >&2
    exit 1
    ;;
esac
SH

cat >"$tmp/bin/dig" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '10.0.20.192'
SH

cat >"$tmp/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$SMOKE_CURL_LOG"
case "$*" in
  *active-healthy.example.test*)
    if ! grep -q 'KEDA_WARMUP_MARKER' "$SMOKE_CURL_LOG"; then
      printf '%s\n' 'KEDA_WARMUP_MARKER' >>"$SMOKE_CURL_LOG"
      printf '000\n'
    else
      printf '200\n'
    fi
    ;;
  *resumed.example.test*) printf '200\n' ;;
  *) printf '503\n' ;;
esac
SH

chmod +x "$tmp/bin/kubectl" "$tmp/bin/dig" "$tmp/bin/curl"
: >"$tmp/kubeconfig"
: >"$tmp/curl.log"
output=""
status=0
if output="$(
  PATH="$tmp/bin:$PATH" \
    SMOKE_FIXTURE_DIR="$tmp" \
    SMOKE_CURL_LOG="$tmp/curl.log" \
    KUBE_ACCESS_BOOTSTRAP=never \
    KUBECONFIG="$tmp/kubeconfig" \
    KEDA_WAKE_RETRY_DELAY_SECONDS=0 \
    ARTIFACT_DIR="$tmp/artifacts" \
    "$repo_root/scripts/runtime-smoke.sh"
)"; then
  status=0
else
  status=$?
fi

[[ "$status" -ne 0 ]] || { printf 'expected active failures in fixture\n%s\n' "$output" >&2; exit 1; }
[[ "$output" == *'RUNTIME_SMOKE_TESTED=4'* ]] || { printf '%s\n' "$output" >&2; exit 1; }
[[ "$output" == *'RUNTIME_SMOKE_FAILURES=2'* ]] || { printf '%s\n' "$output" >&2; exit 1; }
[[ "$output" == *'RUNTIME_SMOKE_SKIPPED_DISABLED_BY_DESIGN=2'* ]] || { printf '%s\n' "$output" >&2; exit 1; }

report="$tmp/artifacts/results.jsonl"
[[ "$(jq -s 'length' "$report")" == 6 ]] || exit 1
[[ "$(jq -s '[.[] | select(.result == "PASS")] | length' "$report")" == 2 ]] || exit 1
[[ "$(jq -s '[.[] | select(.result == "FAIL")] | length' "$report")" == 2 ]] || exit 1
[[ "$(jq -s '[.[] | select(.result == "SKIPPED_DISABLED_BY_DESIGN")] | length' "$report")" == 2 ]] || exit 1
[[ "$(jq -s '[.[] | select(.route == "active-no-endpoint" and .result == "FAIL" and (.reasons | contains("no-ready-endpoint")))] | length' "$report")" == 1 ]] || exit 1
[[ "$(jq -s '[.[] | select(.route == "absent-indeterminate" and .result == "FAIL")] | length' "$report")" == 1 ]] || exit 1
[[ "$(jq -s '[.[] | select(.route == "resumed" and .result == "PASS")] | length' "$report")" == 1 ]] || exit 1
[[ "$(jq -s '[.[] | select(.route == "active-healthy" and .result == "PASS" and .kedaManaged == true and .httpAttempts == 2)] | length' "$report")" == 1 ]] || exit 1
if grep -q 'suspended-by-' "$tmp/curl.log"; then
  printf 'suspended routes must not be probed\n' >&2
  exit 1
fi

printf '%s\n' 'RUNTIME_SMOKE_SUSPENSION_TEST=PASS'
