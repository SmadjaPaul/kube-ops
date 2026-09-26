#!/usr/bin/env bash
set -euo pipefail

command -v kustomize >/dev/null 2>&1 || {
  echo "ERROR: kustomize is required" >&2
  exit 2
}

roots=(
  k8s/infrastructure/controllers
  k8s/infrastructure/network
  k8s/infrastructure/storage
  k8s/infrastructure/database
  k8s/infrastructure/auth
  k8s/infrastructure/security
  k8s/applications/ai
  k8s/applications/media
  k8s/applications/automation
  k8s/applications/web
  k8s/applications/tools
  k8s/applications/business
)

rendered="$(mktemp)"
trap 'rm -f "$rendered"' EXIT

for root in "${roots[@]}"; do
  if [[ ! -f "$root/kustomization.yaml" && ! -f "$root/kustomization.yml" ]]; then
    echo "ERROR: active root has no kustomization: $root" >&2
    exit 1
  fi

  echo "# ROOT: $root" >>"$rendered"
  kustomize build --enable-helm "$root" >>"$rendered"
  printf '\n---\n' >>"$rendered"
done

forbidden='peekoff\.com|10\.25\.150\.|172\.20\.20\.103|proxmox-csi-2|bitwarden-backend|truenas|backblaze|BACKBLAZE_|MINIO_|minio\.'
if grep -Ein "$forbidden" "$rendered"; then
  echo "ERROR: active rendered desired state still contains an upstream/legacy binding" >&2
  exit 1
fi

external_secret_count="$(grep -Ec '^[[:space:]]*kind:[[:space:]]*ExternalSecret[[:space:]]*$' "$rendered" || true)"
if (( external_secret_count == 0 )); then
  echo "ERROR: active desired state unexpectedly renders zero ExternalSecrets" >&2
  exit 1
fi

# Kustomize normalizes inline mappings into block YAML. Record only fields
# inside secretStoreRef/remoteRef blocks from the rendered desired state.
inventory="$(awk '
  /^[[:space:]]*secretStoreRef:[[:space:]]*$/ {
    in_store=1
    in_remote=0
    next
  }
  /^[[:space:]]*remoteRef:[[:space:]]*$/ {
    in_remote=1
    in_store=0
    next
  }
  in_store && /^[[:space:]]*name:[[:space:]]*/ {
    v=$0
    sub(/^[[:space:]]*name:[[:space:]]*/, "", v)
    gsub(/^"/, "", v)
    gsub(/"$/, "", v)
    print "STORE " v
    in_store=0
    next
  }
  in_remote && /^[[:space:]]*key:[[:space:]]*/ {
    v=$0
    sub(/^[[:space:]]*key:[[:space:]]*/, "", v)
    gsub(/^"/, "", v)
    gsub(/"$/, "", v)
    print "KEY " v
    in_remote=0
    next
  }
' "$rendered")"

inventory_key_count="$(printf '%s\n' "$inventory" | awk '$1=="KEY" && length($2)>0 {n++} END {print n+0}')"
if (( inventory_key_count == 0 )); then
  echo "ERROR: rendered ExternalSecrets exist but no remoteRef keys were inventoried" >&2
  exit 1
fi

bad_stores="$(printf '%s\n' "$inventory" | awk '$1=="STORE" && length($2)>0 && $2!="doppler-cluster" {print $2}' | sort -u)"
if [[ -n "$bad_stores" ]]; then
  echo "ERROR: active ExternalSecrets reference non-Doppler stores:" >&2
  printf '%s\n' "$bad_stores" >&2
  exit 1
fi

bad_keys="$(printf '%s\n' "$inventory" | awk '$1=="KEY" && length($2)>0 {print $2}' | grep -Ev '^[A-Z][A-Z0-9_]*$' || true)"
if [[ -n "$bad_keys" ]]; then
  echo "ERROR: active Doppler remote keys must be UPPER_SNAKE_CASE:" >&2
  printf '%s\n' "$bad_keys" >&2
  exit 1
fi

echo "ACTIVE_NFS_REFERENCES=0"
echo "ACTIVE_TRUENAS_REFERENCES=0"
echo "ACTIVE_MINIO_S3_BACKUP_REFERENCES=0"
echo "ACTIVE_BACKBLAZE_REFERENCES=0"
echo "ACTIVE_BITWARDEN_REFERENCES=0"

if ! grep -q 'https://fsn1\.your-objectstorage\.com' "$rendered"; then
  echo "ERROR: Hetzner fsn1 object storage endpoint is not present in active desired state" >&2
  exit 1
fi

if grep -Eq '^[[:space:]]*kind:[[:space:]]*ObjectStore[[:space:]]*$' "$rendered" &&
   ! grep -q 's3://smadja-dev-homelab-backups/cnpg/' "$rendered"; then
  echo "ERROR: active CNPG ObjectStores are not targeting the canonical Hetzner bucket" >&2
  exit 1
fi

echo "ACTIVE_HETZNER_BACKUP_ENDPOINT=PASS"
echo "ACTIVE_EXTERNAL_SECRET_COUNT=$external_secret_count"
echo "ACTIVE_DOPPLER_STORES=PASS"
echo "ACTIVE_DOPPLER_REQUIRED_KEYS_BEGIN"
printf '%s\n' "$inventory" | awk '$1=="KEY" && length($2)>0 {print $2}' | sort -u
echo "ACTIVE_DOPPLER_REQUIRED_KEYS_END"
