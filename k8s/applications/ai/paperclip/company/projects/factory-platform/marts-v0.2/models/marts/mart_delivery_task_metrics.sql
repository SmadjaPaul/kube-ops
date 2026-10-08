{{ config(materialized='table') }}

with tasks as (
    select * from {{ ref('mart_delivery_task') }}
),

eligible as (
    select
        count(*) filter (where accepted_task_flag = 1) as accepted_task_throughput,
        count(*) filter (where first_pass_success_flag = 1) as first_pass_success_count,
        sum(human_oversight_minutes_per_success) as successful_oversight_minutes,
        sum(cost_per_accepted_task) as successful_cost_usd,
        sum(change_failure_count) as failed_changes,
        sum(deployment_count) as deployed_changes,
        sum(rework_deployment_count) as rework_deployments,
        count(*) filter (where innovation_eligible_flag = 1 and accepted_task_flag = 1) as innovation_eligible_successes,
        sum(innovation_success_flag) as innovation_successes
    from tasks
),

cycle as (
    select
        percentile_cont(0.50) within group (order by end_to_end_cycle_time_seconds) as end_to_end_cycle_time_p50_seconds,
        percentile_cont(0.90) within group (order by end_to_end_cycle_time_seconds) as end_to_end_cycle_time_p90_seconds
    from tasks
    where end_to_end_cycle_time_seconds is not null
      and end_to_end_cycle_time_seconds >= 0
),

review as (
    select
        percentile_cont(0.50) within group (order by review_turnaround_minutes) as review_turnaround_p50_minutes,
        percentile_cont(0.90) within group (order by review_turnaround_minutes) as review_turnaround_p90_minutes
    from tasks
    where review_turnaround_minutes is not null
      and review_turnaround_minutes >= 0
)

select
    e.accepted_task_throughput,
    c.end_to_end_cycle_time_p50_seconds,
    c.end_to_end_cycle_time_p90_seconds,
    r.review_turnaround_p50_minutes,
    r.review_turnaround_p90_minutes,
    case when e.accepted_task_throughput > 0 then e.first_pass_success_count::numeric / e.accepted_task_throughput end as first_pass_success,
    case when e.accepted_task_throughput > 0 then e.successful_oversight_minutes / e.accepted_task_throughput end as human_oversight_minutes_per_success,
    case when e.accepted_task_throughput > 0 then e.successful_cost_usd / e.accepted_task_throughput end as cost_per_accepted_task,
    case when e.deployed_changes > 0 then e.failed_changes::numeric / e.deployed_changes end as change_fail_rate,
    case when e.deployed_changes > 0 then e.rework_deployments::numeric / e.deployed_changes end as deployment_rework_rate,
    case when e.innovation_eligible_successes > 0 then e.innovation_successes::numeric / e.innovation_eligible_successes end as innovation_ratio
from eligible e
cross join cycle c
cross join review r
