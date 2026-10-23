#!/usr/bin/env bash
set -euo pipefail
auth=k8s/infrastructure/auth/authentik/extra/blueprints/apps-media.yaml
outpost=k8s/infrastructure/auth/authentik/extra/blueprints/outposts.yaml
grant=k8s/infrastructure/auth/authentik/referencegrant.yaml
pol=k8s/infrastructure/network/policies/applications/media/media/allow-media-access.yaml
for app in radarr sonarr prowlarr; do
  route="k8s/applications/media/arr/$app/http-route.yaml"
  sts="k8s/applications/media/arr/$app/statefulset.yaml"
  yq -e '.spec.rules | all(.backendRefs | all(.name == "ak-outpost-proxy-outpost" and .namespace == "auth" and .port == 9000))' "$route" >/dev/null
  if grep -Fq "${app^^}__AUTH__METHOD" "$sts"; then echo "FAIL: premature External auth rollout for $app"; exit 1; fi
  grep -Fq "name: k8s.smadja.dev/services-media/$app-proxy" "$auth"
  grep -Fq "internal_host: http://$app.media.svc.cluster.local:80" "$auth"
  grep -Fq "[name, \"k8s.smadja.dev/services-media/$app-proxy\"]" "$outpost"
done
yq -e '.spec.ingress[0].toPorts[0].ports | all(.port != "7878" and .port != "8989" and .port != "9696")' "$pol" >/dev/null
grep -Fq "name: allow-media-to-arr-proxy-outpost" "$grant"
echo "ARR_AUTHENTIK_PROXY_STATIC=PASS (PHASE A ONLY; NO EXTERNAL AUTH ADMITTED)"
