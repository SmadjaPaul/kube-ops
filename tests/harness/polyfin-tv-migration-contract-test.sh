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
has "$route" '([.spec.parentRefs[].name] | sort) == ["external", "internal"]'
has "$route" '.spec.rules | length == 1'
has "$route" '.spec.rules[0].matches[0].path.type == "PathPrefix" and .spec.rules[0].matches[0].path.value == "/"'
has "$route" '.spec.rules[0].backendRefs[0].name == "polyfin" and .spec.rules[0].backendRefs[0].port == 80'

# Check redirect_uri exactness; never accept URL wildcards or a plaintext secret.
has "$auth" '([.entries[] | select(.id == "polyfin_provider") | .attrs.redirect_uris[].url] | sort) == ["https://media.smadja.dev/admin/api/provider/callback", "https://tv.smadja.dev/admin/api/provider/callback"]'
has "$auth" '([.entries[] | select(.id == "polyfin_provider") | .attrs.redirect_uris[].matching_mode] | all(. == "strict"))'
grep -Fq 'client_secret: !Env POLYFIN_OIDC_CLIENT_SECRET' "$auth" || fail "OIDC secret must remain environment backed"
has "$aio/http-route.yaml" '([.spec.parentRefs[].name] | sort) == ["internal"]'
has "$aio/http-route.yaml" '.spec.hostnames == ["aiostreams.smadja.dev"]'
not_has "$aio/http-route.yaml" '.spec.hostnames[] == "tv.smadja.dev"'

if yq -e '.spec.hostnames | contains(["tv.smadja.dev"])' "$route" >/dev/null; then
  # Stage 2: tv is Polyfin's stable canonical address; old media alias remains
  # available for existing clients during migration.
  has "$route" '([.spec.hostnames[]] | sort) == ["media.smadja.dev", "tv.smadja.dev"]'
  ! grep -Fq -- '- family-http-route.yaml' "$aio/kustomization.yaml" || fail "legacy public AIOStreams tv route still enabled"
  has "$auth" '.entries[] | select(.id == "polyfin_application") | .attrs.meta_launch_url == "https://tv.smadja.dev"'
  phase=cutover
else
  # Stage 1: no second owner of tv. Qualify media public first.
  has "$route" '.spec.hostnames == ["media.smadja.dev"]'
  grep -Fq -- '- family-http-route.yaml' "$aio/kustomization.yaml" || fail "AIOStreams family route missing before cutover"
  has "$aio/family-http-route.yaml" '([.spec.parentRefs[].name] | sort) == ["external"] and .spec.hostnames == ["tv.smadja.dev"]'
  has "$auth" '.entries[] | select(.id == "polyfin_application") | .attrs.meta_launch_url == "https://media.smadja.dev"'
  phase=canary
fi

# Prevent accidental collision with dormant historic private pilot fixtures.
! grep -Eq '^[[:space:]]*-[[:space:]]+http-route\.yaml[[:space:]]*$' \
  k8s/applications/media/polyfin/kustomization.yaml || fail "historic tv Polyfin HTTPRoute activated"
# No long-lived external video relay should be added as part of this cutover.
! grep -Eq '^\s*- name: external\s*$' "$aio/http-route.yaml" || fail "AIOStreams internal control route became public"
echo "POLYFIN_TV_MIGRATION=PASS phase=$phase (STATIC_ONLY; EXTERNAL_ROLLOUT_NOT_AUTHORIZED)"
