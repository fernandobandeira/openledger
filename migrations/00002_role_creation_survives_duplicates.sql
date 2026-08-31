-- 00002 -- role creation survives a duplicate.
--
-- ADR-0003's known issue, scheduled there as exactly this migration: the
-- migrate try-lock is per DATABASE (the database is part of the advisory lock
-- tag) while roles are per CLUSTER, so two first-migrates into sibling
-- databases on a fresh cluster each hold their own lock, both find the roles
-- absent in pg_roles, and race their CREATE ROLE into the cluster-wide
-- pg_authid_rolname_index -- the loser aborts on a duplicate. The baseline's
-- guard (`IF NOT EXISTS (SELECT 1 FROM pg_roles ...)`) is idempotent but not
-- race-safe: both racers read "absent" before either commits.
--
-- The race-safe form is the exception handler below -- CREATE, and treat "it
-- already exists" as the success it is. Two error codes on purpose: a role
-- that existed before the statement is duplicate_object, while the LOSER of a
-- truly concurrent pair surfaces as unique_violation on pg_authid's index
-- once the winner commits (the e2e login fixture catches the same pair --
-- crates/e2e/tests/e2e/support/postgres.rs).
--
-- WHAT THIS DOES NOT PROTECT: the baseline's own guarded CREATE ROLE still
-- runs first on a fresh cluster, and 00001 froze on 2026-08-27 (ADR-0003;
-- scripts/check-migrations-immutable.sh refuses any edit), so two first-
-- migrates can still collide inside 00001 -- the loser fails whole (sqlx
-- wraps each migration in its own transaction, nothing is half-applied) and
-- a re-run heals, because by then the roles exist and the guard sees them.
-- The e2e suite therefore keeps its one-at-a-time migrate mutex. What this
-- migration guarantees is narrower and real: from 00002 onward -- every
-- re-run, and any database whose bookkeeping says "00001 applied" on a
-- cluster that lacks the roles (a restore onto a fresh cluster) -- role
-- creation cannot fail on a role that already exists or on a concurrent
-- CREATE, and this file is the form every later role migration copies.
DO $$ BEGIN
    BEGIN
        CREATE ROLE openledger_app NOLOGIN;
    EXCEPTION WHEN duplicate_object OR unique_violation THEN NULL;
    END;
    BEGIN
        CREATE ROLE openledger_read NOLOGIN;
    EXCEPTION WHEN duplicate_object OR unique_violation THEN NULL;
    END;
    BEGIN
        CREATE ROLE openledger_recon NOLOGIN;
    EXCEPTION WHEN duplicate_object OR unique_violation THEN NULL;
    END;
END $$;
