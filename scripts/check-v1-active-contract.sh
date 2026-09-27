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
  AGENTS.md
  README.md
  scripts/bootstrap-cluster.sh
  k8s/infrastructure/application-set.yaml
  k8s/applications/application-set.yaml
)

if grep -En 'theepicsaxguy/homelab|peekoff\.com|10\.25\.150\.' "${control_files[@]}"; then
  echo "ERROR: V1 control files still contain upstream or legacy bindings" >&2
  exit 1
fi

for appset in k8s/infrastructure/application-set.yaml k8s/applications/application-set.yaml; do
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
grep -q 'cloudflared' k8s/infrastructure/network/kustomization.yaml

if grep -Eq '(^|/)(security)(/|$)' k8s/infrastructure/application-set.yaml; then
  echo "ERROR: security stack must stay outside first green" >&2
  exit 1
fi
if grep -Eq 'k8s/applications/(games|business|catalog)' k8s/applications/application-set.yaml; then
  echo "ERROR: post-V1 application groups must stay outside first green" >&2
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
  k8s/applications/ai
  k8s/applications/media
  k8s/applications/automation
  k8s/applications/web
  k8s/applications/tools
)

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

grep -q 'https://fsn1\.your-objectstorage\.com' "$rendered" || {
  echo "ERROR: Hetzner fsn1 endpoint is missing from active desired state" >&2
  exit 1
}

echo "V1_REPOSITORY_BOUNDARY=PASS"
echo "V1_BOOTSTRAP_CONTRACT=PASS"
echo "V1_ACTIVE_RENDER=PASS"
echo "V1_DOPPLER_STORES=PASS"
echo "ACTIVE_DOPPLER_REQUIRED_KEYS_BEGIN"
printf '%s\n' "$inventory" | awk '$1=="KEY" {print $2}' | sort -u
echo "ACTIVE_DOPPLER_REQUIRED_KEYS_END"
