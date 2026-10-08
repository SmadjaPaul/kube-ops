{{ config(materialized='incremental', unique_key='idempotency_key') }}

select
    tenant_id,
    source,
    event_id,
    idempotency_key,
    schema_version,
    task_id,
    run_id,
    attempt,
    repository,
    sha,
    pr,
    work_item_id,
    agent_run_id,
    outcome,
    tests,
    observed_at
from {{ ref('stg_factory_test_run_events') }}
{% if is_incremental() %}
where observed_at > (select coalesce(max(observed_at), '1970-01-01'::timestamptz) from {{ this }})
{% endif %}
