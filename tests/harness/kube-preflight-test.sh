#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$repo_root/scripts/lib/kube-preflight.sh"

test_tmp="$(mktemp -d "${TMPDIR:-/tmp}/kube-ops-preflight-test.XXXXXX")"
trap 'rm -rf "$test_tmp"; kube_access_cleanup' EXIT

test_kubeconfig="$test_tmp/operator-kubeconfig"
: >"$test_kubeconfig"

fake_digest="$(
  printf '%s' 'https://10.0.20.60:6443' |
    _kube_access_sha256_stream
)"

kubectl() {
  case "${FAKE_KUBECTL_MODE:-pass}:$*" in
    pass:config\ view*) printf '%s' 'https://10.0.20.60:6443' ;;
    pass:*--raw=/version*) printf '%s' '{"gitVersion":"v1.36.3"}' ;;
    pass:*get\ namespace/default*) printf '%s\n' 'namespace/default' ;;
    invalid-context:config\ view*) printf '%s' 'http://localhost:8080' ;;
    invalid-context:*) return 1 ;;
    unreachable:config\ view*) printf '%s' 'https://10.0.20.60:6443' ;;
    unreachable:*--raw=/version*) return 1 ;;
    unreachable:*) return 1 ;;
    *) return 1 ;;
  esac
}

doppler() {
  case "$*" in
    me) return 0 ;;
    "secrets get KUBERNETES_OPERATOR_KUBECONFIG --project infrastructure --config prd --plain")
      printf '%s' 'fake-canonical-kubeconfig'
      ;;
    "secrets get KUBERNETES_OPERATOR_KUBECONFIG_SHA256 --project infrastructure --config prd --plain")
      printf '%s' "$fake_digest"
      ;;
    *) return 1 ;;
  esac
}

assert_contains() {
  local haystack=$1
  local needle=$2
  [[ "$haystack" == *"$needle"* ]] || {
    printf 'ASSERTION_FAILED missing=%s output=%s\n' "$needle" "$haystack" >&2
    exit 1
  }
}

run_case() {
  local mode=$1
  local expected_reason=$2
  local output
  local status=0

  if output="$(
    FAKE_KUBECTL_MODE="$mode" \
      KUBE_ACCESS_BOOTSTRAP=never \
      KUBECONFIG="$test_kubeconfig" \
      require_kube_access 2>&1
  )"; then
    status=0
  else
    status=$?
  fi

  [[ "$status" -eq 2 ]] || {
    printf 'ASSERTION_FAILED mode=%s status=%s\n' "$mode" "$status" >&2
    exit 1
  }
  assert_contains "$output" 'KUBE_ACCESS=BLOCKED'
  assert_contains "$output" "REASON=$expected_reason"
}

saved_kubeconfig="${KUBECONFIG-}"
unset KUBECONFIG
if output="$(KUBE_ACCESS_BOOTSTRAP=never require_kube_access 2>&1)"; then
  status=0
else
  status=$?
fi
KUBECONFIG="$saved_kubeconfig"
export KUBECONFIG
[[ "$status" -eq 2 ]] || {
  printf 'ASSERTION_FAILED missing-kubeconfig status=%s\n' "$status" >&2
  exit 1
}
assert_contains "$output" 'REASON=missing_operator_context'
assert_contains "$output" 'NEXT_ACTION=USE_JUST_KUBE_ACCESS_CHECK_NOT_A_MANUAL_KUBECONFIG'

run_case invalid-context invalid_operator_context
run_case unreachable api_unreachable

pass_output="$(
  FAKE_KUBECTL_MODE=pass \
    KUBE_ACCESS_BOOTSTRAP=never \
    KUBECONFIG="$test_kubeconfig" \
    require_kube_access
)"
assert_contains "$pass_output" 'KUBE_ACCESS=PASS'
assert_contains "$pass_output" 'KUBECONFIG_PRESENT=yes'
assert_contains "$pass_output" 'API_REACHABLE=yes'
assert_contains "$pass_output" 'CLUSTER_VERSION=v1.36.3'

unset KUBECONFIG
auto_output="$(FAKE_KUBECTL_MODE=pass KUBE_ACCESS_BOOTSTRAP=auto require_kube_access)"
assert_contains "$auto_output" 'KUBE_ACCESS=PASS'
assert_contains "$auto_output" 'KUBE_ACCESS_SOURCE=doppler_operator_distribution'
assert_contains "$auto_output" 'CLUSTER_VERSION=v1.36.3'

# Ambient kubeconfigs are not authoritative. Auto mode must replace them with
# the canonical Doppler-distributed operator context rather than trusting them.
printf '%s' 'stale-local-context' >"$test_tmp/stale-kubeconfig"
ambient_output="$(
  FAKE_KUBECTL_MODE=pass \
    KUBE_ACCESS_BOOTSTRAP=auto \
    KUBECONFIG="$test_tmp/stale-kubeconfig" \
    require_kube_access
)"
assert_contains "$ambient_output" 'KUBE_ACCESS=PASS'
assert_contains "$ambient_output" 'KUBE_ACCESS_SOURCE=doppler_operator_distribution'

printf '%s\n' 'KUBE_PREFLIGHT_TEST=PASS'
