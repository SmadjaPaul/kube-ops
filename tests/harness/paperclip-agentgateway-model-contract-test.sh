#!/usr/bin/env bash
set -euo pipefail

# Verify the live desired-state consumer/gateway contract before runtime.
# This does not claim Agentgateway replicas or the provider are ready.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
runtime="$root/k8s/applications/ai/paperclip/runtime-config.yaml"
external_secret="$root/k8s/applications/ai/paperclip/externalsecret.yaml"
gateway="$root/k8s/applications/platform/agentgateway/resources.yaml"

for binary in yq jq; do
  command -v "$binary" >/dev/null || { echo "missing $binary" >&2; exit 1; }
done

opencode_json="$(yq -r '.data.OPENCODE_CONFIG_CONTENT' "$runtime")"
jq -e '
  (.enabled_providers == ["agentgateway"]) and
  (.provider.agentgateway.models | type == "object" and length > 0) and
  .provider.agentgateway.options.apiKey == "{env:AGENTGATEWAY_API_KEY}" and
  (.model | startswith("agentgateway/")) and
  (.small_model | startswith("agentgateway/"))
' <<<"$opencode_json" >/dev/null

service_host="$(yq -r 'select(.kind == "Service" and .metadata.name == "agentgateway") | .metadata.name + "." + .metadata.namespace + ".svc.cluster.local"' "$gateway")"
service_port="$(yq -r 'select(.kind == "Service" and .metadata.name == "agentgateway") | .spec.ports[0].port' "$gateway")"
expected_base="http://${service_host}:${service_port}/v1"
actual_base="$(jq -r '.provider.agentgateway.options.baseURL' <<<"$opencode_json")"
[[ "$actual_base" == "$expected_base" ]] || {
  echo "Paperclip OpenCode Agentgateway endpoint differs from Service" >&2
  exit 1
}

gateway_yaml="$(yq -r 'select(.kind == "ConfigMap" and .metadata.name == "agentgateway-config") | .data."config.yaml"' "$gateway")"
available_models="$(yq -r '.llm.models[].name' <<<"$gateway_yaml")"
allowed_models="$(yq -r '.llm.policies.apiKey.keys[0].allowedModels[]' <<<"$gateway_yaml")"
mapfile -t exposed_models < <(jq -r '.provider.agentgateway.models | keys[]' <<<"$opencode_json")
for alias in "${exposed_models[@]}"; do
  grep -Fxq -- "$alias" <<<"$available_models" || {
    echo "Paperclip alias absent from Agentgateway: $alias" >&2
    exit 1
  }
  grep -Fxq -- "$alias" <<<"$allowed_models" || {
    echo "Paperclip alias denied by Agentgateway canary key: $alias" >&2
    exit 1
  }
done
for selection in model small_model; do
  chosen="$(jq -r --arg key "$selection" '.[$key]' <<<"$opencode_json")"
  alias="${chosen#agentgateway/}"
  printf '%s\n' "${exposed_models[@]}" | grep -Fxq -- "$alias" || {
    echo "Paperclip $selection alias absent from advertised models: $alias" >&2
    exit 1
  }
done

yq -e '
  .spec.data[]
  | select(.secretKey == "AGENTGATEWAY_API_KEY" and .remoteRef.key == "APP_AGENTGATEWAY_CLIENT_KEY")
' "$external_secret" >/dev/null

echo "PAPERCLIP_AGENTGATEWAY_MODEL_CONTRACT=PASS"
