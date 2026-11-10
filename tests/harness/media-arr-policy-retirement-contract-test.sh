#!/usr/bin/env bash
set -euo pipefail

policy_dir=k8s/infrastructure/network/policies/applications/media/media
kustom="$policy_dir/kustomization.yaml"
rendered="$(mktemp)"
trap 'rm -f "$rendered"' EXIT

# Retain the source manifests as historical evidence, but make the active
# Kustomize graph contain only the shared media policy.
for legacy in \
  allow-prowlarr-to-arr.yaml \
  allow-arr-to-prowlarr.yaml \
  allow-arr-to-decypharr.yaml; do
  test -s "$policy_dir/$legacy"
  ! grep -Fxq -- "- $legacy" "$kustom"
done
grep -Fxq -- '- allow-media-access.yaml' "$kustom"

kustomize build k8s/infrastructure/network/policies/applications/media >"$rendered"
grep -Fq 'name: media-access' "$rendered"
for retired in prowlarr-to-arr arr-to-prowlarr arr-to-decypharr; do
  if grep -Fq "name: $retired" "$rendered"; then
    echo "MEDIA_ARR_POLICY_RETIREMENT=FAIL rendered=$retired" >&2
    exit 1
  fi
done

echo 'MEDIA_ARR_POLICY_RETIREMENT=PASS (HISTORICAL_SOURCES_RETAINED_ACTIVE_GRAPH_CLEAN)'
