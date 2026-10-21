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
  'name: arc-runners-node-npm-egress'
  'targetRevision: 0.15.0'
  'name: arc-gha-rs-controller'
  'minRunners: 0'
  'maxRunners: 3'
  'pod-security.kubernetes.io/enforce: restricted'
  'image: postgres:18-alpine@sha256:77f585114c32fbca283dc835b0596f4e52b51b4c6662d7810b2f4084f60a1873'
)

for pattern in "${required_patterns[@]}"; do
  grep -F -- "$pattern" "$rendered" >/dev/null || {
    printf 'ARC_GITOPS_CONTRACT=FAIL missing=%s\n' "$pattern" >&2
    exit 1
  }
done

assert_yq() {
  local expression=$1 expected=$2 actual
  actual="$(yq eval-all "$expression" "$rendered")"
  [[ "$actual" == "$expected" ]] || {
    printf 'ARC_GITOPS_CONTRACT=FAIL expression=%s expected=%s actual=%s\n' \
      "$expression" "$expected" "$actual" >&2
    exit 1
  }
}

runner_values='select(.kind == "Application" and .metadata.name == "apps-arc-factory-ci") | .spec.source.helm.valuesObject.template.spec'
assert_yq "$runner_values | .automountServiceAccountToken" 'false'
assert_yq "$runner_values | .securityContext.runAsNonRoot" 'true'
assert_yq "$runner_values | .securityContext.runAsUser" '1001'
assert_yq "$runner_values | .securityContext.runAsGroup" '1001'
assert_yq "$runner_values | .securityContext.fsGroup" '1001'
assert_yq "$runner_values | .securityContext.fsGroupChangePolicy" 'OnRootMismatch'
assert_yq "$runner_values | .containers[] | select(.name == \"runner\") | .image" \
  'ghcr.io/actions/actions-runner:2.338.0@sha256:4ffadc0002b2581327e06101fc8c06cd189232baf79fe561fac9caeb76f5e807'
assert_yq "$runner_values | .containers[] | select(.name == \"runner\") | .securityContext.allowPrivilegeEscalation" 'false'
assert_yq "$runner_values | .containers[] | select(.name == \"runner\") | (.securityContext.capabilities.drop | join(\",\"))" 'ALL'
assert_yq "$runner_values | .containers[] | select(.name == \"runner\") | .securityContext.seccompProfile.type" 'RuntimeDefault'
assert_yq "$runner_values | .containers[] | select(.name == \"postgres\") | .image" \
  'postgres:18-alpine@sha256:77f585114c32fbca283dc835b0596f4e52b51b4c6662d7810b2f4084f60a1873'
assert_yq "$runner_values | .containers[] | select(.name == \"postgres\") | (.args | join(\",\"))" \
  '-c,listen_addresses=localhost'
assert_yq "$runner_values | .containers[] | select(.name == \"postgres\") | .securityContext.runAsNonRoot" 'true'
assert_yq "$runner_values | .containers[] | select(.name == \"postgres\") | .securityContext.runAsUser" '70'
assert_yq "$runner_values | .containers[] | select(.name == \"postgres\") | .securityContext.runAsGroup" '70'
assert_yq "$runner_values | .containers[] | select(.name == \"postgres\") | .securityContext.allowPrivilegeEscalation" 'false'
assert_yq "$runner_values | .containers[] | select(.name == \"postgres\") | (.securityContext.capabilities.drop | join(\",\"))" 'ALL'
assert_yq "$runner_values | .containers[] | select(.name == \"postgres\") | .securityContext.seccompProfile.type" 'RuntimeDefault'
assert_yq "$runner_values | .containers[] | select(.name == \"postgres\") | (.args | join(\",\"))" '-c,listen_addresses=localhost'
assert_yq "$runner_values | .containers[] | select(.name == \"postgres\") | (.startupProbe.exec.command | join(\",\"))" 'pg_isready,-U,factory,-d,factory'
assert_yq "$runner_values | .containers[] | select(.name == \"postgres\") | (.readinessProbe.exec.command | join(\",\"))" 'pg_isready,-U,factory,-d,factory'
assert_yq "$runner_values | .containers[] | select(.name == \"postgres\") | .ports[0].containerPort" '5432'
assert_yq "$runner_values | .containers[] | select(.name == \"postgres\") | .resources.requests.cpu" '100m'
assert_yq "$runner_values | .containers[] | select(.name == \"postgres\") | .resources.requests.memory" '256Mi'
assert_yq "$runner_values | .containers[] | select(.name == \"postgres\") | .resources.requests.\"ephemeral-storage\"" '512Mi'
assert_yq "$runner_values | .containers[] | select(.name == \"postgres\") | .resources.limits.cpu" '1'
assert_yq "$runner_values | .containers[] | select(.name == \"postgres\") | .resources.limits.memory" '1Gi'
assert_yq "$runner_values | .containers[] | select(.name == \"postgres\") | .resources.limits.\"ephemeral-storage\"" '2Gi'
assert_yq "$runner_values | (.containers | length)" '2'
assert_yq "$runner_values | ((.volumes // []) | length)" '0'

runner_download_policy='select(.kind == "CiliumNetworkPolicy" and .metadata.name == "arc-runners-node-npm-egress")'
assert_yq "$runner_download_policy | .metadata.namespace" 'arc-runners'
assert_yq "$runner_download_policy | .spec.endpointSelector.matchLabels.\"k8s:actions.github.com/scale-set-name\"" 'factory-ci-arc'
assert_yq "$runner_download_policy | [.spec.egress[]?.toFQDNs[]?.matchName] | unique | sort | join(\",\")" \
  'api.nuget.org,extensions.duckdb.org,files.pythonhosted.org,nodejs.org,public.cdn.getdbt.com,pypi.org,raw.githubusercontent.com,registry.npmjs.org,release-assets.githubusercontent.com'
assert_yq "$runner_download_policy | [.spec.egress[] | select(.toFQDNs[0].matchName == \"extensions.duckdb.org\") | .toPorts[]?.ports[]?.port] | sort | join(\",\")" \
  '80'
assert_yq "$runner_download_policy | [.spec.egress[] | select(.toFQDNs[0].matchName == \"extensions.duckdb.org\") | .toPorts[]?.ports[]? | (.port + \"/\" + .protocol)] | join(\",\")" \
  '80/TCP'

[[ "$(grep -Ec '^[[:space:]]+automated:' "$rendered")" == "2" ]] || {
  printf 'ARC_GITOPS_CONTRACT=FAIL child-applications-not-automated\n' >&2
  exit 1
}

for project in "$infrastructure_project" "$applications_project"; do
  grep -F -- '    - ghcr.io/actions/actions-runner-controller-charts' "$project" >/dev/null || {
    printf 'ARC_GITOPS_CONTRACT=FAIL appproject-oci-source-allowlist file=%s\n' "$project" >&2
    exit 1
  }
done

if grep -En 'privileged:\s*true|ACTIONS_RUNNER_REQUIRE_JOB_CONTAINER:\s*false|github_token:|github_app_private_key:\s*\|' "$rendered"; then
  printf 'ARC_GITOPS_CONTRACT=FAIL insecure-or-inline-credential\n' >&2
  exit 1
fi

printf 'ARC_GITOPS_CONTRACT=PASS\n'
