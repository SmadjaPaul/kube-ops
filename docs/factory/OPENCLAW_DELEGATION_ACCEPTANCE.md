# OpenClaw native delegation — GitOps qualification contract

Status: `STATIC_PREPARED`. **A Git change is not proof of a live delegated run.**

## Scope / security boundary

This qualification uses **only** the existing isolated `openclaw-talos-test` cell.
It remains **suspended** in Git. Do not run a delegation test in the shared
`openclaw` ops instance: its service account can read Kubernetes diagnostics.
Do not borrow credentials, PVCs or workspaces from `openclaw-talos-personal`
or `openclaw-talos-ops`.

The test cell has `automountServiceAccountToken: false`, no projected K8s
token, no GitHub or Kubernetes egress in its Cilium policy, and only LiteLLM
credentials via ESO. The configured parent can only read its own test data and
use bounded native session tools. Its child additionally loses execution,
writes and recursive delegation. It uses `litellm/factory/fast` with maximum
two children, bounded runtimes and auto-archive.

This configuration provides **neither** a secure general-purpose code-execution
sandbox nor a coding-harness runtime. The child still shares the instance's
operating-system trust boundary. Do not classify it as multi-tenant isolation.

## T0 — Static preflight (safe and automatable)

```bash
node --test tests/harness/openclaw-delegation-contract.test.mjs
```

The GitHub Actions workflow `openclaw-delegation-contract.yaml` runs this
test when an OpenClaw cell, its model alias or the contract changes.

Read the pinned image tag in `openclaw-talos-test/instance.yaml`, then check
the matching upstream OpenClaw schema and operator version. Run the *installed*
OpenClaw configuration validation against the rendered runtime configuration,
not only the embedded JSON syntax. Do not execute `doctor --fix` against a
shared production PVC to perform this qualification.

Static acceptance is `STATIC_PASS` only if the test passes and the pinned
OpenClaw version accepts `agents.entries`, `agents.defaults.subagents`,
`tools.subagents.tools.deny`, and the session-tool allowlist. Otherwise:
`CONFIG_SCHEMA_BLOCKED`.

## T1 — Live native sub-agent smoke (separate authorized rollout)

A human/operator first reviews the GitOps change required to activate the
test cell, validates its runtime security boundary, and reconciles it through
Argo CD. Do not patch the live resource, uncomment a production permission, or
treat this runbook as permission to activate the suspended cell.

1. Confirm Ready state, actual configuration and available tools via the
   supported CLI (including `/tools` if offered). No `exec`, `process`,
   filesystem write, shell or Kubernetes API tool should be effective.
2. Invoke a real parent turn on `talos-test`: *Use `sessions_spawn` with
   `runtime: "subagent"`, isolated context, one simple read-only comparison
   task and a timeout. Return the child session ID and summarize its result.*
3. Capture the real spawn event, parent session key, distinct child session
   key, child model alias, LiteLLM request/usage and child completion/announce
   event. Use logs/traces with secret and prompt content redacted.
4. Check the parent receives the **child-produced** answer. A parent's textual
   assertion that it delegated is not sufficient.
5. Repeat with two independent children under the configured concurrency cap.
6. Verify that a third/nested child or a child command-execution attempt is
   refused by policy. Use a harmless request (e.g. read a non-existent file or
   ask whether `exec` is available); do not attempt privilege escalation.
7. Test a bounded child timeout/failure without restarting an active shared
   gateway. Restart/recovery remains `NOT_TESTED` until separately proven.

Observe parent/child correlation through the existing LiteLLM and OpenClaw
telemetry. An observed LiteLLM inference without a distinct child trace does
**not** prove that native delegation occurred.

## T2 — ACP coding harness (different qualification)

Only after inspecting upstream/pinned `@openclaw/acpx`, the actual gateway
plugin configuration, available harnesses and isolated workspace/identity,
run `sessions_spawn(runtime: "acp")` against an existing harmless test repo.
Do **not** execute ACP in the ops pod or give the coding harness a K8s token.
Use a separately authorized and isolated execution runtime. Do not install
packages interactively in the OpenClaw pod.

A successful ACP test needs its own child session, a changed test file,
locally executed test results and, only with scoped GitHub authorization, a
reviewable non-merged PR. A native T1 PASS does not imply ACP PASS.

## T3 — Open WebUI entry point (distinct evidence)

After direct Gateway success, log in through Authentik to Open WebUI and select
the appropriate backend. Send the same read-only delegation request, confirm
a real child event, and verify that the parent's answer reaches the user.

The OpenAI-compatible chat endpoint responding HTTP 200 or `/v1/models`
responding 200 is only transport evidence; do not claim E2E delegation.

## Evidence / report

Use `PASS`, `FAIL`, `BLOCKED`, or `NOT_TESTED` for:

```text
STATIC_CONFIG_JSON=
PINNED_RUNTIME_SCHEMA=
TEST_CELL_SUSPENDED_BY_DEFAULT=
TEST_CELL_NO_K8S_TOKEN=
TEST_CELL_NETWORK_BOUNDARY=
LIVE_TEST_CELL_READY=
PARENT_TOOL_AVAILABLE=
NATIVE_SESSIONS_SPAWN=
CHILD_DISTINCT_SESSION=
CHILD_LITELLM_INFERENCE=
CHILD_RESULT_RETURNED=
PARALLEL_CHILDREN=
CHILD_EXEC_DENIED=
CHILD_NESTED_SPAWN_DENIED=
CRASH_RESUME=
ACP_BACKEND_READY=
ACP_CODING_TASK=
OPENWEBUI_USER_E2E=
METRICS_CORRELATED=
```

Record commit SHA, PR, Argo desired/live revision, safe timestamps, session
IDs (where non-sensitive), model alias, durations and observed token/cost
metrics. Report any `HUMAN_GATE` explicitly. No secret values, prompts with
personal data or credentials in PR comments and logs.

### References

- https://docs.openclaw.ai/tools/subagents/tool-reference
- https://docs.openclaw.ai/tools/subagents/tool-policy
- https://docs.openclaw.ai/gateway/config-tools/sessions-and-subagents
- https://docs.openclaw.ai/tools/acp-agents
- https://docs.openclaw.ai/gateway/config-tools/tool-policy
