#!/usr/bin/env bash
# PRD-81 : garde du contournement Polyfin (parsers.py du fournisseur jellyfin de Music Assistant).
# Echoue si l'image MA change sans mise a jour du patch, ou si le fichier patche s'ecarte du diff attendu.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP="$ROOT/k8s/applications/automation/music-assistant"
PATCHED_FOR="2.10.8"
UPSTREAM_SHA256="9e185dbce19c489e40e8bd0567a7dc6732feb20406d42c0658c6dc473a2381e5"

fail() { echo "FAIL: $*" >&2; exit 1; }

# 1. L'image MA est celle pour laquelle le patch a ete fait.
grep -Eq "image: ghcr.io/music-assistant/server:${PATCHED_FOR//./\\.}@sha256:" "$APP/deployment.yaml" ||
  fail "l'image MA n'est plus ${PATCHED_FOR} : verifier si le contournement Polyfin est encore necessaire (retirer le montage) ou regenerer patches/jellyfin-parsers.{py,diff} sur la nouvelle version, puis mettre PATCHED_FOR/UPSTREAM_SHA256 a jour"

# 2. Le fichier patche = parsers.py amont + exactement le diff attendu.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cp "$APP/patches/jellyfin-parsers.py" "$work/parsers.py"
(cd "$work" && patch -R -s -p1 < "$APP/patches/jellyfin-parsers.diff") || fail "le diff attendu ne s'inverse pas sur le fichier patche"
got="$(shasum -a 256 "$work/parsers.py" | cut -d' ' -f1)"
[ "$got" = "$UPSTREAM_SHA256" ] || fail "fichier patche - diff attendu != parsers.py amont ${PATCHED_FOR} (sha ${got})"
grep -q 'workaround Polyfin CanDownload=false audio' "$APP/patches/jellyfin-parsers.py" || fail "commentaire du workaround absent"
[ "$(grep -c '^[-+][^-+]' "$APP/patches/jellyfin-parsers.diff")" -eq 3 ] || fail "le diff doit changer une ligne (1 retrait, 2 ajouts)"

# 3. Montage : subPath en lecture seule sur le parsers.py du paquet, ConfigMap generee, rechargement.
if command -v kustomize >/dev/null 2>&1; then
  out="$(kustomize build "$APP")"
  grep -q 'name: ma-jellyfin-parsers-patch' <<<"$out" || fail "ConfigMap ma-jellyfin-parsers-patch absente"
  grep -q 'subPath: parsers.py' <<<"$out" || fail "montage subPath absent"
  grep -q 'configmap.reloader.stakater.com/reload: ma-jellyfin-parsers-patch' <<<"$out" || fail "annotation Reloader absente"
  grep -q 'providers/jellyfin/parsers.py' <<<"$out" || fail "chemin cible absent"
fi
echo "ma-jellyfin-patch-test: PASS"
