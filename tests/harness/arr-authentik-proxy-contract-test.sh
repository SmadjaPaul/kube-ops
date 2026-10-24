#!/usr/bin/env bash
set -euo pipefail
auth=k8s/infrastructure/auth/authentik/extra/blueprints/apps-media.yaml
outpost=k8s/infrastructure/auth/authentik/extra/blueprints/outposts.yaml
grant=k8s/infrastructure/auth/authentik/referencegrant.yaml
pol=k8s/infrastructure/network/policies/applications/media/media/allow-media-access.yaml
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
done
for port in 7878 8989 9696; do
  if yq -r '.spec.ingress[0].toPorts[0].ports[].port' "$pol" | grep -Fxq "$port"; then
    echo "FAIL: host/Gateway Arr bypass port $port still admitted"; exit 1
  fi
done
grep -Fq "name: allow-media-to-arr-proxy-outpost" "$grant"
grep -Fq "k8s:app.kubernetes.io/name: authentik-outpost-proxy" "$pol"
echo "ARR_AUTHENTIK_PROXY_STATIC=PASS (PHASE A ONLY; NO EXTERNAL AUTH ADMITTED)"
