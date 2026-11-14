-- PLT-301: read-only fingerprint of a Hindsight database. Run the same file on
-- the homelab source, the OKE recovery and the off-Oracle restore; the three
-- outputs must be identical (same writes window, see the drill runbook).
\pset format unaligned
\pset tuples_only on
SELECT 'server_version=' || current_setting('server_version');
SELECT 'extension=' || extname || ':' || extversion FROM pg_extension ORDER BY 1;
SELECT 'rows=' || table_name || ':' ||
       (xpath('/row/c/text()', query_to_xml(format('SELECT count(*) AS c FROM public.%I', table_name), false, true, '')))[1]::text
  FROM information_schema.tables
 WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
 ORDER BY table_name;
SELECT 'banks_md5=' || coalesce(md5(string_agg(b::text, '|' ORDER BY b::text)), 'empty') FROM public.banks b;
SELECT 'roles_md5=' || md5(string_agg(rolname || ':' || rolcanlogin || ':' || rolsuper || ':' || rolcreatedb, '|' ORDER BY rolname))
  FROM pg_roles WHERE rolname !~ '^(pg_|cnpg_|streaming_replica$|postgres$)';
SELECT 'grants_md5=' || md5(string_agg(grantee || ':' || table_name || ':' || privilege_type, '|' ORDER BY grantee, table_name, privilege_type))
  FROM information_schema.role_table_grants WHERE table_schema = 'public';
SELECT 'owner=' || tableowner || ':' || count(*) FROM pg_tables WHERE schemaname = 'public' GROUP BY tableowner ORDER BY 1;
