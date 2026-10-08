with runs as (
    select * from {{ ref('fct_test_runs') }}
),
counts as (
    select
        count(*) as run_count,
        count(*) filter (where outcome in ('passed', 'failed', 'cancelled')) as known_run_count,
        count(*) filter (where outcome = 'passed') as successful_run_count,
        count(*) filter (where outcome = 'unknown' or jsonb_path_exists(tests, '$[*] ? (@.classification == "UNCLASSIFIED")')) as unknown_or_unclassified_run_count,
        count(*) filter (where repository <> 'UNKNOWN' and sha <> 'UNKNOWN') as covered_run_count
    from runs
), test_counts as (
    select
        count(*) filter (where test->>'classification' <> 'UNCLASSIFIED') as classified_test_count,
        count(*) filter (where test->>'classification' = 'PASSED') as passed_test_count
    from runs cross join lateral jsonb_array_elements(tests) as test
)
select
    run_count,
    known_run_count,
    successful_run_count,
    unknown_or_unclassified_run_count,
    classified_test_count,
    passed_test_count,
    covered_run_count,
    successful_run_count::numeric / nullif(known_run_count, 0) as run_success_rate,
    passed_test_count::numeric / nullif(classified_test_count, 0) as test_pass_rate,
    covered_run_count::numeric / nullif(run_count, 0) as coverage_rate
from counts cross join test_counts
