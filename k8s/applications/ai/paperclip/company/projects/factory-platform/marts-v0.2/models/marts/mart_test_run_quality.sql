{{ config(materialized='table') }}

with runs as (
    select *
    from {{ var('factory_test_run_events_relation', 'factory_test_run_events') }}
    where test_run_id is not null
),

deduped as (
    select *
    from (
        select runs.*, row_number() over (
            partition by tenant_id, source_system, dedupe_scope, dedupe_key
            order by observed_at, raw_event_id
        ) as delivery_rank
        from runs
    ) ranked
    where delivery_rank = 1
),

summary as (
    select
        count(*) as test_run_count,
        count(*) filter (where execution_source = 'local') as local_test_run_count,
        count(*) filter (where execution_source = 'github_actions') as github_test_run_count,
        count(*) filter (where status = 'passed') as passed_test_run_count,
        count(*) filter (where status = 'failed') as failed_test_run_count,
        count(*) filter (where classification = 'unknown') as unknown_classification_count,
        count(*) filter (where classification = 'unclassified') as unclassified_count,
        count(*) filter (where pr_number is not null) as pr_linked_test_run_count,
        count(*) filter (where repository is not null and commit_sha is not null) as repository_sha_complete_count,
        count(distinct task_id) as task_count,
        count(distinct run_id) as run_count,
        sum(coalesce(failure_count, 0)) as failure_count,
        avg(duration_ms) as average_duration_ms
    from deduped
)

select
    *,
    case when test_run_count > 0 then passed_test_run_count::numeric / test_run_count end as pass_rate,
    case when test_run_count > 0 then failed_test_run_count::numeric / test_run_count end as failure_rate,
    case when test_run_count > 0 then pr_linked_test_run_count::numeric / test_run_count end as pr_link_rate,
    case when test_run_count > 0 then repository_sha_complete_count::numeric / test_run_count end as identity_completeness_rate
from summary
