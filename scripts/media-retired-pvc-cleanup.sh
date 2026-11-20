#!/usr/bin/env bash
# Bounded cleanup: exactly seven user-approved EMPTY Media PVCs.
# Default read-only. Deletion requires --execute plus approval variable.
set -euo pipefail
mode=inspect
if (( $# > 0 )); then
  case "$1" in
    --execute) mode=delete ;;
    --help|-h)
      echo "Usage: ALLOW_EMPTY_MEDIA_PVC_DELETION=yes bash scripts/media-retired-pvc-cleanup.sh --execute"
      exit 0 ;;
    *) echo "PVC_CLEANUP=BLOCKED invalid argument" >&2; exit 2 ;;
  esac
fi
(( $# <= 1 )) || { echo "PVC_CLEANUP=BLOCKED too many arguments" >&2; exit 2; }
if [[ "$mode" == delete ]]; then
  if [[ "${ALLOW_EMPTY_MEDIA_PVC_DELETION:-}" != yes ]]; then
    echo "PVC_CLEANUP=BLOCKED approval guard missing" >&2
    exit 2
  fi
fi
for cmd in kubectl jq; do
  command -v "$cmd" >/dev/null || { echo "MISSING=$cmd" >&2; exit 2; }
done
source "$(dirname "$0")/lib/kube-preflight.sh"
require_kube_access >/dev/null
trap 'kube_access_cleanup' EXIT

if grep -Eq '^[[:space:]]*-[[:space:]]*(sabnzbd|audiobookshelf)[[:space:]]*$' \
  k8s/applications/media/kustomization.yaml; then
  echo "PVC_CLEANUP=BLOCKED: legacy workload still in Media GitOps" >&2; exit 3
fi
if grep -Eq '^[[:space:]]*-[[:space:]]*daily-(sabnzbd|audiobookshelf)\.yaml' \
  k8s/infrastructure/controllers/velero/schedules/kustomization.yaml; then
  echo "PVC_CLEANUP=BLOCKED: legacy Velero schedule still in GitOps" >&2; exit 3
fi
argocd="$(kubectl --request-timeout=10s -n argocd get applications.argoproj.io apps-media -o json)"
jq -e '.status.sync.status == "Synced" and .status.health.status == "Healthy"' \
  <<< "$argocd" >/dev/null ||
  { echo "PVC_CLEANUP=BLOCKED: apps-media not Synced/Healthy" >&2; exit 3; }
for name in velero-daily-sabnzbd velero-daily-audiobookshelf; do
  found="$(kubectl --request-timeout=10s -n velero get schedules.velero.io "$name" --ignore-not-found -o name)"
  [[ -z "$found" ]] || { echo "PVC_CLEANUP=BLOCKED $found" >&2; exit 3; }
done
for kind in statefulset deployment service httproute; do
  for name in sabnzbd audiobookshelf; do
    found="$(kubectl --request-timeout=10s -n media get "$kind" "$name" --ignore-not-found -o name)"
    [[ -z "$found" ]] || { echo "PVC_CLEANUP=BLOCKED $found" >&2; exit 3; }
  done
done
pods="$(kubectl --request-timeout=10s -n media get pods -o json)"
for name in sabnzbd audiobookshelf; do
  if jq -e --arg name "$name" \
    '.items | any(.[]; (.metadata.labels.app == $name) or (.metadata.name | startswith($name + "-")))' \
    <<< "$pods" >/dev/null; then
    echo "PVC_CLEANUP=BLOCKED: Pods still exist for $name" >&2; exit 3
  fi
done

# Exact immutable whitelist. Never select by label or wildcard.
claims=(
  config-audiobookshelf-0
  metadata-audiobookshelf-0
  audiobooks-audiobookshelf-0
  podcasts-audiobookshelf-0
  config-sabnzbd-0
  nzb-backup-sabnzbd-0
  incomplete-downloads-sabnzbd-0
)
# Abort the entire batch if ANY target PVC is referenced by ANY live Pod.
for claim in "${claims[@]}"; do
  if jq -e --arg pvc "$claim" \
    '.items | any(.[]; any(.spec.volumes[]?; .persistentVolumeClaim.claimName? == $pvc))' \
    <<< "$pods" >/dev/null; then
    echo "PVC_CLEANUP=BLOCKED: Pod still mounts $claim" >&2; exit 3
  fi
done
for claim in "${claims[@]}"; do
  found="$(kubectl --request-timeout=10s -n media get pvc "$claim" --ignore-not-found -o name)"
  if [[ -z "$found" ]]; then
    echo "PVC_ABSENT=$claim"
  elif [[ "$mode" == inspect ]]; then
    echo "PVC_ELIGIBLE_FOR_DELETION=$claim"
  else
    kubectl --request-timeout=15s -n media delete pvc "$claim" --wait=false
    echo "PVC_DELETE_REQUESTED=$claim"
  fi
done
echo "PVC_CLEANUP_MODE=$mode"
echo "PVC_CLEANUP_SCOPE=EXACTLY_SEVEN_NAMED_CLAIMS"
