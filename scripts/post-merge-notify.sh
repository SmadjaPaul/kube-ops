#!/usr/bin/env bash
# ntfy notification of the post-merge verification (PLT-390 lot 3).
# Reuses the existing ntfy channel: ALERTMANAGER_NTFY_URL (full publish URL, the topic is the secret; the same one
# Alertmanager uses). Never printed, never a GitHub secret.
#   In the post-merge runner pod (KUBECTL_RO_IN_CLUSTER=1): read from the cluster Secret monitoring/alertmanager-ntfy-url
#   (key url) with the pod ServiceAccount, which may get that ONE Secret (rbac.yaml). No Doppler.
#   Elsewhere: injected by scripts/doppler-safe.sh (Doppler cluster/prd).
# Usage: bash scripts/post-merge-notify.sh [--dry-run] TITLE PRIORITY MESSAGE   (PRIORITY: default|high|urgent)
# Exit 0 sent (or dry-run), 2 BLOCKED (no URL / ntfy refused). A notification failure never hides the decision.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
dry=0; [[ ${1:-} == --dry-run ]] && { dry=1; shift; }
[[ $# -eq 3 ]] || { echo "usage: post-merge-notify.sh [--dry-run] TITLE PRIORITY MESSAGE" >&2; exit 2; }
title=$1; prio=$2; msg=$3
case "$prio" in default|high|urgent) ;; *) echo "ERROR: bad priority" >&2; exit 2 ;; esac
if (( dry )); then echo "NOTIFY=DRY_RUN title=\"$title\" priority=$prio message=\"$msg\""; exit 0; fi
if [[ -z ${NTFY_PUBLISH_URL:-} && ${KUBECTL_RO_IN_CLUSTER:-} == 1 ]]; then
  # shellcheck source=lib/in-cluster-kubeconfig.sh
  . "$here/lib/in-cluster-kubeconfig.sh"
  kcfg=$(in_cluster_kubeconfig "${KUBECTL_RO_SA_DIR:-/var/run/secrets/kubernetes.io/serviceaccount}") || kcfg=""
  NTFY_PUBLISH_URL=$(KUBECONFIG=${kcfg:-/nonexistent} kubectl -n monitoring get secret alertmanager-ntfy-url -o jsonpath='{.data.url}' 2>/dev/null | base64 -d 2>/dev/null) || true
  [[ -z $kcfg ]] || rm -f "$kcfg"
  [[ -n $NTFY_PUBLISH_URL ]] || { echo "NOTIFY=BLOCKED reason=ntfy_secret_unreadable"; exit 2; }
  [[ -z ${GITHUB_ACTIONS:-} ]] || echo "::add-mask::$NTFY_PUBLISH_URL"
fi
if [[ -z ${NTFY_PUBLISH_URL:-} ]]; then
  if [[ -z ${PM_NOTIFY_INNER:-} ]]; then
    PM_NOTIFY_INNER=1 bash "$here/doppler-safe.sh" run --only ALERTMANAGER_NTFY_URL -p cluster -c prd -- \
      bash -c 'NTFY_PUBLISH_URL=$ALERTMANAGER_NTFY_URL exec bash "$0" "$@"' "${BASH_SOURCE[0]}" "$title" "$prio" "$msg" \
      || { echo "NOTIFY=BLOCKED reason=doppler_or_ntfy_failed"; exit 2; }
    exit 0
  fi
  echo "NOTIFY=BLOCKED reason=no_ntfy_url"; exit 2
fi
# The Alertmanager URL may carry a query (e.g. ?template=alertmanager, which expects Alertmanager JSON):
# publish plain text to the bare topic URL.
NTFY_PUBLISH_URL=${NTFY_PUBLISH_URL%%\?*}
# URL through a curl config on stdin: not in the process arguments.
resp=$(mktemp "${TMPDIR:-/tmp}/ntfy.XXXXXX"); trap 'rm -f "$resp"' EXIT
code=$(printf 'url = "%s"\n' "$NTFY_PUBLISH_URL" | curl -sS --max-time 20 -K - -o "$resp" -w '%{http_code}' \
  -H "Title: $title" -H "Priority: $prio" -H "Tags: rotating_light" -d "$msg" 2>/dev/null) || code=000
if [[ $code == 2?? ]]; then echo "NOTIFY=SENT"; else
  # ntfy error body is JSON ({"code":..,"error":..}); it never contains the topic URL.
  echo "NOTIFY=BLOCKED reason=ntfy_refused http=$code error=$(jq -r '.error // empty' "$resp" 2>/dev/null | cut -c1-120)"; exit 2
fi
