-- Spike 024 -- the bounded checkpoint reconciliation.
--
-- Today's recon_checkpoint_breaks joins EACH close to EVERY entry with
-- effective_at < that close's ends_at, so close k re-aggregates the whole prefix
-- up to period k and the total work is O(entries x closes) -- measured
-- 1 : 3.2 : 5.8 : 8.2 over 3/6/9/12 closes (spike 020).
--
-- THE OBSERVATION THAT BOUNDS IT. The checkpoint is CUMULATIVE: the recompute has
-- no lower bound on effective_at, so consecutive checkpoints differ by exactly
-- one close's own arrivals. So instead of recomputing C levels, assign each entry
-- the index of the FIRST close whose checkpoint contains it -- one number per
-- entry, one pass -- and compare the DIFFERENCE of consecutive stored levels
-- against the sum of the entries assigned to that index.
--
-- The assignment is O(log C) per entry, not O(C): the two bounds are monotone
-- (period ends increase, and computed_at_xid is a captured pg_snapshot_xmin,
-- which is non-decreasing), so
--     first close whose end is above this entry's effective_at
--       = width_bucket(effective_at, <the ends, ascending>) + 1
--     first close whose cursor is above this entry's xact_id
--       = width_bucket(xact_id, <the cursors, in the same order>) + 1
-- and the entry enters at the LATER of the two. width_bucket over an array is a
-- binary search; xid8 has a default btree opclass (verified), so it works on the
-- cursor axis too.
--
-- WHAT IT COSTS IN COVERAGE, and it is not nothing. Comparing differences is
-- equivalent to comparing levels ONLY if the stored levels form a complete,
-- ordered run per account -- so the difference comparison alone LOSES a drift
-- class that the level comparison catches: a deleted TRAILING row for an account
-- with no arrivals in that period produces no difference to disagree with. That
-- is not hypothetical; it is measured in sql/55_drift_classes.sql. The presence
-- check below is what restores it, and it is O(stored rows) -- which is the floor
-- for any check that inspects every stored row at all.
--
-- :idterm is 'ci.k' when the close's own transaction is admitted to its own
-- checkpoint BY IDENTITY (the proposal), and 'NULL::bigint' when it is not (the
-- shipped strict bound). Nothing else differs between the two readings.
\set ON_ERROR_STOP on

CREATE OR REPLACE VIEW cl_indexed AS
SELECT c.tenant_id, c.currency, c.period_code, c.ends_at, c.computed_at_xid,
       c.transaction_id,
       row_number() OVER (PARTITION BY c.tenant_id, c.currency ORDER BY c.ends_at)::bigint AS k
FROM ledger_period_closes c;

-- The per-(tenant, currency) boundary arrays, ordered by period end. THE ORDER
-- IS THE INVARIANT: `curs` is only monotone if closing in period order also
-- closes in cursor order, which nothing in the schema says. recon_close_order
-- below is the check that says it.
CREATE OR REPLACE VIEW cl_arrays AS
SELECT tenant_id, currency, count(*)::int AS n,
       array_agg(ends_at         ORDER BY k) AS ends,
       array_agg(computed_at_xid ORDER BY k) AS curs
FROM cl_indexed
GROUP BY tenant_id, currency;

CREATE OR REPLACE VIEW recon_checkpoint_breaks_bounded AS
-- MATERIALIZED, both of them. Referenced as plain views the two close indexes are
-- re-planned at every reference -- seven WindowAgg nodes in the first draft's plan
-- -- and the planner's estimate for the whole view was dominated by that rather
-- than by the single pass over ledger_entries it was designed around. They are a
-- dozen rows; compute them once.
WITH cl AS MATERIALIZED (SELECT * FROM cl_indexed),
arr AS MATERIALIZED (SELECT * FROM cl_arrays),
last_k AS MATERIALIZED (
    SELECT tenant_id, currency, MAX(k) AS last_k FROM cl GROUP BY tenant_id, currency
),
banded AS (
    -- ONE PASS over ledger_entries. `j` is the index of the first close whose
    -- checkpoint contains this entry, or NULL if no close does (an entry
    -- effective beyond the last close boundary).
    SELECT e.tenant_id, e.currency, e.account_id,
           CASE WHEN e.direction = 'debit'  THEN e.amount_minor ELSE 0 END AS dr,
           CASE WHEN e.direction = 'credit' THEN e.amount_minor ELSE 0 END AS cr,
           -- LEAST ignores NULLs in PostgreSQL, so the identity term can only
           -- pull the index EARLIER and is inert for an ordinary entry.
           LEAST(
             NULLIF(GREATEST(width_bucket(e.effective_at, a.ends)::bigint + 1,
                             width_bucket(e.xact_id,      a.curs)::bigint + 1),
                    a.n::bigint + 1),
             :idterm
           ) AS j
    FROM ledger_entries e
    JOIN ledger_transactions x
      ON x.tenant_id = e.tenant_id AND x.id = e.transaction_id AND x.status = 'posted'
    JOIN arr a ON a.tenant_id = e.tenant_id AND a.currency = e.currency
    LEFT JOIN cl ci
      ON ci.tenant_id = e.tenant_id AND ci.currency = e.currency
     AND ci.transaction_id = e.transaction_id
), arrivals AS (
    SELECT tenant_id, currency, account_id, j,
           SUM(dr) AS dr, SUM(cr) AS cr
    FROM banded WHERE j IS NOT NULL
    GROUP BY tenant_id, currency, account_id, j
), stored AS (
    SELECT b.tenant_id, b.currency, b.account_id, b.period_code, k.k,
           b.input, b.output,
           b.input  - COALESCE(lag(b.input)  OVER w, 0) AS d_in,
           b.output - COALESCE(lag(b.output) OVER w, 0) AS d_out,
           lag(k.k) OVER w AS prev_k
    FROM ledger_period_balances b
    JOIN cl k
      ON k.tenant_id = b.tenant_id AND k.currency = b.currency
     AND k.period_code = b.period_code
    WINDOW w AS (PARTITION BY b.tenant_id, b.currency, b.account_id ORDER BY k.k)
), span AS (
    -- THE PRESENCE HALF. The checkpoint is cumulative, so once an account has a
    -- stored row at close k it must have one at every later close of that
    -- (tenant, currency): the account set is non-decreasing in the period end.
    -- A gap, or a missing trailing row, is drift the difference comparison
    -- cannot see -- this is what keeps the bounded form's coverage equal to the
    -- level form's. O(stored rows) and touches no entry.
    SELECT s.tenant_id, s.currency, s.account_id,
           MIN(s.k) AS first_k, COUNT(*) AS rows_present, MAX(lk.last_k) AS last_k
    FROM stored s
    JOIN last_k lk ON lk.tenant_id = s.tenant_id AND lk.currency = s.currency
    GROUP BY s.tenant_id, s.currency, s.account_id
)
-- 1. the arithmetic: each close's own arrivals against the difference of levels
SELECT COALESCE(s.tenant_id, r.tenant_id)   AS tenant_id,
       COALESCE(s.period_code, rk.period_code) AS period_code,
       COALESCE(s.currency,   r.currency)   AS currency,
       COALESCE(s.account_id, r.account_id) AS account_id,
       COALESCE(s.d_in,  0)  AS stored_input,
       COALESCE(s.d_out, 0)  AS stored_output,
       COALESCE(r.dr,    0)  AS recomputed_input,
       COALESCE(r.cr,    0)  AS recomputed_output,
       CASE WHEN s.account_id IS NULL THEN 'missing_row'
            WHEN r.account_id IS NULL THEN 'spurious_row'
            ELSE 'value_drift' END AS reason
FROM stored s
FULL JOIN arrivals r
  ON r.tenant_id = s.tenant_id AND r.currency = s.currency
 AND r.account_id = s.account_id AND r.j = s.k
LEFT JOIN cl rk ON rk.tenant_id = r.tenant_id AND rk.currency = r.currency AND rk.k = r.j
-- COMPARE VALUES, not presence (A11, kept): a close that wrote a 0/0 row for a
-- dormant account has a stored row and no arrivals, and 0 = 0 is not a break.
WHERE COALESCE(s.d_in,  0) <> COALESCE(r.dr, 0)
   OR COALESCE(s.d_out, 0) <> COALESCE(r.cr, 0)
UNION ALL
-- 2. the presence half
SELECT sp.tenant_id, spk.period_code,
       sp.currency, sp.account_id,
       sp.rows_present, sp.last_k - sp.first_k + 1, 0::bigint, 0::bigint,
       'row_span' AS reason
FROM span sp
LEFT JOIN cl spk ON spk.tenant_id = sp.tenant_id AND spk.currency = sp.currency
                AND spk.k = sp.last_k
WHERE sp.rows_present <> sp.last_k - sp.first_k + 1;


-- ----------------------------------------------------------------------
-- The invariants the bounded form needs and the schema does not state.
--
-- Both are O(closes) and neither touches ledger_entries. They are not overhead
-- on the bounded form: the first is what makes the AT-CLOSE claim in ADR-0011 §3
-- true rather than accidental, and the second is what makes the difference
-- comparison equivalent to the level comparison.
CREATE OR REPLACE VIEW recon_close_order AS
WITH seq AS (
    SELECT k.*, x.xact_id AS txn_xact_id,
           lag(k.computed_at_xid) OVER w AS prev_cursor,
           lag(k.ends_at)         OVER w AS prev_ends,
           lag(k.period_code)     OVER w AS prev_period
    FROM cl_indexed k
    JOIN ledger_transactions x
      ON x.tenant_id = k.tenant_id AND x.id = k.transaction_id
    WINDOW w AS (PARTITION BY k.tenant_id, k.currency ORDER BY k.k)
), prev_txn AS (
    SELECT s.*, px.xact_id AS prev_txn_xact_id
    FROM seq s
    LEFT JOIN cl_indexed pk
      ON pk.tenant_id = s.tenant_id AND pk.currency = s.currency AND pk.period_code = s.prev_period
    LEFT JOIN ledger_transactions px
      ON px.tenant_id = pk.tenant_id AND px.id = pk.transaction_id
)
SELECT tenant_id, currency, period_code, computed_at_xid, txn_xact_id, prev_cursor,
       prev_txn_xact_id, reason
FROM prev_txn, LATERAL (
    SELECT r FROM unnest(ARRAY[
        -- (i) closing in period order must also close in cursor order, or the
        -- stored levels stop nesting and a DIFFERENCE is not a difference of
        -- nested sets.
        CASE WHEN prev_cursor IS NOT NULL AND computed_at_xid < prev_cursor
             THEN 'cursor_not_monotone' END,
        -- (ii) the previous close's OWN entries must be below this close's
        -- cursor, or this checkpoint silently omits the previous sweep and is
        -- not the at-close position either. This is the condition that turns
        -- ADR-0011 A4's prose into a fact.
        CASE WHEN prev_txn_xact_id IS NOT NULL AND prev_txn_xact_id >= computed_at_xid
             THEN 'previous_close_above_cursor' END,
        -- (iii) a cursor ABOVE the close's own commit position cannot have been
        -- captured by the close: pg_snapshot_xmin is <= the caller's own xid
        -- whenever the caller holds one. This is the INVERSE of the shipped
        -- recon_close_breaks predicate, which refuses a cursor BELOW the close.
        CASE WHEN computed_at_xid > txn_xact_id THEN 'cursor_above_close' END,
        -- (iv) and a cursor above the current horizon was never captured at all
        -- -- the same forgery recon_cursor_breaks refuses for an entry, applied
        -- to the one xid8 column that sits under a TABLE-WIDE insert grant.
        CASE WHEN computed_at_xid > pg_snapshot_xmin(pg_current_snapshot())
             THEN 'cursor_above_horizon' END
    ]) AS r WHERE r IS NOT NULL
) AS b(reason);
