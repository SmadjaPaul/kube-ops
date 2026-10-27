# MiniMax quota regulation v1

Status: **prepared, not active**.

This document records the smallest safe contract for using the included
MiniMax capacity. It deliberately does not change the active Agentgateway
budget, read a Secret value, start an LLM run, enable PLT-100, or resume
PLT-124. The machine-readable contract is
[`minimax-quota-regulation-v1.json`](./minimax-quota-regulation-v1.json).

## Finding

The current GitOps configuration gives the `factory-canary` key one
Agentgateway budget of 5,000,000 tokens over `rolling: 24h`. The observed
runtime overage is `used=5,036,071`, followed by fail-closed 429 responses.
That limit is not a representation of the MiniMax subscription contract:
MiniMax describes independent 5-hour and 7-day windows, both starting with
the first use of the window. Agentgateway per-key budgets use fixed windows
aligned to the Unix epoch, so changing `24h` to `5h` would still be the wrong
clock and would omit the weekly constraint.

The current Agentgateway process is the standalone v1.6.0 deployment with a
durable SQLite database. This is why the current counter survives restart,
but it does not make the provider window semantics equivalent.

Agentgateway records `gen_ai.usage.input_tokens` and
`gen_ai.usage.output_tokens` in the request logs. `cache_read.input_tokens`
must not be added to `input_tokens`: Agentgateway documents that the input
series already includes cached tokens. The actual provider charging contract
still comes from the MiniMax response and must be measured with a controlled,
authenticated observation before any numeric translation is attempted.

## Policy

The future admission decision has exactly one provider observation and one
reservation owner. It requires a fresh, read-only response for both provider
windows and a per-run estimate. It allocates the measured remaining capacity
as follows:

| class | share | rule |
| --- | ---: | --- |
| autonomous | 70% | normal Factory work |
| priority/manual | 20% | explicitly prioritised work |
| emergency reserve | 10% | kept unavailable to ordinary dispatch |

These are fractions of the provider-reported remaining capacity, not token
counts. A percentage is never multiplied by an inferred or hard-coded token
limit. Capacity is not consumed just to fill a window.

The native Agentgateway token bucket is the smoothing layer, with a small
interval, while the provider observation is the hard admission prerequisite.
Those controls have different invariants: the provider observation protects
the two subscription windows; the token bucket limits bursts. There is no
second custom scheduler and no pay-as-you-go fallback. A quota API error,
stale observation, exhausted window, duplicate reservation, or provider
budget 429 suspends admission without blind retries.

## What remains unqualified

The endpoint is reachable without credentials but returns an authentication
failure. The repository intentionally does not print or inspect the
`APP_MINIMAX_TOKEN_PLAN_API_KEY` value. An authenticated response sample is
therefore still required to bind the adapter to the provider's exact JSON
fields and reset timestamps. Until that sample exists, no active 5-hour,
weekly, or dynamic smoothing limit is safe to merge.

Agentgateway's current pod does not expose its Prometheus admin endpoint in
the declared container ports, and the current Factory dashboards explicitly
do not claim token/cost-per-run series. The existing OTLP/log evidence is
useful for reconciliation but is not a provider-quota counter.

## Test contract

The companion contract test exercises the decision boundary without an LLM
call: non-expired and expired observations, low or exhausted windows,
insufficient per-run budget, high cache-read reporting, quota API errors,
restart/reconciliation, duplicate reservations, fail-closed suspension, and
safe reallocation. It also asserts that this change leaves the active
Agentgateway 24-hour guard untouched.

## Activation and rollback

Activation requires a separate operator decision after an authenticated quota
sample, exact field mapping, isolated native Agentgateway validation, and a
review of the resulting cost. This prepared change has no runtime mutation.
Rollback is a Git revert followed by the normal Argo reconciliation; no
provider credential, Kubernetes Secret, state, or database is modified.
