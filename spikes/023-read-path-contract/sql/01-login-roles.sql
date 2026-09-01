-- Spike 023 · the two login roles Q2 needs, and the exact DDL, recorded here
-- because roles are CLUSTER-wide and this is a scratch database.
--
-- Nothing in `migrations/` is touched. `sql/99-teardown.sql` drops both.
--
-- Why they exist: the shipped tree has one DATABASE_URL and it is the owner's,
-- and the owner is not bound by RLS at all (`FORCE ROW LEVEL SECURITY` is
-- deliberately not set — ADR-0013). So the owner cannot answer the question a
-- deployment actually faces: what happens when the LOGIN behind the read path
-- is a member of the read role, with or without also being a member of the
-- writer's. `reconcile.rs` already documents the shape — "the login behind
-- DATABASE_URL only needs membership" — and never has to ask, because the
-- sweep's role is admitted to every tenant by an explicit policy.
--
-- INHERIT on both, which is the default and the point: an inheriting member
-- gets the member role's privileges WITHOUT `SET ROLE`, and a policy declared
-- `TO openledger_read` applies to any current_user that `pg_has_role(...,
-- 'USAGE')` reaches. That is what makes the dual-membership case in Q2/H a
-- real hazard rather than a hypothetical one.

DROP ROLE IF EXISTS spike023_reader;
DROP ROLE IF EXISTS spike023_dual;

-- The read path's own login: a member of the read role and nothing else.
CREATE ROLE spike023_reader LOGIN PASSWORD 'spike023' INHERIT;
GRANT openledger_read TO spike023_reader;

-- The serving process's login as a deployment would actually shape it: it must
-- write, so it is a member of openledger_app; if it is ALSO made a member of
-- openledger_read so that reads can share its pool, both policies apply.
CREATE ROLE spike023_dual LOGIN PASSWORD 'spike023' INHERIT;
GRANT openledger_app  TO spike023_dual;
GRANT openledger_read TO spike023_dual;

-- Neither login owns anything, which is the property spike 004 asked for and
-- ADR-0013 restates: "the app role must not own the tables".
\pset format unaligned
\pset tuples_only on
SELECT r.rolname || ' member_of=' ||
       coalesce((SELECT string_agg(g.rolname, ',' ORDER BY g.rolname)
                 FROM pg_auth_members m JOIN pg_roles g ON g.oid = m.roleid
                 WHERE m.member = r.oid), '<none>')
FROM pg_roles r WHERE r.rolname LIKE 'spike023%' ORDER BY r.rolname;
