#!/usr/bin/env bash
# Installs the pinned tools the post-merge job needs on the stock ARC runner image (PLT-390 lot 3):
# kubectl, jq, yq, just, into ~/.local/bin. Each download is checked against a pinned sha256 (linux/amd64).
# Hosts: dl.k8s.io, github.com release assets (allowed by the egress policy of the kube-ops scale set).
# Usage: bash scripts/ci-install-tools.sh   (then PATH="$HOME/.local/bin:$PATH")
set -euo pipefail
[[ $(uname -m) == x86_64 ]] || { echo "ci-install-tools: linux/amd64 only (got $(uname -m))" >&2; exit 2; }
bin=${CI_TOOLS_BIN:-$HOME/.local/bin}; mkdir -p "$bin"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/ci-tools.XXXXXX"); trap 'rm -rf "$tmp"' EXIT
sha_of() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
fetch() { # URL SHA256 DEST
  curl -fsSL --max-time 120 -o "$3" "$1"
  [[ $(sha_of "$3") == "$2" ]] || { echo "ci-install-tools: sha256 mismatch for $1" >&2; exit 2; }
}
need() { command -v "$1" >/dev/null 2>&1 && [[ ${CI_TOOLS_FORCE:-} != 1 ]]; }
need kubectl || { fetch https://dl.k8s.io/release/v1.36.3/bin/linux/amd64/kubectl ebbd080e7c2e275093b55915722043257eb24004363e20acb3c4d71919f88336 "$bin/kubectl"; chmod +x "$bin/kubectl"; }
need jq || { fetch https://github.com/jqlang/jq/releases/download/jq-1.8.2/jq-linux-amd64 b1c22172dd303f3be49e935aa56aa48a8b7a46e0bc838b4997d3bb451495870f "$bin/jq"; chmod +x "$bin/jq"; }
need yq || { fetch https://github.com/mikefarah/yq/releases/download/v4.54.3/yq_linux_amd64 129534601871538efe0ba4c5e62a34fb1d5f469bcb975c4fddeb467d82974973 "$bin/yq"; chmod +x "$bin/yq"; }
need just || {
  fetch https://github.com/casey/just/releases/download/1.59.0/just-1.59.0-x86_64-unknown-linux-musl.tar.gz 409044617b6f06517c1035e55ca38c8c856ff8b650e41bc2aa1ef82d5903a23e "$tmp/just.tgz"
  tar -xzf "$tmp/just.tgz" -C "$tmp" just && install -m 0755 "$tmp/just" "$bin/just"
}
echo "CI_TOOLS=READY bin=$bin"
