#!/usr/bin/env bash
# Files of a merge commit -> applications touched (PLT-390 lot 3). Git only, no cluster.
# Usage: bash scripts/post-merge-affected.sh [SHA [BASE]]   (default HEAD; run from a checkout of the repository)
#   BASE (PLT-398): previous tip of main of a push; the files of BASE..SHA are analysed, not only the tip.
#   Without BASE, unknown or all-zero BASE: the first-parent diff of SHA alone.
# Mapping (keep aligned with k8s/bootstrap/argocd-root/applications-applicationset.yaml: one Argo
# Application `apps-<domain>` per generator directory, and apps-applicationset.yaml: one Application
# `app-<name>` per `argocd-app.yaml` descriptor, PLT-394):
#   k8s/applications/<domain>/<app>/**   app=<app>, namespace from the kustomization, and
#       argo=app-<app>      if k8s/applications/<domain>/<app>/argocd-app.yaml exists (migrated app)
#       argo=apps-<domain>  otherwise
# Everything else (domain-level files, platform domain, infrastructure, optional, policy, scripts, tests,
# workflows, justfile...) counts as OTHER, except documentation which is ignored.
# Output: AFFECTED_APP name=.. namespace=.. argo=.. stateful=yes|no (per app), AFFECTED_OTHER count=N sample=..,
#         AFFECTED_CLASS=apps-only|mixed|none.
set -euo pipefail

sha=${1:-HEAD}; base=${2:-}
root=$(git rev-parse --show-toplevel)
cd "$root"
git rev-parse --verify "$sha^{commit}" >/dev/null 2>&1 || { echo "ERROR: unknown commit $sha" >&2; exit 2; }
domains=(media tools ai web automation games business catalog)   # `platform` is infrastructure-grade: OTHER

declare -A seen=()
apps=(); other=0; sample=""
while IFS= read -r f; do
  [[ -n $f ]] || continue
  case "$f" in
    docs/*|website/*|images/*|*.md|CHANGELOG*|LICENSE) continue ;;
  esac
  dom=""; app=""; argo=""; dir=""
  if [[ $f =~ ^k8s/applications/([a-z0-9-]+)/([a-z0-9][-a-z0-9]*)/ ]]; then
    d=${BASH_REMATCH[1]}
    for x in "${domains[@]}"; do [[ $x == "$d" ]] && dom=$d; done
    if [[ -n $dom ]]; then app=${BASH_REMATCH[2]}; argo=apps-$dom; dir=k8s/applications/$dom/$app; fi
  fi
  if [[ -z $app ]]; then
    other=$((other + 1)); [[ -n $sample ]] || sample=$f; continue
  fi
  [[ -z ${seen[$app]:-} ]] || continue
  seen[$app]=1
  # Migrated app (PLT-394): its own Application `app-<name>` replaces the domain Application.
  [[ ! -f $dir/argocd-app.yaml ]] || argo=app-$app
  apps+=("$app|$argo|$dir|$dom")
done < <(if [[ -n $base ]] && git rev-parse --verify "$base^{commit}" >/dev/null 2>&1; then git diff --name-only "$base" "$sha"
         else git show --first-parent --name-only --format= "$sha"; fi)

ns_of() { # kustomization `namespace:` (top level) of DIR, else of its domain dir, else APP
  local dir=$1 dom=$2 app=$3 v="" k
  for k in "$dir/kustomization.yaml" "$dir/kustomization.yml" "k8s/applications/$dom/kustomization.yaml"; do
    [[ -f $k ]] || continue
    v=$(awk '/^namespace:[[:space:]]*/ {sub(/^namespace:[[:space:]]*/, ""); gsub(/["'"'"']/, ""); print; exit}' "$k")
    [[ -z $v ]] || break
  done
  printf '%s' "${v:-$app}"
}

for entry in "${apps[@]:-}"; do
  [[ -n $entry ]] || continue
  IFS='|' read -r app argo dir dom <<<"$entry"
  stateful=no
  # Stateful: PVC, volumeClaimTemplates or a CNPG Cluster in the app tree (the revert does not restore data).
  if [[ -d $dir ]] && grep -rEqs '^kind:[[:space:]]*PersistentVolumeClaim|volumeClaimTemplates|persistentVolumeClaim:|^kind:[[:space:]]*Cluster$' "$dir"; then stateful=yes; fi
  echo "AFFECTED_APP name=$app namespace=$(ns_of "$dir" "$dom" "$app") argo=$argo stateful=$stateful"
done
echo "AFFECTED_OTHER count=$other sample=${sample:-none}"
if (( ${#apps[@]} == 0 )); then echo "AFFECTED_CLASS=none"
elif (( other > 0 )); then echo "AFFECTED_CLASS=mixed"
else echo "AFFECTED_CLASS=apps-only"; fi
