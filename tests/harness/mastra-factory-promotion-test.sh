#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo_root/scripts/promote-mastra-factory-digest.sh"
source_sha=0123456789abcdef0123456789abcdef01234567
digest=sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/scripts" "$tmp/k8s/applications/platform/mastra-factory"
cp "$script" "$tmp/scripts/"
cp "$repo_root/k8s/applications/platform/mastra-factory/deployment.yaml" \
  "$tmp/k8s/applications/platform/mastra-factory/deployment.yaml"
git -C "$tmp" init -q
git -C "$tmp" config user.email test@example.invalid
git -C "$tmp" config user.name promotion-test
git -C "$tmp" add .
git -C "$tmp" commit -qm baseline

first="$(cd "$tmp" && bash scripts/promote-mastra-factory-digest.sh "$source_sha" "$digest" 2>&1)"
grep -q 'PROMOTION=UPDATED' <<<"$first"
second="$(cd "$tmp" && bash scripts/promote-mastra-factory-digest.sh "$source_sha" "$digest" 2>&1)"
grep -q 'PROMOTION=NOOP' <<<"$second"
SHA="$source_sha" IMAGE="ghcr.io/smadjapaul/mastra-factory@$digest" \
  yq -e '(.metadata.annotations."factory-platform.dev/source-sha" == strenv(SHA)) and ((.spec.template.spec.containers[] | select(.name == "factory") | .image) == strenv(IMAGE))' \
  "$tmp/k8s/applications/platform/mastra-factory/deployment.yaml" \
  >/dev/null

if (cd "$tmp" && bash scripts/promote-mastra-factory-digest.sh bad "$digest") 2>/dev/null; then
  echo "invalid source SHA was accepted" >&2
  exit 1
fi

printf 'MASTRA_FACTORY_PROMOTION=PASS idempotent=true sha_bound=true\n'
