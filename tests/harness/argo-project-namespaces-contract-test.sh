#!/usr/bin/env bash
# Contrat de scripts/check-argo-project-namespaces.sh : le controle laisse passer un depot coherent et
# bloque un namespace absent des destinations de l'AppProject (cas infra-previews, arc-runners-kube-ops).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check="$repo_root/scripts/check-argo-project-namespaces.sh"
fixtures="$repo_root/tests/harness/fixtures/argo-project-namespaces"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

run() { # <fixture> -> sortie dans $tmp/out, code retourne
  rm -rf "$tmp/work" && mkdir -p "$tmp/work" && cp -R "$fixtures/$1/k8s" "$tmp/work/k8s"
  bash "$check" "$tmp/work" >"$tmp/out" 2>&1
}

# 1. coherent : jokers (dns-*, ''), Namespace cree, Application imbriquee dans son projet
run ok || { cat "$tmp/out" >&2; fail "fixture ok must pass"; }

# 2. namespace rendu (ConfigMap infra-previews) absent des destinations d'infrastructure
if run missing-namespace; then fail "missing namespace must be rejected"; fi
grep -q 'namespace "infra-previews" is not a destination of AppProject "infrastructure"' "$tmp/out" \
  || { cat "$tmp/out" >&2; fail "missing namespace not reported"; }

# 3. Application imbriquee (projet applications) vers arc-runners-kube-ops, present seulement dans infrastructure :
#    exactement l'oubli corrige par #1664, #1656 puis #1679
if run nested-outside-project; then fail "nested Application outside its project must be rejected"; fi
grep -q 'namespace "arc-runners-kube-ops" is not a destination of AppProject "applications"' "$tmp/out" \
  || { cat "$tmp/out" >&2; fail "nested Application namespace not reported"; }
grep -q 'runner-application.yaml' "$tmp/out" || fail "offending file not named"

echo "OK: argo project namespace contract"
