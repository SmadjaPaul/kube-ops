# Factory Stream D — test-run quality marts v0.1

Stream D owns the quality-specific canonical test-run projection and KPI marts.
It is deliberately separate from C's generic telemetry envelope and delivery
marts.  The adapter boundary accepts local runner, GitHub Actions, and
Elementary result shapes, but emits one canonical `factory.test_run.completed`
event before facts or marts are built.

## Contract

Every canonical event carries tenant/source, schema id and version,
idempotency, provenance, and the correlation chain:

`task_id`, `run_id`, `attempt`, `repository`, `sha`, `pr`, `work_item_id`,
`agent_run_id`.

Missing optional source identifiers are explicit `UNKNOWN`; missing test
classification is explicit `UNCLASSIFIED`.  They remain visible in the fact
and are excluded from KPI denominators unless the metric says otherwise.

The harness is stdlib-only and models the intended boundary:

`source adapter -> canonical event -> fct_test_runs -> mart_test_run_quality`

The SQL files are intentionally generic PostgreSQL/dbt-compatible contracts.
They do not recreate or copy C's Elementary models; Elementary is only an
input adapter here.

## KPI semantics

- `run_success_rate`: successful classified runs / classified runs.
- `test_pass_rate`: passed tests / classified tests.
- `coverage_rate`: runs with a known repository and SHA / all runs.
- `unknown_or_unclassified_run_count`: retained quality signal, not silently
  dropped from the population.

Each ratio is `NULL` when its denominator is zero.  No KPI treats UNKNOWN or
UNCLASSIFIED as a failure or as a passing observation.

## Evidence

The fixtures and focused tests are STATIC evidence.  dbt execution requires
the canonical application's `factory_platform` profile and a database; this
checkout does not provide either.
