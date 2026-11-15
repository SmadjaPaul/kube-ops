-- PLT-303 drill, seed A (before the drill base backup): synthetic test rows in
-- the EMPTY OKE database, role hindsight. Deterministic, re-runnable.
INSERT INTO public.banks (bank_id, name, background)
SELECT 'drill-a-' || g, 'Drill bank A' || g, 'PLT-303 synthetic test data'
  FROM generate_series(1, 3) g
ON CONFLICT DO NOTHING;
INSERT INTO public.documents (id, bank_id, original_text, content_hash)
SELECT 'drill-a-doc-' || g, 'drill-a-1', 'synthetic text ' || g, md5('hindsight-drill-a-' || g)
  FROM generate_series(1, 1000) g
ON CONFLICT DO NOTHING;
SELECT 'seed_a_banks=' || count(*) FROM public.banks WHERE bank_id LIKE 'drill-a-%';
SELECT 'seed_a_docs=' || count(*) FROM public.documents WHERE id LIKE 'drill-a-doc-%';
SELECT 'seed_a_done_at=' || to_char(clock_timestamp() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"');
