#!/usr/bin/env bash

set -euo pipefail

KUBE_ACCESS_TMPDIR="${KUBE_ACCESS_TMPDIR:-}"

_kube_access_sha256_stream() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}

_kube_access_digest() {
  local file="$1"
  KUBECONFIG="$file" command kubectl config view --raw --minify -o json |
    _kube_access_sha256_stream
}

kube_access_cleanup() {
  if [[ -n "${KUBE_ACCESS_TMPDIR:-}" && -d "$KUBE_ACCESS_TMPDIR" ]]; then
    rm -rf -- "$KUBE_ACCESS_TMPDIR"
  fi
  KUBE_ACCESS_TMPDIR=""
}

_kube_access_blocked() {
  local reason="$1"
  local present="$2"
  local reachable="$3"
  local next_action="$4"

  printf 'KUBE_ACCESS=BLOCKED\nREASON=%s\nKUBECONFIG_PRESENT=%s\nAPI_REACHABLE=%s\nNEXT_ACTION=%s\n' \
    "$reason" "$present" "$reachable" "$next_action" >&2
  return 2
}

_materialize_canonical_operator_kubeconfig() {
  local project="${KUBE_ACCESS_DOPPLER_PROJECT:-infrastructure}"
  local config="${KUBE_ACCESS_DOPPLER_CONFIG:-prd}"
  local kubeconfig expected actual

  if ! command -v doppler >/dev/null 2>&1; then
    _kube_access_blocked \
      canonical_operator_distribution_unavailable \
      no \
      no \
      AUTHENTICATE_DOPPLER_OR_USE_HOMELAB_INFRA_KUBE_ACCESS_HARNESS
    return
  fi

  if ! doppler me >/dev/null 2>&1; then
    _kube_access_blocked \
      doppler_not_authenticated \
      no \
      no \
      RUN_DOPPLER_LOGIN_THEN_RETRY
    return
  fi

  umask 077
  KUBE_ACCESS_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/kube-ops-operator-access.XXXXXX")"
  kubeconfig="$KUBE_ACCESS_TMPDIR/kubeconfig"

  if ! doppler secrets get KUBERNETES_OPERATOR_KUBECONFIG \
    --project "$project" --config "$config" --plain >"$kubeconfig" 2>/dev/null; then
    kube_access_cleanup
    _kube_access_blocked \
      canonical_operator_kubeconfig_missing \
      no \
      no \
      RUN_HOMELAB_INFRA_JUST_KUBE_ACCESS_SYNC
    return
  fi
  chmod 600 "$kubeconfig"

  if ! expected="$(
    doppler secrets get KUBERNETES_OPERATOR_KUBECONFIG_SHA256 \
      --project "$project" --config "$config" --plain 2>/dev/null
  )" || [[ -z "$expected" ]]; then
    kube_access_cleanup
    _kube_access_blocked \
      canonical_operator_fingerprint_missing \
      yes \
      no \
      RUN_HOMELAB_INFRA_JUST_KUBE_ACCESS_SYNC
    return
  fi

  if ! actual="$(_kube_access_digest "$kubeconfig")" || [[ -z "$actual" ]]; then
    kube_access_cleanup
    _kube_access_blocked \
      canonical_operator_context_invalid \
      yes \
      no \
      RUN_HOMELAB_INFRA_JUST_KUBE_ACCESS_SYNC
    return
  fi

  if [[ "$actual" != "$expected" ]]; then
    kube_access_cleanup
    _kube_access_blocked \
      canonical_operator_integrity_mismatch \
      yes \
      no \
      RUN_HOMELAB_INFRA_JUST_KUBE_ACCESS_SYNC
    return
  fi

  export KUBECONFIG="$kubeconfig"
  export KUBE_ACCESS_CANONICALIZED=yes
  export KUBE_ACCESS_SOURCE=doppler_operator_distribution

  # Most callers have no EXIT trap. Callers that install their own trap after
  # this function must append kube_access_cleanup to that trap.
  trap 'kube_access_cleanup' EXIT
}

require_kube_access() {
  local kubeconfig_present=no
  local api_reachable=no
  local reason=missing_operator_context
  local cluster_version=
  local server=
  local kubeconfig_path="${KUBECONFIG:-}"
  local source="${KUBE_ACCESS_SOURCE:-existing_environment}"
  local bootstrap_mode="${KUBE_ACCESS_BOOTSTRAP:-auto}"

  command -v kubectl >/dev/null 2>&1 || {
    _kube_access_blocked kubectl_missing no no INSTALL_KUBECTL
    return
  }
  command -v jq >/dev/null 2>&1 || {
    _kube_access_blocked jq_missing no no INSTALL_JQ
    return
  }

  # A kubeconfig handed to us by homelab-infra's canonical harness is already
  # validated and may be reused. Any other ambient KUBECONFIG is deliberately
  # ignored in auto mode so stale/wrong-cluster local files cannot win.
  if [[ "$bootstrap_mode" == auto && "${KUBE_ACCESS_CANONICALIZED:-}" != yes ]]; then
    _materialize_canonical_operator_kubeconfig || return $?
    kubeconfig_path="$KUBECONFIG"
    source="${KUBE_ACCESS_SOURCE:-doppler_operator_distribution}"
  elif [[ -n "$kubeconfig_path" && -f "$kubeconfig_path" ]]; then
    kubeconfig_present=yes
  fi

  kubeconfig_path="${KUBECONFIG:-}"
  if [[ -n "$kubeconfig_path" && -f "$kubeconfig_path" ]]; then
    kubeconfig_present=yes
  fi

  if [[ "$kubeconfig_present" != yes ]]; then
    _kube_access_blocked \
      "$reason" \
      "$kubeconfig_present" \
      "$api_reachable" \
      USE_JUST_KUBE_ACCESS_CHECK_NOT_A_MANUAL_KUBECONFIG
    return
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
    printf 'KUBE_ACCESS=PASS\nKUBECONFIG_PRESENT=yes\nAPI_REACHABLE=yes\nCLUSTER_VERSION=%s\nKUBE_ACCESS_SOURCE=%s\n' \
      "$cluster_version" "$source"
    return 0
  fi

  local next_action=RUN_HOMELAB_INFRA_JUST_KUBE_ACCESS_SYNC
  if [[ "$bootstrap_mode" == never ]]; then
    next_action=USE_CANONICAL_KUBE_ACCESS_HARNESS
  fi

  _kube_access_blocked \
    "$reason" \
    "$kubeconfig_present" \
    "$api_reachable" \
    "$next_action"
}
