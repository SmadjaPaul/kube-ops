#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
arc_root="$repo_root/k8s/optional/github-actions-arc"
homelab_arc_root="$repo_root/k8s/optional/github-actions-arc-homelab-infra"
pilot_arc_root="$repo_root/k8s/optional/github-actions-arc-homelab-iac-pilot"
website_arc_root="$repo_root/k8s/optional/github-actions-arc-website"
aiostreams_network_policy="$repo_root/k8s/applications/media/aiostreams/networkpolicy.yaml"
infrastructure_project="$repo_root/k8s/bootstrap/argocd-root/infrastructure-project.yaml"
applications_project="$repo_root/k8s/bootstrap/argocd-root/applications-project.yaml"
rendered="$(mktemp)"
website_rendered="$(mktemp)"
cleanup() { rm -f "$rendered" "$website_rendered"; }
trap cleanup EXIT

kubectl kustomize "$arc_root" >"$rendered"
printf '\n---\n' >>"$rendered"
kubectl kustomize "$homelab_arc_root" >>"$rendered"
printf '\n---\n' >>"$rendered"
kubectl kustomize "$pilot_arc_root" >>"$rendered"
# PRD-28: the website scale set is rendered apart, so the Application count
# checked below for the shared directories keeps its meaning.
kubectl kustomize "$website_arc_root" >"$website_rendered"

required_patterns=(
  'name: arc-systems'
  'name: arc-runners'
  'name: arc-github-app'
  'name: infra-arc-controller'
  'name: apps-arc-factory-ci'
  'name: apps-arc-factory-ci-light'
  'name: arc-runners-factory-light-download-egress'
  'name: apps-arc-homelab-infra-ci'
  'name: arc-runner-bounds'
  'name: arc-systems-github-egress'
  'name: arc-runners-github-egress'
  'name: arc-runners-node-npm-egress'
  'targetRevision: 0.15.0'
  'name: arc-gha-rs-controller'
  'minRunners: 0'
  'maxRunners: 3'
  'maxRunners: 2'
  'pod-security.kubernetes.io/enforce: restricted'
  'image: postgres:18-alpine@sha256:77f585114c32fbca283dc835b0596f4e52b51b4c6662d7810b2f4084f60a1873'
)

for pattern in "${required_patterns[@]}"; do
  grep -F -- "$pattern" "$rendered" >/dev/null || {
    printf 'ARC_GITOPS_CONTRACT=FAIL missing=%s\n' "$pattern" >&2
    exit 1
  }
done

# PLT-417: every ARC scale set keeps its heavy scratch writes off the Talos system
# disk (etcd shares it): any `ephemeral` volume must use longhorn-bulk-scratch
# (bulk tier, reclaimPolicy Delete; longhorn-bulk is Retain and would leak one
# volume per job), and /tmp plus the runner's heavy dirs must not be the container layer.
scratch_contract() {
  local file=$1 name classes tmp_mounted
  name="$(yq eval '.metadata.name' "$file")"
  classes="$(yq eval '[.spec.source.helm.valuesObject.template.spec.volumes[] | select(has("ephemeral")) | .ephemeral.volumeClaimTemplate.spec.storageClassName] | unique | join(",")' "$file")"
  tmp_mounted="$(yq eval '[.spec.source.helm.valuesObject.template.spec.containers[] | select(.name == "runner") | .volumeMounts[] | select(.mountPath == "/tmp") | .name] | join(",")' "$file")"
  [[ "$classes" == 'longhorn-bulk-scratch' && "$tmp_mounted" == 'tmp' ]] || {
    printf 'ARC_GITOPS_CONTRACT=FAIL scratch app=%s classes=%s tmp_mounted=%s\n' "$name" "$classes" "$tmp_mounted" >&2
    exit 1
  }
}
# Every scale set uses scratch volumes (PLT-417). Lot 1 moved the ones that do not run
# this repository's CI; lot 2 the rest, once a real run had passed on lot 1.
scratch_scale_sets=(
  github-actions-arc/runner-application.yaml
  github-actions-arc/runner-light-application.yaml
  github-actions-arc-website/runner-application.yaml
  github-actions-arc-ha-config/runner-application.yaml
  github-actions-arc-agent-harness/runner-application.yaml
  github-actions-arc-agent-harness/runner-application-agents.yaml
  github-actions-arc-homelab-iac-pilot/runner-application.yaml
  github-actions-arc-homelab-infra/runner-application.yaml
  github-actions-arc-kube-ops/runner-application.yaml
  github-actions-arc-kube-ops-pr/runner-application.yaml
)
for runner_file in "${scratch_scale_sets[@]}"; do
  scratch_contract "$repo_root/k8s/optional/$runner_file"
done
scratch_class="$repo_root/k8s/infrastructure/storage/longhorn/scratch-storageclass.yaml"
[[ "$(yq eval '[.reclaimPolicy, .parameters.diskSelector, .volumeBindingMode] | join(",")' "$scratch_class")" == 'Delete,bulk,WaitForFirstConsumer' ]] || {
  printf 'ARC_GITOPS_CONTRACT=FAIL longhorn-bulk-scratch must be Delete/bulk/WaitForFirstConsumer\n' >&2
  exit 1
}

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
  'ghcr.io/smadjapaul/factory-ci-arc@sha256:17ea282d02b71da140ee6b6aa25793fb7c8d02fd44429769861ac8752b27a27f'
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
# PLT-417: the only volumes are the per-pod scratch volumes (see scratch_contract below).
assert_yq "$runner_values | [.volumes[].name] | join(\",\")" 'work,tmp'

light_runner_values='select(.kind == "Application" and .metadata.name == "apps-arc-factory-ci-light") | .spec.source.helm.valuesObject'
assert_yq "$light_runner_values | .githubConfigUrl" 'https://github.com/SmadjaPaul/factory-platform'
assert_yq "$light_runner_values | .githubConfigSecret" 'arc-github-app'
assert_yq "$light_runner_values | .minRunners" '0'
assert_yq "$light_runner_values | .maxRunners" '2'
assert_yq "$light_runner_values | .template.spec.automountServiceAccountToken" 'false'
assert_yq "$light_runner_values | .template.spec.securityContext.runAsNonRoot" 'true'
assert_yq "$light_runner_values | .template.spec.securityContext.runAsUser" '1001'
assert_yq "$light_runner_values | .template.spec.securityContext.fsGroup" '1001'
assert_yq "$light_runner_values | .template.spec.securityContext.runAsGroup" '1001'
assert_yq "$light_runner_values | .template.spec | has(\"serviceAccountName\")" 'false'
assert_yq "$light_runner_values | .template.spec | (has(\"hostNetwork\") or has(\"hostPID\") or has(\"hostIPC\"))" 'false'
assert_yq "$light_runner_values | .template.spec.containers[0] | (has(\"env\") or has(\"envFrom\"))" 'false'
assert_yq "$light_runner_values | .template.spec.containers[0].resources | [.requests.cpu, .requests.memory, .requests.\"ephemeral-storage\", .limits.cpu, .limits.memory, .limits.\"ephemeral-storage\"] | join(\",\")" \
  '250m,512Mi,512Mi,2,2Gi,4Gi'
assert_yq "$light_runner_values | (.template.spec.imagePullSecrets | map(.name) | join(\",\"))" 'arc-factory-ghcr-pull'
# No PostgreSQL (or any other) sidecar and only the scratch volumes (PLT-417) on the light scale set.
assert_yq "$light_runner_values | .template.spec.containers | length" '1'
assert_yq "$light_runner_values | [.template.spec.volumes[].name] | join(\",\")" 'work,tmp'
assert_yq "$light_runner_values | .template.spec.containers[0].name" 'runner'
# The light runner must stay on the exact Factory runner image.
assert_yq "$light_runner_values | .template.spec.containers[0].image" \
  "$(yq eval-all "$runner_values | .containers[] | select(.name == \"runner\") | .image" "$rendered")"
assert_yq "$light_runner_values | .template.spec.containers[0].securityContext.allowPrivilegeEscalation" 'false'
assert_yq "$light_runner_values | (.template.spec.containers[0].securityContext.capabilities.drop | join(\",\"))" 'ALL'
assert_yq "$light_runner_values | .template.spec.containers[0].securityContext.seccompProfile.type" 'RuntimeDefault'
light_download_policy='select(.kind == "CiliumNetworkPolicy" and .metadata.name == "arc-runners-factory-light-download-egress")'
assert_yq "$light_download_policy | .metadata.namespace" 'arc-runners'
assert_yq "$light_download_policy | .spec.endpointSelector.matchLabels.\"k8s:actions.github.com/scale-set-name\"" 'factory-ci-arc-light'
assert_yq "$light_download_policy | [.spec.egress[]?.toFQDNs[]?.matchName] | unique | sort | join(\",\")" \
  'api.nuget.org,files.pythonhosted.org,nodejs.org,pypi.org,raw.githubusercontent.com,registry.npmjs.org,release-assets.githubusercontent.com'
assert_yq "$light_download_policy | .spec | has(\"enableDefaultDeny\")" 'false'
assert_yq "$light_download_policy | .spec.egress | length" '2'
assert_yq "$light_download_policy | [.spec.egress[]?.toFQDNs[]?.matchPattern] | length" '0'
assert_yq "$light_download_policy | [.spec.egress[]?.toCIDR[]?, .spec.egress[]?.toCIDRSet[]?, .spec.egress[]?.toEntities[]?, .spec.egress[]?.toServices[]?] | length" '0'
assert_yq "$light_download_policy | .spec.egress[0].toEndpoints | length" '1'
assert_yq "$light_download_policy | .spec.egress[0].toEndpoints[0].matchLabels.\"k8s:io.kubernetes.pod.namespace\"" 'kube-system'
assert_yq "$light_download_policy | .spec.egress[0].toEndpoints[0].matchLabels.\"k8s:k8s-app\"" 'kube-dns'
assert_yq "$light_download_policy | [.spec.egress[0].toPorts[0].ports[] | (.port + \"/\" + .protocol)] | sort | join(\",\")" \
  '53/TCP,53/UDP'
assert_yq "$light_download_policy | [.spec.egress[1].toPorts[]?.ports[]? | (.port + \"/\" + .protocol)] | join(\",\")" \
  '443/TCP'
assert_yq "$light_download_policy | [.spec.egress[1] | keys | .[]] | sort | join(\",\")" 'toFQDNs,toPorts'

homelab_runner_values='select(.kind == "Application" and .metadata.name == "apps-arc-homelab-infra-ci") | .spec.source.helm.valuesObject'
assert_yq "$homelab_runner_values | .githubConfigUrl" 'https://github.com/SmadjaPaul/homelab-infra'
assert_yq "$homelab_runner_values | .githubConfigSecret" 'arc-github-app'
assert_yq "$homelab_runner_values | .minRunners" '0'
assert_yq "$homelab_runner_values | .maxRunners" '2'
assert_yq "$homelab_runner_values | .template.spec.automountServiceAccountToken" 'false'
assert_yq "$homelab_runner_values | .template.spec.securityContext.runAsNonRoot" 'true'
assert_yq "$homelab_runner_values | .template.spec.securityContext.runAsUser" '1001'
assert_yq "$homelab_runner_values | .template.spec.securityContext.runAsGroup" '1001'
assert_yq "$homelab_runner_values | .template.spec.securityContext.fsGroup" '1001'
assert_yq "$homelab_runner_values | .template.spec.containers | length" '1'
assert_yq "$homelab_runner_values | .template.spec.containers[0].name" 'runner'
assert_yq "$homelab_runner_values | .template.spec.containers[0].image" \
  'ghcr.io/smadjapaul/arc-ci-runner:tools1-576e0cb@sha256:087f055d11e3c2a0afd3606fa9b3a45b54a80401c201cd8df0cb261023557709'
assert_yq "$homelab_runner_values | .template.spec.containers[0].securityContext.allowPrivilegeEscalation" 'false'
assert_yq "$homelab_runner_values | .template.spec.containers[0].securityContext.seccompProfile.type" 'RuntimeDefault'

pilot_runner_values='select(.kind == "Application" and .metadata.name == "apps-arc-homelab-iac-pilot") | .spec.source.helm.valuesObject'
assert_yq "$pilot_runner_values | .githubConfigUrl" 'https://github.com/SmadjaPaul/homelab-infra'
assert_yq "$pilot_runner_values | .githubConfigSecret" 'arc-github-app'
assert_yq "$pilot_runner_values | .minRunners" '0'
assert_yq "$pilot_runner_values | .maxRunners" '2'
assert_yq "$pilot_runner_values | .template.spec.automountServiceAccountToken" 'false'
assert_yq "$pilot_runner_values | .template.spec.securityContext.runAsNonRoot" 'true'
assert_yq "$pilot_runner_values | .template.spec.containers | length" '1'

homelab_download_policy='select(.kind == "CiliumNetworkPolicy" and .metadata.name == "arc-runners-homelab-infra-downloads")'
assert_yq "$homelab_download_policy | .metadata.namespace" 'arc-runners'
assert_yq "$homelab_download_policy | .spec.endpointSelector.matchLabels.\"k8s:actions.github.com/scale-set-name\"" 'homelab-infra-ci-arc'
assert_yq "$homelab_download_policy | [.spec.egress[]?.toFQDNs[]?.matchName] | unique | sort | join(\",\")" \
  'api.cloudflare.com,api.doppler.com,api.github.com,api.nuget.org,codeload.github.com,files.pythonhosted.org,github-registry-files.githubusercontent.com,github-releases.githubusercontent.com,github.com,mise-versions.jdx.dev,mise.jdx.dev,nodejs.org,objects-origin.githubusercontent.com,objects.githubusercontent.com,pypi.org,raw.githubusercontent.com,registry.npmjs.org,registry.opentofu.org,registry.terraform.io,release-assets.githubusercontent.com,releases.hashicorp.com,tuf-repo-cdn.sigstore.dev'

# PLT-296/PLT-298: LAN egress for plans is one /32 and one port per API, nothing else.
for lan_policy in 'proxmox-api|10.0.20.51/32|8006/TCP' 'unifi-api|10.0.20.1/32|443/TCP'; do
  IFS='|' read -r lan_name lan_cidr lan_port <<<"$lan_policy"
  lan_expr="select(.kind == \"CiliumNetworkPolicy\" and .metadata.name == \"arc-runners-homelab-infra-$lan_name\")"
  assert_yq "$lan_expr | .spec.endpointSelector.matchLabels.\"k8s:actions.github.com/scale-set-name\"" 'homelab-infra-ci-arc'
  assert_yq "$lan_expr | .spec.egress | length" '1'
  assert_yq "$lan_expr | [.spec.egress[0].toCIDR[]] | join(\",\")" "$lan_cidr"
  assert_yq "$lan_expr | [.spec.egress[0].toPorts[].ports[] | (.port + \"/\" + .protocol)] | join(\",\")" "$lan_port"
done

pilot_network_policy='select(.kind == "CiliumNetworkPolicy" and .metadata.name == "arc-runners-homelab-iac-pilot-egress")'
assert_yq "$pilot_network_policy | [.spec.egress[]?.toEndpoints[]? | select(.matchLabels.\"k8s:app.kubernetes.io/name\" == \"aiostreams\") | .matchLabels.\"k8s:io.kubernetes.pod.namespace\"] | join(\",\")" 'media'
assert_yq "$pilot_network_policy | [.spec.egress[] | select(.toEndpoints[0].matchLabels.\"k8s:app.kubernetes.io/name\" == \"aiostreams\") | .toPorts[]?.ports[]? | (.port + \"/\" + .protocol)] | join(\",\")" '3000/TCP'
assert_yq "$pilot_network_policy | [.spec.egress[]?.toFQDNs[]?.matchName | select(. == \"pypi.org\" or . == \"files.pythonhosted.org\")] | join(\",\")" 'pypi.org,files.pythonhosted.org'

assert_yq_file() {
  local expression=$1 file=$2 expected=$3 actual
  actual="$(yq eval "$expression" "$file")"
  [[ "$actual" == "$expected" ]] || {
    printf 'ARC_GITOPS_CONTRACT=FAIL expression=%s file=%s expected=%s actual=%s\n' \
      "$expression" "$file" "$expected" "$actual" >&2
    exit 1
  }
}

assert_yq_file '.spec.ingress[] | select(.fromEndpoints[0].matchLabels."k8s:actions.github.com/scale-set-name" == "homelab-iac-pilot-arc") | [.fromEndpoints[0].matchLabels."k8s:io.kubernetes.pod.namespace", .toPorts[]?.ports[]? | (.port + "/" + .protocol)] | join(",")' \
  "$aiostreams_network_policy" 'arc-runners,3000/TCP'

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

# PRD-28: dedicated website scale set, own namespace, quota and default-deny egress.
assert_yq_website() {
  local expression=$1 expected=$2 actual
  actual="$(yq eval-all "$expression" "$website_rendered")"
  [[ "$actual" == "$expected" ]] || {
    printf 'ARC_GITOPS_CONTRACT=FAIL website expression=%s expected=%s actual=%s\n' \
      "$expression" "$expected" "$actual" >&2
    exit 1
  }
}
website_values='select(.kind == "Application" and .metadata.name == "apps-arc-website-ci") | .spec.source.helm.valuesObject'
assert_yq_website 'select(.kind == "Application" and .metadata.name == "apps-arc-website-ci") | .spec.destination.namespace' 'arc-runners-website'
assert_yq_website 'select(.kind == "Application" and .metadata.name == "apps-arc-website-ci") | .spec.source.helm.releaseName' 'website-ci-arc'
assert_yq_website 'select(.kind == "Application" and .metadata.name == "apps-arc-website-ci") | .spec.source.targetRevision' '0.15.0'
assert_yq_website "$website_values | .githubConfigUrl" 'https://github.com/SmadjaPaul/website'
assert_yq_website "$website_values | .githubConfigSecret" 'arc-github-app'
assert_yq_website "$website_values | .minRunners" '0'
assert_yq_website "$website_values | .maxRunners" '1'
assert_yq_website "$website_values | .template.spec.automountServiceAccountToken" 'false'
assert_yq_website "$website_values | .template.spec.securityContext.runAsNonRoot" 'true'
assert_yq_website "$website_values | .template.spec.securityContext.runAsUser" '1001'
assert_yq_website "$website_values | .template.spec | (has(\"serviceAccountName\") or has(\"hostNetwork\") or has(\"imagePullSecrets\"))" 'false'
assert_yq_website "$website_values | .template.spec.containers | length" '1'
assert_yq_website "$website_values | .template.spec.containers[0] | (has(\"env\") or has(\"envFrom\"))" 'false'
assert_yq_website "$website_values | [.template.spec.volumes[].name] | join(\",\")" 'work,tmp'
assert_yq_website "$website_values | .template.spec.containers[0].image | test(\"^ghcr.io/smadjapaul/arc-ci-runner:[A-Za-z0-9._-]+@sha256:[0-9a-f]{64}$\")" 'true'
assert_yq_website "$website_values | .template.spec.containers[0].securityContext.allowPrivilegeEscalation" 'false'
assert_yq_website "$website_values | (.template.spec.containers[0].securityContext.capabilities.drop | join(\",\"))" 'ALL'
assert_yq_website "$website_values | .template.spec.containers[0].securityContext.seccompProfile.type" 'RuntimeDefault'
# CPU ceiling (D-2026-11-15-05): one runner at 250m is the most the node can host.
assert_yq_website "$website_values | .template.spec.containers[0].resources | [.requests.cpu, .requests.memory, .limits.cpu, .limits.memory, .limits.\"ephemeral-storage\"] | join(\",\")" '250m,1Gi,2,4Gi,6Gi'
assert_yq_website 'select(.kind == "Namespace") | .metadata.name + "," + .metadata.labels."pod-security.kubernetes.io/enforce"' 'arc-runners-website,restricted'
assert_yq_website 'select(.kind == "ResourceQuota") | .metadata.namespace' 'arc-runners-website'
assert_yq_website 'select(.kind == "ResourceQuota") | .spec.hard | [.pods, .["requests.cpu"], .["limits.cpu"], .["limits.memory"], .["limits.ephemeral-storage"]] | join(",")' '1,250m,2,4Gi,6Gi'
assert_yq_website 'select(.kind == "ExternalSecret") | .metadata.namespace + "," + .spec.target.name' 'arc-runners-website,arc-github-app'
website_policy='select(.kind == "CiliumNetworkPolicy" and .metadata.name == "arc-runners-website-egress")'
assert_yq_website "$website_policy | .metadata.namespace" 'arc-runners-website'
assert_yq_website "$website_policy | .spec.endpointSelector | length" '0'
assert_yq_website "$website_policy | .spec | has(\"enableDefaultDeny\")" 'false'
assert_yq_website "$website_policy | [.spec.egress[]?.toFQDNs[]?.matchName] | unique | sort | join(\",\")" \
  'api.cloudflare.com,api.github.com,api.sanity.io,cdn.sanity.io,codeload.github.com,github-registry-files.githubusercontent.com,github-releases.githubusercontent.com,github.com,lechaplais.com,objects-origin.githubusercontent.com,objects.githubusercontent.com,raw.githubusercontent.com,registry.npmjs.org,release-assets.githubusercontent.com,tli60dkb.api.sanity.io,tli60dkb.apicdn.sanity.io'
assert_yq_website "$website_policy | [.spec.egress[]?.toFQDNs[]?.matchPattern] | sort | join(\",\")" '*.actions.githubusercontent.com,*.blob.core.windows.net'
# No LAN, no Kubernetes API, no catch-all: only DNS endpoints and FQDNs.
assert_yq_website "$website_policy | [.spec.egress[]?.toCIDR[]?, .spec.egress[]?.toCIDRSet[]?, .spec.egress[]?.toEntities[]?, .spec.egress[]?.toServices[]?] | length" '0'
assert_yq_website "$website_policy | [.spec.egress[]?.toPorts[]?.ports[]? | (.port + \"/\" + .protocol)] | unique | sort | join(\",\")" '443/TCP,53/TCP,53/UDP'
for project in "$infrastructure_project" "$applications_project"; do
  grep -F -- '    - namespace: arc-runners-website' "$project" >/dev/null || {
    printf 'ARC_GITOPS_CONTRACT=FAIL website-namespace-not-in-appproject file=%s\n' "$project" >&2
    exit 1
  }
done
grep -F -- 'path: k8s/optional/github-actions-arc-website' \
  "$repo_root/k8s/bootstrap/argocd-root/infrastructure-applicationset.yaml" >/dev/null || {
  printf 'ARC_GITOPS_CONTRACT=FAIL website-path-not-in-applicationset\n' >&2
  exit 1
}

# agent-harness scale set: own namespace, repository scope, ephemeral (min 0, max 1), no secret in the runner except the pr-triage key (PLT-453).
agent_harness_rendered="$(mktemp)"
kubectl kustomize "$repo_root/k8s/optional/github-actions-arc-agent-harness" >"$agent_harness_rendered"
ah_values='select(.kind == "Application" and .metadata.name == "apps-arc-agent-harness-ci") | .spec.source.helm.valuesObject'
assert_yq_ah() {
  local actual
  actual="$(yq eval-all "$1" "$agent_harness_rendered")"
  [[ "$actual" == "$2" ]] || {
    printf 'ARC_GITOPS_CONTRACT=FAIL agent-harness expression=%s expected=%s actual=%s\n' "$1" "$2" "$actual" >&2
    rm -f "$agent_harness_rendered"
    exit 1
  }
}
assert_yq_ah 'select(.kind == "Application" and .metadata.name == "apps-arc-agent-harness-ci") | .spec.source.helm.releaseName' 'agent-harness-ci-arc'
assert_yq_ah 'select(.kind == "Application" and .metadata.name == "apps-arc-agent-harness-agents") | .spec.source.helm.releaseName' 'agent-harness-agents-arc'
assert_yq_ah 'select(.kind == "Application" and .metadata.name == "apps-arc-agent-harness-ci") | .spec.destination.namespace' 'arc-runners-agent-harness'
assert_yq_ah 'select(.kind == "Application" and .metadata.name == "apps-arc-agent-harness-agents") | .spec.destination.namespace' 'arc-runners-agent-harness'
assert_yq_ah "$ah_values | .githubConfigUrl" 'https://github.com/SmadjaPaul/agent-harness'
assert_yq_ah "$ah_values | .minRunners" '0'
assert_yq_ah "$ah_values | .maxRunners" '1'
assert_yq_ah "$ah_values | .template.spec.automountServiceAccountToken" 'false'
# PLT-490: the common CI scale set carries NO secret (pull_request jobs run PR code); the pr-triage
# Agentgateway key (PLT-453) is mounted only in the dedicated agents scale set (one optional secretKeyRef
# env var from the generated copy pr-triage-agentgateway). No envFrom anywhere; scratch volume mounts only (PLT-417).
ah_agents_values='select(.kind == "Application" and .metadata.name == "apps-arc-agent-harness-agents") | .spec.source.helm.valuesObject'
for v in "$ah_values" "$ah_agents_values"; do
  assert_yq_ah "$v | .template.spec.containers[0] | has(\"envFrom\")" 'false'
  assert_yq_ah "$v | [.template.spec.containers[0].volumeMounts[].name] | join(\",\")" 'work,tmp'
  assert_yq_ah "$v | .githubConfigUrl" 'https://github.com/SmadjaPaul/agent-harness'
  assert_yq_ah "$v | .maxRunners" '1'
done
assert_yq_ah "$ah_values | .template.spec.containers[0] | has(\"env\")" 'false'
assert_yq_ah "$ah_agents_values | .template.spec.containers[0].env | length" '1'
assert_yq_ah "$ah_agents_values | .template.spec.containers[0].env[0].name" 'PR_TRIAGE_AGENTGATEWAY_KEY'
assert_yq_ah "$ah_agents_values | .template.spec.containers[0].env[0] | [.name, .valueFrom.secretKeyRef.name, .valueFrom.secretKeyRef.optional, has(\"value\")] | join(\",\")" 'PR_TRIAGE_AGENTGATEWAY_KEY,pr-triage-agentgateway,true,false'
# PLT-455: only the sentinel policy may reach the Kubernetes API (toEntities kube-apiserver); no CIDR anywhere.
assert_yq_ah 'select(.kind == "CiliumNetworkPolicy") | [.spec.egress[]?.toCIDR[]?] | length' '0'
assert_yq_ah 'select(.kind == "CiliumNetworkPolicy" and .metadata.name != "incident-sentinel-egress") | [.spec.egress[]?.toEntities[]?] | length' '0'
assert_yq_ah 'select(.kind == "CiliumNetworkPolicy" and .metadata.name == "incident-sentinel-egress") | [.spec.egress[]?.toEntities[]?] | join(",")' 'kube-apiserver'
assert_yq_ah 'select(.kind == "Application" and .metadata.name == "apps-arc-agent-harness-sentinel") | .spec.source.helm.valuesObject.template.spec.serviceAccountName' 'incident-sentinel'
assert_yq_ah 'select(.kind == "Application" and .metadata.name == "apps-arc-agent-harness-sentinel") | .spec.source.helm.valuesObject.template.spec.containers[0].env | map(.name) | join(",")' 'INCIDENT_SENTINEL_AGENTGATEWAY_KEY'
rm -f "$agent_harness_rendered"
for project in "$infrastructure_project" "$applications_project"; do
  grep -F -- '    - namespace: arc-runners-agent-harness' "$project" >/dev/null || {
    printf 'ARC_GITOPS_CONTRACT=FAIL agent-harness-namespace-not-in-appproject file=%s\n' "$project" >&2
    exit 1
  }
done
grep -F -- 'path: k8s/optional/github-actions-arc-agent-harness' \
  "$repo_root/k8s/bootstrap/argocd-root/infrastructure-applicationset.yaml" >/dev/null || {
  printf 'ARC_GITOPS_CONTRACT=FAIL agent-harness-path-not-in-applicationset\n' >&2
  exit 1
}

[[ "$(grep -Ec '^[[:space:]]+automated:' "$rendered")" == "5" ]] || {
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

# PLT-442: the kube-ops PR CI scale set runs PR code, so it never mounts a Kubernetes token.
kube_ops_pr_root="$repo_root/k8s/optional/github-actions-arc-kube-ops-pr"
grep -F -- 'automountServiceAccountToken: false' "$kube_ops_pr_root/runner-application.yaml" >/dev/null || {
  printf 'ARC_GITOPS_CONTRACT=FAIL kube-ops-pr-mounts-token\n' >&2
  exit 1
}
if grep -En 'serviceAccountName:|automountServiceAccountToken:\s*true|kube-apiserver' "$kube_ops_pr_root"/*.yaml; then
  printf 'ARC_GITOPS_CONTRACT=FAIL kube-ops-pr-token-or-apiserver-access\n' >&2
  exit 1
fi
grep -F -- 'path: k8s/optional/github-actions-arc-kube-ops-pr' \
  "$repo_root/k8s/bootstrap/argocd-root/infrastructure-applicationset.yaml" >/dev/null || {
  printf 'ARC_GITOPS_CONTRACT=FAIL kube-ops-pr-path-not-in-applicationset\n' >&2
  exit 1
}

printf 'ARC_GITOPS_CONTRACT=PASS\n'
