#!/usr/bin/env bash
# PLT-46: fail when a manifest under k8s/ carries an expired homelab/expires-at label.
# Convention: drills, restore proofs and pilots set `homelab/expires-at: "YYYY-MM-DD"`
# on their Namespace/PVC and use StorageClass longhorn-drill (reclaimPolicy Delete).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
today="$(date -u +%F)"
rc=0
while IFS=: read -r file line value; do
  date="$(sed -E 's/.*homelab\/expires-at:[[:space:]]*"?([0-9]{4}-[0-9]{2}-[0-9]{2})"?.*/\1/' <<<"$value")"
  if [[ ! "$date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    echo "::error file=$file,line=$line::homelab/expires-at must be YYYY-MM-DD"
    rc=1
  elif [[ "$date" < "$today" || "$date" == "$today" ]]; then
    echo "::error file=$file,line=$line::drill expired on $date: remove it from Git (Argo prunes it) and delete leftovers"
    rc=1
  fi
done < <(grep -rnE --include='*.yaml' --include='*.yml' '^[[:space:]]+homelab/expires-at:' k8s || true)
exit "$rc"
