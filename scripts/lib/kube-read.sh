#!/usr/bin/env bash
# Single read path for investigation scripts: every cluster read goes through
# scripts/kubectl-ro.sh (verb whitelist, no Secret data, preflight, limited identity).
# Source it; never call `kubectl` directly from an investigation script.
#
# kro ARGS...   = bash scripts/kubectl-ro.sh ARGS...
# KUBECTL_RO_SCRIPT overrides the wrapper path (offline tests with a fake only).
# KUBECTL_RO_CLUSTER=homelab|oracle-a1 selects the cluster (kubectl-ro.sh --cluster).
#
# kro_session_begin PARENT_DIR : one preflight for all the kro calls of this script
# (and of its children). Creates PARENT_DIR/kro-session (0700) and exports
# KUBECTL_RO_SESSION_DIR. PARENT_DIR must be a private temp dir that the caller's
# EXIT trap removes (the verified kubeconfig copy lives there). Never an artifact dir.
KUBE_READ_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kro_session_begin() {
  local parent=${1:?kro_session_begin: dossier parent requis}
  [[ -n "${KUBECTL_RO_SESSION_DIR:-}" ]] && return 0 # already inside a session (child script)
  (umask 077 && mkdir -p "$parent/kro-session") && chmod 700 "$parent/kro-session" || return 0
  export KUBECTL_RO_SESSION_DIR="$parent/kro-session"
}
kro() {
  if [[ -n "${KUBECTL_RO_CLUSTER:-}" ]]; then
    bash "${KUBECTL_RO_SCRIPT:-$KUBE_READ_DIR/kubectl-ro.sh}" --cluster "$KUBECTL_RO_CLUSTER" "$@"
  else
    bash "${KUBECTL_RO_SCRIPT:-$KUBE_READ_DIR/kubectl-ro.sh}" "$@"
  fi
}
