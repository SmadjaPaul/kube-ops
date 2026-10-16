#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "usage: $0 SOURCE_SHA DIGEST [MANIFEST]" >&2
  exit 64
}

[[ $# -ge 2 && $# -le 3 ]] || usage
source_sha="$1"
digest="$2"
manifest_rel="${3:-k8s/applications/platform/mastra-factory/deployment.yaml}"

[[ "$source_sha" =~ ^[0-9a-f]{40}$ ]] || {
  echo "source SHA must be a 40-character lowercase hexadecimal commit" >&2
  exit 2
}
[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || {
  echo "image digest must be sha256:<64 lowercase hexadecimal characters>" >&2
  exit 2
}

repo_root="$(git rev-parse --show-toplevel)"
manifest_path="$repo_root/$manifest_rel"
[[ -f "$manifest_path" ]] || {
  echo "manifest not found: $manifest_rel" >&2
  exit 2
}

command -v yq >/dev/null || {
  echo "yq is required for deterministic YAML mutation" >&2
  exit 127
}

desired_image="ghcr.io/smadjapaul/mastra-factory@$digest"
container_count="$(yq -r '[.spec.template.spec.containers[] | select(.name == "factory")] | length' "$manifest_path")"
[[ "$container_count" == 1 ]] || {
  echo "expected exactly one mastra-factory container named factory" >&2
  exit 2
}

current_image="$(yq -r '.spec.template.spec.containers[] | select(.name == "factory") | .image' "$manifest_path")"
current_source_sha="$(yq -r '.metadata.annotations."factory-platform.dev/source-sha" // ""' "$manifest_path")"

if [[ "$current_image" == "$desired_image" && "$current_source_sha" == "$source_sha" ]]; then
  echo "PROMOTION=NOOP source_sha=$source_sha digest=$digest"
  exit 0
fi

if [[ "$current_image" == "$desired_image" && -n "$current_source_sha" && "$current_source_sha" != "$source_sha" ]]; then
  echo "refusing digest/source mismatch: existing source $current_source_sha" >&2
  exit 2
fi

# Never overwrite an unrelated local edit in the desired-state file. An exact
# desired state is safe to report as a no-op even when the file is uncommitted.
git -C "$repo_root" diff --quiet -- "$manifest_rel" || {
  echo "refusing to overwrite unstaged changes in $manifest_rel" >&2
  exit 2
}
git -C "$repo_root" diff --cached --quiet -- "$manifest_rel" || {
  echo "refusing to overwrite staged changes in $manifest_rel" >&2
  exit 2
}

SOURCE_SHA="$source_sha" IMAGE="$desired_image" yq -i '
  .metadata.annotations."factory-platform.dev/source-sha" = strenv(SOURCE_SHA) |
  (.spec.template.spec.containers[] | select(.name == "factory") | .image) = strenv(IMAGE)
' "$manifest_path"

test "$(yq -r '.metadata.annotations."factory-platform.dev/source-sha"' "$manifest_path")" = "$source_sha"
test "$(yq -r '.spec.template.spec.containers[] | select(.name == "factory") | .image' "$manifest_path")" = "$desired_image"
echo "PROMOTION=UPDATED source_sha=$source_sha digest=$digest"
