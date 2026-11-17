#!/usr/bin/env bash
# Garde anti-dérive du catalogue Backstage : catalog/generated/all.yaml et catalog/locations.yaml
# doivent être exactement ce que scripts/catalog/generate-catalog.mjs produit depuis Git.
set -euo pipefail

cd "$(dirname "$0")/../.."
generator='scripts/catalog/generate-catalog.mjs'
all='catalog/generated/all.yaml'
command -v yq >/dev/null || { echo "yq is required" >&2; exit 1; }
command -v node >/dev/null || { echo "node is required" >&2; exit 1; }

# 1. Format des entités (apiVersion, kind, nommage, champs Component, annotations, unicité).
node --test tests/harness/catalog-generator-test.mjs >/dev/null

# 2. Dépôt à jour : la sortie régénérée est identique aux fichiers commités.
node "$generator" --check

# 3. Test négatif : une modification à la main de all.yaml doit faire échouer la garde.
backup="$(mktemp)"
cp "$all" "$backup"
trap 'cp "$backup" "$all"; rm -f "$backup"' EXIT
printf '\n# edition manuelle hors generateur\n' >>"$all"
if node "$generator" --check >/dev/null 2>&1; then
  echo "CATALOG_GENERATED_FRESH=FAIL (edition manuelle acceptee)" >&2
  exit 1
fi
cp "$backup" "$all"
node "$generator" --check
echo "CATALOG_GENERATED_FRESH=PASS"
