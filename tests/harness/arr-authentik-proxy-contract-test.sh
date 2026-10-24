#!/usr/bin/env bash
set -euo pipefail
auth=k8s/infrastructure/auth/authentik/extra/blueprints/apps-media-v2.yaml
outpost=k8s/infrastructure/auth/authentik/extra/blueprints/outposts-v2.yaml
grant=k8s/infrastructure/auth/authentik/referencegrant.yaml
pol=k8s/infrastructure/network/policies/applications/media/media/allow-media-access.yaml
prowlarr_pol=k8s/infrastructure/network/policies/applications/media/media/allow-prowlarr-to-arr.yaml
for app in radarr sonarr prowlarr; do
  route="k8s/applications/media/arr/$app/http-route.yaml"
  sts="k8s/applications/media/arr/$app/statefulset.yaml"
  test "$(yq -r '.spec.rules[0].backendRefs[0].name' "$route")" = "ak-outpost-proxy-outpost"
  test "$(yq -r '.spec.rules[0].backendRefs[0].namespace' "$route")" = "auth"
  test "$(yq -r '.spec.rules[0].backendRefs[0].port' "$route")" = "9000"
  test "$(yq -r '.spec.rules | length' "$route")" = "1"
  if grep -Fq "${app^^}__AUTH__METHOD" "$sts"; then echo "FAIL: premature External auth rollout for $app"; exit 1; fi
  grep -Fq "name: k8s.smadja.dev/services-media/$app-proxy" "$auth"
  case "$app" in
    radarr) port=7878 ;;
    sonarr) port=8989 ;;
    prowlarr) port=9696 ;;
  esac
  grep -Fq "internal_host: http://$app.media.svc.cluster.local:$port" "$auth"
  grep -Fq "[name, \"k8s.smadja.dev/services-media/$app-proxy\"]" "$outpost"
  # Enforce migration of the prior Media Users binding (policy_engine_mode=any).
  grep -Fq "id: ${app}_retire_media_users_policy_binding" "$auth"
done
for port in 7878 8989 9696; do
  if yq -r '.spec.ingress[0].toPorts[0].ports[].port' "$pol" | grep -Fxq "$port"; then
    echo "FAIL: host/Gateway Arr bypass port $port still admitted"; exit 1
  fi
done
grep -Fq "name: allow-media-to-arr-proxy-outpost" "$grant"
grep -Fq "k8s:app.kubernetes.io/name: authentik-outpost-proxy" "$pol"
grep -Fq "name: prowlarr-to-arr" "$prowlarr_pol"
grep -Fq 'app: prowlarr' "$prowlarr_pol"
grep -Fq 'port: "7878"' "$prowlarr_pol"
grep -Fq 'port: "8989"' "$prowlarr_pol"
grep -Fq "model: authentik_blueprints.metaapplyblueprint" "$outpost"
grep -Fq "name: Apps - Media v2" "$outpost"
grep -Fq "required: true" "$outpost"
for app in radarr sonarr prowlarr; do
  # Extract and structurally test the complete removal entry, not a comment.
  yq -e 'true' "$auth" >/dev/null 2>&1 || true # Authentik YAML custom tags aren't parsed by standard yq
  grep -A5 "id: ${app}_retire_media_users_policy_binding" "$auth" |
    grep -Fq "state: absent" || { echo "MISSING_LEGACY_BINDING_RETIREMENT=$app" >&2; exit 1; }
done
echo "ARR_AUTHENTIK_PROXY_STATIC=PASS (PHASE A ONLY; NO EXTERNAL AUTH ADMITTED)"
