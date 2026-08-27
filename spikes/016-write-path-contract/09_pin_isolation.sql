-- 09_pin_isolation.sql -- the writer does not INHERIT its isolation level.
--
-- "Correctness is never configurable" applies here literally: a deployment that
-- sets default_transaction_isolation to anything stricter loses most of its
-- writes (02). The fix is not documentation. BEGIN ISOLATION LEVEL READ COMMITTED
-- overrides the deployment default, per transaction, and the writer issues it.

\pset pager off
\echo '=== a deployment default of serializable...'
SET default_transaction_isolation = 'serializable';
BEGIN; SHOW transaction_isolation; COMMIT;

\echo ''
\echo '=== ...is overridden by the writer, per transaction.'
BEGIN ISOLATION LEVEL READ COMMITTED; SHOW transaction_isolation; COMMIT;
RESET default_transaction_isolation;

\echo ''
\echo '=== and the failure the writer is avoiding carries SQLSTATE 40001,'
\echo '=== which plpgsql names serialization_failure.'
DO $$ BEGIN
    RAISE EXCEPTION USING ERRCODE = '40001';
EXCEPTION WHEN serialization_failure THEN
    RAISE NOTICE 'serialization_failure == SQLSTATE %', SQLSTATE;
END $$;
