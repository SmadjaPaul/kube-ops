#!/usr/bin/env bash
set -euo pipefail
root="k8s/applications/media"
cfg="$root/decypharr/configmap.yaml"
deploy="$root/decypharr/deployment.yaml"
secret="$root/decypharr/external-secret.yaml"
media="$root/kustomization.yaml"
pol="k8s/infrastructure/network/policies/applications/media/media"
! grep -Fxq -- '- decypharr' "$media"
! grep -Eq '^[[:space:]]*-[[:space:]]*qbittorrent([[:space:]]|$)' "$media"
test ! -e "$root/qbittorrent/kustomization.yaml"
grep -Fq 'APP_TORBOX_API_KEY' "$secret"
grep -Fq 'APP_RADARR_API_KEY' "$secret"
grep -Fq 'APP_SONARR_API_KEY' "$secret"
grep -Fq 'DECYPHARR_DEBRIDS__0__API_KEY' "$deploy"
grep -Fq 'DECYPHARR_ARRS__0__TOKEN' "$deploy"
grep -Fq 'DECYPHARR_ARRS__1__TOKEN' "$deploy"
grep -Fq 'DECYPHARR_PORT' "$deploy"
grep -Fq 'DECYPHARR_USE_AUTH' "$deploy"
grep -Fq 'DECYPHARR_DOWNLOAD_FOLDER' "$deploy"
grep -Fq '"default_download_action": "download"' "$cfg"
grep -Fq '"type": "none"' "$cfg"
grep -Fq '"use_auth": true' "$cfg"
python3 - "$cfg" <<'PY'
import json
import sys
from pathlib import Path

lines = Path(sys.argv[1]).read_text().splitlines()
start = lines.index("  config.json: |") + 1
payload = "\n".join(line[4:] for line in lines[start:])
json.loads(payload)
PY
echo "DECYPHARR_TORBOX_RETIRED=PASS (STATIC_ONLY; HISTORICAL PACKAGE NOT ADMITTED)"
