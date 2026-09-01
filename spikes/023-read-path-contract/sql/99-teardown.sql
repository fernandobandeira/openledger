-- Spike 023 · give the cluster back what it lent us.
--
-- The scratch DATABASE is dropped separately (`DROP DATABASE spike023`, run
-- from the `postgres` database) because you cannot drop the one you are
-- connected to. What has to be undone from inside is the two LOGIN ROLES,
-- because roles are cluster-wide and this spike created them: they are the
-- only thing spike 023 leaves outside its own database, and
-- `sql/01-login-roles.sql` is the only thing that created them.
--
-- Nothing under `migrations/` was touched, and the `openledger_*` roles the
-- baseline creates are left exactly as they were — the schema-snapshot test
-- only dumps `rolname LIKE 'openledger\_%'`, so a `spike023_*` role could never
-- have reached it, and after this file there is none anyway.

DROP ROLE IF EXISTS spike023_reader;
DROP ROLE IF EXISTS spike023_dual;

\pset format unaligned
\pset tuples_only on
SELECT 'spike023 roles remaining: ' || count(*) FROM pg_roles WHERE rolname LIKE 'spike023%';
SELECT 'openledger roles untouched: ' || string_agg(rolname, ', ' ORDER BY rolname)
FROM pg_roles WHERE rolname LIKE 'openledger%';
