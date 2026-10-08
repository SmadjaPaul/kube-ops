{{ config(materialized='view') }}

with events as (
    select *
    from {{ var('factory_delivery_events_relation', 'factory_delivery_events') }}
    where task_id is not null
),

rollup as (
    select
        task_id,
        max(intent_id) as intent_id,
        max(project_id) as project_id,
        max(repository_id) as repository_id,
        max(pr_id) as pr_id,
        max(task_type) as task_type,
        max(priority) as priority,
        max(environment) as environment,
        max(agent_id) as agent_id,
        max(provider) as provider,
        max(model_name) as model_name,
        min(case when event_name = 'intent_created' then event_ts end) as intent_at,
        min(case when event_name = 'task_started' then event_ts end) as started_at,
        min(case when event_name = 'pr_opened' then event_ts end) as pr_opened_at,
        min(case when event_name = 'review_requested' then event_ts end) as review_requested_at,
        min(case when event_name = 'review_response' then event_ts end) as first_review_response_at,
        min(case when event_name = 'acceptance' then event_ts end) as accepted_at,
        max(event_ts) as source_last_event_at,
        max(case when event_name = 'acceptance' then coalesce(attempt_number, 1) end) as acceptance_attempt_number,
        max(case when event_name = 'acceptance' and event_ts is not null and coalesce(accepted, true) then 1 else 0 end) as accepted_task_flag,
        sum(case when event_name = 'change_failure' then 1 else 0 end) as change_failure_count,
        sum(case when event_name = 'deployment' then 1 else 0 end) as deployment_count,
        sum(case when event_name = 'rework' then 1 else 0 end) as rework_deployment_count,
        sum(case when event_name = 'ci_run' then 1 else 0 end) as ci_run_count,
        coalesce(sum(case when event_name = 'ci_run' then coalesce(ci_retry_count, 0) else 0 end), 0) as ci_retry_count,
        coalesce(sum(case when event_name in ('oversight_session', 'review_response') then coalesce(human_oversight_minutes, 0) else 0 end), 0) as human_oversight_minutes,
        sum(cost_usd) as attributed_cost_usd,
        max(case when event_name = 'review_response' then review_rounds end) as review_rounds,
        sum(input_tokens) as input_tokens,
        sum(output_tokens) as output_tokens,
        sum(tool_calls) as tool_calls,
        max(case when event_name = 'pr_opened' then pr_additions end) as pr_additions,
        max(case when event_name = 'pr_opened' then pr_deletions end) as pr_deletions,
        max(case when event_name = 'pr_opened' then pr_files_changed end) as pr_files_changed,
        max(task_complexity_score) as task_complexity_score,
        max(context_quality_score) as context_quality_score,
        max(classification_confidence) as classification_confidence,
        max(case when event_name = 'acceptance' then coalesce(innovation_eligible, false)::int end) as innovation_eligible_flag,
        max(case when event_name = 'acceptance' then coalesce(innovation_task, false)::int end) as innovation_task_flag
    from events
    group by task_id
)

select
    task_id,
    intent_id,
    project_id,
    repository_id,
    pr_id,
    task_type,
    priority,
    environment,
    agent_id,
    provider,
    model_name,
    intent_at,
    started_at,
    pr_opened_at,
    review_requested_at,
    first_review_response_at,
    accepted_at,
    source_last_event_at,
    acceptance_attempt_number,
    accepted_task_flag,
    case
        when intent_at is not null
         and accepted_at is not null
         and accepted_at >= intent_at
        then extract(epoch from (accepted_at - intent_at))::bigint
    end as end_to_end_cycle_time_seconds,
    case
        when accepted_task_flag = 1
         and coalesce(acceptance_attempt_number, 0) = 1
         and change_failure_count = 0
         and rework_deployment_count = 0
        then 1 else 0
    end as first_pass_success_flag,
    case when accepted_task_flag = 1 then human_oversight_minutes end as human_oversight_minutes_per_success,
    case when accepted_task_flag = 1 then attributed_cost_usd end as cost_per_accepted_task,
    change_failure_count,
    deployment_count,
    rework_deployment_count,
    ci_run_count,
    ci_retry_count,
    human_oversight_minutes,
    attributed_cost_usd,
    review_rounds,
    case
        when review_requested_at is not null
         and first_review_response_at is not null
         and first_review_response_at >= review_requested_at
        then extract(epoch from (first_review_response_at - review_requested_at)) / 60.0
    end as review_turnaround_minutes,
    input_tokens,
    output_tokens,
    tool_calls,
    pr_additions,
    pr_deletions,
    pr_files_changed,
    task_complexity_score,
    case
        when task_complexity_score is null then 'unknown'
        when task_complexity_score < 0.33 then 'low'
        when task_complexity_score < 0.66 then 'medium'
        else 'high'
    end as task_complexity_band,
    context_quality_score,
    case
        when context_quality_score is null then 'unknown'
        when context_quality_score < 0.33 then 'low'
        when context_quality_score < 0.66 then 'medium'
        else 'high'
    end as context_quality_band,
    classification_confidence,
    innovation_eligible_flag,
    innovation_task_flag,
    case
        when innovation_eligible_flag = 1 and accepted_task_flag = 1
        then innovation_task_flag
    end as innovation_success_flag
from rollup
