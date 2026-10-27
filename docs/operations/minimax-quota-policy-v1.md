# MiniMax route policy v1

Status: **ready for GitOps promotion**.

This change removes the adaptive quota controller from the proposal. MiniMax
remains the provider-side authority for its subscription windows; Agentgateway
keeps routing, strict client authentication, telemetry, route/model isolation,
and only the burst protection that is separately approved. Mastra owns the
per-run budget, concurrency, timeout, bounded retry, and provider-availability
resume decisions.

## Static route isolation

The `factory-canary` Agentgateway identity allows only `factory/fast` and
`factory/code`. Both models use the MiniMax base URL, their respective MiniMax
model IDs, and the single existing `MINIMAX_API_KEY` environment reference.
There is no alternate provider or PAYG fallback configured for these routes.
The `factory/research` route is a separate identity and is outside this
candidate.

The binding is static evidence only. The credential value is intentionally not
read, so the Subscription Key class and billing boundary are **not proven**.
MiniMax's Subscription Key and standard API key are distinct credentials;
therefore route isolation alone cannot authorize removal of billing risk.

## Runtime boundary

The qualified `sk-cp` Subscription Key is now the credential behind the
existing `MINIMAX_API_KEY` reference. This change removes only the local
`5,000,000` tokens / rolling `24h` Agentgateway ceiling for `factory/fast` and
`factory/code`; MiniMax remains the quota authority for the 5-hour and weekly
windows. Mastra still owns per-run budgets, concurrency, timeouts and bounded
retries.

No Secret, database, provider quota, PLT-124 state or PLT-100 intake is
changed by this PR. The existing Agentgateway route budget is intentionally
removed only for the two qualified Factory routes; `factory/research` remains
outside this scope.

## Activation gates

Before promotion, the operator must retain the proof that the existing
`APP_MINIMAX_TOKEN_PLAN_API_KEY` is a MiniMax Subscription Key and that no
fallback provider or PAYG credential is reachable from `factory/fast` or
`factory/code`. The current ExternalSecret mapping remains:

```text
agentgateway/agentgateway-runtime:MINIMAX_API_KEY
  <- ClusterSecretStore/doppler-cluster
  <- Doppler cluster/prd:APP_MINIMAX_TOKEN_PLAN_API_KEY
```

Until those gates pass, no runtime budget change or Argo promotion is
authorized. MiniMax 5-hour and weekly windows remain provider-owned; they are
not reconstructed from Agentgateway counters or percentages.

## Validation and rollback

Use the repository's existing `just check` and affected-component checks. No
new adaptive controller or quota test harness is retained. The candidate is
reviewed as one atomic GitOps change. Rollback is a Git revert followed by the
normal Argo reconciliation; it does not modify credentials, provider state, or
database state.

This PR has no approval to resume PLT-124, activate PLT-100, dispatch a
Factory run, or start a build. After an explicit promotion GO, the next
Factory priority remains the single-concurrency Linear → Mastra → PR pilot.
