-- PLT-190 drill, seed B (AFTER the first base backup is Completed): 500 more
-- rows that exist only in the WAL stream, so the restore proves WAL replay and
-- not just the base backup. Re-runnable.
INSERT INTO public.marker (id, phase, payload)
SELECT g, 'B', md5('pg-shared-drill-' || g) FROM generate_series(10001, 10500) g
ON CONFLICT DO NOTHING;
SELECT 'seed_b_rows=' || count(*) FROM public.marker WHERE phase = 'B';
SELECT 'seed_b_done_at=' || to_char(clock_timestamp() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"');
