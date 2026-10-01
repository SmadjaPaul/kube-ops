#!/usr/bin/env bash
resolve_argo_app() {
  local requested=$1
  local candidate
  for candidate in "$requested" "apps-$requested" "infra-$requested"; do
    if kubectl -n argocd get application.argoproj.io "$candidate" >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  echo "ERROR: Argo Application not found: $requested" >&2
  return 1
}
