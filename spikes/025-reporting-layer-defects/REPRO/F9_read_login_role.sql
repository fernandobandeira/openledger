-- The reader this reproduction connects as.
--
-- openledger_read is NOLOGIN by design, so a reproduction that wants to be
-- bound by the RLS policies needs a LOGIN role that INHERITS it. Same shape as
-- crates/e2e/tests/e2e/support/postgres.rs::ensure_login_role, and for the same
-- reason: roles are CLUSTER-wide, so the name is fixed and guarded rather than
-- generated, and it is never dropped -- a DROP ROLE here would break whatever
-- other database on this cluster is using it.
--
-- Run as the OWNER. It grants nothing beyond openledger_read: everything the
-- reader can see below, it sees through the baseline's own grants and policies.

\set ON_ERROR_STOP on

DO $$ BEGIN
    BEGIN
        CREATE ROLE spike025_read_login;
    EXCEPTION WHEN duplicate_object OR unique_violation THEN NULL;
    END;
    ALTER ROLE spike025_read_login LOGIN PASSWORD 'spike025-only';
    GRANT openledger_read TO spike025_read_login;
END $$;

SELECT r.rolname, r.rolcanlogin, r.rolbypassrls,
       pg_has_role('spike025_read_login', 'openledger_read', 'USAGE') AS inherits_read
FROM pg_roles r WHERE r.rolname = 'spike025_read_login';
