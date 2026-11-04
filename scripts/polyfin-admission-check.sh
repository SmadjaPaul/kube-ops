#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--self-test" ]]; then
  root="$(cd "$(dirname "$0")/.." && pwd)"
  checker="$root/scripts/polyfin-admission-check.sh"
  policy="$root/.github/polyfin/private-pilot-admission-v060.json"
  image="$(jq -er '.image.repository + ":" + .image.tag + "@" + .image.digest' "$policy")"
  tmpdir="$(mktemp -d /tmp/polyfin-tier-test.XXXXXX)"
  trap 'rm -rf "$tmpdir"' EXIT
  printf '%s\n' \
    $'target\tCVE-2026-6653\tlibxml2\t1\tUNFIXED\tCRITICAL\taffected' \
    $'target\tCVE-2025-69720\tlibtinfo6\t1\tUNFIXED\tHIGH\taffected' \
    $'target\tCVE-2026-103111\tlibpcre2-8-0\t1\t10.46-1~deb13u3\tHIGH\tfixed' \
    >"$tmpdir/findings.tsv"

  POLYFIN_ADMISSION_NOW=2026-11-05T12:00:00Z "$checker" --image "$image" --findings "$tmpdir/findings.tsv" --policy "$policy" >/dev/null

  jq '.blockedFindings = ["CVE-2026-6653"]' "$policy" >"$tmpdir/blocked.json"
  if POLYFIN_ADMISSION_NOW=2026-11-05T12:00:00Z "$checker" --image "$image" --findings "$tmpdir/findings.tsv" --policy "$tmpdir/blocked.json" >/dev/null 2>&1; then exit 1; fi
  jq '.admission.expiresAt = "2026-11-04T23:59:59Z"' "$policy" >"$tmpdir/expired.json"
  if POLYFIN_ADMISSION_NOW=2026-11-05T12:00:00Z "$checker" --image "$image" --findings "$tmpdir/findings.tsv" --policy "$tmpdir/expired.json" >/dev/null 2>&1; then exit 1; fi
  jq '.perimeter.externalRoute = true' "$policy" >"$tmpdir/external.json"
  if POLYFIN_ADMISSION_NOW=2026-11-05T12:00:00Z "$checker" --image "$image" --findings "$tmpdir/findings.tsv" --policy "$tmpdir/external.json" >/dev/null 2>&1; then exit 1; fi
  jq '.workload.nonRoot = false' "$policy" >"$tmpdir/privileged.json"
  if POLYFIN_ADMISSION_NOW=2026-11-05T12:00:00Z "$checker" --image "$image" --findings "$tmpdir/findings.tsv" --policy "$tmpdir/privileged.json" >/dev/null 2>&1; then exit 1; fi
  jq '.securityTier = "T1" | .admission.mode = "strict" | del(.riskRegister,.blockedFindings)' "$policy" >"$tmpdir/strict.json"
  if POLYFIN_ADMISSION_NOW=2026-11-05T12:00:00Z "$checker" --image "$image" --findings "$tmpdir/findings.tsv" --policy "$tmpdir/strict.json" >/dev/null 2>&1; then exit 1; fi
  [[ "$(wc -l <"$tmpdir/findings.tsv" | tr -d ' ')" == 3 ]]
  echo 'POLYFIN_SECURITY_TIER_TEST=PASS T2 residual/critical bounded; active/expired/external/privilege/strict negatives rejected'
  exit 0
fi

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
expires="$(jq -er '.admission.expiresAt // .approval.expiresAt' "$policy")"

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

# T2/T3 pilot policies deliberately separate complete scan evidence from the
# admission verdict.  The legacy policy shape remains strict by default so
# existing T0/T1-like callers cannot silently become risk-accepted.
admission_mode="$(jq -r '.admission.mode // "strict"' "$policy")"
if [[ "$admission_mode" == "risk-accepted" ]]; then
  tier="$(jq -er '.securityTier' "$policy")"
  [[ "$tier" == "T2" || "$tier" == "T3" ]] || {
    echo "POLYFIN_ADMISSION=FAIL risk-accepted policy requires T2 or T3, got $tier" >&2
    exit 1
  }

  jq -e '
    .perimeter.publicExposure == false and
    .perimeter.externalRoute == false and
    .perimeter.networkPolicyMaintained == true and
    .perimeter.credentialsIsolated == true and
    .workload.nonRoot == true and
    .workload.readOnlyRootFilesystem == true and
    .workload.serviceAccountToken == false and
    .workload.allCapabilitiesDropped == true and
    (.perimeter.unauthorizedPrivileges | not)
  ' "$policy" >/dev/null || {
    echo 'POLYFIN_ADMISSION=FAIL T2/T3 perimeter or privilege controls are not bounded' >&2
    exit 1
  }
fi

accepted="$(mktemp)"
observed="$(mktemp)"
unexpected="$(mktemp)"
unused="$(mktemp)"
trap 'rm -f "$accepted" "$observed" "$unexpected" "$unused"' EXIT

jq -r '.acceptedFindings[]?.id // empty' "$policy" | sort -u > "$accepted"
awk -F '\t' 'NF >= 2 && $2 != "" { print $2 }' "$findings" | sort -u > "$observed"

[[ -s "$observed" ]] || { echo 'POLYFIN_ADMISSION=FAIL no Trivy findings supplied' >&2; exit 1; }

if [[ "$admission_mode" == "risk-accepted" ]]; then
  tracked="$(mktemp)"
  blocked="$(mktemp)"
  affected="$(mktemp)"
  trap 'rm -f "$accepted" "$observed" "$unexpected" "$unused" "$tracked" "$blocked" "$affected"' EXIT
  jq -r '(.riskRegister[]?, .acceptedFindings[]?, .t2ResidualFindings[]?) | .id' "$policy" | sort -u > "$tracked"
  jq -r '.blockedFindings[]? // empty' "$policy" | sort -u > "$blocked"
  awk -F '\t' 'NF >= 2 && $2 != "" && ($7 == "" || $7 != "fixed") { print $2 }' "$findings" | sort -u > "$affected"

  comm -13 "$tracked" "$observed" > "$unexpected"
  if [[ -s "$unexpected" ]]; then
    echo 'POLYFIN_ADMISSION=FAIL unreviewed CVEs in complete scan:' >&2
    cat "$unexpected" >&2
    exit 1
  fi

  if comm -12 "$blocked" "$affected" | grep -q .; then
    echo 'POLYFIN_ADMISSION=FAIL actively exploited/reachable grave CVE is present' >&2
    comm -12 "$blocked" "$affected" >&2
    exit 1
  fi

  for cve in $(jq -r '.mustBeAbsent[]? // empty' "$policy"); do
    if grep -Fxq "$cve" "$affected"; then
      echo "POLYFIN_ADMISSION=FAIL corrected CVE returned: $cve" >&2
      exit 1
    fi
  done

  jq -e '[((.riskRegister[]?, .acceptedFindings[]?, .t2ResidualFindings[]?)) | select(.id == "CVE-2026-6653" and .severity == "CRITICAL" and (.disposition == "temporary-risk-acceptance" or .disposition == null))] | length == 1' "$policy" >/dev/null || {
    echo 'POLYFIN_ADMISSION=FAIL CVE-2026-6653 requires an explicit temporary acceptance' >&2
    exit 1
  }

  echo "POLYFIN_ADMISSION=PASS tier=$tier image=$image platform=$platform scanned=$(wc -l < "$observed" | tr -d ' ') affected=$(wc -l < "$affected" | tr -d ' ') expires=$expires"
  exit 0
fi

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
