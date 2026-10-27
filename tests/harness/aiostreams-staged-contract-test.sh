#!/usr/bin/env bash
set -euo pipefail
root=k8s/applications/media
pkg="$root/aiostreams"
grep -Fxq -- '- configarr' "$root/kustomization.yaml"
grep -Fxq -- '- aiostreams' "$root/kustomization.yaml"
grep -Fq "APP_AIOSTREAMS_SECRET_KEY" "$pkg/external-secret.yaml"
grep -Fq "APP_AIOSTREAMS_OPERATOR_AUTH" "$pkg/external-secret.yaml"
grep -Fq "ghcr.io/viren070/aiostreams:v2.37.0" "$pkg/deployment.yaml"
grep -Fq 'ghcr.io/viren070/aiostreams:v2.37.0@sha256:bcfd8580695a50c8f464578a0e25af065f3bd17eac35ed82a733a18342ca9718' "$pkg/deployment.yaml"
grep -Fq 'value: "false"' "$pkg/deployment.yaml"
grep -Fq "FORCE_PROXY_ENABLED" "$pkg/deployment.yaml"
grep -Fq "AIOSTREAMS_AUTH_REQUIRED" "$pkg/deployment.yaml"
grep -Fq "AIOSTREAMS_OIDC_ENABLED" "$pkg/deployment.yaml"
grep -Fq "name: ANIME_DB_LEVEL_OF_DETAIL" "$pkg/deployment.yaml"
grep -Fq "value: none" "$pkg/deployment.yaml"
grep -Fq "mountPath: /app/data" "$pkg/deployment.yaml"
grep -Fq "runAsNonRoot: true" "$pkg/deployment.yaml"
grep -Fq "runAsUser: 2501" "$pkg/deployment.yaml"
grep -Fq "runAsGroup: 2501" "$pkg/deployment.yaml"
grep -Fq "readOnlyRootFilesystem: true" "$pkg/deployment.yaml"
grep -Fq "path: /api/v1/health" "$pkg/deployment.yaml"
grep -Fq "port: \"3000\"" "$pkg/networkpolicy.yaml"
grep -Fq -- '- name: internal' "$pkg/http-route.yaml"
if grep -Fq -- '- name: external' "$pkg/http-route.yaml"; then
  echo "AIOSTREAMS_STAGE=FAIL: staged route must not attach to Gateway/external" >&2
  exit 1
fi
if grep -Eq 'toEntities:[[:space:]]*$|-[[:space:]]+world([[:space:]]|$)' "$pkg/networkpolicy.yaml"; then
  echo "AIOSTREAMS_STAGE=FAIL: staged workload must not have blanket world egress" >&2
  exit 1
fi
# The active private app now has an explicit metadata/addon control-plane
# FQDN allowlist. Stronger endpoint/port assertions are enforced by the scoped
# egress contract.
grep -Fq 'matchName: api.torbox.app' "$pkg/networkpolicy.yaml"
grep -Fq 'matchName: search-api.torbox.app' "$pkg/networkpolicy.yaml"
grep -Fq 'matchName: v3-cinemeta.strem.io' "$pkg/networkpolicy.yaml"
grep -Fq 'matchName: v3.sg.media-imdb.com' "$pkg/networkpolicy.yaml"
grep -Fq 'matchName: remuxdb.1632022.xyz' "$pkg/networkpolicy.yaml"
grep -Fq 'matchName: comet.feels.legal' "$pkg/networkpolicy.yaml"
grep -Fq 'matchName: meteorfortheweebs.midnightignite.me' "$pkg/networkpolicy.yaml"
grep -Fq 'matchName: stremthru.13377001.xyz' "$pkg/networkpolicy.yaml"
grep -Fq 'matchName: opensubtitles.stremio.homes' "$pkg/networkpolicy.yaml"
grep -Fq 'https://aiostreams.smadja.dev/api/v1/auth/oidc/callback' \
  k8s/infrastructure/auth/authentik/extra/blueprints/apps-aiostreams.yaml
grep -Fq 'APP_AIOSTREAMS_OIDC_CLIENT_SECRET' "$pkg/oidc-external-secret.dormant.yaml"
grep -Fq 'production data' "$pkg/README.md"
if grep -Eq 'AIOSTREAMS_CLIENT_SECRET:[[:space:]]*[A-Za-z0-9]' \
  k8s/infrastructure/auth/authentik/extra/blueprints/apps-aiostreams.yaml; then
  echo "AIOSTREAMS_STAGE=FAIL: OIDC client secret must remain environment-backed" >&2
  exit 1
fi
if grep -Eq 'privileged: true|SYS_ADMIN|mountPropagation:' "$pkg/deployment.yaml"; then
  echo "AIOSTREAMS_STAGE=FAIL: privileged capability or mount propagation detected" >&2
  exit 1
fi
if grep -Eq 'api.?key:[[:space:]]+[a-zA-Z0-9]{16,}' "$pkg"/*.yaml; then
  echo "AIOSTREAMS_STAGE=FAIL: inline API key detected" >&2
  exit 1
fi
echo "AIOSTREAMS_PRIVATE_ADMISSION=PASS (STATIC_ONLY; NO IMAGE OR RUNTIME PROOF)"
