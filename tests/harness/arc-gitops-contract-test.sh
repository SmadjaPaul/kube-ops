#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
arc_root="$repo_root/k8s/optional/github-actions-arc"
homelab_arc_root="$repo_root/k8s/optional/github-actions-arc-homelab-infra"
infrastructure_project="$repo_root/k8s/bootstrap/argocd-root/infrastructure-project.yaml"
applications_project="$repo_root/k8s/bootstrap/argocd-root/applications-project.yaml"
rendered="$(mktemp)"
cleanup() { rm -f "$rendered"; }
trap cleanup EXIT

kubectl kustomize "$arc_root" >"$rendered"
printf '\n---\n' >>"$rendered"
kubectl kustomize "$homelab_arc_root" >>"$rendered"

required_patterns=(
  'name: arc-systems'
  'name: arc-runners'
  'name: arc-github-app'
  'name: infra-arc-controller'
  'name: apps-arc-factory-ci'
  'name: apps-arc-homelab-infra-ci'
  'name: arc-runner-bounds'
  'name: arc-systems-github-egress'
  'name: arc-runners-github-egress'
  'name: arc-runners-node-npm-egress'
  'targetRevision: 0.15.0'
  'name: arc-gha-rs-controller'
  'minRunners: 0'
  'maxRunners: 3'
  'maxRunners: 1'
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

homelab_runner_values='select(.kind == "Application" and .metadata.name == "apps-arc-homelab-infra-ci") | .spec.source.helm.valuesObject'
assert_yq "$homelab_runner_values | .githubConfigUrl" 'https://github.com/SmadjaPaul/homelab-infra'
assert_yq "$homelab_runner_values | .githubConfigSecret" 'arc-github-app'
assert_yq "$homelab_runner_values | .minRunners" '0'
assert_yq "$homelab_runner_values | .maxRunners" '1'
assert_yq "$homelab_runner_values | .template.spec.automountServiceAccountToken" 'false'
assert_yq "$homelab_runner_values | .template.spec.securityContext.runAsNonRoot" 'true'
assert_yq "$homelab_runner_values | .template.spec.securityContext.runAsUser" '1001'
assert_yq "$homelab_runner_values | .template.spec.securityContext.runAsGroup" '1001'
assert_yq "$homelab_runner_values | .template.spec.securityContext.fsGroup" '1001'
assert_yq "$homelab_runner_values | .template.spec.containers | length" '1'
assert_yq "$homelab_runner_values | .template.spec.containers[0].name" 'runner'
assert_yq "$homelab_runner_values | .template.spec.containers[0].image" \
  'ghcr.io/actions/actions-runner:2.338.0@sha256:4ffadc0002b2581327e06101fc8c06cd189232baf79fe561fac9caeb76f5e807'
assert_yq "$homelab_runner_values | .template.spec.containers[0].securityContext.allowPrivilegeEscalation" 'false'
assert_yq "$homelab_runner_values | .template.spec.containers[0].securityContext.seccompProfile.type" 'RuntimeDefault'

homelab_download_policy='select(.kind == "CiliumNetworkPolicy" and .metadata.name == "arc-runners-homelab-infra-downloads")'
assert_yq "$homelab_download_policy | .metadata.namespace" 'arc-runners'
assert_yq "$homelab_download_policy | .spec.endpointSelector.matchLabels.\"k8s:actions.github.com/scale-set-name\"" 'homelab-infra-ci-arc'
assert_yq "$homelab_download_policy | [.spec.egress[]?.toFQDNs[]?.matchName] | unique | sort | join(\",\")" \
  'api.github.com,api.nuget.org,codeload.github.com,files.pythonhosted.org,github-registry-files.githubusercontent.com,github-releases.githubusercontent.com,github.com,mise.jdx.dev,nodejs.org,objects-origin.githubusercontent.com,objects.githubusercontent.com,pypi.org,raw.githubusercontent.com,registry.npmjs.org,registry.opentofu.org,registry.terraform.io,release-assets.githubusercontent.com,releases.hashicorp.com,tuf-repo-cdn.sigstore.dev'

runner_download_policy='select(.kind == "CiliumNetworkPolicy" and .metadata.name == "arc-runners-node-npm-egress")'
assert_yq "$runner_download_policy | .metadata.namespace" 'arc-runners'
assert_yq "$runner_download_policy | .spec.endpointSelector.matchLabels.\"k8s:actions.github.com/scale-set-name\"" 'factory-ci-arc'
assert_yq "$runner_download_policy | [.spec.egress[]?.toFQDNs[]?.matchName] | unique | sort | join(\",\")" \
  'api.nuget.org,dl.google.com,extensions.duckdb.org,files.pythonhosted.org,nodejs.org,public.cdn.getdbt.com,pypi.org,raw.githubusercontent.com,registry.npmjs.org,release-assets.githubusercontent.com'
assert_yq "$runner_download_policy | [.spec.egress[] | select(.toFQDNs[0].matchName == \"extensions.duckdb.org\") | .toPorts[]?.ports[]?.port] | sort | join(\",\")" \
  '80'
assert_yq "$runner_download_policy | [.spec.egress[] | select(.toFQDNs[0].matchName == \"extensions.duckdb.org\") | .toPorts[]?.ports[]? | (.port + \"/\" + .protocol)] | join(\",\")" \
  '80/TCP'

factory_sts_policy='select(.kind == "CiliumNetworkPolicy" and .metadata.name == "arc-runners-factory-sts-egress")'
assert_yq "$factory_sts_policy | .metadata.namespace" 'arc-runners'
assert_yq "$factory_sts_policy | .spec.endpointSelector.matchLabels.\"k8s:actions.github.com/scale-set-name\"" 'factory-ci-arc'
assert_yq "$factory_sts_policy | [.spec.egress[]?.toFQDNs[]?.matchName] | unique | sort | join(\",\")" \
  'sts.googleapis.com'
assert_yq "$factory_sts_policy | [.spec.egress[]?.toFQDNs[]?.matchPattern] | length" '0'
assert_yq "$factory_sts_policy | [.spec.egress[]?.toCIDR[]?, .spec.egress[]?.toCIDRSet[]?, .spec.egress[]?.toEntities[]?] | length" '0'
assert_yq "$factory_sts_policy | [.spec.egress[]?.toEndpoints[]?.matchLabels.\"k8s:io.kubernetes.pod.namespace\"] | unique | join(\",\")" \
  'kube-system'
assert_yq "$factory_sts_policy | [.spec.egress[]?.toPorts[]?.rules.dns[]?.matchName] | unique | join(\",\")" \
  'sts.googleapis.com'
assert_yq "$factory_sts_policy | [.spec.egress[] | select(.toFQDNs[0].matchName == \"sts.googleapis.com\") | .toPorts[]?.ports[]? | (.port + \"/\" + .protocol)] | join(\",\")" \
  '443/TCP'

factory_gcp_credentials_policy='select(.kind == "CiliumNetworkPolicy" and .metadata.name == "arc-runners-factory-gcp-credentials-egress")'
assert_yq "$factory_gcp_credentials_policy | .metadata.namespace" 'arc-runners'
assert_yq "$factory_gcp_credentials_policy | .spec.endpointSelector.matchLabels.\"k8s:actions.github.com/scale-set-name\"" 'factory-ci-arc'
assert_yq "$factory_gcp_credentials_policy | [.spec.egress[]?.toFQDNs[]?.matchName] | unique | sort | join(\",\")" \
  'iamcredentials.googleapis.com'
assert_yq "$factory_gcp_credentials_policy | [.spec.egress[]?.toFQDNs[]?.matchPattern] | length" '0'
assert_yq "$factory_gcp_credentials_policy | [.spec.egress[]?.toCIDR[]?, .spec.egress[]?.toCIDRSet[]?, .spec.egress[]?.toEntities[]?] | length" '0'
assert_yq "$factory_gcp_credentials_policy | [.spec.egress[]?.toEndpoints[]?.matchLabels.\"k8s:io.kubernetes.pod.namespace\"] | unique | join(\",\")" \
  'kube-system'
assert_yq "$factory_gcp_credentials_policy | [.spec.egress[]?.toPorts[]?.rules.dns[]?.matchName] | unique | join(\",\")" \
  'iamcredentials.googleapis.com'
assert_yq "$factory_gcp_credentials_policy | [.spec.egress[] | select(.toFQDNs[0].matchName == \"iamcredentials.googleapis.com\") | .toPorts[]?.ports[]? | (.port + \"/\" + .protocol)] | join(\",\")" \
  '443/TCP'

factory_gcs_policy='select(.kind == "CiliumNetworkPolicy" and .metadata.name == "arc-runners-factory-gcs-egress")'
assert_yq "$factory_gcs_policy | .metadata.namespace" 'arc-runners'
assert_yq "$factory_gcs_policy | .spec.endpointSelector.matchLabels.\"k8s:actions.github.com/scale-set-name\"" 'factory-ci-arc'
assert_yq "$factory_gcs_policy | .spec | has(\"enableDefaultDeny\")" 'false'
assert_yq "$factory_gcs_policy | .spec.egress | length" '2'
assert_yq "$factory_gcs_policy | [.spec.egress[] | select(has(\"toEndpoints\"))] | length" '1'
assert_yq "$factory_gcs_policy | [.spec.egress[] | select(has(\"toFQDNs\"))] | length" '1'
assert_yq "$factory_gcs_policy | [.spec.egress[]?.toFQDNs[]?.matchName] | unique | sort | join(\",\")" \
  'storage.googleapis.com'
assert_yq "$factory_gcs_policy | [.spec.egress[]?.toFQDNs[]?.matchPattern] | length" '0'
assert_yq "$factory_gcs_policy | [.spec.egress[]?.toCIDR[]?, .spec.egress[]?.toCIDRSet[]?, .spec.egress[]?.toEntities[]?] | length" '0'
assert_yq "$factory_gcs_policy | [.spec.egress[]?.toEndpoints[]?.matchLabels.\"k8s:io.kubernetes.pod.namespace\"] | unique | join(\",\")" \
  'kube-system'
assert_yq "$factory_gcs_policy | .spec.egress[0].toEndpoints | length" '1'
assert_yq "$factory_gcs_policy | .spec.egress[0].toEndpoints[0].matchLabels.\"k8s:k8s-app\"" 'kube-dns'
assert_yq "$factory_gcs_policy | .spec.egress[0].toPorts | length" '1'
assert_yq "$factory_gcs_policy | [.spec.egress[0].toPorts[0].ports[] | (.port + \"/\" + .protocol)] | sort | join(\",\")" \
  '53/TCP,53/UDP'
assert_yq "$factory_gcs_policy | [.spec.egress[]?.toPorts[]?.rules.dns[]?.matchName] | unique | join(\",\")" \
  'storage.googleapis.com'
assert_yq "$factory_gcs_policy | .spec.egress[0].toPorts[0].rules.dns | length" '1'
assert_yq "$factory_gcs_policy | .spec.egress[1].toFQDNs | length" '1'
assert_yq "$factory_gcs_policy | .spec.egress[1].toPorts | length" '1'
assert_yq "$factory_gcs_policy | [.spec.egress[] | select(.toFQDNs[0].matchName == \"storage.googleapis.com\") | .toPorts[]?.ports[]? | (.port + \"/\" + .protocol)] | join(\",\")" \
  '443/TCP'

[[ "$(grep -Ec '^[[:space:]]+automated:' "$rendered")" == "3" ]] || {
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
