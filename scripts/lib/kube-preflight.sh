#!/usr/bin/env bash

set -euo pipefail

require_kube_access() {
  local kubeconfig_present=no
  local api_reachable=no
  local reason=missing_operator_context
  local cluster_version=
  local server=
  local kubeconfig_path="${KUBECONFIG:-}"

  if [[ -n "$kubeconfig_path" && -f "$kubeconfig_path" ]]; then
    kubeconfig_present=yes
  fi

  if [[ "$kubeconfig_present" != yes ]]; then
    printf 'KUBE_ACCESS=BLOCKED\nREASON=%s\nKUBECONFIG_PRESENT=%s\nAPI_REACHABLE=%s\n' \
      "$reason" "$kubeconfig_present" "$api_reachable" >&2
    return 2
  fi

  if ! server="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)" || [[ -z "$server" ]]; then
    reason=invalid_operator_context
  elif [[ "$server" =~ ^https?://(localhost|127\.|0\.0\.0\.0|\[::1\])(:[0-9]+)?(/|$) ]]; then
    reason=invalid_operator_context
  elif ! cluster_version="$(kubectl --request-timeout=8s get --raw=/version 2>/dev/null | jq -r '.gitVersion // empty')" || [[ -z "$cluster_version" ]]; then
    reason=api_unreachable
  elif ! kubectl --request-timeout=8s get namespace/default -o name >/dev/null 2>&1; then
    reason=api_unreachable
  else
    api_reachable=yes
    printf 'KUBE_ACCESS=PASS\nKUBECONFIG_PRESENT=yes\nAPI_REACHABLE=yes\nCLUSTER_VERSION=%s\n' "$cluster_version"
    return 0
  fi

  printf 'KUBE_ACCESS=BLOCKED\nREASON=%s\nKUBECONFIG_PRESENT=%s\nAPI_REACHABLE=%s\n' \
    "$reason" "$kubeconfig_present" "$api_reachable" >&2
  return 2
}
