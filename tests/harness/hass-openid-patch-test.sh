#!/usr/bin/env bash
# PRD-87b : garde du correctif hass-openid (ui_views.py). Echoue si OPENID_COMMIT change sans mise a jour du patch,
# ou si le fichier livre s'ecarte de (fichier amont epingle + diff relu).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP="$ROOT/k8s/applications/automation/hassio"
PATCHED_FOR="0135a6f8150693ecb99cd5ba42446e0d1e66994d"
UPSTREAM_SHA256="7ba0578671820ac5504fbde3201e12092512a3a1ee101e0a05bad9dad6c27b01"
PATCHED_SHA256="858d760fe9f52456cf3840f6ecd703234ed756bef244f4a593e32edc8950c807"
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
fail() { echo "FAIL: $*" >&2; exit 1; }
sts="$APP/statefulset.yaml"

grep -q "value: ${PATCHED_FOR}\$" "$sts" || fail "OPENID_COMMIT a change : regenerer patches/openid-ui_views.{py,diff} sur le nouveau commit (ou retirer le patch si PR cavefire/hass-openid#101 est mergee), puis mettre a jour PATCHED_FOR et les sha256"
grep -q "archive/${PATCHED_FOR}.tar.gz" "$sts" || fail "URL de l'archive != OPENID_COMMIT du patch"
grep -q "value: ${UPSTREAM_SHA256}\$" "$sts" || fail "sha256 amont absent du statefulset"
grep -q "value: ${PATCHED_SHA256}\$" "$sts" || fail "sha256 patche absent du statefulset"
[ "$(sha "$APP/patches/openid-ui_views.py")" = "$PATCHED_SHA256" ] || fail "openid-ui_views.py != sha256 attendu"

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
mkdir -p "$work/custom_components/openid"
cp "$APP/patches/openid-ui_views.py" "$work/custom_components/openid/ui_views.py"
(cd "$work" && patch -R -s -p1 < "$APP/patches/openid-ui_views.diff") || fail "le diff ne s'inverse pas sur le fichier livre"
[ "$(sha "$work/custom_components/openid/ui_views.py")" = "$UPSTREAM_SHA256" ] || fail "fichier livre - diff != ui_views.py amont epingle"
[ "$(grep -c '^diff --git' "$APP/patches/openid-ui_views.diff")" -eq 1 ] || fail "le diff doit toucher un seul fichier"
if grep -Eq '^\+.*(http|requests|aiohttp\.Client|socket|subprocess|os\.environ)' "$APP/patches/openid-ui_views.diff"; then fail "le diff ajoute un acces reseau/processus/env"; fi

if command -v kustomize >/dev/null 2>&1; then
  out="$(kustomize build "$APP")"
  grep -q 'name: ha-openid-ui-views-patch' <<<"$out" || fail "ConfigMap ha-openid-ui-views-patch absente"
  grep -q 'mountPath: /openid-patch' <<<"$out" || fail "montage du patch absent"
fi
echo "hass-openid-patch-test: PASS"
