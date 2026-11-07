#!/usr/bin/env bash
set -euo pipefail
root=k8s/applications/media
pkg="$root/aiostreams"
grep -Fxq -- '- aiostreams' "$root/kustomization.yaml"
grep -Fq "APP_AIOSTREAMS_SECRET_KEY" "$pkg/external-secret.yaml"
grep -Fq "APP_AIOSTREAMS_OPERATOR_AUTH" "$pkg/external-secret.yaml"
grep -Fq "ghcr.io/viren070/aiostreams:v2.37.0" "$pkg/deployment.yaml"
grep -Fq 'ghcr.io/viren070/aiostreams:v2.37.0@sha256:bcfd8580695a50c8f464578a0e25af065f3bd17eac35ed82a733a18342ca9718' "$pkg/deployment.yaml"
grep -Fq 'value: "false"' "$pkg/deployment.yaml"
grep -Fq "FORCE_PROXY_ENABLED" "$pkg/deployment.yaml"
grep -Fq "AIOSTREAMS_AUTH_REQUIRED" "$pkg/deployment.yaml"
grep -Fq "name: JELLYFIN_PIN_SIGN_IN" "$pkg/deployment.yaml"
grep -A1 -F "name: JELLYFIN_PIN_SIGN_IN" "$pkg/deployment.yaml" | grep -Fq 'value: "false"'
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
grep -Fxq 'aiostreams.smadja.dev' <(yq -r '.spec.hostnames[]' "$pkg/http-route.yaml")
if grep -Fxq 'tv.smadja.dev' <(yq -r '.spec.hostnames[]' "$pkg/http-route.yaml"); then
  echo "AIOSTREAMS_STAGE=FAIL: family hostname must use its dedicated route" >&2
  exit 1
fi
# PLT-135 cutover: keep the same Argo-managed HTTPRoute object/identity.
# No simultaneous second tv.smadja.dev route: PruneLast is irrelevant.
family="$pkg/family-http-route.yaml"
grep -Fxq -- '- family-http-route.yaml' "$pkg/kustomization.yaml"
yq -e '.apiVersion == "gateway.networking.k8s.io/v1" and .kind == "HTTPRoute" and .metadata.name == "aiostreams-family" and .metadata.namespace == "media"' "$family" >/dev/null
[[ "$(yq -r '.spec.hostnames | join(",")' "$family")" == "tv.smadja.dev" ]]
[[ "$(yq -r '.spec.parentRefs[].name' "$family" | LC_ALL=C sort | tr '\n' ',')" == "external,internal," ]]
[[ "$(yq -r '.spec.parentRefs[].namespace' "$family" | LC_ALL=C sort -u)" == "gateway" ]]
yq -e '.spec.rules | length == 1' "$family" >/dev/null
yq -e '.spec.rules[0].matches | length == 1' "$family" >/dev/null
yq -e '.spec.rules[0].matches[0].path.type == "PathPrefix" and .spec.rules[0].matches[0].path.value == "/"' "$family" >/dev/null
yq -e '.spec.rules[0].backendRefs | length == 1' "$family" >/dev/null
yq -e '.spec.rules[0].backendRefs[0].name == "polyfin" and .spec.rules[0].backendRefs[0].port == 80' "$family" >/dev/null
yq -e '.spec.rules[0].filters == null' "$family" >/dev/null
grep -Fq -- 'name: polyfin' "$root/polyfin/service.yaml"
grep -Fq -- 'port: 80' "$root/polyfin/service.yaml"
# Keep the previous Polyfin media alias and AIOStreams internal control route.
[[ "$(yq -r '.spec.hostnames | join(",")' "$root/polyfin-media-route.yaml")" == "media.smadja.dev" ]]
[[ "$(yq -r '.spec.parentRefs[].name' "$root/polyfin-media-route.yaml")" == "internal" ]]
[[ "$(yq -r '.spec.hostnames | join(",")' "$pkg/http-route.yaml")" == "aiostreams.smadja.dev" ]]
# Strict dual callbacks, without an OIDC client secret in Git.
auth=k8s/infrastructure/auth/authentik/extra/blueprints/apps-polyfin.yaml
[[ "$(yq -r '.entries[] | select(.id == "polyfin_provider") | .attrs.redirect_uris[].url' "$auth" | LC_ALL=C sort | tr '\n' ',')" == "https://media.smadja.dev/admin/api/provider/callback,https://tv.smadja.dev/admin/api/provider/callback," ]]
[[ "$(yq -r '.entries[] | select(.id == "polyfin_provider") | .attrs.redirect_uris[].matching_mode' "$auth" | LC_ALL=C sort -u)" == "strict" ]]
[[ "$(yq -r '.entries[] | select(.id == "polyfin_application") | .attrs.meta_launch_url' "$auth")" == "https://tv.smadja.dev" ]]
grep -Fq 'client_secret: !Env POLYFIN_OIDC_CLIENT_SECRET' "$auth"
# Ensure historical Polyfin route remains disabled, preventing duplicate hostname claims.
! grep -Eq '^[[:space:]]*-[[:space:]]+http-route\.yaml[[:space:]]*$' "$root/polyfin/kustomization.yaml"
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
grep -Fq 'matchName: opensubtitles-v3.strem.io' "$pkg/networkpolicy.yaml"
grep -Fq 'matchName: tmdb.elfhosted.com' "$pkg/networkpolicy.yaml"
grep -Fq 'matchName: 1fe84bc728af-stremio-anime-catalogs.baby-beamup.club' "$pkg/networkpolicy.yaml"
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
