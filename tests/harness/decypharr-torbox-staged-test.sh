#!/usr/bin/env bash
set -euo pipefail
root="k8s/applications/media"
media="$root/kustomization.yaml"
pol="k8s/infrastructure/network/policies/applications/media/media"
! grep -Fxq -- '- decypharr' "$media"
! grep -Fxq -- '- allow-arr-to-decypharr.yaml' "$pol/kustomization.yaml"
! grep -Eq '^[[:space:]]*-[[:space:]]*qbittorrent([[:space:]]|$)' "$media"
! kustomize build --enable-helm k8s/applications/media | grep -Eq '^[[:space:]]+name: decypharr$'
grep -Fxq -- '- bookorbit' "$media"
grep -Fxq -- '- aiostreams' "$media"
grep -Fxq -- '- audiobookrequest' "$media"
grep -Fxq -- '- polyfin' "$media"
grep -Fxq -- '- media-share-pvc.yaml' "$media"
echo "DECYPHARR_RETIRED=PASS (STATIC_ONLY; NO RUNTIME PROOF)"
