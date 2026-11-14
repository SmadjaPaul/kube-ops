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
SELECT 'roles_md5=' || md5(string_agg(concat_ws(':', rolname, rolcanlogin, rolsuper, rolcreatedb,
         rolcreaterole, rolreplication, rolbypassrls, rolinherit), '|' ORDER BY rolname))
  FROM pg_roles WHERE rolname !~ '^(pg_|cnpg_|streaming_replica$|postgres$)';
SELECT 'memberships_md5=' || coalesce(md5(string_agg(concat_ws(':', r.rolname, m.rolname, a.admin_option, a.inherit_option, a.set_option),
         '|' ORDER BY r.rolname, m.rolname)), 'none')
  FROM pg_auth_members a JOIN pg_roles r ON r.oid = a.roleid JOIN pg_roles m ON m.oid = a.member
 WHERE m.rolname !~ '^(pg_|cnpg_|streaming_replica$|postgres$)';
-- ACLs keep PUBLIC grants and grant options (role names, not OIDs); owners
-- are part of each entry because a NULL ACL means "owner default".
SELECT 'schema_acl=' || nspname || ':' || pg_get_userbyid(nspowner) || ':' || coalesce(nspacl::text, 'default')
  FROM pg_namespace WHERE nspname = 'public';
SELECT 'acl_md5=' || md5(string_agg(concat_ws(':', c.relname, c.relkind, pg_get_userbyid(c.relowner), coalesce(c.relacl::text, 'default')),
         '|' ORDER BY c.relname))
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p', 'v', 'm', 'S');
SELECT 'routine_acl_md5=' || coalesce(md5(string_agg(concat_ws(':', p.oid::regprocedure::text, pg_get_userbyid(p.proowner), p.prosecdef, coalesce(p.proacl::text, 'default')),
         '|' ORDER BY p.oid::regprocedure::text)), 'none')
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public';
SELECT 'database_acl=' || pg_get_userbyid(datdba) || ':' || coalesce(datacl::text, 'default')
  FROM pg_database WHERE datname = current_database();
SELECT 'owner=' || tableowner || ':' || count(*) FROM pg_tables WHERE schemaname = 'public' GROUP BY tableowner ORDER BY 1;
