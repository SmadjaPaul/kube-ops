#!/usr/bin/env bash
# Contrat de scripts/check-oke-images-arm64.sh (PLT-405) : registre simule par des manifestes JSON locaux,
# aucun acces reseau. Positif : index avec linux/arm64. Negatifs : index amd64 seul, manifeste unique, image inconnue.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check="$repo_root/scripts/check-oke-images-arm64.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$tmp/reg"
cat >"$tmp/reg/multi.json" <<'JSON'
{"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[
 {"digest":"sha256:a","platform":{"architecture":"amd64","os":"linux"}},
 {"digest":"sha256:b","platform":{"architecture":"arm64","os":"linux"}}]}
JSON
cat >"$tmp/reg/amd64only.json" <<'JSON'
{"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[
 {"digest":"sha256:a","platform":{"architecture":"amd64","os":"linux"}},
 {"digest":"sha256:c","platform":{"architecture":"unknown","os":"unknown"}}]}
JSON
cat >"$tmp/reg/single.json" <<'JSON'
{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json","config":{"digest":"sha256:d"},"layers":[]}
JSON
cat >"$tmp/inspect.sh" <<EOF2
#!/usr/bin/env bash
f="$tmp/reg/\${1//[^A-Za-z0-9._-]/_}.json"
[[ -f \$f ]] || { echo "not found: \$1" >&2; exit 1; }
cat "\$f"
EOF2
chmod +x "$tmp/inspect.sh"
export OKE_IMAGE_INSPECT_CMD="$tmp/inspect.sh"
reg() { cp "$tmp/reg/$2.json" "$tmp/reg/$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_').json"; }

run() { bash "$check" --images-file "$tmp/images" >"$tmp/out" 2>&1; }
expect_fail() {
  if run; then cat "$tmp/out" >&2; fail "$2: must be rejected"; fi
  grep -qF -- "$1" "$tmp/out" || { cat "$tmp/out" >&2; fail "$2: expected message '$1'"; }
}

reg ghcr.io/x/good:1 multi; reg ghcr.io/x/amd:1 amd64only; reg ghcr.io/x/single:1 single

# positif
printf 'ghcr.io/x/good:1\n' >"$tmp/images"
run || { cat "$tmp/out" >&2; fail "multi-arch image with arm64 must pass"; }
grep -q 'OKE_IMAGES_ARM64=PASS (1 images' "$tmp/out" || fail "PASS summary missing"

# negatifs
printf 'ghcr.io/x/good:1\nghcr.io/x/amd:1\n' >"$tmp/images"
expect_fail 'no linux/arm64 variant' "amd64-only index"
printf 'ghcr.io/x/single:1\n' >"$tmp/images"
expect_fail 'single manifest' "single-arch manifest"
printf 'ghcr.io/x/missing:1\n' >"$tmp/images"
expect_fail 'manifest unreadable' "unknown image"

# rendu reel : un depot sans descripteur ni dossier OKE est une erreur de configuration (exit 2), pas un PASS vide
mkdir -p "$tmp/empty"
if bash "$check" "$tmp/empty" >"$tmp/out" 2>&1; then fail "empty repository must not pass"; fi

echo "oke-images-arm64-contract-test: OK"
