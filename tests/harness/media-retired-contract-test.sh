#!/usr/bin/env bash
set -euo pipefail
m=k8s/applications/media/kustomization.yaml
v=k8s/infrastructure/controllers/velero/schedules/kustomization.yaml
! grep -Eq '^[[:space:]]*-[[:space:]]*(sabnzbd|audiobookshelf)[[:space:]]*$' "$m"
! grep -Eq '^[[:space:]]*-[[:space:]]*daily-(sabnzbd|audiobookshelf)\.yaml' "$v"
grep -Fxq -- '- media-share-pvc.yaml' "$m"
grep -Fxq -- '- decypharr' "$m"
grep -Fxq -- '- aiostreams' "$m"
grep -Fxq -- '- audiobookrequest' "$m"
grep -Fxq -- '- daily-audiobookrequest.yaml' "$v"
echo 'MEDIA_DECOMMISSION_STATIC=PASS'
