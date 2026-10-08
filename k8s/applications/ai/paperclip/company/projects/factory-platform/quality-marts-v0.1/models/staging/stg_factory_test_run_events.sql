select
    tenant_id,
    source,
    event_id,
    idempotency_key,
    (schema->>'version')::integer as schema_version,
    data->>'task_id' as task_id,
    data->>'run_id' as run_id,
    (data->>'attempt')::integer as attempt,
    data->>'repository' as repository,
    data->>'sha' as sha,
    data->>'pr' as pr,
    data->>'work_item_id' as work_item_id,
    data->>'agent_run_id' as agent_run_id,
    data->>'outcome' as outcome,
    data->'tests' as tests,
    observed_at
from {{ source('factory', 'test_run_events') }}
