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
  k8s/applications/ai
  k8s/applications/media
  k8s/applications/automation
  k8s/applications/web
  k8s/applications/tools
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

forbidden='peekoff\.com|10\.25\.150\.|172\.20\.20\.103|proxmox-csi-2|bitwarden-backend|truenas|s3://|barmanObjectName|kind:[[:space:]]+ObjectStore'
if grep -Ein "$forbidden" "$rendered"; then
  echo "ERROR: active rendered desired state still contains an upstream/legacy storage or secret-provider binding" >&2
  exit 1
fi

inventory="$(awk '
  /^---[[:space:]]*$/ { external=0; want_store=0; want_key=0 }
  /^kind:[[:space:]]*ExternalSecret[[:space:]]*$/ { external=1 }
  external && /^[[:space:]]+secretStoreRef:[[:space:]]*$/ { want_store=1; next }
  external && want_store && /^[[:space:]]+name:[[:space:]]*/ {
    v=$0; sub(/^[[:space:]]+name:[[:space:]]*/, "", v); gsub(/["'"'"']/, "", v)
    print "STORE " v
    want_store=0
  }
  external && /^[[:space:]]+remoteRef:[[:space:]]*$/ { want_key=1; next }
  external && want_key && /^[[:space:]]+key:[[:space:]]*/ {
    v=$0; sub(/^[[:space:]]+key:[[:space:]]*/, "", v); gsub(/["'"'"']/, "", v)
    print "KEY " v
    want_key=0
  }
' "$rendered")"

bad_stores="$(printf '%s\n' "$inventory" | awk '$1=="STORE" && $2!="doppler-cluster" {print $2}' | sort -u)"
if [[ -n "$bad_stores" ]]; then
  echo "ERROR: active ExternalSecrets reference non-Doppler stores:" >&2
  printf '%s\n' "$bad_stores" >&2
  exit 1
fi

bad_keys="$(printf '%s\n' "$inventory" | awk '$1=="KEY" {print $2}' | grep -Ev '^[A-Z][A-Z0-9_]*$' || true)"
if [[ -n "$bad_keys" ]]; then
  echo "ERROR: active Doppler remote keys must be UPPER_SNAKE_CASE:" >&2
  printf '%s\n' "$bad_keys" >&2
  exit 1
fi

echo "ACTIVE_NFS_REFERENCES=0"
echo "ACTIVE_TRUENAS_REFERENCES=0"
echo "ACTIVE_MINIO_S3_BACKUP_REFERENCES=0"
echo "ACTIVE_BITWARDEN_REFERENCES=0"
echo "ACTIVE_DOPPLER_STORES=PASS"
echo "ACTIVE_DOPPLER_REQUIRED_KEYS_BEGIN"
printf '%s\n' "$inventory" | awk '$1=="KEY" {print $2}' | sort -u
echo "ACTIVE_DOPPLER_REQUIRED_KEYS_END"
