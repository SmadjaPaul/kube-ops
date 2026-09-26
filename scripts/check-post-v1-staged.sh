#!/usr/bin/env bash
set -euo pipefail

command -v kustomize >/dev/null 2>&1 || {
  echo "ERROR: kustomize is required" >&2
  exit 2
}

roots=(
  k8s/infrastructure/controllers/argocd-mcp
  k8s/applications/business/stalwart
  k8s/applications/business/bulwark
  k8s/applications/business/twenty
  k8s/applications/business/chatwoot
  k8s/applications/business/messages
  k8s/applications/catalog/renovate
  k8s/applications/catalog/paperless
  k8s/applications/catalog/dawarich
  k8s/applications/catalog/metabase
)

rendered="$(mktemp)"
trap 'rm -f "$rendered"' EXIT

for root in "${roots[@]}"; do
  echo "== render ${root} =="
  kustomize build --enable-helm "$root" >"$rendered"

  if grep -Ein 'peekoff\.com|10\.25\.150\.|172\.20\.20\.103|proxmox-csi-2|bitwarden-backend|truenas|backblaze|BACKBLAZE_|MINIO_|minio\.' "$rendered"; then
    echo "ERROR: staged desired state contains a legacy environment binding: $root" >&2
    exit 1
  fi

  if grep -q 'storageClassName: persistent' "$rendered"; then
    echo "ERROR: staged app still uses upstream storageClassName=persistent: $root" >&2
    exit 1
  fi

  if grep -q 'storageClassName: proxmox-csi' "$rendered"; then
    echo "STAGED_PROXMOX_CSI=${root}:PASS"
  fi

  echo "STAGED_RENDER=${root}:PASS"
done
