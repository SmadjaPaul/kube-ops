#!/usr/bin/env bash
# PLT-317 — only Fleet agent endpoints reach Gateway/external.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
pkg="$root/k8s/optional/fleet"
public="$pkg/http-route-public.yaml"
fail() { echo "FLEET_PUBLIC_ROUTE=FAIL $*" >&2; exit 1; }

allowed='
PathPrefix /api/osquery/
PathPrefix /api/v1/osquery/
PathPrefix /api/fleet/orbit/
Exact /api/fleet/device/ping
PathPrefix /api/v1/fleet/device/
PathPrefix /api/latest/fleet/device/
PathPrefix /device/
PathPrefix /assets/
Exact /mdm/apple/scep
Exact /mdm/apple/mdm
'
actual="$(sed -nE 's/^[[:space:]]*- path: \{type: ([A-Za-z]+), value: ([^}]+)\}.*/\1 \2/p' "$public" | sort)"
expected="$(printf '%s' "$allowed" | sed '/^$/d' | sort)"
[ "$actual" = "$expected" ] || fail "public paths differ from the agent allowlist"

# Every rule must carry explicit matches (a rule without matches is a catch-all).
rules="$(grep -c '^[[:space:]]*- matches:' "$public")"
[ "$(grep -c '^[[:space:]]*- backendRefs:\|^[[:space:]]*backendRefs:' "$public")" = "$rules" ] || fail "rule without matches"
grep -Eq '^[[:space:]]*- name: external$' "$public" || fail "public route must attach to Gateway/external"
if grep -Eq '^[[:space:]]*- name: internal$' "$public"; then fail "public route must not attach to Gateway/internal"; fi

# The admin route stays LAN-only.
if grep -Eq '^[[:space:]]*- name: external$' "$pkg/http-route.yaml"; then
  fail "admin route attached to Gateway/external"
fi
grep -Fxq '  - http-route-public.yaml' "$pkg/kustomization.yaml" || fail "public route not rendered"

echo "FLEET_PUBLIC_ROUTE=PASS"
