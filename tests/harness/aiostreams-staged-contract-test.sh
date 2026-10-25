#!/usr/bin/env bash
set -euo pipefail
root=k8s/applications/media
pkg="$root/aiostreams"
grep -Fxq -- '- configarr' "$root/kustomization.yaml"
if grep -Fxq -- '- aiostreams' "$root/kustomization.yaml"; then
  echo "AIOSTREAMS_STAGE=FAIL: activation before operator admission"
  exit 1
fi
grep -Fq "APP_AIOSTREAMS_SECRET_KEY" "$pkg/external-secret.yaml"
grep -Fq "APP_AIOSTREAMS_OPERATOR_AUTH" "$pkg/external-secret.yaml"
grep -Fq "ghcr.io/viren070/aiostreams:v2.37.0" "$pkg/deployment.yaml"
grep -Fq 'value: "false"' "$pkg/deployment.yaml"
grep -Fq "FORCE_PROXY_ENABLED" "$pkg/deployment.yaml"
grep -Fq "AIOSTREAMS_AUTH_REQUIRED" "$pkg/deployment.yaml"
grep -Fq "AIOSTREAMS_OIDC_ENABLED" "$pkg/deployment.yaml"
grep -Fq "mountPath: /app/data" "$pkg/deployment.yaml"
grep -Fq "port: \"3000\"" "$pkg/networkpolicy.yaml"
if grep -Eq 'privileged: true|SYS_ADMIN|mountPropagation:' "$pkg/deployment.yaml"; then
  echo "AIOSTREAMS_STAGE=FAIL: privileged capability or mount propagation detected" >&2
  exit 1
fi
if grep -Eq 'api.?key:[[:space:]]+[a-zA-Z0-9]{16,}' "$pkg"/*.yaml; then
  echo "AIOSTREAMS_STAGE=FAIL: inline API key detected" >&2
  exit 1
fi
echo "AIOSTREAMS_STAGED=PASS (STATIC_ONLY; NO IMAGE OR RUNTIME PROOF)"
