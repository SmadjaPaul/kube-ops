#!/usr/bin/env bash
set -euo pipefail

deny() {
  printf 'Atlantis Apps admission denied: %s\n' "$*" >&2
  exit 1
}

[[ "${BASE_REPO_OWNER:-}/${BASE_REPO_NAME:-}" == "SmadjaPaul/homelab-infra" ]] || deny 'base repository'
[[ "${HEAD_REPO_OWNER:-}/${HEAD_REPO_NAME:-}" == "$BASE_REPO_OWNER/$BASE_REPO_NAME" ]] || deny 'fork'
[[ "${BASE_BRANCH_NAME:-}" == main ]] || deny 'base branch'
[[ -z "${COMMENT_ARGS:-}" ]] || deny 'comment arguments'
[[ "${WORKSPACE:-}" == default ]] || deny 'workspace'
[[ "${REPO_REL_DIR:-}" == "terraform/aiostreams" || "${REPO_REL_DIR:-}" == "terraform/polyfin" ]] || deny 'root is not an Apps root'
[[ "${PROJECT_NAME:-}" == "${REPO_REL_DIR#terraform/}" ]] || deny 'project/root mismatch'
[[ -n "${HEAD_COMMIT:-}" ]] || deny 'immutable head missing'
[[ -f "${DIR:-}/backend.tf" ]] || deny 'backend missing'
[[ -f "${DIR:-}/.terraform.lock.hcl" ]] || deny 'provider lockfile missing'

case "$PROJECT_NAME" in
  aiostreams)
    [[ -f /etc/atlantis/roots/aiostreams/backend/AWS_ACCESS_KEY_ID ]] || deny 'AIOStreams backend identity unavailable'
    [[ -f /etc/atlantis/roots/aiostreams/provider/AIOSTREAMS_PASSWORD ]] || deny 'AIOStreams provider identity unavailable'
    ;;
  polyfin)
    [[ -f /etc/atlantis/roots/polyfin/backend/AWS_ACCESS_KEY_ID ]] || deny 'Polyfin backend identity unavailable'
    [[ -f /etc/atlantis/roots/polyfin/provider/POLYFIN_ADMIN_PASSWORD ]] || deny 'Polyfin provider identity unavailable'
    ;;
  *) deny 'unknown project';;
esac

printf 'Atlantis Apps root admission PASS: %s\n' "$PROJECT_NAME"
