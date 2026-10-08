-- Relation-free SQL fixture. It should return zero rows in PostgreSQL.
with events(task_id, event_name, event_ts, attempt_number, accepted,
            human_oversight_minutes, cost_usd, ci_retry_count,
            innovation_eligible, innovation_task) as (
    values
        ('t-success', 'intent_created', timestamp '2026-01-01 10:00:00', null, null, null, null, null, null, null),
        ('t-success', 'review_requested', timestamp '2026-01-01 10:30:00', null, null, null, null, null, null, null),
        ('t-success', 'review_response', timestamp '2026-01-01 10:45:00', null, 15, null, null, null, null, null),
        ('t-success', 'deployment', timestamp '2026-01-01 11:00:00', 1, null, null, 2.50, 0, null, null),
        ('t-success', 'acceptance', timestamp '2026-01-01 11:30:00', 1, true, null, null, null, true, true),
        ('t-failed', 'intent_created', timestamp '2026-01-01 10:00:00', null, null, null, null, null, null, null),
        ('t-failed', 'deployment', timestamp '2026-01-01 10:05:00', 1, null, null, 1.00, 1, null, null),
        ('t-failed', 'change_failure', timestamp '2026-01-01 10:06:00', 1, null, null, null, null, null, null),
        ('t-failed', 'acceptance', timestamp '2026-01-01 10:30:00', 2, true, null, null, null, false, false),
        ('t-open', 'intent_created', timestamp '2026-01-01 10:00:00', null, null, null, null, null, null, null),
        ('t-rework', 'intent_created', timestamp '2026-01-01 10:00:00', null, null, null, null, null, null, null),
        ('t-rework', 'deployment', timestamp '2026-01-01 10:05:00', 1, null, null, null, null, null, null),
        ('t-rework', 'deployment', timestamp '2026-01-01 10:10:00', 2, null, null, null, null, null, null),
        ('t-rework', 'rework', timestamp '2026-01-01 10:15:00', 2, null, null, null, null, null, null),
        ('t-rework', 'acceptance', timestamp '2026-01-01 10:30:00', 2, true, null, null, null, false, false)
),

actual as (
    select
        task_id,
        max(case when event_name = 'acceptance' then 1 else 0 end) as accepted_task_flag,
        extract(epoch from (
            max(case when event_name = 'acceptance' then event_ts end)
            - min(case when event_name = 'intent_created' then event_ts end)
        ))::bigint as cycle_seconds,
        max(case when event_name = 'acceptance' then attempt_number end) as acceptance_attempt,
        max(case when event_name = 'change_failure' then 1 else 0 end) as change_failure_flag,
        count(*) filter (where event_name = 'deployment') as deployment_count,
        count(*) filter (where event_name = 'rework') as rework_count,
        max(case when event_name = 'acceptance' then innovation_eligible::int end) as innovation_eligible_flag,
        max(case when event_name = 'acceptance' then innovation_task::int end) as innovation_task_flag
    from events
    group by task_id
),

expected(task_id, accepted_task_flag, cycle_seconds, first_pass_success_flag, innovation_success_flag, deployment_rework_rate) as (
    values
        ('t-success', 1, 5400, 1, 1, 0.0),
        ('t-failed', 1, 1800, 0, 0, 0.0),
        ('t-open', 0, null, 0, null, null),
        ('t-rework', 1, 1800, 0, 0, 0.5)
)

select e.*
from expected e
left join actual a using (task_id)
where a.task_id is null
   or a.accepted_task_flag <> e.accepted_task_flag
   or a.cycle_seconds is distinct from e.cycle_seconds
   or (case when a.accepted_task_flag = 1
             and a.acceptance_attempt = 1
             and a.change_failure_flag = 0
            then 1 else 0 end) <> e.first_pass_success_flag
   or (case when a.innovation_eligible_flag = 1 and a.accepted_task_flag = 1
            then a.innovation_task_flag end) is distinct from e.innovation_success_flag
   or (case when a.deployment_count > 0
            then a.rework_count::numeric / a.deployment_count end) is distinct from e.deployment_rework_rate;
