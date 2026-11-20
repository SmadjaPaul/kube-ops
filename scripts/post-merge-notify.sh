#!/usr/bin/env bash
# ntfy notification of the post-merge verification (PLT-390 lot 3).
# Reuses the existing ntfy channel: Doppler cluster/prd ALERTMANAGER_NTFY_URL (full publish URL with the secret
# topic, the same one Alertmanager uses). The URL is injected by scripts/doppler-safe.sh and never printed.
# Usage: bash scripts/post-merge-notify.sh [--dry-run] TITLE PRIORITY MESSAGE   (PRIORITY: default|high|urgent)
# Exit 0 sent (or dry-run), 2 BLOCKED (no URL / ntfy refused). A notification failure never hides the decision.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
dry=0; [[ ${1:-} == --dry-run ]] && { dry=1; shift; }
[[ $# -eq 3 ]] || { echo "usage: post-merge-notify.sh [--dry-run] TITLE PRIORITY MESSAGE" >&2; exit 2; }
title=$1; prio=$2; msg=$3
case "$prio" in default|high|urgent) ;; *) echo "ERROR: bad priority" >&2; exit 2 ;; esac
if (( dry )); then echo "NOTIFY=DRY_RUN title=\"$title\" priority=$prio message=\"$msg\""; exit 0; fi
if [[ -z ${NTFY_PUBLISH_URL:-} ]]; then
  if [[ -z ${PM_NOTIFY_INNER:-} ]]; then
    PM_NOTIFY_INNER=1 bash "$here/doppler-safe.sh" run --only ALERTMANAGER_NTFY_URL -p cluster -c prd -- \
      bash -c 'NTFY_PUBLISH_URL=$ALERTMANAGER_NTFY_URL exec bash "$0" "$@"' "${BASH_SOURCE[0]}" "$title" "$prio" "$msg" \
      || { echo "NOTIFY=BLOCKED reason=doppler_or_ntfy_failed"; exit 2; }
    exit 0
  fi
  echo "NOTIFY=BLOCKED reason=no_ntfy_url"; exit 2
fi
curl -fsS --max-time 20 -H "Title: $title" -H "Priority: $prio" -H "Tags: rotating_light" -d "$msg" "$NTFY_PUBLISH_URL" >/dev/null \
  && echo "NOTIFY=SENT" || { echo "NOTIFY=BLOCKED reason=ntfy_refused"; exit 2; }
