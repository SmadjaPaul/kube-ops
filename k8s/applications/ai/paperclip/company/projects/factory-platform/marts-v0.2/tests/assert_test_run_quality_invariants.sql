-- dbt data test: zero rows means test-run identity and classification quality holds.
select test_run_id, 'missing_identity' as violation
from {{ var('factory_test_run_events_relation', 'factory_test_run_events') }}
where task_id is null
   or run_id is null
   or attempt < 1
   or repository is null
   or commit_sha is null

union all

select test_run_id, 'invalid_classification' as violation
from {{ var('factory_test_run_events_relation', 'factory_test_run_events') }}
where classification not in ('functional', 'infrastructure', 'flake', 'policy', 'unknown', 'unclassified')

union all

select test_run_id, 'github_missing_workflow_identity' as violation
from {{ var('factory_test_run_events_relation', 'factory_test_run_events') }}
where execution_source = 'github_actions'
  and (workflow is null or workflow_run_id is null)

union all

select test_run_id, 'duplicate_dedupe_key' as violation
from {{ var('factory_test_run_events_relation', 'factory_test_run_events') }}
group by test_run_id, tenant_id, source_system, dedupe_scope, dedupe_key
having count(*) > 1
