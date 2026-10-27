#!/usr/bin/env bash
set -euo pipefail

policy=.github/polyfin/private-pilot-admission.json
checker=scripts/polyfin-admission-check.sh
image="$(jq -er '.image.repository + ":" + .image.tag + "@" + .image.digest' "$policy")"
tmpdir="$(mktemp -d /tmp/polyfin-admission-test.XXXXXX)"
trap 'rm -rf "$tmpdir"' EXIT

jq -r '.acceptedFindings[].id | "target\t" + . + "\tpkg\t1\tUNFIXED\tHIGH\taffected"' "$policy" > "$tmpdir/findings.tsv"

POLYFIN_ADMISSION_NOW=2026-11-01T12:00:00Z "$checker" \
  --image "$image" --findings "$tmpdir/findings.tsv" --policy "$policy"

if POLYFIN_ADMISSION_NOW=2026-11-01T12:00:00Z "$checker" \
  --image "${image%@*}@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
  --findings "$tmpdir/findings.tsv" --policy "$policy"; then
  echo 'expected digest mismatch to fail' >&2
  exit 1
fi

printf 'target\tCVE-2099-0001\tpkg\t1\tUNFIXED\tHIGH\taffected\n' >> "$tmpdir/findings.tsv"
if POLYFIN_ADMISSION_NOW=2026-11-01T12:00:00Z "$checker" \
  --image "$image" --findings "$tmpdir/findings.tsv" --policy "$policy"; then
  echo 'expected unaccepted CVE to fail' >&2
  exit 1
fi

sed -i 's/2026-11-01T12:00:00Z/2026-12-01T12:00:00Z/' "$tmpdir/findings.tsv" 2>/dev/null || true
if POLYFIN_ADMISSION_NOW=2026-11-27T00:00:00Z "$checker" \
  --image "$image" --findings "${tmpdir}/findings.tsv" --policy "$policy"; then
  echo 'expected expired admission to fail' >&2
  exit 1
fi

echo 'POLYFIN_ADMISSION_TEST=PASS positive; digest/new-CVE/expiry negatives rejected'
