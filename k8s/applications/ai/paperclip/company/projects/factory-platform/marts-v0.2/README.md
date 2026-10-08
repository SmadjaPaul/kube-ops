# Factory Platform delivery mart v0.2

This directory is a Git-only dbt specification for delivery economics and
engineering throughput. It deliberately has no runtime, Kubernetes, secret, or
warehouse connection assumptions.

## Contract and grain

`mart_delivery_task` has exactly one row per logical `task_id`, from the first
delivery intent to runtime acceptance (or the last known non-accepted state).
The source contract is a typed append-only relation named by the
`factory_delivery_events_relation` dbt var; the default placeholder is
`factory_delivery_events`.

Required event columns:

| Column | Meaning |
| --- | --- |
| `task_id` | Stable logical task key; never reuse it for a retry. |
| `intent_id` | Delivery intent key; nullable only for legacy backfill. |
| `event_name` | One of the event names below. Unknown names are retained but do not contribute to measures. |
| `event_ts` | Event time in UTC. |
| `attempt_number` | 1-based delivery attempt; nullable for non-attempt events. |

Optional typed attributes are aggregated by the fact model:
`project_id`, `repository_id`, `pr_id`, `task_type`, `priority`,
`environment`, `agent_id`, `model_name`, `provider`, `accepted`,
`human_oversight_minutes`, `cost_usd`, `review_rounds`, `ci_retry_count`,
`input_tokens`, `output_tokens`, `tool_calls`, `pr_additions`,
`pr_deletions`, `pr_files_changed`, `task_complexity_score`,
`context_quality_score`, `classification_confidence`, `innovation_eligible`,
and `innovation_task`.
Token, tool-call, cost, oversight, and CI-retry values are additive event
amounts; PR size and review rounds are latest/snapshot attributes and are not
summed.

Recognised event names are `intent_created`, `task_started`, `pr_opened`,
`review_requested`, `review_response`, `ci_run`, `deployment`,
`change_failure`, `rework`, `acceptance`, and `oversight_session`.
`acceptance` is the runtime acceptance boundary. A task remains in the mart
when acceptance is missing or late.

The stable row key is `task_id`; `intent_id` is a business dimension, not the
primary key. The fact keeps `source_last_event_at` and a deterministic
source watermark so late-arriving event policy is visible.

## Measures and definitions

The row-grain mart exposes these measures/flags:

| Measure | Definition |
| --- | --- |
| `accepted_task_flag` | 1 when an acceptance event exists with a valid timestamp. |
| `accepted_task_throughput` | Aggregate `sum(accepted_task_flag)`; one accepted task counts once. |
| `end_to_end_cycle_time_seconds` | Acceptance minus intent, only when both are present and ordered. |
| `first_pass_success_flag` | Accepted on attempt 1 with no rework and no change failure. |
| `human_oversight_minutes_per_success` | Total oversight minutes for an accepted task; null for non-accepted tasks. Aggregate as sum / accepted tasks. |
| `cost_per_accepted_task` | Attributed task cost for an accepted task; null otherwise. Aggregate as cost / accepted tasks. |
| `change_fail_rate` | Aggregate failed changes / deployed changes. Row fields expose numerator and denominator. |
| `deployment_rework_rate` | Aggregate rework deployments / deployed changes (deployment count). Row fields expose numerator and denominator. |
| `review_turnaround_minutes` | First review response minus review request, when ordered. |
| `innovation_ratio` | Aggregate innovation tasks / eligible accepted tasks. Classification is supplied upstream; no keyword inference is done here. |

`mart_delivery_task_metrics` computes p50/p90 cycle time, p50/p90 review
turnaround, and the rates above. Percentiles use `percentile_cont` over valid,
non-negative durations. Metrics are cohortable by the mart dimensions without
rebuilding event history.

## Dimensions and diagnostics

Dimensions are intentionally narrow: task/intent/project/repository/PR,
task type, priority, environment, agent, provider/model, and UTC intent and
acceptance dates. Numeric diagnostics are retained to explain movement in the
headline metrics:

- PR additions, deletions, files changed;
- review rounds and review turnaround;
- CI retries and CI run count;
- model/provider, input/output tokens, and tool calls;
- task complexity score/band and context quality score/band;
- deployment count, rework deployment count, and change-failure count;
- acceptance attempt and classification confidence.

No new normalization layer is introduced: event roll-up is the only fact
transformation and the mart is a thin, named metric contract.

## Null, late, and invalid data policy

- Missing acceptance is a valid in-flight/non-accepted task, not a zero.
- Missing intent or acceptance makes cycle time null; it is never coerced to 0.
- Negative or impossible intervals are null and flagged by the invariant test.
- Missing denominators yield null rates, never division by zero.
- Late events are included when their `event_ts` is newer than the current
  source watermark. Consumers should use `source_last_event_at` for incremental
  reprocessing; a recommended seven-day lookback absorbs ordinary lateness.
- Duplicate delivery of the same event must be removed upstream using an
  immutable event id if available. This v0.2 contract does not invent one.
- Unknown event names remain observable through the source but contribute no
  measure; a source-quality monitor should count them.
- Costs and token counts are nullable when attribution is unavailable; null is
  distinct from zero.

## Validation

Static validation can run without a cluster or live application. The dbt
models compile against a configured warehouse relation only when materialized;
`tests/sql/assert_inline_fixture_metrics.sql` is relation-free and exercises
the key formulas with inline events. `tests/assert_mart_delivery_task_invariants.sql`
is the dbt data-test contract for the materialized mart.

Expected checks for an implementation environment are:

```text
dbt parse --project-dir marts-v0.2
dbt compile --project-dir marts-v0.2 --select mart_delivery_task+
dbt test --project-dir marts-v0.2 --select mart_delivery_task+
```

The last two commands require a dbt adapter only at execution time; no
runtime evidence is part of this specification.
