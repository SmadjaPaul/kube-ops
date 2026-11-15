-- PLT-190 drill, seed A (before the first base backup): 10000 synthetic rows,
-- deterministic payload. Runs as role polyfin in database backup_drill.
-- Re-runnable: ON CONFLICT DO NOTHING.
CREATE TABLE IF NOT EXISTS public.marker (
  id         integer PRIMARY KEY,
  phase      text NOT NULL,
  payload    text NOT NULL,
  written_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
INSERT INTO public.marker (id, phase, payload)
SELECT g, 'A', md5('pg-shared-drill-' || g) FROM generate_series(1, 10000) g
ON CONFLICT DO NOTHING;
SELECT 'seed_a_rows=' || count(*) FROM public.marker WHERE phase = 'A';
SELECT 'seed_a_done_at=' || to_char(clock_timestamp() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"');
