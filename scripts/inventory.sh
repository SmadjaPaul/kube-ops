#!/usr/bin/env bash
set -euo pipefail
command -v jq >/dev/null || { echo "ERROR: jq required" >&2; exit 2; }

extract_paths() {
  local file=$1
  awk '/^[[:space:]]*- path: / {print $3}' "$file"
}

app_roots="$(extract_paths k8s/bootstrap/argocd-root/applications-applicationset.yaml | jq -Rsc 'split("\n")[:-1]')"
infra_roots="$(extract_paths k8s/bootstrap/argocd-root/infrastructure-applicationset.yaml | jq -Rsc 'split("\n")[:-1]')"
routes="$(grep -RhoE '[a-z0-9][a-z0-9.-]*\.smadja\.dev' k8s/applications k8s/infrastructure 2>/dev/null | sort -u | jq -Rsc 'split("\n")[:-1]')"

jq -n --argjson applications "$app_roots" --argjson infrastructure "$infra_roots" --argjson hostnames "$routes"   '{applicationRoots:$applications,infrastructureRoots:$infrastructure,declaredHostnames:$hostnames}'
