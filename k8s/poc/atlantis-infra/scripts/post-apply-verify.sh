#!/usr/bin/env bash
set -euo pipefail

[[ "${PROJECT_NAME:-}" == github || "${PROJECT_NAME:-}" == unifi ]] || {
  echo 'Atlantis Infra post-apply denied: unexpected project' >&2
  exit 1
}
[[ "${REPO_REL_DIR:-}" == "terraform/$PROJECT_NAME" ]] || {
  echo 'Atlantis Infra post-apply denied: root mismatch' >&2
  exit 1
}
[[ "${WORKSPACE:-}" == default ]] || {
  echo 'Atlantis Infra post-apply denied: workspace mismatch' >&2
  exit 1
}
[[ -n "${HEAD_COMMIT:-}" && -n "${PULL_NUM:-}" ]] || {
  echo 'Atlantis Infra post-apply denied: immutable PR identity missing' >&2
  exit 1
}
[[ -f "${DIR:-}/backend.tf" && -f "${DIR:-}/.terraform.lock.hcl" ]] || {
  echo 'Atlantis Infra post-apply denied: root contract missing' >&2
  exit 1
}

printf 'ATLANTIS_POST_APPLY=PASS project=%s pr=%s head=%s root=%s workspace=%s\n' \
  "$PROJECT_NAME" "$PULL_NUM" "$HEAD_COMMIT" "$REPO_REL_DIR" "$WORKSPACE"
