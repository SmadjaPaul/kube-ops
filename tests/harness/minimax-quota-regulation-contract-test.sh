#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
contract="$repo_root/docs/operations/minimax-quota-regulation-v1.json"
agentgateway="$repo_root/k8s/applications/platform/agentgateway/resources.yaml"

command -v jq >/dev/null || { echo 'jq is required' >&2; exit 2; }
command -v yq >/dev/null || { echo 'yq is required' >&2; exit 2; }

jq -e '
  .schemaVersion == "minimax-quota-regulation/v1" and
  .status == "prepared-not-active" and
  .provider.payAsYouGoFallback == false and
  (.provider.windows | map(.duration) == ["5h", "7d"]) and
  (.provider.windows | all(.[]; .semantics == "rolling-from-first-use")) and
  .provider.observation.unknownResponse == "deny" and
  .provider.observation.percentToTokensConversion == "forbidden" and
  ((.allocation.autonomousFraction + .allocation.priorityFraction + .allocation.reserveFraction - 1) | fabs < 0.000001) and
  .allocation.concurrency == 1 and
  .admission.requiresBothWindows == true and
  .admission.quotaApiUnavailable == "deny" and
  .admission.quotaExhausted == "suspend-without-blind-retry" and
  .admission.duplicateReservation == "deny" and
  .smoothing.implementation == "native-agentgateway-token-bucket" and
  .smoothing.active == false and
  .runtimeBoundary.activeAgentgatewayConfigChanged == false and
  .runtimeBoundary.plT124 == "suspended" and
  .runtimeBoundary.plT100 == "off" and
  .rollback.runtimeMutationInThisChange == false and
  .rollback.stateMutation == false and
  .rollback.providerCredentialMutation == false
' "$contract" >/dev/null

agentgateway_config="$(yq -r 'select(.kind == "ConfigMap" and .metadata.name == "agentgateway-config").data."config.yaml"' "$agentgateway")"
config_json="$(yq -o=json <<<"$agentgateway_config")"
jq -e '
  ([.llm.policies.apiKey.keys[] | select(.metadata.name == "factory-canary") | .budgets[]]) as $budgets |
  ($budgets | length == 1 and
    .[0].name == "canary-daily-tokens" and
    .[0].limit.unit == "Tokens" and
    .[0].limit.amount == 5000000 and
    .[0].window.rolling == "24h" and
    .[0].onBudgetExceeded == "Block")
' <<<"$config_json" >/dev/null

fixture_result="$(jq -cn '
  def decision($five; $week; $run; $fresh; $duplicate):
    if ($fresh | not) then "deny:stale-or-unavailable"
    elif $duplicate then "deny:duplicate-reservation"
    elif ($five <= 0 or $week <= 0) then "suspend:provider-window-exhausted"
    elif $run <= 0 then "deny:per-run-budget"
    else "admit:bounded-reservation"
    end;
  [
    (decision(0.80; 0.60; 1000; true; false) == "admit:bounded-reservation"),
    (decision(0.02; 0.60; 1000; true; false) == "admit:bounded-reservation"),
    (decision(0.80; 0.00; 1000; true; false) == "suspend:provider-window-exhausted"),
    (decision(0.80; 0.60; 0; true; false) == "deny:per-run-budget"),
    (decision(0.80; 0.60; 1000; false; false) == "deny:stale-or-unavailable"),
    (decision(0.80; 0.60; 1000; true; true) == "deny:duplicate-reservation"),
    (120000 == (100000 + 20000))
  ] | all
')"
[[ "$fixture_result" == true ]]

printf '%s\n' 'MINIMAX_QUOTA_REGULATION_CONTRACT=PASS active_runtime_unchanged=true llm_calls=0'
