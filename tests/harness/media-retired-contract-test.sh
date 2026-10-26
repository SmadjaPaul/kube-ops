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
grep -Eq '^[[:space:]]*-[[:space:]]*daily-audiobookrequest\.yaml[[:space:]]*$' "$v"
script=scripts/media-retired-pvc-cleanup.sh
bash -n "$script"
grep -Fq 'ALLOW_EMPTY_MEDIA_PVC_DELETION' "$script"
grep -Fq 'require_kube_access' "$script"
grep -Fq 'get pods -o json' "$script"
grep -Fq 'PVC_CLEANUP_SCOPE=EXACTLY_SEVEN_NAMED_CLAIMS' "$script"
python3 - "$script" <<'PY'
import pathlib, sys
script=pathlib.Path(sys.argv[1]).read_text()
claimed=script.split("claims=(\n",1)[1].split("\n)",1)[0]
names=claimed.split()
expected={
  "config-audiobookshelf-0","metadata-audiobookshelf-0",
  "audiobooks-audiobookshelf-0","podcasts-audiobookshelf-0",
  "config-sabnzbd-0","nzb-backup-sabnzbd-0",
  "incomplete-downloads-sabnzbd-0",
}
assert len(names)==7 and set(names)==expected,(names,expected)
assert "media-share" not in names
PY
env -u ALLOW_EMPTY_MEDIA_PVC_DELETION bash "$script" --execute > /dev/null 2>&1 && { echo "UNGUARDED_DELETE=FAIL"; exit 1; }
echo 'MEDIA_DECOMMISSION_STATIC=PASS'
