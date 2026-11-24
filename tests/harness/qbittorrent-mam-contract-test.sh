#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

rendered="$TMP_DIR/qbittorrent-mam.yaml"
kustomize build "$ROOT/k8s/applications/media/qbittorrent-mam" >"$rendered"

grep -Fq 'replicas: 1' "$rendered"
grep -Fq 'storageClassName: longhorn-fast' "$rendered"
grep -Fq 'claimName: media-share' "$rendered"
grep -Fq 'mountPath: /data' "$rendered"
# Renovate bumps the tag and digest: the contract is the image and the digest pin, not one frozen version.
grep -Eq 'qbittorrentofficial/qbittorrent-nox:[0-9][0-9.]*-[0-9]+@sha256:[0-9a-f]{64}' "$rendered"
grep -Eq 'image: python:[0-9][0-9.]*-alpine[0-9.]+@sha256:[0-9a-f]{64}' "$rendered"
grep -Fq 'type: ClusterIP' "$rendered"
if grep -Eq 'type: (LoadBalancer|NodePort)|kind: (Ingress|HTTPRoute)' "$rendered"; then
  echo 'QBITTORRENT_MAM_CONTRACT=FAIL public service or route found' >&2
  exit 1
fi
# PLT-474 (#1929): the WebUI password is generated in the cluster, never read from Doppler.
grep -Fq 'name: qbittorrent-mam-auth' "$rendered"
grep -Fq 'WEBUI_PASSWORD: ' "$rendered"
grep -Fq 'kind: Password' "$rendered"
grep -Fq 'refreshPolicy: CreatedOnce' "$rendered"
if grep -Fq 'BOOKORBIT_QBITTORRENT_WEBUI_PASSWORD' "$rendered"; then
  echo 'QBITTORRENT_MAM_CONTRACT=FAIL WebUI password read from Doppler again' >&2
  exit 1
fi
grep -Fq 'STORAGE_CONTRACT=PASS uid=2501 hardlinks=2' "$ROOT/k8s/applications/media/qbittorrent-mam/bootstrap.py"
grep -Fq 'Session\GlobalMaxRatio' "$ROOT/k8s/applications/media/qbittorrent-mam/bootstrap.py"
grep -Fq 'AutoDeleteAddedTorrentFile' "$ROOT/k8s/applications/media/qbittorrent-mam/bootstrap.py"
if grep -Eiq 'myanonamouse\.net|mam_id|dynamicSeedbox|mam-session' "$ROOT/k8s/applications/media/qbittorrent-mam/networkpolicy.yaml"; then
  echo 'QBITTORRENT_MAM_CONTRACT=FAIL MAM access found in qBittorrent policy' >&2
  exit 1
fi
if grep -REiq '/api/v2/torrents/delete|deleteFiles.?=.?true|deleteTorrent' "$ROOT/k8s/applications/media/qbittorrent-mam"; then
  echo 'QBITTORRENT_MAM_CONTRACT=FAIL automatic torrent deletion found' >&2
  exit 1
fi
grep -Fq 'qbittorrent-mam' "$ROOT/k8s/applications/media/bookorbit/networkpolicy.yaml"
grep -Fq 'mountPath: /appdata/plugins/indexers/myanonamouse' "$ROOT/k8s/applications/media/bookorbit/app.yaml"
grep -Fq '          - bookorbit' "$ROOT/k8s/infrastructure/network/policies/applications/media/media/allow-media-access.yaml"
grep -Fq '          - qbittorrent-mam' "$ROOT/k8s/infrastructure/network/policies/applications/media/media/allow-media-access.yaml"

echo 'QBITTORRENT_MAM_CONTRACT=PASS'
