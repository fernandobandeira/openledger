-- F9, half two -- a cursor-pinned statement is reproducible in its NUMBERS and
-- not in its SHAPE.
--
-- Both statement functions enumerate their scopes from ledger_accounts:
--
--     scopes AS (SELECT DISTINCT l.tenant_id, l.currency FROM ledger_accounts l
--                WHERE l.tenant_id = p_tenant)
--
-- and ledger_accounts has no xact_id column, so nothing in that CTE is filtered
-- by p_cursor. The choice is deliberate and the comment says why -- a scope that
-- has been opened but has not posted is still a scope -- but it means the cursor
-- pins the journal only. Opening an account in a NEW currency changes the FACE of
-- an already-issued statement re-run at its own cursor: a whole all-zero currency
-- block appears, with its own synthesised current_year_earnings plug row.
--
-- Run as the OWNER, in ONE psql session (the pinned cursor is a psql variable and
-- the before-image is a TEMP table). It opens one account and posts nothing.
-- F9_run.sh polls the cluster horizon before this runs, so the pinned cursor is
-- not lagging behind the seeded entries.

\set ON_ERROR_STOP on
\pset null '(null)'

\echo '=== 0a. the negative control: all ten checks at zero before anything is'
\echo '===     opened, so a green summary in section 9 is not green by inheritance'
SELECT * FROM reconciliation;

\echo
\echo '=== 0b. the horizon: every seeded entry is strictly below the cursor, so'
\echo '===     the statement below is the whole seeded book and not a lagged slice'
SELECT max(xact_id)::text AS max_entry_xact_id,
       pg_snapshot_xmin(pg_current_snapshot())::text AS report_cursor,
       max(xact_id) < pg_snapshot_xmin(pg_current_snapshot()) AS strictly_below
FROM ledger_entries;

-- C is captured ONCE, as a literal, and re-used verbatim. report_cursor() is
-- VOLATILE; calling it twice would compare two different reports.
SELECT report_cursor()::text AS c \gset
\echo '=== 1. the cursor this statement is pinned at, C:'
\echo :'c'

CREATE TEMP TABLE f9_before AS
SELECT * FROM balance_sheet_at('t1', 'infinity', :'c'::xid8);

\echo
\echo '=== 2. BEFORE -- the issued statement, pinned at C'
SELECT tenant_id, currency, fs_line, caption, sort_order, amount_minor, side,
       pinned_cursor::text
FROM f9_before ORDER BY currency, sort_order;
SELECT count(*) AS rows, count(DISTINCT currency) AS currency_blocks FROM f9_before;

\echo
\echo '=== 3. open one account in a NEW currency and post NOTHING to it.'
\echo '===    due_from_treasury: an asset, counterparty_scope=shared, so a house'
\echo '===    account satisfies ck_accounts__per_shard_is_owned, and is_perimeter'
\echo '===    is false, so chart_lint stays quiet. uq_accounts__house is'
\echo '===    (tenant, purpose, currency), so this row collides with nothing.'
INSERT INTO ledger_accounts
       (tenant_id, owner_type, owner_id, purpose, category, normal_balance,
        counterparty_scope, currency)
VALUES ('t1','house',NULL,'due_from_treasury','asset','debit','shared','EUR');
SELECT tenant_id, purpose, currency, owner_type FROM ledger_accounts
WHERE currency = 'EUR';

\echo
\echo '=== 4. AFTER -- the SAME call, at the SAME literal cursor C'
SELECT tenant_id, currency, fs_line, caption, sort_order, amount_minor, side,
       pinned_cursor::text
FROM balance_sheet_at('t1', 'infinity', :'c'::xid8) ORDER BY currency, sort_order;
SELECT count(*) AS rows, count(DISTINCT currency) AS currency_blocks
FROM balance_sheet_at('t1', 'infinity', :'c'::xid8);

\echo
\echo '=== 5. what the statement GAINED: an entire EUR block plus its plug row'
SELECT * FROM (
    SELECT * FROM balance_sheet_at('t1','infinity', :'c'::xid8)
    EXCEPT ALL
    SELECT * FROM f9_before
) g ORDER BY currency, sort_order;

\echo
\echo '=== 6. what it LOST: nothing. The numbers are reproducible; only the shape'
\echo '===    moved.'
SELECT * FROM (
    SELECT * FROM f9_before
    EXCEPT ALL
    SELECT * FROM balance_sheet_at('t1','infinity', :'c'::xid8)
) l ORDER BY currency, sort_order;

\echo
\echo '=== 7. and every USD row is byte-identical in both directions'
SELECT count(*) AS usd_rows_that_moved FROM (
    (SELECT * FROM f9_before WHERE currency = 'USD'
     EXCEPT ALL
     SELECT * FROM balance_sheet_at('t1','infinity', :'c'::xid8) WHERE currency = 'USD')
    UNION ALL
    (SELECT * FROM balance_sheet_at('t1','infinity', :'c'::xid8) WHERE currency = 'USD'
     EXCEPT ALL
     SELECT * FROM f9_before WHERE currency = 'USD')
) d;

\echo
\echo '=== 8. income_statement_for reads the same scopes CTE, so it gains the'
\echo '===    same EUR block at the same pinned cursor'
SELECT tenant_id, currency, fs_line, amount_minor, side
FROM income_statement_for('t1','2026-08-01Z','2026-09-01Z', :'c'::xid8)
ORDER BY currency, sort_order;

\echo
\echo '=== 9. does any check notice? All ten, after the account was opened.'
SELECT * FROM reconciliation;
SELECT * FROM chart_lint ORDER BY severity, rule, subject;
