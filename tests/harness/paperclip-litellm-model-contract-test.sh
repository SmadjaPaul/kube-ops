#!/usr/bin/env bash
set -euo pipefail

# Keep the deployed LiteLLM model list and the OpenCode consumer projection in
# sync without deploying another model-catalog controller.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
runtime="$root/k8s/applications/ai/paperclip/runtime-config.yaml"
external_secret="$root/k8s/applications/ai/paperclip/externalsecret.yaml"
litellm_config="$root/k8s/applications/ai/litellm/proxy_server_config.yaml"
litellm_service="$root/k8s/applications/ai/litellm/svc.yaml"

for binary in yq jq; do
  command -v "$binary" >/dev/null || { echo "missing $binary" >&2; exit 1; }
done

opencode_json="$(yq -r '.data.OPENCODE_CONFIG_CONTENT' "$runtime")"
jq -e '.enabled_providers | index("litellm") != null' <<<"$opencode_json" >/dev/null
jq -e '
  (.provider.litellm.models | type == "object") and
  (.provider.litellm.models | length > 0) and
  .provider.litellm.options.apiKey == "{env:LITELLM_API_KEY}" and
  (.model | startswith("litellm/")) and
  (.small_model | startswith("litellm/"))
' <<<"$opencode_json" >/dev/null

service_host="$(yq -r '.metadata.name + "." + .metadata.namespace + ".svc.cluster.local"' "$litellm_service")"
service_port="$(yq -r '.spec.ports[0].port' "$litellm_service")"
expected_base="http://${service_host}:${service_port}/v1"
actual_base="$(jq -r '.provider.litellm.options.baseURL' <<<"$opencode_json")"
if [[ "$actual_base" != "$expected_base" ]]; then
  echo "OpenCode LiteLLM URL does not match the in-cluster Service" >&2
  exit 1
fi

mapfile -t exposed_models < <(jq -r '.provider.litellm.models | keys[]' <<<"$opencode_json")
available_models="$(yq -r '.model_list[].model_name' "$litellm_config")"
for alias in "${exposed_models[@]}"; do
  if ! grep -Fxq -- "$alias" <<<"$available_models"; then
    echo "OpenCode model is absent from LiteLLM: $alias" >&2
    exit 1
  fi
done
for selection in model small_model; do
  selected="$(jq -r --arg key "$selection" '.[$key]' <<<"$opencode_json")"
  alias="${selected#litellm/}"
  if ! printf '%s\n' "${exposed_models[@]}" | grep -Fxq -- "$alias"; then
    echo "OpenCode $selection is not in the advertised registry: $alias" >&2
    exit 1
  fi
done

# Never read a secret value. Assert only that ESO projects an appropriate key.
yq -e '
  .spec.data[]
  | select(.secretKey == "LITELLM_API_KEY" and .remoteRef.key == "APP_PAPERCLIP_LITELLM_API_KEY")
' "$external_secret" >/dev/null

echo "PAPERCLIP_LITELLM_MODEL_CONTRACT=PASS"
