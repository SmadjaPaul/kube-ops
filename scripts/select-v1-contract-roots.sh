#!/usr/bin/env bash
set -euo pipefail

# Output is a comma-separated allowlist consumed by check-v1-active-contract.sh.
# Unknown paths deliberately select the complete render.
if [[ -n "${V1_CHANGED_FILES:-}" ]]; then
  changed_files="$V1_CHANGED_FILES"
elif [[ "${GITHUB_EVENT_NAME:-}" == pull_request && -n "${GITHUB_BASE_SHA:-}" && -n "${GITHUB_HEAD_SHA:-}" ]]; then
  # A PR runner may not have either object despite receiving the event.  A
  # failed or empty diff is intentionally full-scope, never an empty PASS.
  if ! changed_files="$(git diff --name-only "$GITHUB_BASE_SHA" "$GITHUB_HEAD_SHA" 2>/dev/null)"; then
    echo all
    exit 0
  fi
else
  echo all
  exit 0
fi

[[ -n "$changed_files" ]] || { echo all; exit 0; }

# Render-neutral paths cannot change any kustomize output: the owner admission
# registry is data read only by the trusted workflow-integrity gate. A PR made
# only of such paths renders exactly what main already validated, so it gets
# the smallest active root as a toolchain smoke render (PLT-210). Any other
# path, known or unknown, keeps its scoped or complete render.
smoke_root=k8s/infrastructure/network/policies/auth
full=false
neutral=false
declare -A roots=()
while IFS= read -r path; do
  [[ -n "$path" ]] || continue
  case "$path" in
    .github/workflow-integrity-admissions.json)
      neutral=true
      ;;
    .github/*|AGENTS.md|README.md|package.json|package-lock.json|\
    scripts/check-v1-active-contract.sh|scripts/select-v1-contract-roots.sh|\
    k8s/bootstrap/*|k8s/infrastructure/controllers/*|k8s/infrastructure/storage/*|\
    k8s/infrastructure/database/*|k8s/infrastructure/auth/*|k8s/infrastructure/security/*|\
    k8s/applications/platform/kustomization.yaml|k8s/applications/ai/kustomization.yaml)
      full=true
      ;;
    k8s/optional/sparkyfitness/*)
      roots[k8s/optional/sparkyfitness]=1
      ;;
    k8s/infrastructure/network/policies/auth/*)
      roots[k8s/infrastructure/network/policies/auth]=1
      ;;
    k8s/infrastructure/network/*)
      roots[k8s/infrastructure/network]=1
      ;;
    k8s/applications/media/polyfin/*)
      # Polyfin is an active component of the media root, not an independent
      # V1 root. Render the owning root so scoped validation stays aligned with
      # the actual Argo boundary.
      roots[k8s/applications/media]=1
      ;;
    k8s/applications/games/romm/*)
      # RomM is rendered by the games root (the only active games component);
      # games/romm alone is not an active V1 root (PLT-228).
      roots[k8s/applications/games]=1
      ;;
    k8s/applications/*/*)
      roots[k8s/applications/$(cut -d/ -f3 <<<"$path")]=1
      ;;
    k8s/infrastructure/*/*)
      roots[k8s/infrastructure/$(cut -d/ -f3 <<<"$path")]=1
      ;;
    *)
      full=true
      ;;
  esac
done <<<"$changed_files"

if [[ "$full" == true ]]; then
  echo all
elif [[ ${#roots[@]} -eq 0 && "$neutral" == true ]]; then
  echo "$smoke_root"
elif [[ ${#roots[@]} -eq 0 ]]; then
  echo all
else
  printf '%s\n' "${!roots[@]}" | sort | paste -sd, -
fi
