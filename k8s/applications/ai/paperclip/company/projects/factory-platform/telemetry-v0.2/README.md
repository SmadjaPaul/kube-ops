# Factory Platform telemetry contract v0.2

This directory is the Git-only contract for the Factory Intelligence event stream. It is
not a collector, database migration, Kubernetes manifest, or runtime integration. The
canonical event schema is [schema/event-envelope.schema.json](schema/event-envelope.schema.json).

## Contract shape

Every event is a self-contained envelope with these stable concerns:

| Field | Contract |
| --- | --- |
| `contract`, `spec_version` | `factory.telemetry`, exactly `0.2` |
| `event_id` | UUID for this emitted envelope; never reused |
| `event_type` | Versioned `noun.action` name; the schema couples it to `data` |
| `tenant_id`, `entity` | Tenant boundary and the primary entity identity |
| `dedupe` | Deterministic key, strategy, and scope for at-least-once ingestion |
| `occurred_at` | When the source says the event happened |
| `observed_at` | When the collector observed or emitted it |
| `producer` | Collector/component name, version, and environment |
| `provenance` | Source system, source kind, source identifiers, and optional trace/revision |
| `raw` | Content-addressed reference to the captured source representation |
| `data` | Small canonical event payload; source-only fields go in `attributes` |
| `extensions` | Namespaced additions that consumers must ignore unless understood |

The envelope deliberately carries identity and lineage once. It does not copy full source
objects into multiple normalized tables. Consumers can build projections from `data`, while
the original capture remains recoverable through `raw.storage_ref` and verifiable with
`raw.content_sha256`.

## Event vocabulary

The v0.2 schema covers:

`task.created`, `task.completed`, `agent_run.started`, `agent_run.completed`,
`model.invoked`, `tool_call.completed`, `subagent_call.completed`,
`human_intervention.requested`, `human_intervention.resolved`, `pr.opened`,
`review.submitted`, `ci.completed`, `merge.completed`, `argo_sync.completed`,
`runtime_acceptance.completed`, `incident.opened`, `recovery.completed`,
`rework.detected`, `cost.recorded`, and `test_run.completed`.

Actions are append-only observations. A later state change is a new event, not an update to
an earlier row. `task.completed`, for example, records the terminal observation while the
original `task.created` remains immutable.

## Idempotence and deduplication

Ingestion is at-least-once. The uniqueness boundary is:

`(tenant_id, provenance.source_system, dedupe.scope, dedupe.key)`

`dedupe.strategy` explains how the key was made:

- `source_event_id`: stable upstream delivery/event identifier;
- `content_hash`: digest of the source event when no delivery ID exists;
- `natural_key`: a documented source/entity/action key for sources without either.

`event_id` identifies an envelope and is not a substitute for the dedupe key. Retries may
produce a new envelope ID but must retain the same dedupe tuple. A collector must not silently
merge two different source events just because their payloads look similar.

## Provenance, time, and raw capture

`occurred_at` is source time and may be older than ingestion. `observed_at` is collector
time; it should normally be greater than or equal to `occurred_at`, but delayed and
clock-skewed sources are valid and should be measured rather than rewritten.

`raw` is an immutable-ish evidence pointer, not an invitation to put credentials or large
source documents in the event stream. Store bytes under a content-addressed reference,
record the exact SHA-256 and byte length, and set `redaction` to `partial` or `full` when
the capture was sanitized. Secret values, access tokens, and credential material must never
be present in `raw`, `data`, `attributes`, or `extensions`.

## Compatibility rules

Within `0.2`, changes are additive:

1. Existing field meanings and enum values are not repurposed.
2. New envelope fields are optional and must be added to the schema before use.
3. New source-specific fields belong in `data.attributes` under a documented namespace.
4. New cross-system fields belong in a namespaced `extensions` object.
5. Removing/renaming a required field, changing its meaning, or changing an enum requires a
   new `spec_version` and a migration note.
6. Consumers should ignore unknown extension namespaces and preserve the raw event when they
   cannot project a new payload field.

The schema is intentionally strict about the envelope and canonical payload keys, while
`attributes` and `extensions` are the explicit escape hatches for forward compatibility.

## Test-run contract

`test_run.completed` is the minimal structured test result. Its required fields are
`test_run_id`, `task_id`, `run_id`, `attempt`, `repository`, `commit_sha`,
`execution_source`, `status`, and `classification`. `execution_source` is `local` or
`github_actions`; GitHub executions may additionally carry `workflow`, `workflow_run_id`,
and `job_name`. Pull-request identity is represented by optional `pr_number` and `pr_url`.

`classification` is deliberately explicit: `functional`, `infrastructure`, `flake`, and
`policy` are known classes; `unknown` means the producer cannot determine a class and
`unclassified` means classification was not attempted. Producers must retain both values
instead of inferring a class from a failure message. The envelope's existing uniqueness
boundary remains `(tenant_id, provenance.source_system, dedupe.scope, dedupe.key)`; a test
run retry therefore uses a stable source event or natural key such as
`github_actions:<workflow_run_id>:<job_name>` while retaining a distinct envelope ID.

## Validation

The examples are an array of standalone events so they can exercise the schema in one file:

```sh
python3 tests/validate-fixtures.py
```

The test uses the local `jsonschema` package when available, validates all examples, checks
the event-type coverage, and asserts the cross-field invariants that JSON Schema cannot
express (unique event IDs, stable dedupe tuples, and `observed_at >= occurred_at` for the
fixtures). It also validates a deliberately broken copy to prove rejection behavior.

## Source integrations

The [PostHog raw-event ingress](integrations/posthog/) uses a PostHog destination
webhook for at-least-once forwarding. It preserves the source event as sanitized,
content-addressed evidence and does not introduce a polling datastore or a runtime
credential contract.
