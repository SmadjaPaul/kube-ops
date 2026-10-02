#!/usr/bin/env bash
set -euo pipefail

command -v kustomize >/dev/null 2>&1 || {
  echo "ERROR: kustomize is required" >&2
  exit 2
}

canonical_repo='https://github.com/SmadjaPaul/kube-ops.git'

if [[ -d tofu ]]; then
  echo "ERROR: kube-ops must not contain a tofu/ root; external/Talos IaC belongs to homelab-infra" >&2
  exit 1
fi

iac_files="$(find . -type f \( -name '*.tf' -o -name '*.tofu' \) -not -path './.git/*' -print)"
if [[ -n "$iac_files" ]]; then
  echo "ERROR: Terraform/OpenTofu files are forbidden in kube-ops:" >&2
  printf '%s\n' "$iac_files" >&2
  exit 1
fi

control_files=(
  scripts/bootstrap-cluster.sh
  k8s/bootstrap/argocd-root/infrastructure-applicationset.yaml
  k8s/bootstrap/argocd-root/applications-applicationset.yaml
)

if grep -En 'theepicsaxguy/homelab|peekoff\.com|10\.25\.150\.' "${control_files[@]}"; then
  echo "ERROR: V1 control files still contain upstream or legacy bindings" >&2
  exit 1
fi

for appset in k8s/bootstrap/argocd-root/infrastructure-applicationset.yaml k8s/bootstrap/argocd-root/applications-applicationset.yaml; do
  grep -qF "$canonical_repo" "$appset" || {
    echo "ERROR: $appset does not reference the canonical repository" >&2
    exit 1
  }
done

grep -q 'version: 1.20.2' k8s/infrastructure/network/cilium/kustomization.yaml
grep -q 'v1.6.1' k8s/infrastructure/network/gateway-api/kustomization.yaml
grep -q 'version: 0.5.12' k8s/infrastructure/storage/proxmox-csi/kustomization.yaml
grep -q 'volumeBindingMode: WaitForFirstConsumer' k8s/infrastructure/storage/proxmox-csi/values.yaml
grep -q 'PROXMOX_CSI_TOKEN_ID' k8s/infrastructure/storage/proxmox-csi/externalsecret.yaml
grep -q 'PROXMOX_CSI_TOKEN_SECRET' k8s/infrastructure/storage/proxmox-csi/externalsecret.yaml

# Longhorn is introduced as a staged V1 storage backend while Proxmox CSI
# remains available for existing PVCs. It must not become the default until the
# dedicated Talos data volume and runtime storage canary are proven.
grep -q 'version: 1.12.1' k8s/infrastructure/storage/longhorn/kustomization.yaml
grep -q 'defaultClass: false' k8s/infrastructure/storage/longhorn/values.yaml
grep -q 'createStorageClass: false' k8s/infrastructure/storage/longhorn/values.yaml
grep -q 'defaultDataPath: /var/mnt/k8s-fast/longhorn' k8s/infrastructure/storage/longhorn/values.yaml
grep -q 'v2DataEngine: false' k8s/infrastructure/storage/longhorn/values.yaml
grep -q 'name: longhorn-fast' k8s/infrastructure/storage/longhorn/storageclasses.yaml
grep -q 'diskSelector: fast' k8s/infrastructure/storage/longhorn/storageclasses.yaml
grep -q 'name: longhorn-bulk' k8s/infrastructure/storage/longhorn/storageclasses.yaml
grep -q 'diskSelector: bulk' k8s/infrastructure/storage/longhorn/storageclasses.yaml
grep -q 'path: /var/mnt/k8s-fast' k8s/infrastructure/storage/longhorn/node-homeops.yaml
grep -q 'path: /var/mnt/k8s-bulk' k8s/infrastructure/storage/longhorn/node-homeops.yaml
grep -q 'cloudflared' k8s/infrastructure/network/kustomization.yaml

# Backend/admin surfaces that are only consumed from inside the cluster or LAN
# must never attach to the public Gateway. Qdrant is consumed by Open WebUI via
# its ClusterIP service; Zigbee2MQTT is an operator UI.
for internal_route in \
  k8s/applications/ai/qdrant/httproute.yaml; do
  grep -q 'name: internal' "$internal_route" || {
    echo "ERROR: $internal_route must attach to the internal Gateway" >&2
    exit 1
  }
  if grep -q 'name: external' "$internal_route"; then
    echo "ERROR: $internal_route must not attach to the external Gateway" >&2
    exit 1
  fi
done

# LiteLLM is a privileged provider-credential broker. V1 uses the official
# Helm chart, stable provider-neutral lanes and an in-cluster Von classifier.
litellm_values='k8s/applications/ai/litellm/values.yaml'
litellm_application='k8s/applications/ai/litellm-helm-application.yaml'
litellm_kustomization='k8s/applications/ai/litellm/kustomization.yaml'
litellm_provider_secrets='k8s/applications/ai/litellm/litellm-provider-secrets.yaml'
von_deployment='k8s/applications/ai/litellm/von-deployment.yaml'
litellm_network_policy='k8s/infrastructure/network/policies/applications/ai/litellm/allow-litellm-access.yaml'

grep -q 'chart: litellm-helm' "$litellm_application"
grep -q 'targetRevision: 1.103.2' "$litellm_application"
grep -q 'repoURL: ghcr.io/berriai' "$litellm_application"
grep -q 'tag: v1.103.2' "$litellm_values"
grep -q 'migrationJob:' "$litellm_values"
grep -q 'enabled: true' "$litellm_values"
grep -q 'useExisting: true' "$litellm_values"
grep -q 'litellm-postgresql-restored-rw.litellm.svc.cluster.local:5432' "$litellm_values"
grep -q 'require_auth_for_metrics_endpoint: true' "$litellm_values"
grep -q 'turn_off_message_logging: true' "$litellm_values"
grep -q 'redact_user_api_key_info: true' "$litellm_values"
grep -q 'redact_messages_in_exceptions: true' "$litellm_values"
grep -q 'store_prompts_in_spend_logs: false' "$litellm_values"
grep -q 'allow_requests_on_db_unavailable: false' "$litellm_values"
grep -q 'store_model_in_db: false' "$litellm_values"
grep -q 'enable_pre_call_checks: true' "$litellm_values"
for model_lane in research fast code reasoning review auto; do
  grep -q "model_name: $model_lane" "$litellm_values" || {
    echo "ERROR: LiteLLM is missing stable model lane: $model_lane" >&2
    exit 1
  }
done
grep -q 'model: dashscope/qwen3.8-flash' "$litellm_values"
grep -q 'model: dashscope/qwen3.8-max' "$litellm_values"
grep -q 'model: xiaomi_mimo/mimo-v2.6-flash' "$litellm_values"
grep -q 'model: xiaomi_mimo/mimo-v2.6-pro' "$litellm_values"
grep -q 'classifier_type: jev' "$litellm_values"
grep -q 'model: von-latest' "$litellm_values"
grep -q 'classifier_fallback: heuristic' "$litellm_values"
grep -q 'classifier_context_window_size: 3' "$litellm_values"
grep -q 'TYPESAFE_API_BASE: "http://von.litellm.svc.cluster.local:8000"' "$litellm_values"
grep -q 'ghcr.io/wfzyx/von:1.3.7-cpu' "$von_deployment"
grep -q 'openvino' "$von_deployment"
grep -q -- '--on-overflow' "$von_deployment"
grep -q 'APP_VON_API_KEY' k8s/applications/ai/litellm/von-secrets.yaml
grep -q 'APP_XIAOMI_MIMO_API_KEY' "$litellm_provider_secrets"
grep -q 'APP_ALIBABA_MODEL_STUDIO_API_KEY' "$litellm_provider_secrets"
grep -q 'APP_ALIBABA_MODEL_STUDIO_BASE_URL' "$litellm_provider_secrets"
grep -q 'api.xiaomimimo.com' "$litellm_network_policy"
grep -q '\*.eu-central-1.maas.aliyuncs.com' "$litellm_network_policy"
if grep -q 'api.typesafe.ai' "$litellm_network_policy"; then
  echo "ERROR: LiteLLM must classify through in-cluster Von, not TypeSafe cloud" >&2
  exit 1
fi
if grep -q 'deployment.yaml\|svc.yaml\|proxy_server_config.yaml' "$litellm_kustomization"; then
  echo "ERROR: raw LiteLLM proxy manifests/config must not coexist with the Helm authority" >&2
  exit 1
fi

# Authentik V1 stays on the current stable series and uses upstream-native
# authentication flows rather than carrying a parallel passwordless graph.
grep -q 'version: 2026.8.3' k8s/infrastructure/auth/authentik/kustomization.yaml
grep -q 'type: ClusterIP' k8s/infrastructure/auth/authentik/values.yaml
grep -q 'base_url: "https://auth.smadja.dev"' k8s/infrastructure/auth/authentik/values.yaml
grep -q 'disable_startup_analytics: true' k8s/infrastructure/auth/authentik/values.yaml
grep -q 'disable_update_check: true' k8s/infrastructure/auth/authentik/values.yaml
grep -q './blueprints/authentication.yaml' k8s/infrastructure/auth/authentik/extra/kustomization.yml
grep -q 'domain: authentik-default' k8s/infrastructure/auth/authentik/extra/blueprints/brands.yaml
grep -q 'branding_default_flow_background: /static/dist/assets/images/flow_background.jpg' k8s/infrastructure/auth/authentik/extra/blueprints/brands.yaml
if grep -q 'flows-passwordless-authentication.yaml\|flows-default-authentication-passwordless.yaml\|flows-webauthn-setup.yaml' k8s/infrastructure/auth/authentik/extra/kustomization.yml; then
  echo "ERROR: Authentik must use the upstream-native authentication baseline" >&2
  exit 1
fi
if grep -q 'homelab\.orkestack\.com\|sso\.smadja\.dev' k8s/infrastructure/auth/authentik/extra/blueprints/{brands,outposts}.yaml; then
  echo "ERROR: Authentik branding/outposts contain stale external bindings" >&2
  exit 1
fi

roots=(
  k8s/infrastructure/controllers
  k8s/infrastructure/network
  k8s/infrastructure/storage
  k8s/infrastructure/monitoring
  k8s/infrastructure/deployment
  k8s/infrastructure/database
  k8s/infrastructure/auth
  k8s/infrastructure/security
  k8s/applications/ai
  k8s/applications/media
  k8s/applications/automation
  k8s/applications/web
  k8s/applications/tools
  k8s/applications/business
  k8s/applications/catalog
  k8s/applications/games
)

# Minecraft remains post-V1, but the games root is now active because RomM is
# part of the V1 desired state.

rendered="$(mktemp)"
trap 'rm -f "$rendered"' EXIT

for root in "${roots[@]}"; do
  [[ -f "$root/kustomization.yaml" || -f "$root/kustomization.yml" ]] || {
    echo "ERROR: active root has no kustomization: $root" >&2
    exit 1
  }
  echo "# ROOT: $root" >>"$rendered"
  kustomize build --enable-helm "$root" >>"$rendered"
  printf '\n---\n' >>"$rendered"
done

command -v kubeconform >/dev/null 2>&1 || {
  echo "ERROR: kubeconform is required" >&2
  exit 2
}
command -v yq >/dev/null 2>&1 || {
  echo "ERROR: yq is required" >&2
  exit 2
}
yq eval 'select(.kind != "CustomResourceDefinition")' "$rendered" |   kubeconform -strict -summary -ignore-missing-schemas -kubernetes-version 1.36.0

# A root may deliberately leave a post-V1 component out of its kustomization
# while retaining its upstream manifests for later activation. Validate what is
# actually rendered by an active root rather than treating inactive source
# files as runtime desired state.
forbidden='peekoff\.com|10\.25\.150\.|172\.20\.20\.103|proxmox-csi-2|bitwarden-backend|truenas|backblaze|BACKBLAZE_|MINIO_|minio\.'
if grep -Ein "$forbidden" "$rendered"; then
  echo "ERROR: active rendered desired state contains a legacy binding" >&2
  exit 1
fi

inventory="$(awk '
  /^---[[:space:]]*$/ { external=0; want_store=0; want_key=0 }
  /^kind:[[:space:]]*ExternalSecret[[:space:]]*$/ { external=1 }
  external && /^[[:space:]]+secretStoreRef:[[:space:]]*$/ { want_store=1; next }
  external && want_store && /^[[:space:]]+name:[[:space:]]*/ {
    v=$0; sub(/^[[:space:]]+name:[[:space:]]*/, "", v); gsub(/["'\''"]/, "", v)
    print "STORE " v
    want_store=0
  }
  external && /^[[:space:]]+remoteRef:[[:space:]]*$/ { want_key=1; next }
  external && want_key && /^[[:space:]]+key:[[:space:]]*/ {
    v=$0; sub(/^[[:space:]]+key:[[:space:]]*/, "", v); gsub(/["'\''"]/, "", v)
    print "KEY " v
    want_key=0
  }
' "$rendered")"

bad_stores="$(printf '%s\n' "$inventory" | awk '$1=="STORE" && $2!="doppler-cluster" {print $2}' | sort -u)"
[[ -z "$bad_stores" ]] || {
  echo "ERROR: active ExternalSecrets reference non-Doppler stores:" >&2
  printf '%s\n' "$bad_stores" >&2
  exit 1
}

bad_keys="$(printf '%s\n' "$inventory" | awk '$1=="KEY" {print $2}' | grep -Ev '^[A-Z][A-Z0-9_]*$' || true)"
[[ -z "$bad_keys" ]] || {
  echo "ERROR: active Doppler keys must be UPPER_SNAKE_CASE:" >&2
  printf '%s\n' "$bad_keys" >&2
  exit 1
}

# Backup resources are part of the full desired-state contract. When CNPG
# object-store resources are active, they must retain the canonical Hetzner
# endpoint; credentials remain externally provisioned through Doppler/ESO.
if grep -q '^kind:[[:space:]]*\(ObjectStore\|ScheduledBackup\)[[:space:]]*$' "$rendered"; then
  grep -q 'https://fsn1\.your-objectstorage\.com' "$rendered" || {
    echo "ERROR: active backup resources are missing the Hetzner fsn1 endpoint" >&2
    exit 1
  }
fi

echo "V1_REPOSITORY_BOUNDARY=PASS"
echo "V1_BOOTSTRAP_CONTRACT=PASS"
echo "V1_ACTIVE_RENDER=PASS"
echo "V1_DOPPLER_STORES=PASS"
echo "ACTIVE_DOPPLER_REQUIRED_KEYS_BEGIN"
printf '%s\n' "$inventory" | awk '$1=="KEY" {print $2}' | sort -u
echo "ACTIVE_DOPPLER_REQUIRED_KEYS_END"
