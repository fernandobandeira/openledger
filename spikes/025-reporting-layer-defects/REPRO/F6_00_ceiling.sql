-- F6, stage 0 -- the ceiling, read off the schema rather than guessed at.
--
-- The finding under test says the `::numeric` lesson written into
-- trial_balance_at and recon_balance_breaks was missed in three other
-- aggregates -- the trial_balance VIEW, recon_transaction_breaks' `legs` CTE
-- and recon_pending_bridge' `pend` CTE -- and that a bare `SUM(amount_minor)`
-- there overflows a running bigint and raises the whole SELECT.
--
-- Two numbers decide whether that is possible at all: what one legal entry can
-- be, and what one cache row can hold. Both are constraints, so both are
-- queryable.

\echo
\echo '########## what constrains ledger_entries.amount_minor'
-- bigint, and a CHECK that bounds it BELOW and not above. There is no upper
-- CHECK anywhere on this column, so the legal range of one entry is
-- [1, 9223372036854775807] -- 1 to 2^63-1 -- and the writer's own domain type
-- (crates/ledger/src/domain.rs) adds only `amount_minor <= 0` as a refusal.
SELECT a.attname AS column, format_type(a.atttypid, a.atttypmod) AS type,
       c.conname AS constraint, pg_get_constraintdef(c.oid) AS definition
FROM pg_attribute a
LEFT JOIN pg_constraint c
       ON c.conrelid = a.attrelid AND a.attnum = ANY (c.conkey) AND c.contype = 'c'
WHERE a.attrelid = 'ledger_entries'::regclass AND a.attname = 'amount_minor';

\echo
\echo '########## ...and ledger_account_balances.input / output'
-- Also bigint, also bounded only below (ck_balances__non_negative). One stripe
-- of one account can therefore hold at most 2^63-1 on each side, and the
-- writer's upsert is `input = input + EXCLUDED.input` at bigint, so the cache
-- row is the ceiling the WRITE PATH runs into first.
SELECT a.attname AS column, format_type(a.atttypid, a.atttypmod) AS type,
       c.conname AS constraint, pg_get_constraintdef(c.oid) AS definition
FROM pg_attribute a
LEFT JOIN pg_constraint c
       ON c.conrelid = a.attrelid AND a.attnum = ANY (c.conkey) AND c.contype = 'c'
WHERE a.attrelid = 'ledger_account_balances'::regclass
  AND a.attname IN ('input', 'output')
ORDER BY a.attname, c.conname;

\echo
\echo '########## the arithmetic: how many maximal entries overflow a bigint sum'
-- Two. 2^63-1 is the largest legal entry and the largest a stripe can hold, so
-- N maximal entries spread over S stripes need ceil(N/S) <= 1 for every cache
-- row to stay legal -- one maximal entry per stripe -- while the sum the three
-- unprotected views take is N * (2^63-1). N=2 already exceeds bigint; the
-- reachability question is therefore only whether two stripes of one account
-- can each hold one maximal entry, and ck_accounts__stripe_count (1..1024) says
-- an account may have up to 1024 of them.
SELECT 9223372036854775807::numeric              AS one_maximal_entry,
       9223372036854775807::numeric * 2          AS two_of_them,
       9223372036854775807::numeric * 2 > 9223372036854775807 AS past_bigint;

\echo
\echo '########## THE FACT THE FINDING TURNS ON: what type does SUM(bigint) have'
-- PostgreSQL's sum() over bigint returns NUMERIC, not bigint. The aggregate
-- accumulates in numeric and cannot overflow -- so a bare `SUM(amount_minor)`
-- is already unbounded, and the `::numeric` in trial_balance_at is a
-- CONVERSION for its declared bigint return type, not a protection.
SELECT pg_typeof(SUM(x))            AS sum_of_bigint,
       pg_typeof(SUM(x::numeric))   AS sum_of_numeric,
       pg_typeof(x + x)             AS bigint_plus_bigint
FROM (VALUES (1::bigint)) v(x) GROUP BY x;

\echo
\echo '########## ...and so the three "unprotected" views already publish numeric'
-- Read from the catalogue, not from the migration text. The committed schema
-- snapshot (schema/snapshot.txt) records the same three lines.
SELECT c.relname AS view, a.attname AS column,
       format_type(a.atttypid, a.atttypmod) AS type
FROM pg_class c
JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
WHERE c.relname IN ('trial_balance', 'recon_transaction_breaks', 'recon_pending_bridge')
  AND a.attname IN ('debits', 'credits', 'balance_minor', 'balance_debit_positive',
                    'imbalance_minor', 'pending_debits', 'pending_credits',
                    'posted_balance_minor', 'pending_balance_minor',
                    'available_balance_minor')
ORDER BY c.relname, a.attnum;
