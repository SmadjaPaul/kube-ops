#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
arc_root="$repo_root/k8s/optional/github-actions-arc"
infrastructure_project="$repo_root/k8s/bootstrap/argocd-root/infrastructure-project.yaml"
applications_project="$repo_root/k8s/bootstrap/argocd-root/applications-project.yaml"
rendered="$(mktemp)"
cleanup() { rm -f "$rendered"; }
trap cleanup EXIT

kubectl kustomize "$arc_root" >"$rendered"

required_patterns=(
  'name: arc-systems'
  'name: arc-runners'
  'name: arc-github-app'
  'name: infra-arc-controller'
  'name: apps-arc-factory-ci'
  'name: arc-runner-bounds'
  'name: arc-systems-github-egress'
  'name: arc-runners-github-egress'
  'targetRevision: 0.15.0'
  'name: arc-gha-rs-controller'
  'minRunners: 0'
  'maxRunners: 1'
  'automountServiceAccountToken: false'
  'runAsNonRoot: true'
  'image: ghcr.io/actions/actions-runner:2.338.0@sha256:4ffadc0002b2581327e06101fc8c06cd189232baf79fe561fac9caeb76f5e807'
  'pod-security.kubernetes.io/enforce: restricted'
)

for pattern in "${required_patterns[@]}"; do
  rg -F "$pattern" "$rendered" >/dev/null || {
    printf 'ARC_GITOPS_CONTRACT=FAIL missing=%s\n' "$pattern" >&2
    exit 1
  }
done

[[ "$(rg -c '^[[:space:]]+automated:' "$rendered")" == "2" ]] || {
  printf 'ARC_GITOPS_CONTRACT=FAIL child-applications-not-automated\n' >&2
  exit 1
}

for project in "$infrastructure_project" "$applications_project"; do
  rg -F -- '    - ghcr.io/actions/actions-runner-controller-charts' "$project" >/dev/null || {
    printf 'ARC_GITOPS_CONTRACT=FAIL appproject-oci-source-allowlist file=%s\n' "$project" >&2
    exit 1
  }
done

if rg -n 'privileged:\s*true|ACTIONS_RUNNER_REQUIRE_JOB_CONTAINER:\s*false|github_token:|github_app_private_key:\s*\|' "$rendered"; then
  printf 'ARC_GITOPS_CONTRACT=FAIL insecure-or-inline-credential\n' >&2
  exit 1
fi

printf 'ARC_GITOPS_CONTRACT=PASS\n'
