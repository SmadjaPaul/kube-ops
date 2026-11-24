#!/usr/bin/env bash
# Controle "image arm64" des charges deployees sur OKE (PLT-405). Les noeuds d'oracle-a1 sont arm64 (A1) :
# une image sans variante linux/arm64 reste en ImagePullBackOff / exec format error, vu seulement apres merge.
#
# Perimetre : les images du rendu `kustomize build --enable-helm` de chaque app a descripteur
# `argocd-app.oracle-a1.yaml` et de chaque dossier infrastructure de k8s/clusters/oracle-a1/ (liste de
# l'ApplicationSet `infrastructure`). Champs lus : `image` (conteneurs, initContainers, ephemeral) et
# `imageName` (CNPG). Chaque reference doit etre un index OCI / liste de manifestes contenant linux/arm64 ;
# une image a manifeste unique est refusee (arm64 non demontre par le manifeste).
#
# Usage : bash scripts/check-oke-images-arm64.sh [racine-du-depot]
#         bash scripts/check-oke-images-arm64.sh --images-file <fichier>   (une reference par ligne, sans rendu)
# Inspection : `docker buildx imagetools inspect --raw <ref>` (registre uniquement, pas de daemon), ou la
# commande de OKE_IMAGE_INSPECT_CMD (recoit la reference en $1, affiche le JSON du manifeste) pour les tests.
# Acces registre en lecture seule, aucun acces cluster ni secret.
set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required" >&2; exit 2; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
errors=0
fail() { echo "FAIL: $*" >&2; errors=$((errors + 1)); }

if [[ ${1:-} == --images-file ]]; then
  [[ -f ${2:-} ]] || { echo "ERROR: --images-file needs a file" >&2; exit 2; }
  grep -v '^[[:space:]]*$' "$2" | sort -u >"$tmp/images" || true
else
  command -v yq >/dev/null 2>&1 || { echo "ERROR: yq is required" >&2; exit 2; }
  command -v kustomize >/dev/null 2>&1 || { echo "ERROR: kustomize is required" >&2; exit 2; }
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  repo="$(cd "${1:-$here/..}" && pwd)"
  : >"$tmp/dirs"
  for f in "$repo"/k8s/applications/*/*/argocd-app.oracle-a1.yaml; do
    [[ -f $f ]] && dirname "$f" >>"$tmp/dirs"
  done
  for pf in "$repo"/k8s/clusters/oracle-a1/argocd-root/*.yaml; do
    yq eval --no-doc 'select(.kind == "ApplicationSet" and .metadata.name == "infrastructure") | .spec.generators[].matrix.generators[]?.git.directories[]?.path // .spec.generators[].git.directories[]?.path' "$pf" 2>/dev/null
  done | grep -E '^k8s/clusters/oracle-a1/' | while IFS= read -r p; do [[ -d $repo/$p ]] && echo "$repo/$p"; done >>"$tmp/dirs" || true
  sort -u -o "$tmp/dirs" "$tmp/dirs"
  [[ -s $tmp/dirs ]] || { echo "ERROR: no OKE directory found (apps with argocd-app.oracle-a1.yaml, infrastructure directories)" >&2; exit 2; }
  : >"$tmp/images"
  while IFS= read -r d; do
    if kustomize build --enable-helm "$d" >"$tmp/render.yaml" 2>"$tmp/render.err"; then
      yq eval --no-doc '[.. | select(tag == "!!map") | (.image, .imageName) | select(tag == "!!str")] | .[]' "$tmp/render.yaml" >>"$tmp/images"
    else
      fail "${d#"$repo"/}: kustomize build failed: $(head -3 "$tmp/render.err" | tr '\n' ' ')"
    fi
  done <"$tmp/dirs"
  grep -v '^[[:space:]]*$' "$tmp/images" | sort -u >"$tmp/images.sorted" || true
  mv "$tmp/images.sorted" "$tmp/images"
fi

inspect() {
  if [[ -n ${OKE_IMAGE_INSPECT_CMD:-} ]]; then
    "$OKE_IMAGE_INSPECT_CMD" "$1"
  else
    docker buildx imagetools inspect --raw "$1"
  fi
}

n=0
while IFS= read -r ref; do
  [[ -n $ref ]] || continue
  n=$((n + 1))
  if ! inspect "$ref" >"$tmp/manifest.json" 2>"$tmp/inspect.err"; then
    fail "$ref: manifest unreadable ($(head -2 "$tmp/inspect.err" | tr '\n' ' '))"
    continue
  fi
  if ! jq -e '(.manifests // null) | type == "array"' "$tmp/manifest.json" >/dev/null 2>&1; then
    fail "$ref: single manifest, not a multi-arch index; linux/arm64 is not proven (publish a multi-arch image)"
  elif ! jq -e '[.manifests[] | select(.platform.os == "linux" and .platform.architecture == "arm64")] | length > 0' "$tmp/manifest.json" >/dev/null; then
    fail "$ref: no linux/arm64 variant (OKE nodes are arm64 A1)"
  fi
done <"$tmp/images"

if [[ $errors -gt 0 ]]; then
  echo "OKE_IMAGES_ARM64=FAIL ($errors of $n images)" >&2
  exit 1
fi
echo "OKE_IMAGES_ARM64=PASS ($n images, all with linux/arm64)"
