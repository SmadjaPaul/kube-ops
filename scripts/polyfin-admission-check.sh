#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 --image IMAGE@DIGEST --findings TSV --policy JSON" >&2
  exit 2
}

image=""
findings=""
policy=""
while (($#)); do
  case "$1" in
    --image) image="${2:-}"; shift 2 ;;
    --findings) findings="${2:-}"; shift 2 ;;
    --policy) policy="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done

[[ -n "$image" && -f "$findings" && -f "$policy" ]] || usage
command -v jq >/dev/null || { echo 'jq is required' >&2; exit 2; }
command -v date >/dev/null || { echo 'date is required' >&2; exit 2; }

to_epoch() {
  if date -u -d "$1" +%s 2>/dev/null; then
    return 0
  fi
  date -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null
}

repository="$(jq -er '.image.repository' "$policy")"
tag="$(jq -er '.image.tag' "$policy")"
digest="$(jq -er '.image.digest' "$policy")"
platform="$(jq -er '.image.platform' "$policy")"
expires="$(jq -er '.approval.expiresAt' "$policy")"

[[ "$platform" == "linux/amd64" ]] || { echo "POLYFIN_ADMISSION=FAIL platform=$platform" >&2; exit 1; }
expected_image="$repository:$tag@$digest"
[[ "$image" == "$expected_image" ]] || {
  echo "POLYFIN_ADMISSION=FAIL image=$image expected=$expected_image" >&2
  exit 1
}

now_input="${POLYFIN_ADMISSION_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
now_epoch="$(to_epoch "$now_input")" || {
  echo "POLYFIN_ADMISSION=FAIL invalid current time: $now_input" >&2
  exit 1
}
expiry_epoch="$(to_epoch "$expires")" || {
  echo "POLYFIN_ADMISSION=FAIL invalid expiry: $expires" >&2
  exit 1
}
(( now_epoch < expiry_epoch )) || {
  echo "POLYFIN_ADMISSION=FAIL expiredAt=$expires now=$now_input" >&2
  exit 1
}

accepted="$(mktemp)"
observed="$(mktemp)"
unexpected="$(mktemp)"
unused="$(mktemp)"
trap 'rm -f "$accepted" "$observed" "$unexpected" "$unused"' EXIT

jq -r '.acceptedFindings[].id' "$policy" | sort -u > "$accepted"
awk -F '\t' 'NF >= 2 && $2 != "" { print $2 }' "$findings" | sort -u > "$observed"

[[ -s "$observed" ]] || { echo 'POLYFIN_ADMISSION=FAIL no Trivy findings supplied' >&2; exit 1; }

comm -23 "$observed" "$accepted" > "$unexpected"
if [[ -s "$unexpected" ]]; then
  echo 'POLYFIN_ADMISSION=FAIL unaccepted CVEs:' >&2
  cat "$unexpected" >&2
  exit 1
fi

comm -13 "$observed" "$accepted" > "$unused"
if [[ -s "$unused" ]]; then
  echo 'POLYFIN_ADMISSION=FAIL accepted CVEs absent from the bound scan:' >&2
  cat "$unused" >&2
  exit 1
fi

for cve in $(jq -r '.mustBeAbsent[]' "$policy"); do
  if grep -Fxq "$cve" "$observed"; then
    echo "POLYFIN_ADMISSION=FAIL corrected CVE returned: $cve" >&2
    exit 1
  fi
done

[[ "$(jq '[.acceptedFindings[] | select(.id == "CVE-2026-6653")] | length' "$policy")" == "1" ]] || {
  echo 'POLYFIN_ADMISSION=FAIL CVE-2026-6653 must have its own acceptance entry' >&2
  exit 1
}

echo "POLYFIN_ADMISSION=PASS image=$image platform=$platform accepted=$(wc -l < "$accepted" | tr -d ' ') expires=$expires"
