#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
selector="$repo_root/scripts/select-v1-contract-roots.sh"

assert_scope() {
  local expected="$1" files="$2" actual
  actual="$(V1_CHANGED_FILES="$files" bash "$selector")"
  [[ "$actual" == "$expected" ]] || {
    echo "expected scope $expected, got $actual for $files" >&2
    exit 1
  }
}

assert_scope 'k8s/infrastructure/network/policies/auth,k8s/optional/sparkyfitness' $'k8s/optional/sparkyfitness/networkpolicy.yaml\nk8s/infrastructure/network/policies/auth/allow-authentik-access.yaml'
assert_scope 'k8s/applications/media' 'k8s/applications/media/polyfin/networkpolicy.yaml'
assert_scope all 'k8s/infrastructure/controllers/argocd/kustomization.yaml'
assert_scope all 'docs/unknown-scope.md'
assert_scope all ''

missing_ref_scope="$(GITHUB_EVENT_NAME=pull_request GITHUB_BASE_SHA=missing GITHUB_HEAD_SHA=missing bash "$selector")"
[[ "$missing_ref_scope" == all ]] || { echo 'missing GitHub refs must fail closed to all' >&2; exit 1; }

if V1_CHANGED_FILES='k8s/optional/does-not-exist/file.yaml' V1_CONTRACT_ROOTS='k8s/optional/does-not-exist' bash "$repo_root/scripts/check-v1-active-contract.sh" >/dev/null 2>&1; then
  echo 'unknown render root must fail closed' >&2
  exit 1
fi

echo 'V1_CONTRACT_SCOPE_TEST=PASS'
