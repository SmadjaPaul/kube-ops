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
)

# Minecraft remains explicitly post-V1 (see AGENTS.md). Its root intentionally
# renders no resources until a real LAN TCP/UDP exposure contract is defined;
# it is therefore not part of the active V1 render set.

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
