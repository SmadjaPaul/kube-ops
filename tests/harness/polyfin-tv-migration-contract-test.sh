#!/usr/bin/env bash
# PLT-135: enforce each phase of the two-step tv.smadja.dev migration.
# Static assertions only. Passing does not authorize public rollout.
set -euo pipefail
route=k8s/applications/media/polyfin-media-route.yaml
aio=k8s/applications/media/aiostreams
auth=k8s/infrastructure/auth/authentik/extra/blueprints/apps-polyfin.yaml
fail() { echo "POLYFIN_TV_MIGRATION=FAIL: $*" >&2; exit 1; }
has() { yq -e "$2" "$1" >/dev/null || fail "$1: $2"; }
not_has() { ! yq -e "$2" "$1" >/dev/null 2>&1 || fail "$1 must not match: $2"; }

has "$route" '.kind == "HTTPRoute" and .metadata.name == "polyfin-media" and .metadata.namespace == "media"'
parents="$(yq -r '.spec.parentRefs[].name' "$route" | LC_ALL=C sort | tr '\n' ',')"
[[ "$parents" == "external,internal," ]] || fail "Polyfin must attach to both gateways; got $parents"
has "$route" '.spec.rules | length == 1'
has "$route" '.spec.rules[0].matches[0].path.type == "PathPrefix" and .spec.rules[0].matches[0].path.value == "/"'
has "$route" '.spec.rules[0].backendRefs[0].name == "polyfin" and .spec.rules[0].backendRefs[0].port == 80'

# Check redirect_uri exactness; never accept URL wildcards or a plaintext secret.
callbacks="$(yq -r '.entries[] | select(.id == "polyfin_provider") | .attrs.redirect_uris[].url' "$auth" | LC_ALL=C sort | tr '\n' ',')"
[[ "$callbacks" == "https://media.smadja.dev/admin/api/provider/callback,https://tv.smadja.dev/admin/api/provider/callback," ]] || fail "expected exact callbacks media and tv"
modes="$(yq -r '.entries[] | select(.id == "polyfin_provider") | .attrs.redirect_uris[].matching_mode' "$auth" | LC_ALL=C sort | tr '\n' ',')"
[[ "$modes" == "strict,strict," ]] || fail "callbacks must be strict"
grep -Fq 'client_secret: !Env POLYFIN_OIDC_CLIENT_SECRET' "$auth" || fail "OIDC secret must remain environment backed"
[[ "$(yq -r '.spec.parentRefs[].name' "$aio/http-route.yaml")" == "internal" ]] || fail "AIOStreams control route must remain private"
[[ "$(yq -r '.spec.hostnames[]' "$aio/http-route.yaml")" == "aiostreams.smadja.dev" ]] || fail "AIOStreams control hostname must be internal-only"
not_has "$aio/http-route.yaml" '.spec.hostnames[] == "tv.smadja.dev"'

if yq -e '.spec.hostnames | contains(["tv.smadja.dev"])' "$route" >/dev/null; then
  # Stage 2: tv is Polyfin's stable canonical address; old media alias remains
  # available for existing clients during migration.
  hosts="$(yq -r '.spec.hostnames[]' "$route" | LC_ALL=C sort | tr '\n' ',')"
  [[ "$hosts" == "media.smadja.dev,tv.smadja.dev," ]] || fail "Polyfin must own media and tv only"
  ! grep -Fq -- '- family-http-route.yaml' "$aio/kustomization.yaml" || fail "legacy public AIOStreams tv route still enabled"
  has "$auth" '.entries[] | select(.id == "polyfin_application") | .attrs.meta_launch_url == "https://tv.smadja.dev"'
  phase=cutover
else
  # Stage 1: no second owner of tv. Qualify media public first.
  [[ "$(yq -r '.spec.hostnames[]' "$route")" == "media.smadja.dev" ]] || fail "stage1 must not take tv yet"
  grep -Fq -- '- family-http-route.yaml' "$aio/kustomization.yaml" || fail "AIOStreams family route missing before cutover"
  [[ "$(yq -r '.spec.parentRefs[].name' "$aio/family-http-route.yaml")" == "external" ]] || fail "AIOStreams tv route must be external-only before cutover"
  [[ "$(yq -r '.spec.hostnames[]' "$aio/family-http-route.yaml")" == "tv.smadja.dev" ]] || fail "unexpected AIOStreams family hostname"
  has "$auth" '.entries[] | select(.id == "polyfin_application") | .attrs.meta_launch_url == "https://media.smadja.dev"'
  phase=canary
fi

# Prevent accidental collision with dormant historic private pilot fixtures.
! grep -Eq '^[[:space:]]*-[[:space:]]+http-route\.yaml[[:space:]]*$' \
  k8s/applications/media/polyfin/kustomization.yaml || fail "historic tv Polyfin HTTPRoute activated"
# No long-lived external video relay should be added as part of this cutover.
! grep -Eq '^\s*- name: external\s*$' "$aio/http-route.yaml" || fail "AIOStreams internal control route became public"
echo "POLYFIN_TV_MIGRATION=PASS phase=$phase (STATIC_ONLY; EXTERNAL_ROLLOUT_NOT_AUTHORIZED)"
