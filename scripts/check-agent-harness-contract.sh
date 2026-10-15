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

# Active AI clients must use logical gateway aliases, not direct providers.
consumer_files=(k8s/applications/ai/gpt-researcher/gpt-researcher-deployment.yaml)
physical_pattern='minimax/|anthropic/|azure/|openai/gpt-|@cf/qwen/|qwen3-embedding-0\\.6b'
if grep -Ein "$physical_pattern" "${consumer_files[@]}"; then
  echo "ERROR: active AI consumer exposes a physical model/provider ID" >&2
  exit 1
fi
echo "AI_CONSUMER_MODEL_ABSTRACTION=PASS"
echo "AGENT_TEST_RESULT_CONTRACT=PASS"
