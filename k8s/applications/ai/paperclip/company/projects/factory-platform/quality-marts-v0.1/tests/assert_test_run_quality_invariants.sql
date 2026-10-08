-- dbt test: no denominator can be zero while a ratio is non-null.
select *
from {{ ref('mart_test_run_quality') }}
where (known_run_count = 0 and run_success_rate is not null)
   or (classified_test_count = 0 and test_pass_rate is not null)
   or (run_count = 0 and coverage_rate is not null)
