#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/affected-tests-harness.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/scripts" "$tmp/k8s/applications/shared"
cp "$repo_root/scripts/affected-tests.sh" "$tmp/scripts/affected-tests.sh"
cp "$repo_root/scripts/affected-tests.conf" "$tmp/scripts/affected-tests.conf"
chmod +x "$tmp/scripts/affected-tests.sh"
git -C "$tmp" init -q
git -C "$tmp" config user.name test
git -C "$tmp" config user.email test@example.invalid
printf '%s\n' base >"$tmp/README.md"
git -C "$tmp" add README.md && git -C "$tmp" commit -qm base
base="$(git -C "$tmp" rev-parse HEAD)"

printf '%s\n' changed >"$tmp/k8s/applications/shared/base.yaml"
git -C "$tmp" add k8s/applications/shared/base.yaml
output="$(AFFECTED_REPO_ROOT="$tmp" "$tmp/scripts/affected-tests.sh" --select "$base")"
[[ "$output" == *'AFFECTED_TESTS=SELECTED'* ]] || { echo "$output"; exit 1; }
[[ "$output" == *'render:k8s/applications/media'* ]] || { echo "$output"; exit 1; }

printf '%s\n' global >"$tmp/scripts/new-check.sh"
git -C "$tmp" add scripts/new-check.sh
output="$(AFFECTED_REPO_ROOT="$tmp" "$tmp/scripts/affected-tests.sh" --select "$base")"
[[ "$output" == *'AFFECTED_CRITICAL=yes'* ]] || { echo "$output"; exit 1; }
[[ "$output" == *'render:k8s/infrastructure/security'* ]] || { echo "$output"; exit 1; }

printf '%s\n' unknown >"$tmp/unclassified.data"
git -C "$tmp" add unclassified.data
output="$(AFFECTED_REPO_ROOT="$tmp" "$tmp/scripts/affected-tests.sh" --select "$base")"
[[ "$output" == *'AFFECTED_CRITICAL=yes'* ]] || { echo "$output"; exit 1; }
[[ "$output" == *'render:k8s/applications/platform'* ]] || { echo "$output"; exit 1; }

printf '%s\n' 'AFFECTED_TEST_SELECTOR=PASS'
