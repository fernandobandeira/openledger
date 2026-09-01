-- 00004 -- the report path reads the checkpoint, and the reporting layer stops
-- claiming things that are not true.
--
-- ADR-0020 (site/content/decisions/0020-checkpoint-on-the-report-path.md) is the
-- specification; spike 024 designed and proved the report path and the bounded
-- checkpoint check, spike 025 reproduced the eight reporting defects that ship in
-- the same unit. ADR-0020 amends ADR-0011 §3 (whose at-close sentence is not
-- merely unbuilt but unsatisfiable as specified) and ADR-0007 §2 (whose snapshot
-- test cannot see a partition detached).
--
-- Nothing here edits 00001 or 00003: ADR-0003's freeze is CI-enforced with no
-- opt-out (scripts/check-migrations-immutable.sh), so a correction to a shipped
-- comment is a new COMMENT statement in a new migration, which is why part 7
-- exists at all.
--
-- THE PARTS, AND WHY THE ORDER IS FORCED (spike 024's PROPOSAL.sql documents the
-- same constraint; the two errors that force it are quoted in part 0):
--
--   0. teardown -- the summary, and the objects whose SHAPE changes
--   1. what the close must store (specification; no DDL -- nothing writes a close)
--   2. recon_checkpoint_breaks: bounded, and the close admitted by identity  \
--   3. close_disclosures, its exact complement                              | one
--   4. the sweep -- close typing, the cursor horizon, the empty close, the   | unit
--      two chart rules                                                      /
--   5. the report path -- the anchor, the position, and the three statements
--   6. the summary, rebuilt, and its grants
--   7. the comments that were false
--
-- Why 2, 3 and the close's arithmetic cannot be split: the checkpoint is
-- AT-CLOSE, so the recompute must admit the closing transaction and the
-- disclosure must exclude it. Admit it in one and not the other and the two
-- together either double-count the closing legs or lose them. Spike 024 measured
-- the half-landed case at 12 break rows on its book, falling to 0 when the pair
-- lands together (FINDINGS §1.6).
--
-- WHAT IS DELIBERATELY NOT HERE, each with the decision that defers it:
--
--  * PARTITIONING ledger_period_balances BY LIST (period_code). Legal, designed
--    and proven (spike 024 §5); ADR-0020 defers adoption to a measurement pass,
--    because the mechanism predicts ~0 saving on a first close. The snapshot's
--    new partition section (crates/e2e/tests/e2e/schema_snapshot.rs) ships anyway
--    -- ADR-0020 rules it in "whether or not partitioning is adopted", because a
--    DETACH is invisible to the dump for ANY table today.
--  * THE TWO TAIL INDEXES (ix_entries__tenant_effective, ix_entries__tenant_commit).
--    ADR-0020's decision rule is written and not yet applied: they are on the hot
--    write path, and "more than 5% off clearings/s and they do not ship". No
--    timing pass has run, so they do not ship. Tail B is already served by
--    PostgreSQL 18's skip scan on ix_entries__asof_commit; tail A gets a
--    sequential scan, which is a defensible outcome rather than a failure.
--  * trial_balance_at AS prefix(to) - prefix(from). Refused by ADR-0020: correct
--    on a normal window and WRONG on an inverted one (negative gross debits where
--    the shipped body returns nothing). Its body here is the baseline's,
--    unchanged except for the return type.
--  * recon_journal_to_reports' window fix and its out-of-window disclosure row.
--    They change EXPECTED_CHECKS from 10 to 11 and must land as a PAIR with the
--    summary-survives-a-failing-check change (spike 025 F4/F5), or
--    journal_to_reports is left with no reachable red path. Migration 00005.
--  * THE CHART-VERSION SEAL (spike 025 F7). A new table, a trigger change and
--    both statement bodies; a decision, not a fix.
--  * A COLUMN-LEVEL INSERT GRANT ON ledger_period_closes withholding
--    computed_at_xid (spike 025 F8's second half). It forecloses a design option
--    -- a close that computes in one transaction and records in another could not
--    then state the cursor it used -- and the fix notes say it should wait for
--    that answer. The bound in part 4a is the half that does not.


-- ======================================================================
-- PART 0 -- TEARDOWN, and why it is a part rather than a line
-- ======================================================================
--
-- `reconciliation` is the operator interface and it pins eight of the objects
-- below, so it comes down first and goes back up last -- and part 6 re-issues its
-- GRANT, because a dropped view takes its ACL with it and openledger_recon reads
-- that view for a living.
--
-- Three things cannot be CREATE OR REPLACEd, and the catalog says so:
--
--   recon_close_breaks   -- its column list grows (prev_cursor, prev_txn_xact_id)
--   the three statements -- their RETURNS TABLE changes bigint -> numeric, and a
--                           changed return type cannot be replaced
--
-- MEASURED, both directions:
--     DROP VIEW recon_close_breaks;
--     ERROR:  cannot drop view recon_close_breaks because other objects depend on it
--     DETAIL:  view reconciliation depends on view recon_close_breaks
--
--     DROP FUNCTION recon_equation_breaks(xid8, timestamptz);
--     ERROR:  cannot drop function recon_equation_breaks(...) because other objects depend on it
--     DETAIL:  view reconciliation depends on function recon_equation_breaks(...)
--
-- recon_equation_breaks is dropped and recreated even though the catalog does NOT
-- force it: it is a string-bodied LANGUAGE sql function, so PostgreSQL records no
-- dependency on balance_sheet_at at all -- verified, `SELECT ... FROM pg_depend
-- WHERE refobjid = 'balance_sheet_at'::regproc` returns zero rows, and the DROP
-- succeeds with the equation function standing. It is recreated anyway for three
-- reasons that are not the catalog's: the summary that DOES pin it has to come
-- down for recon_close_breaks; its header comment is false (part 7); and the
-- REVOKE in part 5f wants to start from a known ACL rather than from whatever a
-- deployment has granted since.
--
-- recon_checkpoint_breaks, close_disclosures, recon_cursor_breaks,
-- recon_transaction_breaks and chart_lint keep their column lists exactly, so
-- they are CREATE OR REPLACEd in place and keep their owner and their grants.
DROP VIEW reconciliation;
DROP VIEW recon_close_breaks;
DROP FUNCTION recon_equation_breaks(xid8, timestamptz);
DROP FUNCTION balance_sheet_at(text, timestamptz, xid8, int);
DROP FUNCTION income_statement_for(text, timestamptz, timestamptz, xid8, int);
DROP FUNCTION trial_balance_at(text, timestamptz, timestamptz, xid8);


-- ======================================================================
-- PART 1 -- WHAT THE CLOSE MUST STORE  (specification; there is no DDL here)
-- ======================================================================
--
-- NOTHING IN THIS REPOSITORY WRITES A CLOSE. `grep -rn period_close crates/`
-- finds the reverse gate's refusal and two e2e fixtures, and no writer. So this
-- part is a specification the write path has to satisfy when it grows one, and it
-- is written here rather than in a Rust comment because parts 2, 3 and 5 are
-- unsound without it.
--
-- THE INVARIANT: ledger_period_balances holds the AT-CLOSE position -- closing
-- entries INCLUDED, so a temporary account's row is exactly 0 and the earnings
-- account carries the swept earnings. ADR-0011 §3 (A4), the table's own comment
-- and recon_close_breaks' header all assert it; the mechanism they assert it
-- THROUGH does not exist.
--
-- WHY IT CANNOT BE DONE WITH AN INEQUALITY, which is ADR-0020's central proof.
-- computed_at_xid must be a value below which the visible set is fixed for all
-- time, and ADR-0011 §1 proves pg_snapshot_xmin is the only such value here.
-- pg_snapshot_xmin is at or below the caller's own xid whenever the caller holds
-- one, so a cursor ABOVE the closing transaction's own entries is unreachable
-- from the transaction that writes them. Binding pg_current_xact_id() instead
-- makes the inequality work and destroys reproducibility: measured, an older
-- writer committing after the close makes the checkpoint reader LOSE a real
-- posting -- 10,570 read as 10,500 (spike 024 FINDINGS §1.3). There is no third
-- value: pg_snapshot_xmax admits in-flight transactions that commit later, and
-- xid8 has no successor operator.
--
-- THE MECHANISM: the close's transaction is ALREADY NAMED, in
-- ledger_period_closes.transaction_id under fk_closes__txn, fk_closes__txn_kind
-- and uq_closes__txn. So it does not need to be reachable through the cursor at
-- all, and the cursor keeps its one job -- bounding everything else.
--
--     INSERT INTO ledger_period_balances (tenant_id, period_code, currency,
--                                         account_id, input, output)
--     SELECT :tenant, :period, :currency, e.account_id,
--            COALESCE(SUM(e.amount_minor) FILTER (WHERE e.direction='debit'), 0),
--            COALESCE(SUM(e.amount_minor) FILTER (WHERE e.direction='credit'),0)
--     FROM ledger_entries e
--     JOIN ledger_transactions x ON x.tenant_id = e.tenant_id AND x.id = e.transaction_id
--                               AND x.status = 'posted'
--     WHERE e.tenant_id = :tenant AND e.currency = :currency
--       AND e.effective_at < :ends_at
--       AND (e.xact_id < :computed_at_xid OR e.transaction_id = :closing_txn)
--     GROUP BY e.account_id;
--
-- TWO ORDERING CONSTRAINTS ON THE CLOSE, both new:
--
--  (a) the checkpoint is written AFTER the closing entries, so they exist to be
--      aggregated. Write it first and the stored row is the PRE-close position,
--      which is what spike 024 measured the shipped helper doing: fee_revenue
--      stored at -500 with no earnings row written at all (FINDINGS §1.2).
--
--  (b) the close must refuse to run while the cluster horizon has not cleared
--      the PREVIOUS close's own transaction. Otherwise this checkpoint silently
--      omits the previous sweep, is not the at-close position either, and the
--      bounded check in part 2 is unsound. A precondition in the writer, not a
--      trigger -- pg_snapshot_xmin(pg_current_snapshot()) > the previous close's
--      transaction's xact_id -- and recon_close_order (part 4a) is what catches a
--      close that ran anyway.
--
-- WHAT THIS DOES NOT DO: it does not make the checkpoint see rows that were
-- uncommitted when the close ran. Those arrive at or above computed_at_xid and
-- are the tail term, exactly as before -- and close_disclosures enumerates them.


-- ======================================================================
-- PART 2 -- recon_checkpoint_breaks: bounded, and the close admitted by IDENTITY
-- ======================================================================
--
-- Two changes in one body, because they are one body.
--
-- (i) THE CLOSE IS ADMITTED BY TRANSACTION IDENTITY. The shipped recompute bounds
-- every entry by `e.xact_id < c.computed_at_xid`, which by part 1's proof cannot
-- include the closing legs -- so the stored row it agrees with is the PRE-close
-- position, and A4's prose was false. The bound is not relaxed to `<=` either:
-- ADR-0020 tested that and REFUSED it, because `<=` is equivalent to equality
-- only when computed_at_xid EQUALS the closing transaction's own xid, which
-- happens only on an idle cluster (measured 16132 against 16134 with one other
-- writer running) and the value that forces equality is not a reproducible
-- cursor. Naming the transaction needs no relationship between the two values at
-- all, which is why it is the mechanism rather than the inequality.
--
-- In the bounded form below the identity admission is the `ci.k` term inside
-- LEAST: an entry belonging to close k's own transaction bands to k+1 on the
-- cursor axis (its xact_id is at or above close k's cursor) and the identity term
-- pulls it back to k. Drop that term and every close reports drift.
--
-- (ii) IT IS BOUNDED. The shipped level form joins EACH close to EVERY entry
-- effective before that close's end, so close k re-aggregates the whole prefix up
-- to period k: measured growing 1 : 3.2 : 5.8 : 8.2 over 3/6/9/12 closes (spike
-- 020). THE OBSERVATION THAT BOUNDS IT: the checkpoint is CUMULATIVE -- the
-- recompute has no lower bound on effective_at -- so consecutive checkpoints
-- differ by exactly one close's own arrivals. Assign each entry the index of the
-- FIRST close whose checkpoint contains it (one number, one pass over
-- ledger_entries) and compare the DIFFERENCE of consecutive stored levels against
-- the entries at that index.
--
-- The assignment is O(log C) per entry, not O(C), because both bounds are
-- monotone under recon_close_order (part 4a):
--     first close whose end is above this entry's effective_at
--        = width_bucket(effective_at, <the ends ascending>) + 1
--     first close whose cursor is above this entry's xact_id
--        = width_bucket(xact_id, <the cursors, same order>) + 1
-- and the entry enters at the LATER of the two. width_bucket over an array is a
-- binary search; xid8 carries a default btree opclass (xid8_ops), so it works on
-- the commit axis too. LEAST ignores NULLs in PostgreSQL, so the identity term
-- can only pull the index earlier and is inert for an ordinary entry.
--
-- THE TWO CTEs ARE MATERIALIZED DELIBERATELY. As plain references the close index
-- is re-planned at every use -- seven WindowAgg nodes -- and the planner's
-- estimate for the whole view was 8x higher, dominated by that rather than by the
-- single pass the design is about. They are a dozen rows.
--
-- WHY BOTH HALVES SHIP, and the second is not belt and braces. Comparing
-- DIFFERENCES loses a drift class the level form catches: a DELETED TRAILING row
-- for an account with no arrivals in that period gives a stored difference of 0
-- against recomputed arrivals of 0, and there is nothing to disagree about.
-- MEASURED: without the presence half the bounded form reports 0 where the level
-- form reports 1; with it, 1 and 1 (spike 024 FINDINGS §3.2). The presence half
-- is O(stored rows) and touches no entry, which is the floor for any check that
-- looks at every stored row at all.
--
-- WHAT THIS VIEW IS NOT SOUND WITHOUT: recon_close_order being green. An
-- out-of-order close makes the stored levels stop nesting, so a DIFFERENCE of
-- levels is not a difference of nested sets, and this view reports FALSE
-- value_drift -- measured 18/18/0 rows in order against 0/2/2 out of order
-- (FINDINGS §3.4). That is why part 4a ships the invariant as its own reason
-- rather than leaving it implied.
--
-- WHAT ELSE IT DOES NOT DO: it does not report the same ROW COUNT or the same
-- reason LABELS as the level form it replaces. A single forged value produces TWO
-- rows -- the difference at close k and at k+1 -- and the second is labelled
-- `spurious_row` because it has no arrivals row to pair with. More sensitive,
-- less precisely worded, and an operator-contract change that is written down
-- here rather than discovered in an incident.
--
-- A11 IS KEPT: compare VALUES, not presence. A dormant account for which the
-- close wrote a 0/0 row has a stored row and no arrivals row, and 0 = 0 is not a
-- break.
CREATE OR REPLACE VIEW recon_checkpoint_breaks AS
WITH cl AS MATERIALIZED (
    SELECT c.tenant_id, c.currency, c.period_code, c.ends_at, c.computed_at_xid,
           c.transaction_id,
           row_number() OVER (PARTITION BY c.tenant_id, c.currency
                              ORDER BY c.ends_at)::bigint AS k
    FROM ledger_period_closes c
), arr AS MATERIALIZED (
    SELECT tenant_id, currency, count(*)::int AS n,
           array_agg(ends_at         ORDER BY k) AS ends,
           array_agg(computed_at_xid ORDER BY k) AS curs
    FROM cl GROUP BY tenant_id, currency
), last_k AS MATERIALIZED (
    SELECT tenant_id, currency, MAX(k) AS last_k FROM cl GROUP BY tenant_id, currency
), banded AS (
    SELECT e.tenant_id, e.currency, e.account_id,
           CASE WHEN e.direction = 'debit'  THEN e.amount_minor ELSE 0 END AS dr,
           CASE WHEN e.direction = 'credit' THEN e.amount_minor ELSE 0 END AS cr,
           LEAST(
             NULLIF(GREATEST(width_bucket(e.effective_at, a.ends)::bigint + 1,
                             width_bucket(e.xact_id,      a.curs)::bigint + 1),
                    a.n::bigint + 1),
             ci.k
           ) AS j
    FROM ledger_entries e
    JOIN ledger_transactions x
      ON x.tenant_id = e.tenant_id AND x.id = e.transaction_id AND x.status = 'posted'
    JOIN arr a ON a.tenant_id = e.tenant_id AND a.currency = e.currency
    LEFT JOIN cl ci
      ON ci.tenant_id = e.tenant_id AND ci.currency = e.currency
     AND ci.transaction_id = e.transaction_id
), arrivals AS (
    SELECT tenant_id, currency, account_id, j, SUM(dr) AS dr, SUM(cr) AS cr
    FROM banded WHERE j IS NOT NULL
    GROUP BY tenant_id, currency, account_id, j
), stored AS (
    SELECT b.tenant_id, b.currency, b.account_id, b.period_code, k.k,
           b.input  - COALESCE(lag(b.input)  OVER w, 0) AS d_in,
           b.output - COALESCE(lag(b.output) OVER w, 0) AS d_out
    FROM ledger_period_balances b
    JOIN cl k
      ON k.tenant_id = b.tenant_id AND k.currency = b.currency
     AND k.period_code = b.period_code
    WINDOW w AS (PARTITION BY b.tenant_id, b.currency, b.account_id ORDER BY k.k)
), span AS (
    -- THE PRESENCE HALF. The checkpoint is cumulative, so once an account has a
    -- stored row at close k it must have one at every LATER close of that
    -- (tenant, currency): the account set is non-decreasing in the period end.
    SELECT s.tenant_id, s.currency, s.account_id,
           MIN(s.k) AS first_k, COUNT(*) AS rows_present, MAX(lk.last_k) AS last_k
    FROM stored s
    JOIN last_k lk ON lk.tenant_id = s.tenant_id AND lk.currency = s.currency
    GROUP BY s.tenant_id, s.currency, s.account_id
)
SELECT COALESCE(s.tenant_id, r.tenant_id)      AS tenant_id,
       COALESCE(s.period_code, rk.period_code) AS period_code,
       COALESCE(s.currency,   r.currency)      AS currency,
       COALESCE(s.account_id, r.account_id)    AS account_id,
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
LEFT JOIN cl rk
  ON rk.tenant_id = r.tenant_id AND rk.currency = r.currency AND rk.k = r.j
WHERE COALESCE(s.d_in,  0) <> COALESCE(r.dr, 0)
   OR COALESCE(s.d_out, 0) <> COALESCE(r.cr, 0)
UNION ALL
SELECT sp.tenant_id, spk.period_code, sp.currency, sp.account_id,
       sp.rows_present, sp.last_k - sp.first_k + 1, 0::numeric, 0::numeric,
       'row_span' AS reason
FROM span sp
LEFT JOIN cl spk
  ON spk.tenant_id = sp.tenant_id AND spk.currency = sp.currency AND spk.k = sp.last_k
WHERE sp.rows_present <> sp.last_k - sp.first_k + 1;


-- ======================================================================
-- PART 3 -- close_disclosures: the exact complement of part 2's bound
-- ======================================================================
--
-- This view is defined as "everything the checkpoint did NOT see", so it moves
-- with part 2 or the two together will both include, or both exclude, the closing
-- entries -- and the closing legs are then counted twice or lost.
--
-- The narrow `e.transaction_id <> c.transaction_id` is what excludes THIS close's
-- own legs. THE WIDE NOT EXISTS OVER ALL CLOSES IS KEPT, and the reason is
-- measured rather than cautious: on a book whose closes of one (tenant, currency)
-- are in period order the wide carve-out is DEAD -- 18 rows with it, 18 without,
-- 0 rows only-without. On a book with an OUT-OF-ORDER close it is live: 0 with, 2
-- without, and the two are the earlier close's own legs (spike 024 FINDINGS
-- §3.4). It is dead exactly when recon_close_order is green, and a carve-out
-- whose deadness depends on another check's greenness is not one to delete.
CREATE OR REPLACE VIEW close_disclosures AS
SELECT c.tenant_id, c.period_code, c.currency, c.computed_at_xid,
       e.id AS entry_id, e.transaction_id, e.account_id, e.direction,
       e.amount_minor, e.effective_at, e.xact_id, e.recorded_at
FROM ledger_period_closes c
JOIN ledger_entries e
  ON e.tenant_id = c.tenant_id AND e.currency = c.currency
 AND e.effective_at < c.ends_at
 AND e.xact_id >= c.computed_at_xid
 AND e.transaction_id <> c.transaction_id
JOIN ledger_transactions x
  ON x.tenant_id = e.tenant_id AND x.id = e.transaction_id AND x.status = 'posted'
WHERE NOT EXISTS (SELECT 1 FROM ledger_period_closes c2
                  WHERE c2.tenant_id = x.tenant_id AND c2.transaction_id = x.id);


-- ======================================================================
-- PART 4 -- THE SWEEP: four reasons added, one horizon fixed, one carve-out,
--           two chart rules
-- ======================================================================

-- ----------------------------------------------------------------------
-- 4a. recon_close_breaks gains FOUR reasons and keeps the one it had
--
-- The check count stays at TEN. This view already returns a `reason` column, so
-- everything below reaches the operator through `close_typing` -- which is the
-- cheapest place to put a journal-shaped lint that has no key
-- (spike 025 FIX-NOTES F2, F8).
--
--  (i)   cursor_precedes_close  -- KEPT, the baseline's own predicate: a cursor
--        below the closing transaction's own commit position recorded a checkpoint
--        computed at a cursor that could not have seen the close it records.
--
--        A NAMED KNOWN ISSUE, because it is the one predicate here whose verdict
--        depends on a convention nothing in this repository has chosen yet. If a
--        close stores pg_snapshot_xmin -- the only reproducible value (ADR-0011
--        §1) -- then computed_at_xid is strictly below its own xid whenever any
--        older transaction is running, and this fires on an HONEST close:
--        measured 16024 < 16025 on a close whose checkpoint reconciles cleanly
--        (spike 024 FINDINGS §1.1). Spike 024's PROPOSAL.sql proposed INVERTING
--        it to `computed_at_xid > txn_xact_id`; ADR-0020 did not rule on it, and
--        it is not one of the four fixes this migration was asked for, so the
--        predicate ships unchanged with the exposure written down instead of
--        silently reversed. The forgery the inverted form was for is caught by
--        (ii) below at a wider bound.
--
--  (ii)  cursor_above_assigned -- computed_at_xid above the CURRENT snapshot's
--        xmax was never captured at all. This is the bound computed_at_xid never
--        had: it is bounded from below by (i) and was unbounded above, so forged
--        to 2^62 it was green in the sweep AND silenced close_disclosures for that
--        period entirely -- and it sits under a TABLE-WIDE INSERT grant
--        (00001_baseline.sql:2518), unlike ledger_entries.xact_id, which is
--        withheld by a column-level grant for the identical reason (spike 025 F8).
--
--        pg_snapshot_XMAX, NOT xmin, and this is the whole point of the fix: xmin
--        is the cluster horizon, so an honest close breaks whenever a NEIGHBOUR
--        holds the horizon -- the same false positive 4b removes for entries.
--        xmax is latestCompletedXid + 1, so no committed transaction's xid can
--        reach it.
--
--        `>=` rather than `>`, which is one value stricter than the fix notes
--        wrote: a close row visible to the sweep has COMMITTED, so its own xid is
--        at or below latestCompletedXid and therefore strictly below xmax, and an
--        honestly captured cursor is at or below its own xid. Both halves are
--        proven above, and the bound is then the same one 4b applies to an entry
--        -- one rule, one place. WHAT IT GIVES UP: a session reading this view
--        INSIDE the transaction that wrote the close sees its own uncommitted row,
--        whose xid can equal xmax; `openledger reconcile` is not that session (it
--        runs BEGIN TRANSACTION READ ONLY and holds no xid), and neither is any
--        reader of the summary.
--
--  (iii) recon_close_order -- the closes of one (tenant, currency) must be in
--        cursor order, and each one's cursor must clear the previous close's own
--        transaction. TWO predicates, ONE reason, because they are one invariant
--        seen from two sides, and both are new:
--
--          * out-of-order closes are LEGAL TODAY -- the shipped sweep reports zero
--            breaks on them -- and they make the bounded form in part 2 report
--            FALSE breaks, because a difference of levels is only a difference of
--            nested sets while the levels nest.
--          * a cursor that has not cleared the PREVIOUS close's transaction means
--            this checkpoint silently omits the previous sweep, so it is not the
--            at-close position either. THIS is the condition that makes A4's prose
--            true, and it is why part 1(b) is a precondition on the close.
--
--        A CONSEQUENCE WORTH STATING: two closes of the same (tenant, currency) in
--        ONE transaction are reported. That is correct rather than incidental --
--        the second close's cursor cannot exceed the first's transaction, so the
--        first close's legs fall outside the second checkpoint's cursor bound and
--        outside its identity term, and the second stored row is not the at-close
--        position.
--
--  (iv)  close_does_not_sweep -- the closed period's revenue and expense
--        positions, as the close itself saw them, must net to zero. This is
--        ADR-0011 §2's definition of a close asserted on the stored rows, and it
--        is the only one of spike 025's three candidate fixes for a MISLABELLED
--        close that addresses the substance: `kind` is free text in the app role's
--        INSERT grant and 'period_close' must remain a legal value, so a CHECK on
--        the label cannot help. Measured: a 700,000.00 fee labelled period_close,
--        named by a fully valid close row with a checkpoint computed exactly as
--        the sweep recomputes it, erased 700,000.00 of revenue from the income
--        statement with all ten checks green (spike 025 F2(b)).
--
--        IT READS THE STORED CHECKPOINT, not ledger_entries, for two reasons. It
--        is then O(closes) index lookups rather than a second O(entries x closes)
--        pass, which would undo part 2's whole purpose; and the stored rows are
--        the at-close position by part 1's invariant, so "every temporary
--        account's row is exactly 0" is A4 stated as arithmetic. WHAT IT DOES NOT
--        CATCH: a close that wrote NO checkpoint at all -- there are then no rows
--        to disagree with, and checkpoint_drift is the check that reports it. A
--        cursor-unbounded form was considered and refused: a legally backdated
--        arrival into the closed period would make an HONEST close's temporary
--        positions non-zero, and turning close_disclosures' population into a
--        break is the period lock this design refuses to take.
--
--  (v)   close_orphan -- a posted kind='period_close' transaction that no
--        ledger_period_closes row names. SPIKE 025's MOST SEVERE FINDING, and it
--        is a plain omission rather than an attack: income_statement_for excludes
--        the closing transaction by key lookup into ledger_period_closes, so with
--        no close row the lookup finds nothing and the entry whose whole job is to
--        zero revenue is counted as operating activity. Measured: a period that
--        earned 250,000.00 reported 0.00 revenue and 0.00 expense, the balance
--        sheet was right to the unit, and `openledger reconcile` exited 0 (F2(a)).
--        checkpoint_drift and close_typing were green for the same reason the
--        income statement was wrong -- the three keys ADR-0011 added to type a
--        close all hang off the close row, and with no row every one of them is
--        vacuous.
--
--        IT CANNOT BE A KEY and it cannot be a CHECK: the transaction is written
--        BEFORE the close row, so a NOT NULL reference from the journal into the
--        period record is unwritable in the order the close happens, and the
--        statement is about the ABSENCE of a row in another table. That is exactly
--        the shape ADR-0004 admits a lint for.
--
-- WHAT IT COSTS. Four of the five reasons are O(closes) and touch no entry;
-- close_does_not_sweep is O(closes) index lookups into pk_period_balances, whose
-- leading three columns are exactly the ones it filters on. close_orphan scans
-- ledger_transactions -- `kind` carries no index -- which is the same population
-- recon_transaction_breaks already walks in full on every sweep, so it adds a
-- pass rather than a cost class. None of the five re-aggregates ledger_entries,
-- which is what part 2 spent its whole design on not doing.
--
-- WHAT THIS VIEW STILL DOES NOT PROTECT AGAINST: a cursor forged BELOW the true
-- one. Measured -- computed_at_xid = 1 is caught by (i), but a cursor forged low
-- on a book with no arrivals above the true cursor produces an arithmetically
-- consistent checkpoint that simply buys nothing. That is a performance defect,
-- not a correctness one -- part 5's tail B picks up everything the checkpoint
-- missed -- and it is recorded rather than guarded.
CREATE VIEW recon_close_breaks AS
WITH indexed AS (
    SELECT c.tenant_id, c.currency, c.period_code, c.ends_at, c.computed_at_xid,
           c.transaction_id,
           row_number() OVER (PARTITION BY c.tenant_id, c.currency
                              ORDER BY c.ends_at)::bigint AS k
    FROM ledger_period_closes c
), seq AS (
    SELECT i.*, x.xact_id AS txn_xact_id,
           lag(i.computed_at_xid) OVER w AS prev_cursor,
           lag(i.period_code)     OVER w AS prev_period
    FROM indexed i
    JOIN ledger_transactions x
      ON x.tenant_id = i.tenant_id AND x.id = i.transaction_id
    WINDOW w AS (PARTITION BY i.tenant_id, i.currency ORDER BY i.k)
), paired AS (
    SELECT s.*, px.xact_id AS prev_txn_xact_id
    FROM seq s
    LEFT JOIN indexed p
      ON p.tenant_id = s.tenant_id AND p.currency = s.currency
     AND p.period_code = s.prev_period
    LEFT JOIN ledger_transactions px
      ON px.tenant_id = p.tenant_id AND px.id = p.transaction_id
)
SELECT p.tenant_id, p.period_code, p.currency, p.transaction_id,
       p.computed_at_xid, p.txn_xact_id, p.prev_cursor, p.prev_txn_xact_id,
       b.reason
FROM paired p, LATERAL (
    SELECT r FROM unnest(ARRAY[
        CASE WHEN p.computed_at_xid < p.txn_xact_id
             THEN 'cursor_precedes_close' END,
        CASE WHEN p.computed_at_xid >= pg_snapshot_xmax(pg_current_snapshot())
             THEN 'cursor_above_assigned' END,
        CASE WHEN (p.prev_cursor IS NOT NULL AND p.computed_at_xid < p.prev_cursor)
                  OR (p.prev_txn_xact_id IS NOT NULL
                      AND p.prev_txn_xact_id >= p.computed_at_xid)
             THEN 'recon_close_order' END,
        CASE WHEN EXISTS (
                 SELECT 1
                 FROM ledger_period_balances s
                 JOIN ledger_accounts a
                   ON a.tenant_id = s.tenant_id AND a.id = s.account_id
                  AND a.currency = s.currency
                 WHERE s.tenant_id = p.tenant_id AND s.period_code = p.period_code
                   AND s.currency = p.currency
                   AND a.category IN ('revenue', 'expense')
                   AND s.input <> s.output)
             THEN 'close_does_not_sweep' END
    ]) AS r WHERE r IS NOT NULL
) AS b(reason)
UNION ALL
-- ...and the close that no period record names. The other direction of the same
-- one-to-one relationship, and the only one no key reaches.
SELECT x.tenant_id, NULL, NULL, x.id,
       NULL, x.xact_id, NULL, NULL,
       'close_orphan'
FROM ledger_transactions x
WHERE x.kind = 'period_close'
  AND x.status = 'posted'
  AND NOT EXISTS (SELECT 1 FROM ledger_period_closes c
                  WHERE c.tenant_id = x.tenant_id AND c.transaction_id = x.id);


-- ----------------------------------------------------------------------
-- 4b. recon_cursor_breaks -- one word, and it stops crying wolf
--
-- The shipped view bounds an entry's xact_id by pg_snapshot_XMIN, and its own
-- comment asserts that "a committed row's commit position is always retired below
-- the horizon by the time the sweep runs". THAT IS FALSE, and report_cursor()'s
-- own comment forty lines above it says why: pg_snapshot_xmin is the CLUSTER's
-- horizon, so one long-running transaction anywhere on the server -- another
-- database included -- holds it back, and every entry committed since sits at or
-- above it. On a busy database that is most recent entries.
--
-- MEASURED, by two spikes independently, one of them by accident when a
-- neighbouring database held the horizon: two above_horizon breaks against one
-- honest committed posting, with the sweep run exactly as `openledger reconcile`
-- runs it (BEGIN TRANSACTION READ ONLY, no xid of its own), and `reconciliation`
-- reporting cursor_forgery <> 0 -- so THE DAILY SWEEP EXITS 1 ON A HEALTHY BOOK
-- (spike 024 FINDINGS §4.1, spike 025 F10).
--
-- pg_snapshot_XMAX is latestCompletedXid + 1, so no COMMITTED xid can reach it:
-- 0 breaks on the same book at the same instant. The `predates_txn` half is
-- unchanged and was never wrong.
--
-- WHAT THE SUBSTITUTION GIVES UP, stated so it is a choice and not an oversight:
-- an xact_id forged into the NARROW BAND between the horizon and xmax -- the
-- currently-in-flight ids -- is no longer caught. That band is bounded by
-- concurrency rather than by time, and the forgeries that buy anything lie below
-- the horizon (`predates_txn`, still caught by the second predicate) or far above
-- it (still caught). This check was always about the impossible shapes only.
--
-- AND pg_snapshot_xmax MUST NOT BE SUBSTITUTED INTO report_cursor(), which is the
-- same expression serving a different question: a report pinned at xmax would
-- include rows still in flight, which is the whole defect ADR-0011 §1 chose xmin
-- to avoid.
CREATE OR REPLACE VIEW recon_cursor_breaks AS
SELECT e.tenant_id, e.id AS entry_id, e.transaction_id, e.xact_id,
       x.xact_id AS txn_xact_id,
       CASE WHEN e.xact_id >= pg_snapshot_xmax(pg_current_snapshot()) THEN 'above_horizon'
            WHEN e.xact_id < x.xact_id THEN 'predates_txn' END AS reason
FROM ledger_entries e
JOIN ledger_transactions x ON x.tenant_id = e.tenant_id AND x.id = e.transaction_id
WHERE e.xact_id >= pg_snapshot_xmax(pg_current_snapshot())
   OR e.xact_id < x.xact_id;


-- ----------------------------------------------------------------------
-- 4c. recon_transaction_breaks -- the EMPTY CLOSE carve-out
--
-- A period in which no revenue or expense moved cannot be closed without breaking
-- the sweep. The close posts one leg pair per temporary account with a non-zero
-- balance (ADR-0011 §2, and the HAVING in every implementation of it), so a period
-- with nothing to sweep writes a period_close transaction with ZERO ENTRIES -- and
-- this view flags every entryless transaction as `no_entries`, the ADR-0004
-- TRUNCATE scar's class. Migration 00003 carved out the VOID and nothing else.
-- MEASURED: a book with a capital injection and no revenue reconciles at ten
-- zeros, and closing its one period takes `openledger reconcile` to exit 1
-- (spike 024 FINDINGS §4.2).
--
-- The carve-out is EXACTLY as narrow as the void's: zero entries AND
-- kind = 'period_close' AND a ledger_period_closes row naming this transaction. A
-- key lookup, the same device ADR-0011 §2 chose for the income statement's
-- exclusion, and tight -- fk_closes__txn_kind already forces the kind and
-- uq_closes__txn makes the naming one-to-one. AN ENTRYLESS TRANSACTION CLAIMING
-- kind='period_close' THAT NO CLOSE ROW NAMES STAYS A BREAK, here as `no_entries`
-- and again in 4a as `close_orphan`.
--
-- CREATE OR REPLACE keeps the view's owner, grants and column list; only the WHERE
-- grows. The body is otherwise migration 00003's, verbatim.
CREATE OR REPLACE VIEW recon_transaction_breaks AS
WITH legs AS (
    -- Aggregated first, then joined: the other form is a merge join driven by an
    -- index scan over every entry -- 931 ms against 754 ms at 1,000,000 entries.
    SELECT e.tenant_id, e.transaction_id, e.currency,
           COALESCE(SUM(e.amount_minor) FILTER (WHERE e.direction = 'debit'), 0)  AS debits,
           COALESCE(SUM(e.amount_minor) FILTER (WHERE e.direction = 'credit'), 0) AS credits,
           COUNT(*) AS leg_count
    FROM ledger_entries e
    GROUP BY e.tenant_id, e.transaction_id, e.currency
)
SELECT x.tenant_id, x.id AS transaction_id, x.status, x.kind,
       x.effective_at, x.recorded_at,
       g.currency,
       COALESCE(g.debits, 0)  AS debits,
       COALESCE(g.credits, 0) AS credits,
       COALESCE(g.debits, 0) - COALESCE(g.credits, 0) AS imbalance_minor,
       COALESCE(g.leg_count, 0) AS leg_count,
       CASE WHEN g.transaction_id IS NULL THEN 'no_entries'
            WHEN g.leg_count = 1          THEN 'single_leg'
            ELSE 'debits_ne_credits' END AS reason
FROM ledger_transactions x
LEFT JOIN legs g ON g.tenant_id = x.tenant_id AND g.transaction_id = x.id
WHERE (g.transaction_id IS NULL OR g.debits <> g.credits)
  -- the void carve-out (ADR-0016, migration 00003), unchanged
  AND NOT (g.transaction_id IS NULL
           AND x.reverses_id IS NOT NULL
           AND EXISTS (SELECT 1 FROM ledger_transactions v
                       WHERE v.tenant_id = x.tenant_id
                         AND v.id = x.reverses_id
                         AND v.status = 'pending'))
  -- ...and the EMPTY CLOSE carve-out (ADR-0020): a period with no
  -- temporary-account movement has nothing to sweep, so its close is a marker,
  -- exactly as the void is.
  AND NOT (g.transaction_id IS NULL
           AND x.kind = 'period_close'
           AND EXISTS (SELECT 1 FROM ledger_period_closes c
                       WHERE c.tenant_id = x.tenant_id AND c.transaction_id = x.id));


-- ----------------------------------------------------------------------
-- 4d. chart_lint gains the two rules the presentation CAN be bounded by
--
-- SQL inside an existing view: no new check row, no grant, no RLS change, and the
-- check count stays at ten. They are the cheap half of spike 025 F1 -- the half
-- that says something about the chart without needing a second declaration to
-- disagree with (which is a decision, and is not in this migration).
--
-- BOTH SHIP AS `warn`, AND THAT IS A MEASUREMENT RATHER THAN A HEDGE. The fix
-- notes proposed them as rules "expressible and not asserted"; run against the
-- PUBLISHED reference chart (schema/chart.sql, versions 1-3) each one fires on a
-- presentation this project deliberately chose:
--
--   * line_mixes_counterparty_scopes fires nine times -- `payables`,
--     `other_assets` and `receivables`, at each of the three versions. `payables`
--     receives network_settlement_payable and accrued_interest_payable (shared)
--     beside platform_rev_share_payable and due_to_tenants (per_shard):
--     "Accounts payable and accrued" covering amounts owed to a card network, a
--     lender and a platform partner is ordinary presentation, not a defect.
--     `other_assets` mixes the same two grains through the contra lines version 3
--     was written to declare, and `receivables` mixes `none` with `per_shard`
--     because the contra-asset allowance sits there.
--   * restricted_shares_a_line fires three times, on `receivables` at each
--     version: customer_receivable (per_shard, counterparty-facing) beside
--     allowance_for_credit_losses (scope 'none'). A contra-asset allowance
--     presented against gross receivables is REQUIRED, not forbidden.
--
-- An error rule that turns the reference chart red is a rule nobody keeps, so
-- these are prompts to justify a line rather than refusals -- and `reconciliation`
-- counts severity='error' only, so neither reaches the sweep.
--
-- AND THE CLAIM THEY DO NOT SUPPORT, recorded because the fix notes make it: they
-- would NOT have caught F1's `customer_wallet -> payables` reproduction as a
-- CHANGE. `payables` already mixes scopes at every published version, so the
-- rule's verdict is identical before and after the injection. What they do is make
-- the mixing SAYABLE, which it was not. They also cannot reach F1's other half --
-- `paid_in_capital -> retained_earnings`, two 'none'-scope equity types on two
-- equity lines -- which is indistinguishable from a legitimate chart by any rule
-- over the chart alone, and the fix notes say so.
--
-- WHAT NEITHER RULE CAN SEE AT ALL, and it is the restricted-cash argument's own
-- case: operating_cash and fbo_cash are both is_perimeter and both `shared`, so
-- mapping fbo_cash onto the `cash` line -- customer float presented as the
-- operator's own liquidity, the exact defect the split exists to prevent -- is
-- invisible to every column in account_types. Nothing distinguishes restricted
-- from unrestricted money in this schema; that absence is the finding, stated from
-- the other side.
--
-- CREATE OR REPLACE keeps the view's column list (rule, severity, subject,
-- detail), its owner and its three grants; the body grows two UNION ALL arms and
-- is otherwise the baseline's, verbatim.
CREATE OR REPLACE VIEW chart_lint AS
SELECT 'type_unpresented' AS rule, 'error' AS severity,
       t.code || ' @ v' || cv.version AS subject,
       'account type has no chart_presentation row in chart version ' || cv.version AS detail
FROM account_types t
CROSS JOIN chart_versions cv
WHERE NOT EXISTS (SELECT 1 FROM chart_presentation p
                   WHERE p.chart_version = cv.version AND p.type_code = t.code)
UNION ALL
SELECT 'line_unreachable', 'info', f.code,
       'fs_line has no account type mapped to it in this chart version'
FROM fs_lines f, chart_version_current cv
WHERE f.chart_version = cv.chart_version
  AND NOT EXISTS (SELECT 1 FROM chart_presentation p
                   WHERE p.chart_version = f.chart_version
                     AND (p.fs_line = f.code OR p.fs_line_contra = f.code))
UNION ALL
SELECT 'per_shard_in_house_account', 'error', t.code,
       'per_shard type held in ' || count(*) || ' house account(s): opposite-sign '
       'positions against different counterparties are already netted at write time'
FROM account_types t
JOIN ledger_accounts a ON a.purpose = t.code AND a.owner_type = 'house'
WHERE t.counterparty_scope = 'per_shard'
GROUP BY t.code
UNION ALL
SELECT 'shared_but_split_by_owner', 'error', t.code,
       'counterparty_scope=shared but accounts are keyed to ' || count(DISTINCT a.owner_id)
       || ' distinct owners'
FROM account_types t
JOIN ledger_accounts a ON a.purpose = t.code AND a.owner_type <> 'house'
WHERE t.counterparty_scope = 'shared'
GROUP BY t.code
HAVING count(DISTINCT a.owner_id) > 1
UNION ALL
SELECT 'none_but_owner_keyed', 'warn', t.code,
       'counterparty_scope=none but ' || count(*) || ' account(s) are owner-keyed'
FROM account_types t
JOIN ledger_accounts a ON a.purpose = t.code AND a.owner_type <> 'house'
WHERE t.counterparty_scope = 'none'
GROUP BY t.code
UNION ALL
SELECT 'perimeter_unattested', 'error', t.code || ' / ' || a.tenant_id || ' / ' || a.id::text,
       'is_perimeter account carries posted entries and has no attestation'
FROM account_types t
JOIN ledger_accounts a ON a.purpose = t.code
WHERE t.is_perimeter
  AND EXISTS (SELECT 1 FROM ledger_entries e
              JOIN ledger_transactions x ON x.tenant_id=e.tenant_id AND x.id=e.transaction_id
                                        AND x.status='posted'
              WHERE e.tenant_id=a.tenant_id AND e.account_id=a.id)
  AND NOT EXISTS (SELECT 1 FROM perimeter_attestations at
                  WHERE at.tenant_id=a.tenant_id AND at.account_id=a.id)
UNION ALL
SELECT 'attested_but_not_perimeter', 'warn', a.purpose || ' / ' || at.source,
       'attestation exists for an account whose type declares is_perimeter = false'
FROM perimeter_attestations at
JOIN ledger_accounts a ON a.tenant_id=at.tenant_id AND a.id=at.account_id AND a.currency=at.currency
JOIN account_types t ON t.code = a.purpose
WHERE NOT t.is_perimeter
GROUP BY a.purpose, at.source
UNION ALL
SELECT 'perimeter_drift', 'error',
       d.purpose || ' / ' || d.tenant_id || ' / ' || d.source,
       'ledger ' || d.ledger_balance_minor || ' against attested '
       || d.external_balance_minor || ' as of ' || d.as_of
FROM perimeter_drift d
WHERE d.drift_minor <> 0
  AND d.as_of = (SELECT max(d2.as_of) FROM perimeter_drift d2
                  WHERE d2.tenant_id=d.tenant_id AND d2.account_id=d.account_id
                    AND d2.currency=d.currency AND d2.source=d.source)
UNION ALL
SELECT 'mirror_same_side', 'error', t.code || ' / ' || t.mirror_type,
       'mirror pair ' || t.code || ' <-> ' || t.mirror_type
         || ' share normal_balance ' || t.normal_balance::text
         || '; a mirror must be opposite-signed to eliminate to zero'
FROM account_types t
JOIN account_types m ON m.code = t.mirror_type
WHERE t.mirror_type IS NOT NULL
  AND t.normal_balance = m.normal_balance
UNION ALL
SELECT 'mirror_undeclared', 'warn', t.code,
       'counterparty_scope=' || t.counterparty_scope
         || ' but no mirror_type declared, not a mirror target, and not a perimeter '
         || 'account: a cross-scope position of this type is reconciled by nothing'
FROM account_types t
WHERE t.counterparty_scope <> 'none'
  AND t.category IN ('asset','liability')
  AND NOT t.is_perimeter
  AND t.mirror_type IS NULL
  AND NOT EXISTS (SELECT 1 FROM account_types m WHERE m.mirror_type = t.code)
  AND EXISTS (SELECT 1 FROM ledger_accounts a
              WHERE a.purpose = t.code AND a.owner_type <> 'house')
UNION ALL
-- 11. ONE LINE, MORE THAN ONE COUNTERPARTY GRAIN (spike 025 F1). balance_sheet_at
--     evaluates a position per ACCOUNT and then sums into the line, so same-sign
--     positions on one line aggregate -- which is fine -- while the line's caption
--     is the only thing a reader sees. A line receiving both a `per_shard` type
--     (one account per counterparty) and a `shared` one (all members facing ONE
--     counterparty) presents two different counterparty grains under one caption,
--     and IAS 32.42 / ASC 210-20-45-1 permit offset only between the same two
--     parties. Counted per version, and over the CONTRA line too: a swung position
--     lands there and is presented under that caption exactly as a normal one is.
SELECT 'line_mixes_counterparty_scopes', 'warn',
       r.fs_line || ' @ v' || r.chart_version,
       'fs_line receives types of ' || count(DISTINCT r.counterparty_scope)
         || ' counterparty_scopes (' || string_agg(DISTINCT r.counterparty_scope, ', ')
         || '): one caption, more than one counterparty grain'
FROM (
    SELECT p.chart_version, p.fs_line, p.counterparty_scope, p.type_code
    FROM chart_presentation p
    UNION ALL
    SELECT p.chart_version, p.fs_line_contra, p.counterparty_scope, p.type_code
    FROM chart_presentation p WHERE p.fs_line_contra IS NOT NULL
) r
GROUP BY r.chart_version, r.fs_line
HAVING count(DISTINCT r.counterparty_scope) > 1
UNION ALL
-- 12. RESTRICTED OR COUNTERPARTY-FACING MONEY SHARING A LINE WITH NEITHER (spike
--     025 F1, generalising the restricted-cash argument in fs_lines' own comment:
--     giving `restricted_cash` the caption 'Cash and cash equivalents' passed
--     every trigger and every test -- "the split was real in the chart and
--     invisible in the report"). The two signals this schema HAS are
--     `is_perimeter` -- "mirrors exactly one EXTERNAL balance" -- and
--     counterparty_scope <> 'none'. A line that receives such a type beside a type
--     with neither presents restricted or third-party money under the same caption
--     as the entity's own unencumbered position. Reg S-X 5-02.1 requires separate
--     disclosure; ASC 230-10-45-4 requires restricted cash to be identified.
SELECT 'restricted_shares_a_line', 'warn',
       r.fs_line || ' @ v' || r.chart_version,
       'fs_line receives restricted or counterparty-facing types ('
         || string_agg(DISTINCT r.type_code, ', ') FILTER (WHERE r.facing)
         || ') and unencumbered ones ('
         || string_agg(DISTINCT r.type_code, ', ') FILTER (WHERE NOT r.facing)
         || ') under one caption'
FROM (
    SELECT p.chart_version, p.fs_line, p.type_code,
           (t.is_perimeter OR p.counterparty_scope <> 'none') AS facing
    FROM chart_presentation p
    JOIN account_types t ON t.code = p.type_code
    UNION ALL
    SELECT p.chart_version, p.fs_line_contra, p.type_code,
           (t.is_perimeter OR p.counterparty_scope <> 'none')
    FROM chart_presentation p
    JOIN account_types t ON t.code = p.type_code
    WHERE p.fs_line_contra IS NOT NULL
) r
GROUP BY r.chart_version, r.fs_line
HAVING bool_or(r.facing) AND bool_or(NOT r.facing);


-- ======================================================================
-- PART 5 -- THE REPORT PATH
-- ======================================================================
--
-- WHICH FUNCTIONS TAKE THE CHECKPOINT, which is the half ADR-0011 §3 did not
-- have. Its sentence -- and roadmap M5's -- says all three statement functions
-- "aggregate ledger_entries from inception". That is TRUE OF balance_sheet_at
-- ONLY, and the correction re-sizes the milestone:
--
--   balance_sheet_at     -- YES. It is a POSITION at one instant and the only one
--                           of the three that scans from inception -- three scans,
--                           in fact: the position aggregate, the earnings plug and
--                           the A14 guard -- and recon_equation_breaks calls it at
--                           ('infinity', report_cursor()) per tenant on EVERY
--                           reconciliation sweep, so wiring it pays twice.
--   trial_balance_at     -- NO. It carries `effective_at >= p_from`, so a caller
--                           asking for one month scans one month, and the only
--                           checkpoint form available to a FLOW is
--                           prefix(to) - prefix(from), which ADR-0020 refuses
--                           pending a crossover measurement: the first version of
--                           it was WRONG on an inverted window, returning negative
--                           gross debits where the shipped body correctly returns
--                           nothing.
--   income_statement_for -- NO, and the reason is structural rather than
--                           budgetary. It is a flow; the accounts it reports are
--                           exactly the ones a close ZEROES, so every checkpoint
--                           row it would read is 0 by construction (A4) and the
--                           flow is only recoverable by adding back the closing
--                           entries the statement is specified to EXCLUDE; and its
--                           dp CTE already carries `effective_at >= p_from`.
--
-- PROVEN AGREEMENT (spike 024 §2.1): the rewritten balance_sheet_at agrees with
-- the from-inception body to the minor unit at all 60 (tenant, cursor, as-of)
-- points of the spike's grid -- a book with no closes, one close, three closes, a
-- backdated posting, a resolution backdated into a closed period, a reversal of a
-- posted transaction backdated into a closed period, a voided pending, a pending
-- never resolved, two currencies closed to DIFFERENT depths, as-of exactly on each
-- close boundary, as-of mid-period, and as-of 'infinity' -- and again on a
-- 30,000-entry, twelve-close book.

-- ----------------------------------------------------------------------
-- 5a. the anchor -- which close a report may read, and there are TWO guards
--
-- Factored out because every reader needs the SAME choice of boundary, and a
-- second copy of it is a second place to get these two wrong. Neither is in
-- ADR-0011 §3, and both are load-bearing:
--
--  (a) PER CURRENCY. pk_closes is (tenant_id, period_code, currency), so a tenant
--      closed through March in USD and only through January in EUR is an ordinary
--      state. A boundary chosen per TENANT reads the wrong checkpoint for one of
--      them. Measured, not hypothetical -- spike 024's book is built that way on
--      purpose.
--
--  (b) THE WHOLE CHECKPOINT MUST BE VISIBLE AT THIS REPORT'S CURSOR, and the last
--      thing to become visible is the CLOSING TRANSACTION, whose xact_id is at or
--      above computed_at_xid. Guarding on computed_at_xid alone admits a
--      checkpoint containing entries the report must not see, and a close that
--      happened after a statement was issued would then RESTATE THAT STATEMENT
--      UPWARD -- precisely the property the cursor exists to prevent (ADR-0011
--      §1). Both predicates are kept: a forged computed_at_xid above its own
--      closing transaction is refused by recon_close_breaks and not by the reader,
--      and a reader that trusts a check it does not run is not a reader.
--
-- STABLE, not IMMUTABLE: it reads tables. A plain SQL set-returning function so
-- PostgreSQL can inline it (ADR-0011 §4). SECURITY INVOKER by default, so the
-- reader's RLS policies on ledger_accounts, ledger_period_closes and
-- ledger_transactions scope it exactly as they scope the statements.
CREATE FUNCTION checkpoint_anchor(p_tenant text, p_asof timestamptz, p_cursor xid8)
RETURNS TABLE (currency char(3), period_code text, boundary timestamptz,
               ckpt_cursor xid8, close_txn uuid)
LANGUAGE sql STABLE AS $$
    SELECT s.currency, c.period_code,
           -- NO CLOSE: boundary '-infinity' and cursor 0. The form then degrades
           -- to the from-inception behaviour with no special case -- tail B is
           -- empty because ck_entries__effective_finite forbids an entry at
           -- -infinity, tail A is everything, and the checkpoint term joins
           -- nothing.
           COALESCE(c.ends_at, '-infinity'::timestamptz),
           COALESCE(c.computed_at_xid, '0'::xid8),
           c.transaction_id
    FROM (SELECT DISTINCT l.currency FROM ledger_accounts l WHERE l.tenant_id = p_tenant) s
    LEFT JOIN LATERAL (
        SELECT k.period_code, k.ends_at, k.computed_at_xid, k.transaction_id
        FROM ledger_period_closes k
        JOIN ledger_transactions kx
          ON kx.tenant_id = k.tenant_id AND kx.id = k.transaction_id
        WHERE k.tenant_id = p_tenant
          AND k.currency = s.currency
          -- half-open, so a close AT the as-of instant leaves tail A empty and the
          -- checkpoint exact. One microsecond either way is a wrong balance sheet.
          AND k.ends_at <= p_asof
          AND k.computed_at_xid <= p_cursor
          AND kx.xact_id < p_cursor
        ORDER BY k.ends_at DESC
        LIMIT 1
    ) c ON true;
$$;

COMMENT ON FUNCTION checkpoint_anchor(text, timestamptz, xid8) IS
  'The close a report at (as_of, cursor) may read from, PER CURRENCY: the latest whose period end is at or before as_of and whose whole checkpoint -- including its own closing transaction -- is visible at the cursor. Returns boundary -infinity and cursor 0 for a currency with no close, so the reader degrades to the from-inception form with no special case (ADR-0020).';


-- ----------------------------------------------------------------------
-- 5b. the position -- checkpoint plus two tails, gross
--
-- THE THREE TERMS ARE DISJOINT AND THEIR UNION IS EXACT, which is what makes this
-- the from-inception aggregate rather than an approximation of it:
--
--   checkpoint  eff < boundary,  admitted by the cursor-or-identity rule
--   tail B      eff < boundary,  xact_id >= C,  and NOT the close's own txn
--   tail A      eff >= boundary, eff < as_of,   xact_id < cursor
--
-- Take any posted entry with eff < as_of and xact_id < cursor. If eff >= boundary
-- it is tail A. Otherwise: below C it is in the checkpoint, at or above C it is
-- tail B -- unless it belongs to the close itself, in which case the checkpoint
-- already carries it. Exhaustive, and no overlap.
--
-- DROP THE `<> close_txn` CLAUSE AND THE CLOSING LEGS ARE COUNTED TWICE. Measured:
-- fee_revenue read 1,000 against a true 500 (ADR-0020, spike 024).
--
-- GROSS, not netted, for two reasons: the earnings plug and the A14 guard both
-- need "did this account have ANY posted entry below the boundary", which is only
-- answerable from a gross sum. ck_entries__amount_positive is
-- CHECK (amount_minor > 0), so debits + credits > 0 iff at least one posted entry.
--
-- numeric, and the cast is at the boundary of each term rather than at the end:
-- SUM(bigint) already returns numeric in PostgreSQL, so what this buys is that
-- ledger_period_balances.input (a bigint column) enters the same sum without a
-- bigint intermediate. ADR-0013's reason, applied where it is actually true.
CREATE FUNCTION checkpoint_position(p_tenant text, p_asof timestamptz, p_cursor xid8)
RETURNS TABLE (currency char(3), account_id uuid, debits numeric, credits numeric)
LANGUAGE sql STABLE AS $$
    WITH a AS (SELECT * FROM checkpoint_anchor(p_tenant, p_asof, p_cursor)),
    terms AS (
        -- 1. the checkpoint. input = debit legs, output = credit legs, posted
        -- only -- the same convention as ledger_account_balances.
        SELECT b.currency, b.account_id, b.input::numeric AS dr, b.output::numeric AS cr
        FROM a
        JOIN ledger_period_balances b
          ON b.tenant_id = p_tenant AND b.currency = a.currency
         AND b.period_code = a.period_code
        UNION ALL
        -- 2. tail A -- effective at or after the boundary, before the as-of.
        -- WANTS ix_entries__tenant_effective, which ADR-0020's decision rule has
        -- not cleared for the write path: both existing indexes put account_id in
        -- second position, so a tenant-wide range on effective_at has no leading
        -- path through either and this term gets a sequential scan today.
        SELECT e.currency, e.account_id,
               CASE WHEN e.direction = 'debit'  THEN e.amount_minor::numeric ELSE 0 END,
               CASE WHEN e.direction = 'credit' THEN e.amount_minor::numeric ELSE 0 END
        FROM a
        JOIN ledger_entries e
          ON e.tenant_id = p_tenant AND e.currency = a.currency
         AND e.effective_at >= a.boundary AND e.effective_at < p_asof
         AND e.xact_id < p_cursor
        JOIN ledger_transactions x
          ON x.tenant_id = e.tenant_id AND x.id = e.transaction_id AND x.status = 'posted'
        UNION ALL
        -- 3. tail B -- the backdated arrivals, which is why ix_entries__asof_commit
        -- exists (ADR-0011 §3). PostgreSQL 18's btree skip scan chooses that index
        -- for the TENANT-WIDE form as well as the single-account one it was
        -- measured on, so this term is served today.
        SELECT e.currency, e.account_id,
               CASE WHEN e.direction = 'debit'  THEN e.amount_minor::numeric ELSE 0 END,
               CASE WHEN e.direction = 'credit' THEN e.amount_minor::numeric ELSE 0 END
        FROM a
        JOIN ledger_entries e
          ON e.tenant_id = p_tenant AND e.currency = a.currency
         AND e.effective_at < a.boundary
         AND e.xact_id >= a.ckpt_cursor AND e.xact_id < p_cursor
         AND (a.close_txn IS NULL OR e.transaction_id <> a.close_txn)
        JOIN ledger_transactions x
          ON x.tenant_id = e.tenant_id AND x.id = e.transaction_id AND x.status = 'posted'
    )
    SELECT t.currency, t.account_id, SUM(t.dr), SUM(t.cr)
    FROM terms t
    GROUP BY t.currency, t.account_id;
$$;

COMMENT ON FUNCTION checkpoint_position(text, timestamptz, xid8) IS
  'Per-account GROSS debits and credits as at (as_of, cursor), from the period checkpoint plus the two tails ADR-0011 §3 specifies -- chosen per currency, and excluding the close''s own transaction from the backdated tail because the checkpoint already carries it. Exactly equal to the from-inception aggregate: proven to the minor unit at 60 (tenant, cursor, as-of) points (ADR-0020).';


-- ----------------------------------------------------------------------
-- 5c. balance_sheet_at -- the shipped body with three substitutions, four guards
--     and a widened return type
--
-- THE THREE SUBSTITUTIONS: `pos` reads checkpoint_position instead of aggregating
-- ledger_entries; the earnings plug reads the same rows rather than re-deriving
-- them; and the A14 guard asks the same question of the same population.
-- EVERYTHING ELSE IS THE BASELINE'S, VERBATIM -- the chart-outward CROSS JOIN
-- fs_lines, the contra routing on position sign, the sign-follows-the-line rule,
-- the constant plug caption and the ORDER BY. The four numbered reasons in the
-- baseline's own header still hold and are not repeated here.
--
-- THE PLUG READS `pos`, and that is deliberate. A second hand-written subquery
-- over ledger_entries -- which is what the shipped body has -- is a second place
-- for the boundary to be chosen, and the two could disagree about where it is
-- while both looking correct. One anchor, one population.
--
-- A14 OVER THE CHECKPOINT POPULATION. `debits + credits > 0` is what makes it
-- equivalent: amount_minor is CHECKed > 0, so an account with any posted entry
-- below the boundary has a non-zero gross row, and a dormant account the close
-- wrote 0/0 for is correctly NOT treated as having entries. WHAT IS NOT PROVEN
-- ANYWHERE: the RED case. Every account type is presented at every chart version
-- on every book either spike built, because schema/chart.sql seeds the chart
-- whole, so this guard has never been seen to fire. ADR-0020 names it as a
-- correctness debt rather than a passing test.
--
-- THE NULL GUARDS (spike 025 F3). No report function was STRICT and none guarded
-- an argument, so a NULL cursor returned THE COMPLETE FACE AT 0.00, PERFECTLY
-- BALANCED, citing a real chart version -- and recon_equation_breaks(NULL, ...)
-- then reported ZERO BREAKS over that fabrication. They sit beside the A13
-- chart-version guard and use its idiom; ERRCODE 22004 (null_value_not_allowed)
-- because the argument is the thing that is wrong, where A13's 23514 says the
-- chart is.
--
-- These guards are also what makes recon_equation_breaks refuse a NULL cursor,
-- which is the exposure that mattered: it is bare SQL, it cannot RAISE, and its
-- zero rows are counted as zero breaks. It reaches this function through
-- CROSS JOIN LATERAL for every tenant, so the raise propagates -- for any book
-- with at least one tenant, which is every book where there is anything to
-- fabricate.
--
-- WHAT THE TENANT GUARD IS NOT: an existence check. `p_tenant IS NULL` is a
-- statement about the argument; "tenant t2 has no accounts" would be a statement
-- about the book, and under RLS it is not even that -- there is no tenant
-- registry, so an unknown tenant and an unauthorised one are the same silence to a
-- SECURITY INVOKER function. Spike 025 F9 has the three options; none is a fix.
--
-- amount_minor IS numeric, and the ::bigint casts are gone (spike 025 F6). The
-- finding that named these three functions as unprotected was BACKWARDS:
-- SUM(bigint) already returns numeric, so the views it accused were never
-- exposed. The hazard is the cast BACK to a declared bigint here, and
-- `ERROR: bigint out of range` was produced through the shipped writer over HTTP
-- in six calls -- so the report that "dies on one large row and reports nothing"
-- was the one the comment claimed was protected.
CREATE FUNCTION balance_sheet_at(p_tenant text, p_asof timestamptz, p_cursor xid8,
                                 p_chart_version int DEFAULT NULL)
RETURNS TABLE (tenant_id text, currency char(3), chart_version int, fs_line text,
               caption text, sort_order int, amount_minor numeric, side text,
               pinned_cursor xid8)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_cv int;
BEGIN
    IF p_tenant IS NULL OR p_asof IS NULL OR p_cursor IS NULL THEN
        RAISE EXCEPTION
          'balance_sheet_at requires a tenant, an as-of instant and a cursor; a NULL argument returns a complete, all-zero, perfectly balanced face'
            USING ERRCODE = '22004';
    END IF;
    v_cv := COALESCE(p_chart_version, (SELECT max(cvx.version) FROM chart_versions cvx));
    IF v_cv IS NULL THEN
        RAISE EXCEPTION 'no chart version exists: seed a chart before running a statement'
            USING ERRCODE = '23514';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM chart_versions cvx WHERE cvx.version = v_cv) THEN
        RAISE EXCEPTION 'chart version % does not exist', v_cv USING ERRCODE = '23514';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM checkpoint_position(p_tenant, p_asof, p_cursor) q
        JOIN ledger_accounts a ON a.tenant_id = p_tenant AND a.id = q.account_id
                              AND a.currency = q.currency
        WHERE q.debits + q.credits > 0
          AND NOT EXISTS (SELECT 1 FROM chart_presentation p
                          WHERE p.chart_version = v_cv AND p.type_code = a.purpose)
    ) THEN
        RAISE EXCEPTION
          'chart version % does not present every account type with posted entries as at this instant (chart_lint.type_unpresented)',
          v_cv USING ERRCODE = '23514';
    END IF;

    RETURN QUERY
    WITH scopes AS (
        SELECT DISTINCT l.tenant_id, l.currency FROM ledger_accounts l
        WHERE l.tenant_id = p_tenant
    ), pos AS (
        SELECT p_tenant AS tenant_id, q.currency, q.account_id,
               p.category, p.counterparty_scope, p.fs_line, p.fs_line_contra,
               q.debits - q.credits AS v
        FROM checkpoint_position(p_tenant, p_asof, p_cursor) q
        JOIN ledger_accounts a ON a.tenant_id = p_tenant AND a.id = q.account_id
                              AND a.currency = q.currency
        JOIN chart_presentation p ON p.chart_version = v_cv AND p.type_code = a.purpose
    ), dp AS (
        SELECT pos.tenant_id, pos.currency, pos.category,
               CASE WHEN pos.fs_line_contra IS NOT NULL
                         AND ((pos.category = 'asset'     AND pos.v < 0)
                           OR (pos.category = 'liability' AND pos.v > 0))
                    THEN pos.fs_line_contra ELSE pos.fs_line END AS fs_line,
               pos.v
        FROM pos
    ), lines AS (
        SELECT s.tenant_id, s.currency,
               f.code AS fs_line, f.caption, f.sort_order, f.side,
               COALESCE(SUM(CASE WHEN f.side = 'asset' THEN d.v ELSE -d.v END), 0)
                   AS amount_minor
        FROM scopes s
        JOIN fs_lines f ON f.chart_version = v_cv
        LEFT JOIN dp d ON d.tenant_id = s.tenant_id AND d.currency = s.currency
                      AND d.fs_line = f.code
        WHERE f.statement = 'balance_sheet'
        GROUP BY s.tenant_id, s.currency, f.code, f.caption, f.sort_order, f.side
    ), plug AS (
        SELECT s.tenant_id, s.currency,
               -COALESCE((
                   SELECT SUM(pp.v) FROM pos pp
                   WHERE pp.tenant_id = s.tenant_id AND pp.currency = s.currency
                     AND pp.category IN ('revenue','expense')
               ), 0) AS amount_minor
        FROM scopes s
    )
    SELECT l.tenant_id, l.currency, v_cv, l.fs_line, l.caption, l.sort_order,
           l.amount_minor, l.side, p_cursor
    FROM lines l
    UNION ALL
    SELECT g.tenant_id, g.currency, v_cv, 'current_year_earnings',
           'Undistributed earnings (since inception)', 9000,
           g.amount_minor, 'equity', p_cursor
    FROM plug g
    ORDER BY 1, 2, 6;
END $$;


-- ----------------------------------------------------------------------
-- 5d. income_statement_for -- the guards and the return type, and NO checkpoint
--
-- The body is the baseline's, verbatim, with two changes and one refusal:
--   * the NULL guard, covering the tenant, BOTH range bounds and the cursor;
--   * amount_minor numeric and the ::bigint cast dropped (5c's reasoning);
--   * NO checkpoint, for the structural reason in part 5's header -- the accounts
--     it reports are exactly the ones a close zeroes.
CREATE FUNCTION income_statement_for(p_tenant text, p_from timestamptz, p_to timestamptz,
                                     p_cursor xid8, p_chart_version int DEFAULT NULL)
RETURNS TABLE (tenant_id text, currency char(3), chart_version int, fs_line text,
               caption text, sort_order int, amount_minor numeric, side text,
               pinned_cursor xid8)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_cv int;
BEGIN
    IF p_tenant IS NULL OR p_from IS NULL OR p_to IS NULL OR p_cursor IS NULL THEN
        RAISE EXCEPTION
          'income_statement_for requires a tenant, both range bounds and a cursor; a NULL argument returns a complete, all-zero statement'
            USING ERRCODE = '22004';
    END IF;
    -- A13: the chart version must EXIST. The old COALESCE never touched
    -- chart_versions, so income_statement_for(..., 999) returned a fabricated,
    -- all-zero, perfectly balanced statement citing a version nobody created.
    v_cv := COALESCE(p_chart_version, (SELECT max(cvx.version) FROM chart_versions cvx));
    IF v_cv IS NULL THEN
        RAISE EXCEPTION 'no chart version exists: seed a chart before running a statement'
            USING ERRCODE = '23514';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM chart_versions cvx WHERE cvx.version = v_cv) THEN
        RAISE EXCEPTION 'chart version % does not exist', v_cv USING ERRCODE = '23514';
    END IF;
    -- A14: an in-scope account WITH posted entries in-window whose type has no
    -- chart_presentation row at this version is silently DROPPED by the INNER JOIN
    -- below -- a whole sub-book vanishing with the statement still balanced. Refuse.
    IF EXISTS (
        SELECT 1
        FROM ledger_entries e
        JOIN ledger_transactions x ON x.tenant_id = e.tenant_id AND x.id = e.transaction_id
                                  AND x.status = 'posted'
        JOIN ledger_accounts a ON a.tenant_id = e.tenant_id AND a.id = e.account_id
                              AND a.currency = e.currency
        WHERE e.tenant_id = p_tenant
          AND e.effective_at >= p_from AND e.effective_at < p_to
          AND e.xact_id < p_cursor
          AND NOT EXISTS (SELECT 1 FROM chart_presentation p
                          WHERE p.chart_version = v_cv AND p.type_code = a.purpose)
    ) THEN
        RAISE EXCEPTION
          'chart version % does not present every account type with posted entries in this window (chart_lint.type_unpresented)',
          v_cv USING ERRCODE = '23514';
    END IF;

    RETURN QUERY
    WITH dp AS (
        SELECT e.tenant_id, e.currency, p.fs_line,
               SUM(CASE WHEN e.direction='debit' THEN e.amount_minor::numeric
                        ELSE -e.amount_minor::numeric END) AS v
        FROM ledger_entries e
        JOIN ledger_transactions x ON x.tenant_id = e.tenant_id AND x.id = e.transaction_id
                                  AND x.status = 'posted'
        JOIN ledger_accounts a ON a.tenant_id = e.tenant_id AND a.id = e.account_id
                              AND a.currency = e.currency
        JOIN chart_presentation p ON p.chart_version = v_cv AND p.type_code = a.purpose
        WHERE e.tenant_id = p_tenant
          AND e.effective_at >= p_from AND e.effective_at < p_to
          AND e.xact_id < p_cursor
          AND NOT EXISTS (SELECT 1 FROM ledger_period_closes c
                          WHERE c.tenant_id = x.tenant_id AND c.transaction_id = x.id)
        GROUP BY e.tenant_id, e.currency, p.fs_line
    ), scopes AS (SELECT DISTINCT l.tenant_id, l.currency FROM ledger_accounts l
                  WHERE l.tenant_id = p_tenant)
    SELECT s.tenant_id, s.currency, v_cv, f.code, f.caption, f.sort_order,
           -- credit-normal lines (revenue) present positive; debit-normal (expense) too
           CASE WHEN f.side = 'credit' THEN -1 ELSE 1 END * COALESCE(SUM(d.v), 0),
           f.side, p_cursor
    FROM scopes s
    JOIN fs_lines f ON f.chart_version = v_cv
    LEFT JOIN dp d ON d.tenant_id = s.tenant_id AND d.currency = s.currency AND d.fs_line = f.code
    WHERE f.statement = 'income_statement'
    GROUP BY s.tenant_id, s.currency, f.code, f.caption, f.sort_order, f.side
    -- ORDERED BY THE CHART. sort_order was written by the seed and read by
    -- nothing, so every value in it could be changed with the suite green -- and the
    -- assertion that claimed to check the order was reading PHYSICAL ROW ORDER.
    ORDER BY 1, 2, 6;
END $$;


-- ----------------------------------------------------------------------
-- 5e. trial_balance_at -- the return type only, and NO guard. Which is a choice.
--
-- The body is the baseline's, verbatim, with the declared bigint columns widened
-- to numeric and the three ::bigint casts dropped (5c's reasoning: SUM already
-- returns numeric, and the cast back to a DECLARED bigint is the overflow).
--
-- IT KEEPS NO NULL GUARD, AND HERE IS WHY. A RAISE cannot live in a bare SELECT,
-- so the guard costs one of two things:
--
--   * STRICT is the WRONG TOOL and is refused: on a RETURNS TABLE function it
--     returns ZERO ROWS, which is the same silence in a different costume.
--   * LANGUAGE plpgsql costs the INLINING. ADR-0011 §4 records that PostgreSQL
--     inlines a simple SQL set-returning function, which is why this function
--     plans as a nested loop over an index scan rather than a Function Scan, and
--     spike 024 §2.7 measured what the plpgsql form loses: the two statement
--     functions are OPAQUE to EXPLAIN.
--
-- So the exposure is left, named, rather than paid for with a measured property
-- and no measurement to justify the trade: `trial_balance_at(t, f, t, NULL)`
-- returns zero rows. What makes that the cheaper side of the trade is WHO READS
-- IT -- nothing does. It is the one statement function no reconciliation check
-- calls, so a NULL here cannot make a CHECK green, which is the shape this
-- migration is about; and no caller in `crates/` passes it anything at all
-- (verified by grep), so the blast radius is a human at a SQL prompt, who gets
-- zero rows rather than a fabricated face. The two functions a check DOES reach
-- -- balance_sheet_at through recon_equation_breaks, and income_statement_for --
-- both raise.
--
-- IF THIS EVER GETS A CALLER, the guard comes with it and the inlining goes.
CREATE FUNCTION trial_balance_at(p_tenant text, p_from timestamptz, p_to timestamptz,
                                 p_cursor xid8)
RETURNS TABLE (tenant_id text, account_id uuid, purpose text, category ledger_category,
               currency char(3), debits numeric, credits numeric,
               balance_debit_positive numeric)
LANGUAGE sql STABLE AS $$
SELECT a.tenant_id, a.id, a.purpose, t.category, e.currency,
       COALESCE(SUM(e.amount_minor::numeric) FILTER (WHERE e.direction='debit'), 0),
       COALESCE(SUM(e.amount_minor::numeric) FILTER (WHERE e.direction='credit'), 0),
       SUM(CASE WHEN e.direction='debit' THEN e.amount_minor::numeric ELSE -e.amount_minor::numeric END)
FROM ledger_entries e
JOIN ledger_transactions x ON x.tenant_id = e.tenant_id AND x.id = e.transaction_id
                          AND x.status = 'posted'
JOIN ledger_accounts a ON a.tenant_id = e.tenant_id AND a.id = e.account_id
                      AND a.currency = e.currency
JOIN account_types   t ON t.code = a.purpose
WHERE a.tenant_id = p_tenant
  AND e.effective_at >= p_from AND e.effective_at < p_to
  AND e.xact_id < p_cursor
GROUP BY a.tenant_id, a.id, a.purpose, t.category, e.currency;
$$;


-- ----------------------------------------------------------------------
-- 5f. recon_equation_breaks -- recreated, told the truth about, and CLOSED
--
-- THE SQL IS UNCHANGED except for dropping casts that are now no-ops. What
-- changes is the CLAIM and the ACL, and both were defects.
--
-- THE CLAIM. The baseline calls this "THE HIGHEST-LEVERAGE CHECK on the list",
-- catching what "no journal-level check can falsify: the PRESENTATION is where it
-- breaks", and names three defects it protects against -- a mis-bounded plug, a
-- mis-typed close, a swung position netted away. IT CATCHES NONE OF THE THREE, and
-- the reason is algebra rather than a bug: `gap_minor` is the sum of every
-- presented position, so on any journal that foots it is IDENTICALLY ZERO. Spike
-- 025 F1 proved it in both directions -- a complete, well-formed chart version
-- that routes customer_wallet onto trade payables and paid_in_capital onto
-- retained earnings moves 500,000.00 of customer funds and 1,000,000.00 of
-- contributed capital onto the wrong captions, and this check returns ZERO ROWS
-- with every one of the other nine also green; and `gap_minor` agreed to the unit
-- with a direct sum of every presented position on the same book.
--
-- WHAT IT ACTUALLY CATCHES: a position REMOVED from the presented sum, or one
-- ADDED with no opposite. All three reachable classes are JOURNAL-level and every
-- one is already reported by another check in the same sweep -- a transaction
-- whose legs do not foot (unbalanced_transactions), an entry dropped by the
-- account or account-type join (orphan_entries), and legs of one transaction
-- straddling the report cursor (cursor_forgery). The published red path in
-- crates/e2e/tests/e2e/reconcile.rs is the first of those and asserts BOTH checks
-- for exactly this reason.
--
-- WHY IT STILL SHIPS: it is the only check that runs the statement FUNCTION rather
-- than re-deriving it, so it fails if a statement RAISES, if the chart is
-- unusable, or -- since ADR-0020 -- if the checkpoint reader disagrees with the
-- journal on the face. That is worth a row. What it is not is a presentation
-- check, and a real one needs a second declaration to disagree with -- a per-type
-- expected line asserted outside the chart version being tested, or a stored
-- issued statement to diff a re-run against. Both are new tables and a new check
-- row, which is a decision (spike 025 F1, option 2) and not a fix.
--
-- THE ACL. EXECUTE was PUBLIC, and the baseline's own comment reasoned that this
-- was harmless because the function "reads only through the SECURITY INVOKER
-- statement function". That is the defect: an RLS-scoped reader who runs it gets
-- ZERO ROWS over ZERO TENANTS -- `tenants` is `SELECT DISTINCT tenant_id FROM
-- ledger_accounts`, which their policy filters -- and zero rows is a green check.
-- The green-check-that-did-not-execute is the shape ADR-0004 names as this
-- project's own recorded failure ("there was nothing left to disagree with --
-- silence read as assent"), and here it was reachable by every role. Closed below.
-- THE TWO STATEMENT FUNCTIONS STAY PUBLIC: they are the read surface, and RLS is
-- what scopes them -- a reader seeing only their own tenant is the design, whereas
-- a SWEEP seeing only one tenant is a lie about coverage.
CREATE FUNCTION recon_equation_breaks(p_cursor xid8, p_asof timestamptz)
RETURNS TABLE (tenant_id text, currency char(3),
               assets_minor numeric, liab_equity_minor numeric, gap_minor numeric)
LANGUAGE sql STABLE AS $$
    -- AN ALGEBRAIC IDENTITY, NOT A PRESENTATION CHECK. gap_minor is the sum of
    -- every presented position, so it is identically zero on any journal that
    -- foots: every routing error and every `side` error inside the chart is
    -- INVISIBLE here, and every red this can produce is also another check's red.
    -- Proven both ways, spike 025 F1. The header comment in
    -- migrations/00004_the_report_path_reads_the_checkpoint.sql carries the
    -- evidence and what a real presentation check would need.
    --
    -- It runs the statement FUNCTION rather than re-deriving it, which is what it
    -- is genuinely for: a statement that raises, a chart that cannot be presented
    -- through, or a checkpoint reader that disagrees with the journal on the face
    -- all reach the operator here.
    WITH tenants AS (SELECT DISTINCT l.tenant_id FROM ledger_accounts l),
    bs AS (
        SELECT b.tenant_id, b.currency, b.side, b.amount_minor
        FROM tenants tn
        CROSS JOIN LATERAL balance_sheet_at(tn.tenant_id, p_asof, p_cursor) b
    )
    SELECT bs.tenant_id, bs.currency,
           COALESCE(SUM(bs.amount_minor) FILTER (WHERE bs.side = 'asset'), 0) AS assets_minor,
           COALESCE(SUM(bs.amount_minor) FILTER (WHERE bs.side IN ('liability','equity')), 0) AS liab_equity_minor,
           COALESCE(SUM(bs.amount_minor) FILTER (WHERE bs.side = 'asset'), 0)
             - COALESCE(SUM(bs.amount_minor) FILTER (WHERE bs.side IN ('liability','equity')), 0) AS gap_minor
    FROM bs
    GROUP BY bs.tenant_id, bs.currency
    HAVING COALESCE(SUM(bs.amount_minor) FILTER (WHERE bs.side = 'asset'), 0)
        <> COALESCE(SUM(bs.amount_minor) FILTER (WHERE bs.side IN ('liability','equity')), 0);
$$;

REVOKE EXECUTE ON FUNCTION recon_equation_breaks(xid8, timestamptz) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION recon_equation_breaks(xid8, timestamptz) TO openledger_recon;


-- ======================================================================
-- PART 6 -- THE SUMMARY, REBUILT, AND ITS GRANTS
-- ======================================================================
--
-- Part 0 dropped it, and a dropped view takes its ACL with it -- so the GRANT is
-- not optional bookkeeping: openledger_recon reads `reconciliation` for a living
-- and `openledger reconcile` is the command that turns it into an exit code.
--
-- TEN ROWS, byte-for-byte the baseline's. Every fix in this migration was chosen
-- to reach the operator through a `reason` on a check that already exists, which
-- is why EXPECTED_CHECKS in crates/db/src/reconcile.rs, the ten-check oracle in
-- the e2e support book and ALL_CHECKS in the e2e sweep tests are all untouched.
-- The eleventh row is migration 00005's, with the summary-survives-a-raise change
-- it has to land beside.
CREATE VIEW reconciliation AS
SELECT 'balance_cache'      AS check_name, COUNT(*) AS breaks FROM recon_balance_breaks
UNION ALL
SELECT 'orphan_entries',           COUNT(*) FROM recon_entry_breaks
UNION ALL
SELECT 'unbalanced_transactions',  COUNT(*) FROM recon_transaction_breaks
UNION ALL
SELECT 'cross_scope_mirror',       COUNT(*) FROM recon_scope_breaks
UNION ALL
SELECT 'journal_to_reports',       COUNT(*) FROM recon_journal_to_reports
                                   WHERE unexplained_debits <> 0 OR unexplained_credits <> 0
UNION ALL
SELECT 'checkpoint_drift',         COUNT(*) FROM recon_checkpoint_breaks
UNION ALL
SELECT 'close_typing',             COUNT(*) FROM recon_close_breaks
UNION ALL
SELECT 'cursor_forgery',           COUNT(*) FROM recon_cursor_breaks
UNION ALL
SELECT 'accounting_equation',      COUNT(*) FROM recon_equation_breaks(report_cursor(), 'infinity')
UNION ALL
SELECT 'chart_lint',               COUNT(*) FROM chart_lint WHERE severity = 'error';

GRANT SELECT ON recon_close_breaks, reconciliation TO openledger_recon;


-- ======================================================================
-- PART 7 -- THE COMMENTS THAT WERE FALSE
-- ======================================================================
--
-- These are not tidying. Every one of them is dumped into schema/snapshot.txt and
-- compared in CI, so they are SHIPPED, REVIEWED CLAIMS -- and an operator who
-- reads a wrong one believes a check is running that is not. ADR-0003 freezes
-- 00001, so a corrected comment is a new statement here.
COMMENT ON TABLE ledger_period_balances IS
  'The effective-axis checkpoint: one row per account per closed period per currency. AT-CLOSE balances -- the closing entries are included, so a temporary account''s row is exactly 0 and the earnings account carries the swept earnings -- and they are admitted to their own checkpoint by TRANSACTION IDENTITY, not through the cursor: a reproducible computed_at_xid is at or below the closing transaction''s own xid, so no inequality can reach them (ADR-0020, amending ADR-0011 §3). Derived, exactly rebuildable, off the write path, read by balance_sheet_at and reconciled by recon_checkpoint_breaks.';

COMMENT ON VIEW recon_checkpoint_breaks IS
  'The stored period checkpoint against ledger_entries, in ONE pass over the journal plus one over the stored rows instead of one prefix re-aggregation per close: each entry is banded to the first close whose checkpoint contains it, and consecutive stored levels are differenced against that band. Two halves, both load-bearing -- the value comparison (missing_row, spurious_row, value_drift) and the presence comparison (row_span), which catches a deleted trailing row the difference form cannot see. The close''s own transaction is admitted to its own checkpoint by identity. SOUND ONLY WHILE recon_close_breaks IS GREEN: an out-of-order close makes the stored levels stop nesting and this view report false drift (ADR-0020).';

COMMENT ON VIEW recon_close_breaks IS
  'Closes that cannot be what they claim: a cursor below its own closing transaction (cursor_precedes_close) or above the current snapshot''s xmax (cursor_above_assigned); closes out of cursor order, or one whose cursor has not cleared the previous close''s transaction (recon_close_order -- the invariant the bounded checkpoint check and the at-close claim both need); a close whose period''s revenue and expense positions do not net to zero in the checkpoint it wrote (close_does_not_sweep -- ADR-0011 §2''s definition of a close, and the only bound on a MISLABELLED one); and a posted kind=''period_close'' transaction that no period record names (close_orphan -- with no close row the income statement counts the sweep as operating activity, and every key that types a close is vacuous). Five reasons, one summary row (ADR-0020).';

COMMENT ON VIEW close_disclosures IS
  'Entries legally backdated past a close (effective_at before ends_at, xact_id at or after computed_at_xid) EXCEPT the close''s own legs, which the checkpoint carries by identity -- not a break: the analogue of IAS 1.41''s reclassification disclosure, so a row here means an already-issued report no longer matches a re-run at "now" (ADR-0011, ADR-0020).';

COMMENT ON VIEW recon_cursor_breaks IS
  'Entries whose commit key is impossible -- an xact_id at or above the current snapshot''s XMAX (nothing committed can reach latestCompletedXid + 1), or below its own transaction''s (a leg claiming to predate its transaction). Bounded by xmax and NOT by xmin: the cluster horizon is held back by any long-running transaction anywhere on the server, so the xmin form reported breaks on honest committed entries and took the daily sweep to exit 1 on a healthy book. What it gives up: a forgery inside the narrow in-flight band between the horizon and xmax (ADR-0011, ADR-0020).';

COMMENT ON VIEW chart_lint IS
  'Chart claims the account register or the presentation contradicts: a type no version presents, a per_shard type in a house account, a same-side mirror pair, an unattested perimeter account, live drift, a line receiving more than one counterparty grain, restricted money sharing a caption with unencumbered money, and more -- twelve shape rules a CHECK or key cannot reach. Empty is passing; reconciliation counts the error-severity rows only, and the two presentation rules are warn because the published reference chart trips each once, legitimately (ADR-0012, ADR-0020).';

COMMENT ON FUNCTION trial_balance_at(text, timestamptz, timestamptz, xid8) IS
  'The trial balance pinned: per-account debits/credits/debit-positive balance for one tenant over an effective range [p_from, p_to) at a commit cursor (xact_id < p_cursor). PUBLISHES numeric, and that is the fix rather than the decoration the old comment claimed: SUM(bigint) already returns numeric in PostgreSQL, so what overflowed was the cast back to a DECLARED bigint -- reproduced as "bigint out of range" through the writer over HTTP. Not guarded against a NULL argument: a RAISE cannot live in a bare SELECT and the plpgsql form loses the inlining ADR-0011 §4 relies on, so a NULL cursor returns zero rows. No reconciliation check reads this function (ADR-0011, ADR-0013, ADR-0020).';

COMMENT ON FUNCTION income_statement_for(text, timestamptz, timestamptz, xid8, int) IS
  'The income statement over an effective range [p_from, p_to), at a commit cursor, under a chart version (default: current). Enumerates FROM the chart; RAISES on a NULL argument, on a version that does not exist, and on a version that does not present every posted account type in-window; excludes the period''s closing transaction. Reads no checkpoint, and cannot: the accounts it reports are exactly the ones a close zeroes. Publishes numeric. Returns its pinned cursor (ADR-0011, ADR-0020).';

COMMENT ON FUNCTION balance_sheet_at(text, timestamptz, xid8, int) IS
  'The balance sheet as at an instant p_asof (effective_at < p_asof, half-open), at a commit cursor, under a chart version (default: current). READS THE PERIOD CHECKPOINT plus two tails, per currency, instead of aggregating the journal from inception -- proven equal to the from-inception form at 60 (tenant, cursor, as-of) points. Enumerates FROM the chart; positions are per-account then routed to a contra line on sign-swing; synthesises the un-closed-earnings plug; RAISES on a NULL argument and on an unpresented type. Publishes numeric. Returns its pinned cursor (ADR-0011, ADR-0012, ADR-0020).';

COMMENT ON FUNCTION recon_equation_breaks(xid8, timestamptz) IS
  'Assets against liabilities + equity + earnings on the FACE of the balance sheet, per tenant and currency, at (p_cursor, p_asof). AN ALGEBRAIC IDENTITY, not a presentation check, and the old comment claiming it the "highest-leverage check" was false: gap_minor is the sum of every presented position, so it is identically zero on any journal that foots and every routing or side error inside the chart is invisible to it -- proven by a well-formed chart version that moved customer funds onto trade payables with this check at zero rows. What it does catch is a position removed from that sum or added with no opposite, all three classes journal-level and each already reported by another check; what it is FOR is that it runs the statement function rather than re-deriving it, so a statement that raises or a checkpoint reader that disagrees with the journal reaches the operator here. EXECUTE is not PUBLIC: an RLS-scoped reader got zero rows over zero tenants, which is a green check that did not execute (ADR-0010, ADR-0020).';
