-- F6, stage 3 -- the three aggregates, read at the state the finding describes.
--
-- Everything the writer was asked to append in stage 2 (F6_run.sh) is in place:
-- one t3 transaction whose DEBIT legs sum to 2 * (2^63-1); two t3 PENDING
-- transactions putting 2 * (2^63-1) of pending debits on one account; and six t4
-- transactions putting one ceiling-sized debit on each of six stripes of one
-- account. Each of the three is exactly the state the finding says makes its
-- view raise `bigint out of range`.

\echo
\echo '########## what the writer actually wrote -- t3'
SELECT e.account_id, x.status, e.direction, e.amount_minor, e.stripe, e.account_seq
FROM ledger_entries e
JOIN ledger_transactions x ON x.tenant_id = e.tenant_id AND x.id = e.transaction_id
WHERE e.tenant_id = 't3' ORDER BY x.status, e.account_id, e.account_seq;

\echo
\echo '########## ...and t4: six stripes of ONE account, each row AT the bigint ceiling'
-- This is the reachability claim, and it holds: `ledger_account_balances` is
-- keyed per stripe (pk_balances carries it), each row holds 9223372036854775807
-- and is legal, and no single row is anywhere near overflow. The writer put them
-- there by itself -- one stripe per dispatcher index (ADR-0018 §1).
SELECT account_id, stripe, input, output, last_seq
FROM ledger_account_balances WHERE tenant_id = 't4' ORDER BY account_id, stripe;

\echo
\echo '=========================================================='
\echo '=== 1. the trial_balance VIEW, which sums bare bigint   ==='
\echo '=========================================================='
-- The claim: trial_balance GROUPs across stripes, so the six legal cache rows
-- above sum past bigint inside the view and the SELECT raises.
--
-- It does not raise. sum(bigint) is numeric in PostgreSQL, so `debits` is
-- 6 * (2^63-1) = 55340232221128654842 and the view reports it.
\x on
SELECT * FROM trial_balance WHERE tenant_id = 't4';
\x off

\echo
\echo '########## the same read through the grant a REPORT READER holds'
-- trial_balance is security_invoker and granted to openledger_read, so the role
-- an actual report runs as is the one that has to survive the read.
SET ROLE openledger_read;
SET app.tenant_id = 't4';
SELECT account_id, purpose, debits, credits, balance_minor, balance_debit_positive
FROM trial_balance;
RESET ROLE;
RESET app.tenant_id;

\echo
\echo '########## and the FUNCTION the finding holds up as the fixed one'
-- trial_balance_at sums `amount_minor::numeric` and then casts the total back to
-- satisfy its declared `RETURNS TABLE (... debits bigint ...)`. The cast is the
-- hazard the comment claims the cast removes: at this state the numeric-summing
-- function is the one that raises and the bare-bigint view is the one that
-- reports. Expected: ERROR: bigint out of range.
SELECT * FROM trial_balance_at('t4', '-infinity', 'infinity', report_cursor());

\echo '########## ...isolated to the cast, one half at a time'
-- The numeric SUM on its own returns the total. It is the `::bigint` the declared
-- return type forces that raises -- so the ADR-0013 comment has the direction of
-- the hazard backwards: casting to numeric moved the overflow from a running
-- accumulator (where PostgreSQL never put it) to the output conversion (where the
-- bare view has none).
SELECT a.id,
       COALESCE(SUM(e.amount_minor::numeric)
                FILTER (WHERE e.direction = 'debit'), 0) AS the_sum_alone
FROM ledger_entries e
JOIN ledger_transactions x ON x.tenant_id = e.tenant_id AND x.id = e.transaction_id
                          AND x.status = 'posted'
JOIN ledger_accounts a ON a.tenant_id = e.tenant_id AND a.id = e.account_id
                      AND a.currency = e.currency
WHERE a.tenant_id = 't4' GROUP BY a.id;

SELECT a.id,
       (COALESCE(SUM(e.amount_minor::numeric)
                 FILTER (WHERE e.direction = 'debit'), 0))::bigint AS the_same_sum_cast_back
FROM ledger_entries e
JOIN ledger_transactions x ON x.tenant_id = e.tenant_id AND x.id = e.transaction_id
                          AND x.status = 'posted'
JOIN ledger_accounts a ON a.tenant_id = e.tenant_id AND a.id = e.account_id
                      AND a.currency = e.currency
WHERE a.tenant_id = 't4' GROUP BY a.id;

\echo '########## ...and the two statement FUNCTIONS, which cast the same way'
-- income_statement_for casts each fs_line total back to bigint. balance_sheet_at
-- does too, and survives here only because revenue and expense net to zero on
-- this book, which is what stage 1 arranged on purpose.
SELECT fs_line, amount_minor
FROM income_statement_for('t4', '-infinity', 'infinity', report_cursor());
SELECT fs_line, amount_minor
FROM balance_sheet_at('t4', 'infinity', report_cursor());

\echo
\echo '=========================================================='
\echo "=== 2. recon_transaction_breaks' legs CTE               ==="
\echo '=========================================================='
-- The claim: one transaction's debit legs sum past bigint and the CTE raises.
--
-- The CTE is run here verbatim so the value is visible even while the view
-- filters the row out (debits = credits, so the transaction is not a break).
SELECT e.transaction_id, e.currency,
       COALESCE(SUM(e.amount_minor) FILTER (WHERE e.direction = 'debit'), 0)  AS debits,
       COALESCE(SUM(e.amount_minor) FILTER (WHERE e.direction = 'credit'), 0) AS credits,
       COUNT(*) AS leg_count,
       pg_typeof(COALESCE(SUM(e.amount_minor)
                          FILTER (WHERE e.direction = 'debit'), 0)) AS debits_type
FROM ledger_entries e
JOIN ledger_transactions x ON x.tenant_id = e.tenant_id AND x.id = e.transaction_id
WHERE e.tenant_id = 't3' AND x.status = 'posted'
GROUP BY e.tenant_id, e.transaction_id, e.currency;

\echo '########## the view over the whole deployment'
SELECT COUNT(*) AS break_rows FROM recon_transaction_breaks;

\echo
\echo '=========================================================='
\echo "=== 3. recon_pending_bridge' pend CTE                   ==="
\echo '=========================================================='
-- The claim: pending debits on one account sum past bigint and the CTE raises.
--
-- The pending population is the easiest of the three to reach, because a pending
-- entry advances `last_seq` and NOT `input`/`output` (ADR-0010: the cache means
-- posted) -- so the per-stripe cache ceiling never enters into it and no striping
-- is needed at all. Two ordinary HTTP calls put 2 * (2^63-1) on one stripe of one
-- account, and the bridge publishes an available balance of 3 * (2^63-1).
\x on
SELECT * FROM recon_pending_bridge WHERE tenant_id = 't3';
\x off

\echo
\echo '=========================================================='
\echo '=== the blast radius: what the operator query does      ==='
\echo '=========================================================='
-- trial_balance is read by recon_scope_breaks, which is counted by
-- reconciliation, so an overflowing trial_balance would take the sweep down with
-- it. There is no overflow, so it does not: ten rows, zero breaks.
SELECT * FROM reconciliation;
