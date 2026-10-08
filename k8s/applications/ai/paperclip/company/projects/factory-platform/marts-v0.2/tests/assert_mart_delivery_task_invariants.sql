-- dbt data test: zero rows means the mart contract holds.
select task_id, 'negative_cycle_time' as violation
from {{ ref('mart_delivery_task') }}
where end_to_end_cycle_time_seconds < 0

union all

select task_id, 'acceptance_before_intent' as violation
from {{ ref('mart_delivery_task') }}
where intent_at is not null
  and accepted_at is not null
  and accepted_at < intent_at

union all

select task_id, 'accepted_without_timestamp' as violation
from {{ ref('mart_delivery_task') }}
where accepted_task_flag = 1
  and accepted_at is null

union all

select task_id, 'success_without_acceptance' as violation
from {{ ref('mart_delivery_task') }}
where first_pass_success_flag = 1
  and accepted_task_flag <> 1

union all

select task_id, 'rate_out_of_range' as violation
from {{ ref('mart_delivery_task') }}
where change_fail_rate < 0 or change_fail_rate > 1
   or deployment_rework_rate < 0 or deployment_rework_rate > 1
