#!/usr/bin/env bash
set -euo pipefail

command -v kustomize >/dev/null 2>&1 || {
  echo "ERROR: kustomize is required" >&2
  exit 2
}

canonical_repo='https://github.com/SmadjaPaul/kube-ops.git'

if [[ -d tofu ]] || find . -path './.git' -prune -o \( -name '*.tf' -o -name '*.tofu' \) -print -quit | grep -q .; then
  echo "ERROR: kube-ops must not contain Terraform/OpenTofu state or configuration" >&2
  exit 1
fi

control_files=(
  scripts/bootstrap-cluster.sh
  k8s/infrastructure/application-set.yaml
  k8s/applications/application-set.yaml
)

if grep -En 'theepicsaxguy/homelab|peekoff\.com|10\.25\.150\.|truenas|bitwarden-backend|backblaze|MINIO_|minio\.' "${control_files[@]}"; then
  echo "ERROR: V1 control files contain upstream/legacy bindings" >&2
  exit 1
fi

for appset in k8s/infrastructure/application-set.yaml k8s/applications/application-set.yaml; do
  grep -qF "$canonical_repo" "$appset" || {
    echo "ERROR: $appset does not reference the canonical kube-ops repository" >&2
    exit 1
  }
done

if grep -Eq 'path:[[:space:]]+k8s/infrastructure/security' k8s/infrastructure/application-set.yaml; then
  echo "ERROR: security stack must stay outside the first-green ApplicationSet" >&2
  exit 1
fi

if grep -Eq 'path:[[:space:]]+k8s/applications/(games|business|catalog)' k8s/applications/application-set.yaml; then
  echo "ERROR: post-V1 application groups must stay outside first green" >&2
  exit 1
fi

roots=(
  k8s/infrastructure/network/gateway-api-crds
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

forbidden='theepicsaxguy/homelab|peekoff\.com|10\.25\.150\.|172\.20\.20\.103|proxmox-csi-2|bitwarden-backend|truenas|backblaze|BACKBLAZE_|MINIO_|minio\.'
if grep -Ein "$forbidden" "$rendered"; then
  echo "ERROR: active rendered desired state contains a legacy binding" >&2
  exit 1
fi

inventory="$(awk '
  /^---[[:space:]]*$/ { external=0; want_store=0; want_key=0 }
  /^kind:[[:space:]]*ExternalSecret[[:space:]]*$/ { external=1 }
  external && /^[[:space:]]+secretStoreRef:[[:space:]]*$/ { want_store=1; next }
  external && want_store && /^[[:space:]]+name:[[:space:]]*/ {
    v=$0; sub(/^[[:space:]]+name:[[:space:]]*/, "", v); gsub(/["'"'"']/, "", v)
    print "STORE " v; want_store=0
  }
  external && /^[[:space:]]+remoteRef:[[:space:]]*$/ { want_key=1; next }
  external && want_key && /^[[:space:]]+key:[[:space:]]*/ {
    v=$0; sub(/^[[:space:]]+key:[[:space:]]*/, "", v); gsub(/["'"'"']/, "", v)
    print "KEY " v; want_key=0
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
  echo "ERROR: active Doppler remote keys must be UPPER_SNAKE_CASE:" >&2
  printf '%s\n' "$bad_keys" >&2
  exit 1
}

grep -q 'https://fsn1\.your-objectstorage\.com' "$rendered" || {
  echo "ERROR: canonical Hetzner backup endpoint missing" >&2
  exit 1
}

if grep -E 'kind:[[:space:]]+ObjectStore' "$rendered" >/dev/null &&
   ! grep -q 's3://smadja-dev-homelab-backups/cnpg/' "$rendered"; then
  echo "ERROR: CNPG ObjectStores do not target the canonical Hetzner bucket" >&2
  exit 1
fi

echo "ACTIVE_NO_IAC_DUPLICATION=PASS"
echo "ACTIVE_CANONICAL_REPO=PASS"
echo "ACTIVE_FIRST_GREEN_SCOPE=PASS"
echo "ACTIVE_LEGACY_BINDINGS=0"
echo "ACTIVE_HETZNER_BACKUP_ENDPOINT=PASS"
echo "ACTIVE_DOPPLER_STORES=PASS"
echo "ACTIVE_DOPPLER_REQUIRED_KEYS_BEGIN"
printf '%s\n' "$inventory" | awk '$1=="KEY" {print $2}' | sort -u
echo "ACTIVE_DOPPLER_REQUIRED_KEYS_END"
