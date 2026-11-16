-- PLT-190: read-only fingerprint of pg-shared. Run the same file on the OKE
-- cluster and on the off-Oracle restore; both outputs must be identical on
-- every line (passwords are not fingerprinted: the restore uses a
-- CNPG-generated one). Run on the restore only after the OKE run.
\pset format unaligned
\pset tuples_only on
SELECT 'server_version=' || current_setting('server_version');
SELECT 'extension=' || extname || ':' || extversion FROM pg_extension ORDER BY 1;
SELECT 'database=' || datname || ':' || pg_get_userbyid(datdba)
  FROM pg_database WHERE NOT datistemplate AND datname <> 'postgres' ORDER BY 1;
SELECT 'roles_md5=' || md5(string_agg(concat_ws(':', rolname, rolcanlogin, rolsuper, rolcreatedb,
         rolcreaterole, rolreplication, rolbypassrls, rolinherit), '|' ORDER BY rolname))
  FROM pg_roles WHERE rolname !~ '^(pg_|cnpg_|streaming_replica$|postgres$)';
SELECT 'rows_a=' || count(*) FROM public.marker WHERE phase = 'A';
SELECT 'rows_b=' || count(*) FROM public.marker WHERE phase = 'B';
SELECT 'max_id=' || coalesce(max(id)::text, 'empty') FROM public.marker;
SELECT 'marker_md5=' || coalesce(md5(string_agg(m::text, '|' ORDER BY m.id)), 'empty') FROM public.marker m;
SELECT 'last_written_at=' || coalesce(to_char(max(written_at) AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'), 'empty') FROM public.marker;
SELECT 'marker_owner=' || tableowner FROM pg_tables WHERE schemaname = 'public' AND tablename = 'marker';
