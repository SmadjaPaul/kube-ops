#!/usr/bin/env bash
# PLT-317 — only Fleet agent endpoints reach Gateway/external.
# Parses the YAML with yq (mikefarah v4): every match must carry an explicit
# path from the allowlist and nothing else; parentRefs are read as objects.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
pkg="$root/k8s/optional/fleet"
public="$pkg/http-route-public.yaml"
admin="$pkg/http-route.yaml"
fail() {
  echo "FLEET_PUBLIC_ROUTE=FAIL $*" >&2
  exit 1
}
command -v yq >/dev/null || fail "yq required"

allowed='PathPrefix /api/osquery/
PathPrefix /api/v1/osquery/
PathPrefix /api/fleet/orbit/
Exact /api/fleet/device/ping
PathPrefix /api/v1/fleet/device/
PathPrefix /api/latest/fleet/device/
PathPrefix /device/
PathPrefix /assets/
Exact /mdm/apple/scep
Exact /mdm/apple/mdm'

[ "$(yq 'select(.kind == "HTTPRoute") | .metadata.name' "$public")" = fleet-agents-public ] || fail "unexpected document"

# A rule without matches, or a match without an explicit path (e.g. `- {}`),
# defaults to prefix / and would publish the admin API.
[ "$(yq '[.spec.rules[] | select((.matches // []) | length == 0)] | length' "$public")" = 0 ] || fail "rule without matches"
[ "$(yq '[.spec.rules[].matches[] | select(.path.type == null or .path.value == null)] | length' "$public")" = 0 ] || fail "match without explicit path"
# Only path matching: no header/query/method widening or narrowing is expected.
[ "$(yq '[.spec.rules[].matches[] | keys | .[] | select(. != "path")] | length' "$public")" = 0 ] || fail "match uses fields other than path"

actual="$(yq -r '.spec.rules[].matches[].path | .type + " " + .value' "$public" | sort)"
expected="$(printf '%s\n' "$allowed" | sort)"
[ "$actual" = "$expected" ] || fail "public paths differ from the agent allowlist"

parents() { yq -r '.spec.parentRefs[] | (.namespace // "") + "/" + .name' "$1" | sort -u; }
[ "$(parents "$public")" = "gateway/external" ] || fail "public route must attach to Gateway/external only"
[ "$(parents "$admin")" = "gateway/internal" ] || fail "admin route must stay on Gateway/internal only"

grep -Fxq '  - http-route-public.yaml' "$pkg/kustomization.yaml" || fail "public route not rendered"

echo "FLEET_PUBLIC_ROUTE=PASS"
