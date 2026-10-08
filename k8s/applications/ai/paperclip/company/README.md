# Smadja Software Factory company package

Git-native Paperclip company definition for the homelab software factory.

Reference patterns deliberately combined here:

- Paperclip `Superpowers Dev Shop`: small role graph and disciplined plan/build/review/release loop.
- Paperclip `GStack`: QA/release emphasis.
- `Teck-Lab/Teck.Agents`: blocker DAGs, isolated worktrees and parallel-safe leaf execution.
- Compound Engineering: Plan -> Work -> Review -> Compound discipline.
- Harness / Loop Engineering: measured inner, outer and meta loops that turn recurring evidence into durable improvements.

## Import

After Paperclip is healthy and the instance has been claimed by the human admin,
import this folder with Paperclip's supported Company import flow. Keep this
directory as the canonical portable definition; runtime Paperclip state is not
the source of truth for the Company package.

The canonical issue inventory is separate:
`projects/kube-ops/backlog-seed.yaml`. It is reconciled through the repository
adapter in `scripts/paperclip/import-backlog-seed.mjs`; Paperclip's Company
import does not natively import that backlog format.

The Company now contains two collaborating units:

- **Engineering** — delivery of product and infrastructure changes.
- **Data Platform & Factory Engineering** — owns `factory-platform`, Factory Intelligence,
  and evidence-driven improvement of the factory harness.

Reviewer and QA & Release remain shared independent gates across both units.

The V1 intentionally has no scheduled heartbeats. Work is started explicitly
while execution and approval boundaries are being qualified.

## Company desired state

`desired-state/company.yaml` is the versioned governance contract for the
organization, mandatory roles, capability registry, decision rights, routing,
policies and accepted architecture decisions. It is reference-only: it does
not provision agents, start work or mutate Paperclip runtime state.

The manifest makes `DEFAULT_HEARTBEAT=OFF` explicit and requires a capability
lookup before every addition. Capability decisions are classified as `REUSE`,
`EXTEND`, `COMPOSE`, `ADAPTER`, `NEW_COMPONENT`, `NEW_SERVICE` or
`BU_CANDIDATE`; structural changes also require an accepted ADR. Validate it
with:

```bash
ruby k8s/applications/ai/paperclip/company/desired-state/validate-desired-state.rb
```

The architecture and rollback boundary is documented in
`desired-state/ARCHITECTURE-ROLLBACK.md`. The existing `.paperclip.yaml`
remains the safe-import package and is intentionally not expanded by this
governance model.

## V1 boundaries

- No self-merge. R1 can be merged only after independent review, QA and required CI gates.
- No direct Kubernetes mutation as the normal delivery path.
- The first DOC smoke may use `opencode_local` to prove orchestration without simultaneously changing execution infrastructure.
- `opencode_local` is bootstrap-only for the production factory security model.
- The target execution boundary is Paperclip's first-party Kubernetes sandbox provider, qualified first with one disposable agent before role-by-role migration.
- The production Paperclip Kustomization does not currently activate the sandbox candidate.
- No generic auth fork is introduced merely to make the factory work.
- Model access routes through the existing in-cluster LiteLLM capability aliases.


## Factory Platform bootstrap

The existing Paperclip Company is the target. Do not replace it.

Paperclip safe import deliberately rejects project `executionWorkspacePolicy`. The portable package therefore carries repository workspaces but no runtime execution policy. Apply the reviewed isolated-worktree policy explicitly after the safe import succeeds.

Use the supported safe import with `collision=skip` so only the three new Factory
Platform agents and the `factory-platform` project are created. Existing
`kube-ops`, `homelab-infra`, agents and other runtime objects must remain untouched.

Preview first:

```bash
npx --yes paperclipai company import \
  k8s/applications/ai/paperclip/company \
  --api-base https://paperclip.smadja.dev \
  --target existing \
  --company-id "$PAPERCLIP_COMPANY_ID" \
  --include agents,projects \
  --agents factory-platform-lead,data-platform-engineer,harness-engineer \
  --collision skip \
  --dry-run \
  --json
```

The preview gate is:

- create: Factory Platform Lead;
- create: Data Platform Engineer;
- create: Harness Engineer;
- create: factory-platform project;
- skip: existing Company objects;
- delete/replace: zero.

Only after that bounded preview passes:

```bash
npx --yes paperclipai company import \
  k8s/applications/ai/paperclip/company \
  --api-base https://paperclip.smadja.dev \
  --target existing \
  --company-id "$PAPERCLIP_COMPANY_ID" \
  --include agents,projects \
  --agents factory-platform-lead,data-platform-engineer,harness-engineer \
  --collision skip \
  --yes \
  --json
```

The strategic purpose is a native Paperclip Goal, not Company-import state:

```bash
GOAL_ID="$(
  npx --yes paperclipai goal create \
    --api-base https://paperclip.smadja.dev \
    --company-id "$PAPERCLIP_COMPANY_ID" \
    --title "Build a self-improving software factory and validate the Data Platform" \
    --description "Use Factory Intelligence to measurably improve autonomy, automation, quality, cost and lead time while evolving factory-platform as the first commercial vertical of the Smadja Data Platform." \
    --level team \
    --json |
  jq -r '.id'
)"

test -n "$GOAL_ID" && test "$GOAL_ID" != "null"

npx --yes paperclipai project update factory-platform \
  --api-base https://paperclip.smadja.dev \
  --company-id "$PAPERCLIP_COMPANY_ID" \
  --goal-ids "$GOAL_ID" \
  --execution-workspace-policy-json '{"enabled":true,"defaultMode":"isolated_workspace","allowIssueOverride":false,"workspaceStrategy":{"type":"git_worktree","baseRef":"main"}}' \
  --json
```

This post-import policy update is intentionally separate from Company portability. Existing `kube-ops` and `homelab-infra` projects are skipped and keep their current runtime policies unchanged.

Do not enable scheduled heartbeats as part of this bootstrap. First close the
Factory Platform V0 observability/backup gates, then start bounded explicit work
so the first Paperclip-native telemetry becomes useful V0.2 evidence.
