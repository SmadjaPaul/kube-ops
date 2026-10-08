#!/usr/bin/env bash
set -euo pipefail

company="k8s/applications/ai/paperclip/company"
roles=(
  engineering-manager
  researcher
  implementation-engineer
  reviewer
  qa-release-engineer
)

[[ -f "$company/CAPABILITIES.md" ]] || {
  echo "ERROR: missing Paperclip capability contract" >&2
  exit 1
}

for role in "${roles[@]}"; do
  file="$company/agents/$role/AGENTS.md"
  [[ -f "$file" ]] || {
    echo "ERROR: missing agent contract: $file" >&2
    exit 1
  }
  grep -q '## Capability contract' "$file" || {
    echo "ERROR: missing capability contract in $file" >&2
    exit 1
  }
  grep -q 'CAN_APPROVE_R2: \*\*NO\*\*' "$file" || {
    echo "ERROR: $role must declare CAN_APPROVE_R2=NO" >&2
    exit 1
  }
done

# Existing-company safe import rejects executionWorkspacePolicy inside the
# portability package. Preserve the isolation invariant in the explicit,
# reviewed post-import project update instead.
if grep -q 'executionWorkspacePolicy:' "$company/.paperclip.yaml"; then
  echo "ERROR: Paperclip safe-import package must not embed executionWorkspacePolicy" >&2
  exit 1
fi
grep -q -- '--execution-workspace-policy-json' "$company/README.md"
grep -q '"defaultMode":"isolated_workspace"' "$company/README.md"
grep -q '"type":"git_worktree"' "$company/README.md"

if grep -A2 'heartbeat:' "$company/.paperclip.yaml" | grep -q 'enabled: true'; then
  echo "ERROR: Paperclip V1 heartbeats must remain disabled until smoke qualification" >&2
  exit 1
fi

for model in default code research review; do
  grep -q "litellm/factory/$model" "$company/.paperclip.yaml" || {
    echo "ERROR: missing logical factory model contract: $model" >&2
    exit 1
  }
done

ruby "$company/desired-state/validate-desired-state.rb"

# Consumer configs must use logical model contracts. Physical provider mappings
# belong in LiteLLM, not in Paperclip/OpenClaw/OpenWebUI/GPT Researcher.
consumer_files=(
  k8s/applications/ai/openclaw/configmap.yaml
  k8s/applications/ai/paperclip/runtime-config.yaml
  k8s/applications/ai/gpt-researcher/gpt-researcher-deployment.yaml
  k8s/applications/ai/openwebui/webui-statefulset.yaml
)

physical_pattern='minimax/|anthropic/|azure/|openai/gpt-|@cf/qwen/|qwen3-embedding-0\.6b'
if grep -Ein "$physical_pattern" "${consumer_files[@]}"; then
  echo "ERROR: active AI consumer exposes a physical model/provider ID" >&2
  exit 1
fi

echo "PAPERCLIP_ROLE_CAPABILITIES=PASS"
echo "PAPERCLIP_WORKSPACE_ISOLATION=PASS"
echo "AI_CONSUMER_MODEL_ABSTRACTION=PASS"
