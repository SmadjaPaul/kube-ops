# Personal agent experience & authority contract — PLT-157/159/160/161

This is the **per-user product behavior**, not merely infrastructure.

## Experience

A family member signs into their own Hermes Webapp, retains conversations and
memory across restarts, and chooses which tools to connect. The same agent can
reason, use approved skills, run permitted routines, and delegate engineering to
the separate Mastra Factory. No custom image is built for each member.

### Tasks to qualify (two consenting users, synthetic data first)

| Intent | Tools and owner | Approval boundary |
|---|---|---|
| Ask/search Gmail & Drive | Individual Google OAuth per tenant; least scopes | No token reuse between users |
| Draft/send an email | Same personal Google connection | Display draft + recipient, explicit send approval |
| Plan exercise and recovery | Per-user SparkyFitness read-only MCP | No medical raw logs to external LLM without consent |
| Plan 7-day meals, 2 batch-cooking sessions, groceries | Existing Mealie + portions; family sharing separately authorized | No recipe/menu writes without confirmation |
| Find a calendar slot | RustiCal/Google Calendar personal access | Propose first, confirm event mutation |
| Build an application | Single scoped Factory handoff API (not GitHub/K8s credentials) | User approves ticket; Factory approves engineering and deploy |
| Notifications/cron | Hermes native scheduler and Matrix personalized DMs | User opt-in, bounded cadence and budget |

## Tenant security (code + tests, not prompts alone)

- Tenant identifier is an opaque ID. Authentik must enforce a **one-to-one
  user subject ↔ allowed OIDC application/agent**; the webapp/dashboard identity
  is an administrator **of that one instance**.
- A tenant must not see or mutate a sibling's OIDC, workspace, sessions, skills,
  tools, Google tokens, MCP tokens, resource URLs or events.
- Factory handoff must accept authenticated requesting tenant/user metadata,
  allow only submit/status/read/cancel of OWN work, and forbid arbitrary tools,
  secrets, github tokens and repository mutation from the tenant.
- Log sensitive operations with minimal metadata. No email bodies, medical
  records, calendar descriptions, access tokens or unredacted model prompts.
- The initial chart disables terminal/code/browser tools pending external
  sandbox isolation. Later sandbox enablement must not add K8s API or mounted
  host/Factory credentials; use explicit egress and approval gates.
- An LLM gateway's model access **does not** grant authority to tools.
  Provider retention/processing and tenant budgets must be verified before
  personal Gmail or wellness data enters prompts.

## E2E acceptance

1. Two users sign in from GrapheneOS/Android and iPhone browser separately.
2. Direct URL guess, forged redirect and cross-tenant WebSocket/API access are
   denied; users cannot switch another person's profile.
3. A sends a draft Gmail request; no mail is sent until approval.
4. B asks to read A's data, and is refused by tools and credentials.
5. A receives a synthetic progressive 4-week workout + week menu + shopping
   list + calendar proposal, with zero writes.
6. B asks for an app; only an approved scoped Factory request is accepted.
7. Both agents preserve their own state across pod recycle and restore.
8. A third user can be admitted via the **single onboarding workflow** without
   touching Helm template, building an image, or editing per-user YAML.
9. Measure CPU/RAM/storage at 2 and 5 agents. Simulate 20–30 users; state
   supported concurrency honestly before adding permanent instances.

No user-facing capabilities are claimed live until the corresponding runtime
test is PASS.
