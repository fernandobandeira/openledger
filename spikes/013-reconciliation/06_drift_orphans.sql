-- DRIFT 3 -- the journal against the reports, and what an orphan is.
--
-- "A SUM over ledger_entries and a SUM over trial_balance, per tenant and
-- currency, should agree and are compared by nothing. Measured on a book carrying
-- one orphan pair: raw journal 55,280.96 against a trial balance of 5,280.96 -- a
-- 50,000.00 gap reported by no view, no constraint and no function."
--
-- HOW AN ORPHAN GETS IN. Every join the three report views make is backed by a
-- foreign key, so on the ordinary write path this population is empty and the view
-- below is dead weight. It is not the ordinary write path that produces one. All
-- 36 internal foreign-key triggers in the shipped schema are ENABLE ORIGIN, and
-- `session_replication_role = 'replica'` -- the logical-replication apply path, and
-- what `pg_restore --disable-triggers` sets -- skips them. That setting is what
-- each case below uses, because it is how this actually happens.
--
-- Note what is NOT an orphan: a pending entry. It is excluded from every report on
-- purpose (ADR-0007 rule 14) and is a named reconciling item, not a break.

\pset footer off

-- ----------------------------------------------------------------------
\echo '=== 3a - an entry pair on an account that does not exist. 50,000.00.'
BEGIN;
SET session_replication_role = 'replica';
INSERT INTO ledger_transactions (tenant_id, id, kind, status, effective_at)
VALUES ('t1','01a04000-0000-7000-8000-00000000ffff','settlement','posted','2026-06-07');
INSERT INTO ledger_entries (tenant_id, transaction_id, account_id, direction,
                            amount_minor, currency, account_seq, effective_at)
VALUES ('t1','01a04000-0000-7000-8000-00000000ffff','01a04000-0000-7000-8000-0000000000aa',
        'debit', 5000000,'USD',1,'2026-06-07'),
       ('t1','01a04000-0000-7000-8000-00000000ffff','01a04000-0000-7000-8000-0000000000bb',
        'credit',5000000,'USD',1,'2026-06-07');
SET session_replication_role = 'origin';

\echo '--- every shipped check is still green: the pair is balanced and absent'
SELECT tenant_id, currency, sum(debits) AS tb_debits, sum(credits) AS tb_credits
FROM trial_balance WHERE tenant_id = 't1' GROUP BY tenant_id, currency;

\echo '--- the reconciliation statement, which names where the gap went'
SELECT tenant_id, currency, journal_debits, pending_debits, orphan_debits,
       reported_debits, tb_debits, unexplained_debits, journal_minus_report_debits
FROM recon_journal_to_reports WHERE tenant_id = 't1';

\echo '--- ...and the population itself, enumerated rather than summarised'
SELECT tenant_id, entry_id, account_id, currency, direction, amount_minor, reason
FROM recon_entry_breaks ORDER BY direction;

SELECT * FROM reconciliation ORDER BY check_name;
ROLLBACK;

-- ----------------------------------------------------------------------
\echo '=== 3b - a chart row deleted under posted history.'
\echo '===      fk_accounts__type refuses this on the ordinary path. Not on this one.'
BEGIN;
SET session_replication_role = 'replica';
DELETE FROM account_types WHERE code = 'fee_revenue';
SET session_replication_role = 'origin';

\echo '--- t1 revenue has left the income statement, and the trial balance no'
\echo '--- longer foots -- but nothing in the artefact reports either fact'
SELECT tenant_id, currency, sum(debits) AS tb_debits, sum(credits) AS tb_credits
FROM trial_balance WHERE tenant_id = 't1' GROUP BY tenant_id, currency;

SELECT tenant_id, entry_id, account_id, amount_minor, reason FROM recon_entry_breaks;
SELECT tenant_id, currency, journal_credits, orphan_credits, reported_credits,
       tb_credits, unexplained_credits
FROM recon_journal_to_reports WHERE tenant_id = 't1';
ROLLBACK;

-- ----------------------------------------------------------------------
\echo '=== 3c - an entry whose transaction is not there.'
BEGIN;
SET session_replication_role = 'replica';
INSERT INTO ledger_entries (tenant_id, transaction_id, account_id, direction,
                            amount_minor, currency, account_seq, effective_at)
SELECT 't1','01a04000-0000-7000-8000-0000000000cc',
       seed_acct('t1','fee_revenue','USD'),'credit',700,'USD',99,'2026-06-08';
SET session_replication_role = 'origin';

SELECT tenant_id, entry_id, transaction_id, amount_minor, reason FROM recon_entry_breaks;
SELECT * FROM reconciliation ORDER BY check_name;
ROLLBACK;

\echo '=== rolled back: clean again'
SELECT * FROM reconciliation ORDER BY check_name;
