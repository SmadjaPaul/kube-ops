#!/usr/bin/env bash
set -euo pipefail

# The versioned result contract belongs to the Factory/agent harness,
# independently of the retired Paperclip runtime.
contract='docs/contracts/agent-test-result-v1.schema.json'
example='docs/contracts/agent-test-result-v1.example.json'
[[ -f "$contract" && -f "$example" ]] || {
  echo "ERROR: missing versioned agent test result contract" >&2
  exit 1
}
node --test tests/harness/agent-test-result-contract.test.mjs

# PLT-312 (M5): doppler-safe (--only, closed project list), kubectl-ro identity, 24 h agent tokens.
bash tests/agent-guard/secret-output-guard-test.sh
# PLT-367 / F1: agent instructions never recommend the operator-identity access recipes; includes a negative case.
bash tests/agent-guard/agent-kube-access-doc-test.sh
# PLT-420: automatic renewal of the 24 h agent token (stubbed provisioning, lock, failure code).
bash tests/agent-guard/agent-operator-token-renew-test.sh

# PLT-210: bare `! cmd` assertions never trip `set -e`.
bash scripts/check-harness-negations.sh

# Active AI clients must use logical gateway aliases, not direct providers.
consumer_files=(k8s/applications/ai/gpt-researcher/gpt-researcher-deployment.yaml)
physical_pattern='minimax/|anthropic/|azure/|openai/gpt-|@cf/qwen/|qwen3-embedding-0\.6b'
if grep -Ein "$physical_pattern" "${consumer_files[@]}"; then
  echo "ERROR: active AI consumer exposes a physical model/provider ID" >&2
  exit 1
fi
echo "AI_CONSUMER_MODEL_ABSTRACTION=PASS"
echo "AGENT_TEST_RESULT_CONTRACT=PASS"
