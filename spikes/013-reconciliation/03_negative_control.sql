-- THE NEGATIVE CONTROL, and it is the half of this spike that is easy to skip.
--
-- A break list that is empty because it is wrong is indistinguishable from a break
-- list that is empty because the book is clean, and this project has shipped that
-- exact failure: ADR-0007 records a schema-snapshot check of "twenty-one lines
-- containing one SELECT that emits a string ... it runs green against the shipped
-- schema and a mutated one alike."
--
-- So every drift file below is paired with this one: clean book, six checks, zero
-- breaks -- run before and after each injection, since each injection rolls back.

\pset footer off
\echo '--- reconciliation: every check, clean book'
SELECT * FROM reconciliation ORDER BY check_name;

\echo '--- the four break lists, row counts'
SELECT (SELECT count(*) FROM recon_balance_breaks)     AS balance_breaks,
       (SELECT count(*) FROM recon_entry_breaks)       AS entry_breaks,
       (SELECT count(*) FROM recon_transaction_breaks) AS transaction_breaks,
       (SELECT count(*) FROM recon_scope_breaks)       AS scope_breaks;

\echo '--- the journal-to-reports statement foots in every scope and currency'
SELECT tenant_id, currency, journal_debits, pending_debits, orphan_debits,
       reported_debits, tb_debits, unexplained_debits, unexplained_credits
FROM recon_journal_to_reports ORDER BY tenant_id, currency;

\echo '--- and the book is not empty: what the reports actually say'
SELECT tenant_id, currency, sum(debits) AS debits, sum(credits) AS credits
FROM trial_balance GROUP BY tenant_id, currency ORDER BY tenant_id, currency;
