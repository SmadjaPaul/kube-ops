#!/usr/bin/env bash
set -euo pipefail
root="k8s/applications/media"
media="$root/kustomization.yaml"
pol="k8s/infrastructure/network/policies/applications/media/media"
if grep -Fxq -- '- decypharr' "$media"; then echo 'DECYPHARR_RETIRED=FAIL: forbidden match at line 6' >&2; exit 1; fi
if grep -Fxq -- '- allow-arr-to-decypharr.yaml' "$pol/kustomization.yaml"; then echo 'DECYPHARR_RETIRED=FAIL: forbidden match at line 7' >&2; exit 1; fi
if grep -Eq '^[[:space:]]*-[[:space:]]*qbittorrent([[:space:]]|$)' "$media"; then echo 'DECYPHARR_RETIRED=FAIL: forbidden match at line 8' >&2; exit 1; fi
rendered="$(kustomize build --enable-helm k8s/applications/media)"
if grep -Eq '^[[:space:]]+name: decypharr$' <<<"$rendered"; then echo 'DECYPHARR_RETIRED=FAIL: decypharr still rendered' >&2; exit 1; fi
grep -Fxq -- '- bookorbit' "$media"
grep -Fxq -- '- aiostreams' "$media"
grep -Fxq -- '- audiobookrequest' "$media"
grep -Fxq -- '- polyfin' "$media"
grep -Fxq -- '- media-share-pvc.yaml' "$media"
echo "DECYPHARR_RETIRED=PASS (STATIC_ONLY; NO RUNTIME PROOF)"
