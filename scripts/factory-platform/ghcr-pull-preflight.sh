#!/usr/bin/env bash
set -euo pipefail

IMAGE="${FACTORY_PLATFORM_IMAGE:-ghcr.io/smadjapaul/factory-platform@sha256:ed5a440109e7d470e3d17cfe6da2a89091901c1479bb818ef5310b614c0d8439}"
USER_NAME="${GITHUB_PACKAGES_USERNAME:-SmadjaPaul}"

if [[ -z "${GITHUB_PAT:-}" ]]; then
  echo "GHCR_EXISTING_PAT_PRESENT=NO"
  exit 2
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
export DOCKER_CONFIG="$tmpdir"

if ! printf '%s' "$GITHUB_PAT" | docker login ghcr.io --username "$USER_NAME" --password-stdin >/dev/null 2>&1; then
  echo "GHCR_EXISTING_PAT_LOGIN=FAIL"
  exit 3
fi
echo "GHCR_EXISTING_PAT_LOGIN=PASS"

if ! docker manifest inspect "$IMAGE" >/dev/null 2>&1; then
  echo "GHCR_FACTORY_PLATFORM_PULL=FAIL"
  exit 4
fi

echo "GHCR_FACTORY_PLATFORM_PULL=PASS"
echo "GHCR_EXISTING_PAT_REUSE_SAFE_FOR_PULL=YES"
