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
  KUBECONFIG="$file" kubectl config view --raw --minify -o json |
    _kube_access_sha256_stream
}

# Expiration (ISO 8601 UTC) du jeton du kubeconfig agent ; vide si ce n'est pas un JWT lisible.
_kube_access_token_expiry() {
  local exp
  exp="$(_kube_access_token_exp_epoch "$1")" || return 0
  [[ -n "$exp" ]] || return 0
  date -u -d "@$exp" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$exp" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true
}

_kube_access_token_exp_epoch() {
  local payload
  payload="$(KUBECONFIG="$1" kubectl config view --raw --minify -o jsonpath='{.users[0].user.token}' 2>/dev/null |
    cut -d. -f2 | tr '_-' '/+')" || return 0
  [[ -n "$payload" ]] || return 0
  while (( ${#payload} % 4 )); do payload+="="; done
  printf '%s' "$payload" | base64 -d 2>/dev/null | jq -r '.exp // empty' 2>/dev/null || true
}

# 0 si le jeton n'a pas expiré (ou si l'expiration est illisible : le serveur tranchera).
_kube_access_not_expired() {
  local exp
  exp="$(_kube_access_token_exp_epoch "$1")"
  [[ -z "$exp" ]] || (( exp > $(date -u +%s) ))
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
  # PLT-237: KUBERNETES_AGENT_OPERATOR_KUBECONFIG selects the limited agent
  # identity (scripts/kubectl-rw.sh); the default stays the operator copy.
  # PLT-257: ..._ORACLE_A1 is the read-only agent identity of OKE (kubectl-ro.sh
  # --cluster oracle-a1); never an OCI exec kubeconfig (it carries Paul's API key).
  local secret="${KUBE_ACCESS_KUBECONFIG_SECRET:-KUBERNETES_OPERATOR_KUBECONFIG}"
  local kubeconfig expected actual

  case "$secret" in
    KUBERNETES_OPERATOR_KUBECONFIG|KUBERNETES_AGENT_OPERATOR_KUBECONFIG|KUBERNETES_AGENT_OPERATOR_KUBECONFIG_ORACLE_A1) ;;
    *)
      _kube_access_blocked \
        canonical_kubeconfig_secret_not_allowed \
        no \
        no \
        USE_KUBERNETES_OPERATOR_KUBECONFIG_OR_KUBERNETES_AGENT_OPERATOR_KUBECONFIG
      return
      ;;
  esac

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

  # PLT-481 : la copie OKE est d'abord lue dans identity/agt (renouvelée par le CronJob d'OKE,
  # D-2026-11-23-04), puis dans infrastructure/prd (--provision, bris de glace). Une copie absente,
  # altérée ou expirée dans la première source bascule sur la seconde ; KUBE_ACCESS_DOPPLER_PROJECT
  # force une source unique.
  local -a projects=("$project")
  if [[ "$secret" == KUBERNETES_AGENT_OPERATOR_KUBECONFIG_ORACLE_A1 && -z "${KUBE_ACCESS_DOPPLER_PROJECT:-}" ]]; then
    projects=(agent-access infrastructure)  # agent-access = identity/agt (limite Doppler de 10 projets)
  fi

  umask 077
  KUBE_ACCESS_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/kube-ops-operator-access.XXXXXX")"
  kubeconfig="$KUBE_ACCESS_TMPDIR/kubeconfig"
  local candidate fail_reason= fail_present=no found=
  for candidate in "${projects[@]}"; do
    fail_reason=canonical_operator_kubeconfig_missing
    fail_present=no
    local cproj=$candidate cconf=$config ctok=
    if [[ "$candidate" == agent-access ]]; then
      cproj=identity cconf=agt
      # Le jeton de service des agents est limité à infrastructure : second jeton, lecture seule de identity/agt.
      [[ -s "${KUBE_ACCESS_AGENT_ACCESS_TOKEN_FILE:-$HOME/.claude-worker/doppler-token-agent-access}" ]] &&
        ctok=$(tr -d '\n' <"${KUBE_ACCESS_AGENT_ACCESS_TOKEN_FILE:-$HOME/.claude-worker/doppler-token-agent-access}")
    fi
    if ! DOPPLER_TOKEN="${ctok:-${DOPPLER_TOKEN:-}}" doppler secrets get "$secret" \
      --project "$cproj" --config "$cconf" --plain >"$kubeconfig" 2>/dev/null; then
      continue
    fi
    chmod 600 "$kubeconfig"
    fail_present=yes
    fail_reason=canonical_operator_fingerprint_missing
    if ! expected="$(
      DOPPLER_TOKEN="${ctok:-${DOPPLER_TOKEN:-}}" doppler secrets get "${secret}_SHA256" \
        --project "$cproj" --config "$cconf" --plain 2>/dev/null
    )" || [[ -z "$expected" ]]; then
      continue
    fi
    fail_reason=canonical_operator_context_invalid
    if ! actual="$(_kube_access_digest "$kubeconfig")" || [[ -z "$actual" ]]; then
      continue
    fi
    fail_reason=canonical_operator_integrity_mismatch
    if [[ "$actual" != "$expected" ]]; then
      continue
    fi
    if [[ "$secret" == KUBERNETES_AGENT_OPERATOR_KUBECONFIG_ORACLE_A1 ]]; then
      KUBE_ACCESS_TOKEN_EXPIRES="$(_kube_access_token_expiry "$kubeconfig")"
      if [[ -n "$KUBE_ACCESS_TOKEN_EXPIRES" ]] && ! _kube_access_not_expired "$kubeconfig"; then
        fail_reason=agent_token_expired
        continue
      fi
    fi
    found="$candidate"
    break
  done
  if [[ -z "$found" ]]; then
    kube_access_cleanup
    _kube_access_blocked \
      "$fail_reason" \
      "$fail_present" \
      no \
      RUN_HOMELAB_INFRA_JUST_KUBE_ACCESS_SYNC
    return
  fi

  export KUBECONFIG="$kubeconfig"
  export KUBE_ACCESS_CANONICALIZED=yes
  if [[ "$secret" == KUBERNETES_AGENT_OPERATOR_KUBECONFIG_ORACLE_A1 ]]; then
    export KUBE_ACCESS_SOURCE=doppler_agent_operator_oracle_a1_distribution
    [[ "$found" == agent-access ]] && export KUBE_ACCESS_SOURCE=doppler_agent_access_oracle_a1_distribution
    export KUBE_ACCESS_TOKEN_EXPIRES
  elif [[ "$secret" == KUBERNETES_AGENT_OPERATOR_KUBECONFIG ]]; then
    export KUBE_ACCESS_SOURCE=doppler_agent_operator_distribution
  else
    export KUBE_ACCESS_SOURCE=doppler_operator_distribution
  fi

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
    # Diagnostic on stderr: stdout stays reserved for the output of the calling
    # wrapper (JSON, key=value lines) that agents parse. KUBE_ACCESS_QUIET=1
    # (require_kube_access_quiet) drops the PASS block for callers that only gate.
    if [[ "${KUBE_ACCESS_QUIET:-}" != 1 ]]; then
      printf 'KUBE_ACCESS=PASS\nKUBECONFIG_PRESENT=yes\nAPI_REACHABLE=yes\nCLUSTER_VERSION=%s\nKUBE_ACCESS_SOURCE=%s\n' \
        "$cluster_version" "$source" >&2
      [[ -z "${KUBE_ACCESS_TOKEN_EXPIRES:-}" ]] || printf 'KUBE_ACCESS_TOKEN_EXPIRES=%s\n' "$KUBE_ACCESS_TOKEN_EXPIRES" >&2
    fi
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

# Gate only: no PASS block, BLOCKED diagnostics still go to stderr.
require_kube_access_quiet() {
  KUBE_ACCESS_QUIET=1 require_kube_access "$@"
}
