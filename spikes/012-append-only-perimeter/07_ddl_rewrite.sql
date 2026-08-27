-- 07 -- CHANNEL D. DDL walks straight through append-only.
-- Re-verified against the current baseline. The two triggers on ledger_entries are
-- ENABLE ALWAYS; neither fires, because a table rewrite is not a DML statement.

\echo '=== before ==='
SELECT tgname, tgenabled FROM pg_trigger
 WHERE tgrelid='ledger_entries'::regclass AND NOT tgisinternal ORDER BY 1;
SELECT tenant_id, account_id, account_seq FROM ledger_entries ORDER BY 1,2,3;

\echo '=== the rewrite ==='
ALTER TABLE ledger_entries ALTER COLUMN account_seq TYPE bigint USING (account_seq * 10);

\echo '=== after: every account_seq multiplied by ten, no error, no trigger fired ==='
SELECT tenant_id, account_id, account_seq FROM ledger_entries ORDER BY 1,2,3;
\echo '=== gaplessness -- the property account_seq exists to provide -- is gone ==='
SELECT tenant_id, account_id, max(account_seq) AS max_seq, count(*) AS rows,
       max(account_seq) = count(*) AS gapless
FROM ledger_entries GROUP BY 1,2 ORDER BY 1,2;
\echo '=== ...and the balance cache still says last_seq = 2 ==='
SELECT tenant_id, account_id, last_seq FROM ledger_account_balances ORDER BY 1,2;

\echo '=== the amount_minor form: refused while the views exist ==='
\set ON_ERROR_STOP 0
ALTER TABLE ledger_entries ALTER COLUMN amount_minor TYPE bigint USING (amount_minor * 10);
\set ON_ERROR_STOP 1
\echo '=== ...and accepted after the DROP VIEW a migrator would do anyway ==='
SELECT tenant_id, currency, fs_line, amount_minor FROM income_statement WHERE amount_minor <> 0;
DROP VIEW trial_balance, balance_sheet, income_statement;
ALTER TABLE ledger_entries ALTER COLUMN amount_minor TYPE bigint USING (amount_minor * 10);
SELECT sum(amount_minor) AS journal_total FROM ledger_entries;

\echo '=== and DROP TABLE is not a DELETE either ==='
DROP TABLE ledger_entries CASCADE;
SELECT count(*) AS ledger_entries_still_exists
  FROM pg_class WHERE relname='ledger_entries';
