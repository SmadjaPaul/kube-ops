#!/usr/bin/env bash
# Resolve an app name to its Argo CD Application name: the name as given, then
# apps-<name>, then infra-<name>. Needs kro (lib/kube-read.sh). One read call.
resolve_argo_app() {
  local requested=$1 candidate names
  if ! names="$(kro get application.argoproj.io -n argocd -o name)"; then
    echo "ERROR: cannot list Argo Applications (cluster access)" >&2
    return 2
  fi
  for candidate in "$requested" "apps-$requested" "infra-$requested"; do
    if grep -Fxq "application.argoproj.io/$candidate" <<<"$names"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  echo "ERROR: Argo Application not found: $requested" >&2
  return 1
}
