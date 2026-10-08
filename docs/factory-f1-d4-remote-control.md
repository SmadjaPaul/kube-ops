# Factory F1 D4 — remote control contract

Status: `REMOTE_EXTERNAL=HUMAN_GATE`

This document is the bounded hand-off for the private path:

```text
OpenWebUI -> Authentik -> OpenClaw -> official Paperclip API/MCP -> Factory
```

It does not start a Paperclip run, create a task, add a comment, change an
approval, or mutate Kubernetes.

## What is prepared

OpenWebUI keeps its existing LiteLLM and `talos-personal` backends and now also
has the shared factory OpenClaw backend:

```text
http://openclaw.openclaw.svc.cluster.local:18789/v1
```

The gateway token is referenced from the existing Doppler key
`APP_MOLTBOT_GATEWAY_TOKEN` through ESO. No token value is present in Git or in
this report. The existing `open-webui` Cilium policy already allows the two
OpenClaw gateway ports.

Paperclip remains private: its HTTPRoute is attached only to
`Gateway/internal`. Do not add a public route to make this path work.

## Official Paperclip primitives

Do not build a local wrapper. The intended client is Paperclip's first-party
`@paperclipai/mcp-server`, configured through OpenClaw's supported
`mcp.servers` registry. It is a thin MCP projection over the Paperclip REST
API and must remain disabled until the credential and client gates below are
closed.

The bounded tool set is:

| Capability | Official primitive |
| --- | --- |
| identity / list work | `paperclipMe`, `paperclipInboxLite`, `paperclipListIssues` |
| task, status, blockers | `paperclipGetIssue`, `paperclipGetHeartbeatContext` |
| task discussion | `paperclipListComments`, `paperclipGetComment` |
| required approvals | `paperclipListIssueApprovals`, `paperclipListApprovals`, `paperclipGetApproval`, `paperclipGetApprovalIssues`, `paperclipListApprovalComments` |
| bounded writes | `paperclipCreateIssue`, `paperclipAddComment`, `paperclipRequestConfirmation` |

`paperclipUpdateIssue`, checkout/release, workspace controls, approval
decisions, document writes, `paperclipApiRequest`, secrets and agent wake/invoke
are not part of the remote-control surface. R0/R1 must be explicit in the
human request; R2 remains human-only.

The current first-party MCP tool list has no dedicated run-list/read tool.
Run observation therefore uses the official Paperclip CLI, not a homemade
adapter:

```bash
npx --yes paperclipai run list --company-id "$PAPERCLIP_COMPANY_ID" --limit 20 --json
npx --yes paperclipai run get <run-id> --json
npx --yes paperclipai run events <run-id> --limit 50 --json
npx --yes paperclipai run issues <run-id> --json
```

These commands are an operator-side read path only. Do not expose the CLI or
the broad `paperclipApiRequest` escape hatch to OpenClaw until a separately
reviewed, argument-bounded primitive exists.

## Evidence observed on 2026-10-08

Read-only in-cluster probe from the OpenWebUI pod to the shared OpenClaw
Service:

```text
GET /health    -> 200
GET /           -> 200
GET /v1/models -> 401 (bearer required; no credential was printed or used)
```

This proves service reachability and the expected authentication boundary. It
does not prove a Paperclip MCP connection, task mutation, agent execution,
checkout, branch, PR, CI, or user journey.

## HUMAN_GATE — exact user test

An external Paperclip client/credential is not present in this worktree or
runtime, so the remote-control result is intentionally `REMOTE_EXTERNAL=HUMAN_GATE`.
After a human has provisioned a scoped Paperclip board/agent credential outside
Git and made the official MCP server available to the OpenClaw image, run this
read-only test in `https://chat.smadja.dev`:

1. Sign in through Authentik.
2. Select the shared OpenClaw backend/model, not `talos-personal`.
3. Send exactly:

   > R0 read-only smoke. Using only the Paperclip official read tools, report the connected company, up to five current tasks, each task's status plus `blockedBy`/`blocks`, linked required approvals, and whether run history is available. Do not create, update, checkout, release, comment, approve, invoke, or start any Paperclip task or agent run. Do not use `paperclipApiRequest` and do not use Kubernetes.

4. Accept only a response that identifies the company and reports task state
   without any Paperclip run being created.

The later bounded-write test is separate and must be explicitly requested by a
human:

> R1 explicit action: create one unassigned Paperclip task in project `kube-ops` with title `F1 D4 remote-control smoke`, status `todo`, and no blockers. Return the issue identifier only. Do not checkout it, invoke an agent, add a comment, or start a run.

That write test is not executed by this change. No R2 action, approval decision,
merge, database patch, or Kubernetes durable write is authorized here.
