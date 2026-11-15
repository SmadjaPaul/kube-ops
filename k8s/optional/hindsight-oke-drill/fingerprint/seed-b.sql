-- PLT-303 drill, seed B (AFTER the drill base backup): rows that only exist in
-- the WAL stream, so the restore proves WAL replay, not only the base backup.
INSERT INTO public.banks (bank_id, name, background)
VALUES ('drill-b-1', 'Drill bank B1', 'PLT-303 synthetic test data (WAL only)')
ON CONFLICT DO NOTHING;
INSERT INTO public.documents (id, bank_id, original_text, content_hash)
SELECT 'drill-b-doc-' || g, 'drill-b-1', 'synthetic wal text ' || g, md5('hindsight-drill-b-' || g)
  FROM generate_series(1, 100) g
ON CONFLICT DO NOTHING;
SELECT 'seed_b_banks=' || count(*) FROM public.banks WHERE bank_id LIKE 'drill-b-%';
SELECT 'seed_b_docs=' || count(*) FROM public.documents WHERE id LIKE 'drill-b-doc-%';
SELECT 'seed_b_done_at=' || to_char(clock_timestamp() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"');
