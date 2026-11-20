#!/usr/bin/env bash
# Single read path for investigation scripts: every cluster read goes through
# scripts/kubectl-ro.sh (verb whitelist, no Secret data, preflight, limited identity).
# Source it; never call `kubectl` directly from an investigation script.
#
# kro ARGS...   = bash scripts/kubectl-ro.sh ARGS...
# KUBECTL_RO_SCRIPT overrides the wrapper path (offline tests with a fake only).
# KUBECTL_RO_CLUSTER=homelab|oracle-a1 selects the cluster (kubectl-ro.sh --cluster).
KUBE_READ_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kro() {
  if [[ -n "${KUBECTL_RO_CLUSTER:-}" ]]; then
    bash "${KUBECTL_RO_SCRIPT:-$KUBE_READ_DIR/kubectl-ro.sh}" --cluster "$KUBECTL_RO_CLUSTER" "$@"
  else
    bash "${KUBECTL_RO_SCRIPT:-$KUBE_READ_DIR/kubectl-ro.sh}" "$@"
  fi
}
