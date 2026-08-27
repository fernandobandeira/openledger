-- 09 -- does the guard close each channel, and what does it NOT close?
\set ON_ERROR_STOP 0

\echo '=== A. the account_seq rewrite -- refused ==='
ALTER TABLE ledger_entries ALTER COLUMN account_seq TYPE bigint USING (account_seq * 10);
SELECT tenant_id, account_seq FROM ledger_entries ORDER BY 1,2 LIMIT 2;

\echo '=== B. the amount_minor rewrite after DROP VIEW -- refused ==='
BEGIN;
DROP VIEW trial_balance, balance_sheet, income_statement;
ALTER TABLE ledger_entries ALTER COLUMN amount_minor TYPE bigint USING (amount_minor * 10);
ROLLBACK;

\echo '=== C. DROP TABLE ledger_entries -- refused ==='
DROP TABLE ledger_entries CASCADE;

\echo '=== D. CREATE TABLE ... INHERITS -- refused ==='
CREATE TABLE shadow_entries () INHERITS (ledger_entries);
SELECT count(*) AS shadow_exists FROM pg_class WHERE relname='shadow_entries';

\echo '=== E. ALTER TABLE ... INHERIT (the same state by another grammar) -- refused ==='
BEGIN;
CREATE TABLE shadow2 (LIKE ledger_entries INCLUDING CONSTRAINTS);
ALTER TABLE shadow2 INHERIT ledger_entries;
ROLLBACK;

\echo '=== F. under session_replication_role = replica -- still refused, because ENABLE ALWAYS ==='
BEGIN;
SET LOCAL session_replication_role = 'replica';
ALTER TABLE ledger_entries ALTER COLUMN account_seq TYPE bigint USING (account_seq * 10);
ROLLBACK;
\echo '-- ...and the counterfactual: the same event trigger left ENABLE ORIGIN --'
ALTER EVENT TRIGGER ck_journal__no_rewrite ENABLE;
BEGIN;
SET LOCAL session_replication_role = 'replica';
ALTER TABLE ledger_entries ALTER COLUMN account_seq TYPE bigint USING (account_seq * 10);
SELECT tenant_id, account_seq FROM ledger_entries ORDER BY 1,2 LIMIT 2;
ROLLBACK;
ALTER EVENT TRIGGER ck_journal__no_rewrite ENABLE ALWAYS;

\echo '=== WHAT IT DOES NOT COVER ==='
\echo '-- 1. TRUNCATE: PostgreSQL refuses an event trigger for it outright --'
CREATE EVENT TRIGGER never ON ddl_command_start
    WHEN TAG IN ('TRUNCATE TABLE') EXECUTE FUNCTION refuse_journal_ddl();
\echo '--    (covered instead by the six statement-level triggers ADR-0004 kept) --'
TRUNCATE ledger_entries;

\echo '-- 2. an ALTER TABLE that does not rewrite: DROP COLUMN is accepted --'
BEGIN;
ALTER TABLE ledger_entries DROP COLUMN recorded_at;
SELECT count(*) AS rows_still_there FROM ledger_entries;
ROLLBACK;

\echo '-- 3. ALTER TABLE ... DISABLE TRIGGER USER: accepted, needs no superuser --'
BEGIN;
ALTER TABLE ledger_entries DISABLE TRIGGER USER;
DELETE FROM ledger_entries WHERE tenant_id='t1';
SELECT count(*) AS after_delete FROM ledger_entries;
ROLLBACK;

\echo '-- 4. DROP EVENT TRIGGER: one statement, and event triggers cannot guard themselves --'
BEGIN;
DROP EVENT TRIGGER ck_journal__no_rewrite;
ALTER TABLE ledger_entries ALTER COLUMN account_seq TYPE bigint USING (account_seq * 10);
SELECT tenant_id, account_seq FROM ledger_entries ORDER BY 1,2 LIMIT 2;
ROLLBACK;

\echo '-- 5. legitimate DDL is untouched --'
BEGIN;
CREATE INDEX ix_entries__tmp ON ledger_entries (recorded_at);
ALTER TABLE ledger_entries ADD COLUMN note text;
ALTER TABLE ledger_entries ADD COLUMN n int NOT NULL DEFAULT 0;
ALTER TABLE ledger_entries SET (fillfactor = 90);
ALTER TABLE ledger_entries ADD CONSTRAINT ck_entries__tmp CHECK (amount_minor < 10000000);
ROLLBACK;
VACUUM FULL ledger_entries;
\echo '-- ...but a volatile DEFAULT does rewrite, and is refused. A true positive: --'
\echo '-- adding that column to posted history writes a new value into every row. --'
ALTER TABLE ledger_entries ADD COLUMN n int NOT NULL DEFAULT (random()*100)::int;

\echo '=== final state: untouched ==='
SELECT count(*) AS entries, sum(amount_minor) AS total, max(account_seq) AS max_seq
FROM ledger_entries;
SELECT count(*) AS event_triggers FROM pg_event_trigger;
