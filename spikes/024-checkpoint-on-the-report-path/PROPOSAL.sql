-- ======================================================================
-- SPIKE 024 -- candidate DDL for migration 00004, "the checkpoint on the
-- report path".
--
-- NOT APPLIED. This file is the reviewable text a human turns into
-- migrations/00004_*.sql. It has been applied by hand in scratch databases and
-- every claim its comments make carries evidence in FINDINGS.md; it has NOT been
-- run as a migration, and the timing pass MEASUREMENT-PLAN.md specifies has not
-- been run at all.
--
-- Commented in the baseline's own style: every object says what invariant it
-- holds, why it is shaped that way, and what it does NOT protect against.
--
-- ADR-0003's freeze is CI-enforced (scripts/check-migrations-immutable.sh, no
-- opt-out), so none of this is an edit to 00001_baseline.sql. 00004 is the next
-- free number.
--
-- THE PARTS, AND ONE ORDERING CONSTRAINT. Parts 1b-3 are ONE UNIT that cannot
-- be split; part 1a must come before every view:
--
--   0.  teardown: the summary and the two views that cannot be REPLACEd
--   1a. ledger_period_balances, partitioned by period -- FIRST, because every
--       view below reads it and a table cannot be dropped under a view
--   1b. the close's own arithmetic (the writer's, spec'd here)   \
--   2.  recon_checkpoint_breaks, admitting the close by identity | one unit
--   3.  close_disclosures, its complement                        /
--   4.  recon_close_breaks, replaced -- and recon_cursor_breaks' one-word fix,
--       and recon_transaction_breaks' empty-close carve-out
--   5.  the statement functions, reading checkpoint + two tails
--   6.  (moved to 1a)
--   7.  the summary, rebuilt, and its grants
--   8.  the schema snapshot's new section -- a test change, not DDL
--
-- Why 1b-3 cannot be split: an AT-CLOSE checkpoint under the shipped STRICT
-- recompute reports drift on every close. Measured: 12 break rows on the spike's
-- book, falling to 0 when part 2 lands (FINDINGS §1.6).
-- ======================================================================


-- ======================================================================
-- PART 0 -- TEARDOWN, and why it is a part rather than a line
-- ======================================================================
--
-- `reconciliation` is the operator interface and it reads eight of the views this
-- migration touches, so it pins them. Two of them cannot be CREATE OR REPLACEd:
-- recon_close_breaks' column list changes (it gains prev_cursor and
-- prev_txn_xact_id), and ledger_period_balances cannot be dropped at all while
-- recon_checkpoint_breaks stands. MEASURED, both:
--
--   DROP VIEW recon_close_breaks;
--   ERROR:  cannot drop view recon_close_breaks because other objects depend on it
--   DETAIL:  view reconciliation depends on view recon_close_breaks
--
--   DROP TABLE ledger_period_balances;
--   ERROR:  cannot drop table ledger_period_balances because other objects depend on it
--   DETAIL:  view recon_checkpoint_breaks depends on table ledger_period_balances
--            view reconciliation depends on view recon_checkpoint_breaks
--
-- So the summary comes down first and goes back up last, and part 7 re-issues its
-- grant -- a dropped view takes its ACL with it, and openledger_recon reads
-- `reconciliation` for a living.
DROP VIEW reconciliation;
DROP VIEW recon_checkpoint_breaks;
DROP VIEW recon_close_breaks;


-- ======================================================================
-- PART 1a -- ledger_period_balances, PARTITIONED BY PERIOD
--
-- FIRST, and the ordering is forced rather than chosen: every view below reads
-- this table, and a table cannot be dropped while a view depends on it. Verified
-- the wrong way round -- with the views recreated first, `DROP TABLE` fails naming
-- recon_checkpoint_breaks and recon_checkpoint_breaks_bounded.
-- ======================================================================
--
-- WHAT IT IS FOR. Spike 020: closing 1,000,000 accounts in one currency took ~49 s
-- and wrote 1,000,003 rows / 135 MB, and ~96% of that is the checkpoint WRITE --
-- one row per account plus primary-key and foreign-key maintenance -- against ~4%
-- aggregation. Its verdict was that this wants partitioning by period "before
-- anything else".
--
-- THE MECHANISM, STATED SO IT CAN BE FALSIFIED. Partitioning by period does NOT
-- reduce the number of rows written or the number of index entries maintained.
-- What it changes is WHICH index they enter: one fresh, empty, sequentially-filled
-- per-partition primary key per close, instead of appending into a shared tree
-- grown by every period before it. If that is where the 96% goes, the saving GROWS
-- with the number of periods already closed and is ~0 ON THE FIRST CLOSE.
-- UNMEASURED. MEASUREMENT-PLAN.md is the pass that has to falsify it.
--
-- THE KEY: LIST (period_code). Legal because period_code is a column of
-- pk_period_balances -- a partition key must be a SUBSET of every unique
-- constraint, not a prefix of it -- so the tenant-leading primary key is
-- UNCHANGED and costs nothing here. Verified:
--     pg_get_partkeydef -> LIST (period_code)
--     pk_period_balances -> PRIMARY KEY (tenant_id, period_code, currency, account_id)
--
-- WHAT IT COSTS, all four measured or read from the schema:
--
--  1. period_code IS A TENANT-SUPPLIED FREE-TEXT LABEL. The baseline's own comment
--     says so: "'2026-02', 'FY2026Q1' -- a label, not a key of time." Under LIST
--     the partition set is the UNION of every tenant's vocabulary. Demonstrated:
--     two tenants, three distinct codes, three partitions.
--  2. THE APP ROLE CANNOT CREATE A PARTITION. The close is an ordinary posting by
--     openledger_app, which holds no CREATE privilege, so a period whose partition
--     was never provisioned would make the CLOSE FAIL rather than merely lose the
--     benefit. The DEFAULT partition is what keeps the close working; provisioning
--     the per-period ones is an operator or migration task.
--  3. THE PARTITIONS CARRY NO GRANTS, AND THAT IS LOAD-BEARING. Policies on a
--     partitioned parent apply to parent-routed access only; a partition addressed
--     DIRECTLY carries only its own policies, and it has none. The only thing
--     stopping a direct, unscoped read of every tenant's checkpoint is the absence
--     of a grant -- verified: `permission denied for table
--     ledger_period_balances_p2026_01` as openledger_read WITH app.tenant_id set.
--     A later `GRANT ... ON ALL TABLES IN SCHEMA public` opens it.
--  4. HASH (period_code) IS THE ALTERNATIVE and buys something different: fixed
--     partition count, no DDL per period, no vocabulary problem -- and no
--     per-period DETACH, and each partition's index still grows with every period.
--     A smaller-trees change, not a lifecycle change. LIST is proposed because the
--     empty-index-per-close mechanism above is the one spike 020's measurement
--     points at.
--
-- WHAT SURVIVES, all verified by applying this and asking the catalog: both
-- foreign keys (on the parent AND every partition, and both still refuse a real
-- violation through the parent); all three RLS policies, with a scoped reader
-- still scoped and an unscoped one still at zero rows; every grant, with
-- parent-routed INSERT working and UPDATE/DELETE/TRUNCATE still refused; and the
-- reconciliation sweep at ten zeros afterwards.
--
-- THE APPEND-ONLY PERIMETER PERMITS THIS ONE. ledger_period_balances is not in
-- refuse_journal_ddl's `protected` array (verified from pg_get_functiondef). The
-- contrast matters and belongs in the ADR: ck_journal__no_inherit is a STATE
-- assertion over pg_inherits, and a partition creates a pg_inherits row exactly as
-- an inheritance child does -- measured, `CREATE TABLE probe_child () INHERITS
-- (ledger_entries)` is refused -- so partitioning any PROTECTED table is refused
-- by the shipped perimeter. The roadmap's "PARTITION BY HASH (tenant_id) succeeds
-- on ledger_entries" needs a caveat.
--
-- THERE IS NO IN-PLACE CONVERSION. Verified: `ALTER TABLE ...  PARTITION BY LIST`
-- is a syntax error, the statement does not exist. So this is create-move-swap.
--
-- AND THE ORDER INSIDE IT IS NOT COSMETIC. Building the partitioned table BESIDE
-- the old one forces suffixed constraint names, and ALTER TABLE ... RENAME
-- CONSTRAINT on a partitioned parent renames THE PARENT'S COPY ONLY -- measured:
-- 55 constraint rows, 20 of them left carrying fk_period_balances__close_new on
-- the partitions and ledger_period_balances_new_tenant_id_not_null everywhere,
-- permanently. So the rows are parked and the old table dropped FIRST. One extra
-- copy of a table that is derived anyway, and the baseline's naming survives.
--
-- THE ALTERNATIVE AVAILABLE ONLY BECAUSE OF WHAT THIS TABLE IS: it is derived and
-- exactly recomputable from ledger_entries at each close's own computed_at_xid,
-- which is ADR-0011 §3's whole argument -- so "rebuild by recomputation" is a
-- legal migration strategy here where it would not be for a journal table.
-- Copying preserves history byte for byte and is what a migration should do; the
-- recompute is the fallback that proves the table is derived. Which is faster on a
-- large book is a number.

CREATE UNLOGGED TABLE lpb_stage AS SELECT * FROM ledger_period_balances;
DROP TABLE ledger_period_balances;

CREATE TABLE ledger_period_balances (
    tenant_id      text NOT NULL,
    period_code    text NOT NULL,
    currency       char(3) NOT NULL,
    account_id     uuid NOT NULL,
    input          bigint NOT NULL,
    output         bigint NOT NULL,
    CONSTRAINT pk_period_balances PRIMARY KEY (tenant_id, period_code, currency, account_id),
    CONSTRAINT ck_period_balances__tenant_non_empty CHECK (btrim(tenant_id) <> ''),
    CONSTRAINT ck_period_balances__non_negative CHECK (input >= 0 AND output >= 0),
    CONSTRAINT fk_period_balances__close FOREIGN KEY (tenant_id, period_code, currency)
        REFERENCES ledger_period_closes (tenant_id, period_code, currency),
    CONSTRAINT fk_period_balances__account FOREIGN KEY (tenant_id, account_id, currency)
        REFERENCES ledger_accounts (tenant_id, id, currency)
) PARTITION BY LIST (period_code);

-- One partition per period code that exists at migration time, plus the DEFAULT.
-- A migration cannot enumerate the future, which is cost 2 above: everything from
-- here is an operator's provisioning job, and the DEFAULT is what makes a missed
-- provisioning a lost benefit rather than a failed close.
--
--   CREATE TABLE ledger_period_balances_p<code>
--       PARTITION OF ledger_period_balances FOR VALUES IN ('<code>');
--
-- ...generated from `SELECT DISTINCT period_code FROM lpb_stage`. Spelled out
-- literally rather than in a DO block, because a migration whose DDL depends on
-- data is a migration nobody can review.
CREATE TABLE ledger_period_balances_pdefault
    PARTITION OF ledger_period_balances DEFAULT;

INSERT INTO ledger_period_balances SELECT * FROM lpb_stage;
DROP TABLE lpb_stage;

ALTER TABLE ledger_period_balances ENABLE ROW LEVEL SECURITY;
CREATE POLICY rls_period_balances__tenant ON ledger_period_balances
    FOR SELECT TO openledger_read
    USING (tenant_id = (SELECT current_setting('app.tenant_id', true)));
CREATE POLICY rls_period_balances__writer ON ledger_period_balances
    FOR ALL TO openledger_app USING (true) WITH CHECK (true);
CREATE POLICY rls_period_balances__recon ON ledger_period_balances
    FOR SELECT TO openledger_recon USING (true);

GRANT SELECT, INSERT ON ledger_period_balances TO openledger_app;
GRANT SELECT ON ledger_period_balances TO openledger_read;
GRANT SELECT ON ledger_period_balances TO openledger_recon;
-- belt and braces, for the reason the baseline gives: a later `GRANT ALL ON ALL
-- TABLES` is one statement and this is the line that survives it in review.
REVOKE UPDATE, DELETE, TRUNCATE ON ledger_period_balances FROM openledger_app;

COMMENT ON TABLE ledger_period_balances IS
  'The effective-axis checkpoint: one row per account per closed period per currency, partitioned BY LIST (period_code). AT-CLOSE balances -- closing entries included, admitted to their own checkpoint by transaction identity rather than through the cursor (spike 024) -- derived, rebuildable, off the write path, and reconciled by recon_checkpoint_breaks.';



-- ======================================================================
-- PART 1b -- WHAT THE CLOSE MUST STORE  (specification; the code is the writer's)
-- ======================================================================
--
-- THE INVARIANT: ledger_period_balances holds the AT-CLOSE position -- closing
-- entries included, so a temporary account's row is exactly 0 and
-- retained_earnings carries the swept earnings. That is what ADR-0011 §3 (A4),
-- the ledger_period_balances comment and recon_close_breaks' header note all
-- assert, and what the shipped mechanism does NOT do: measured, the shipped close
-- stores fee_revenue = -500 and writes no retained_earnings row at all
-- (FINDINGS §1.2).
--
-- WHY IT COULD NOT BE DONE WITH AN INEQUALITY. `computed_at_xid` must be a value
-- below which the visible set is fixed for all time, and ADR-0011 §1 proves that
-- pg_snapshot_xmin is the only such value here. pg_snapshot_xmin is <= the
-- caller's own xid whenever the caller holds one, so a cursor ABOVE the closing
-- transaction's own entries is unreachable from the transaction that writes them.
-- Binding pg_current_xact_id() instead makes the inequality work and destroys
-- reproducibility: measured, an older writer committing after the close makes the
-- checkpoint reader LOSE a real posting (10,570 read as 10,500 -- FINDINGS §1.3).
-- There is no third value: pg_snapshot_xmax admits in-flight transactions that
-- commit later (ADR-0011 §1's refuted `max(xact_id) + 1`), and xid8 has no
-- successor operator.
--
-- THE MECHANISM: the close's own transaction is ALREADY NAMED, in
-- ledger_period_closes.transaction_id under fk_closes__txn, fk_closes__txn_kind
-- and uq_closes__txn. So it does not need to be reachable through the cursor at
-- all. The cursor keeps its one job -- bounding everything else.
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
--      aggregated. The shipped helper writes it first, which is the other half of
--      why the stored row is pre-close.
--
--  (b) THE CLOSE MUST REFUSE TO RUN while the cluster horizon has not cleared the
--      PREVIOUS close's own transaction. If it does not, this checkpoint silently
--      omits the previous sweep and is not the at-close position either -- and the
--      bounded reconciliation in part 4 is unsound. ADR-0011 already accepts the
--      coupling ("a close cannot complete while xmin is pinned below it"); this
--      makes it explicit. A precondition check in the writer, not a trigger:
--
--          pg_snapshot_xmin(pg_current_snapshot())
--              > (the previous close's transaction's xact_id)
--
--      recon_close_order (part 4) is what catches a close that ran anyway.
--
-- WHAT THIS DOES NOT DO: it does not make the checkpoint see rows that were
-- uncommitted when the close ran. Those arrive above computed_at_xid and are the
-- tail term, exactly as before -- and close_disclosures enumerates them.


-- ======================================================================
-- PART 2 -- recon_checkpoint_breaks: the recompute admits the close by identity
-- ======================================================================
--
-- The bound moves from `e.xact_id < c.computed_at_xid` to
-- `... OR e.transaction_id = c.transaction_id`. NOT to `<=`: `<=` is equivalent
-- only when computed_at_xid EQUALS the closing transaction's own xid, which
-- happens only on an idle cluster (measured: 16132 against 16134 with one other
-- writer running -- FINDINGS §1.4), and the value that forces equality is not a
-- reproducible cursor.
--
-- Naming the transaction needs no relationship between the two values at all,
-- which is why it is the mechanism rather than the inequality.
--
-- The rest of the body is the baseline's, verbatim, including A11's
-- compare-VALUES-not-presence rule: a dormant account for which the close wrote a
-- 0/0 row has a stored row and no recomputed row, and 0 = 0 is not a break.
--
-- CREATE, not CREATE OR REPLACE: part 0 dropped it, because part 6 has to drop
-- the table underneath it.
CREATE VIEW recon_checkpoint_breaks AS
WITH recomputed AS (
    SELECT c.tenant_id, c.period_code, c.currency, e.account_id,
           COALESCE(SUM(e.amount_minor) FILTER (WHERE e.direction = 'debit'), 0)  AS input,
           COALESCE(SUM(e.amount_minor) FILTER (WHERE e.direction = 'credit'), 0) AS output
    FROM ledger_period_closes c
    JOIN ledger_entries e
      ON e.tenant_id = c.tenant_id AND e.currency = c.currency
     AND e.effective_at < c.ends_at
     -- the close's own transaction, admitted by IDENTITY rather than through the
     -- cursor. This is what makes the stored row the AT-CLOSE position (A4).
     AND (e.xact_id < c.computed_at_xid OR e.transaction_id = c.transaction_id)
    JOIN ledger_transactions x
      ON x.tenant_id = e.tenant_id AND x.id = e.transaction_id AND x.status = 'posted'
    GROUP BY c.tenant_id, c.period_code, c.currency, e.account_id
)
SELECT COALESCE(s.tenant_id,  r.tenant_id)  AS tenant_id,
       COALESCE(s.period_code, r.period_code) AS period_code,
       COALESCE(s.currency,   r.currency)   AS currency,
       COALESCE(s.account_id, r.account_id) AS account_id,
       COALESCE(s.input, 0)  AS stored_input,
       COALESCE(s.output, 0) AS stored_output,
       COALESCE(r.input, 0)  AS recomputed_input,
       COALESCE(r.output, 0) AS recomputed_output,
       CASE WHEN s.account_id IS NULL THEN 'missing_row'
            WHEN r.account_id IS NULL THEN 'spurious_row'
            ELSE 'value_drift' END AS reason
FROM ledger_period_balances s
FULL JOIN recomputed r
  ON r.tenant_id = s.tenant_id AND r.period_code = s.period_code
 AND r.currency = s.currency AND r.account_id = s.account_id
WHERE COALESCE(s.input, 0)  <> COALESCE(r.input, 0)
   OR COALESCE(s.output, 0) <> COALESCE(r.output, 0);


-- ======================================================================
-- PART 3 -- close_disclosures: the complement of the recompute's bound
-- ======================================================================
--
-- This view is defined as "everything the checkpoint did NOT see", so it has to
-- move with part 2 or the two together will both include, or both exclude, the
-- closing entries.
--
-- The narrow `e.transaction_id <> c.transaction_id` replaces the shipped wide
-- NOT EXISTS over ALL closes. THE WIDE FORM IS KEPT ANYWAY, and the reason is
-- measured rather than cautious: on a book where the closes of one
-- (tenant, currency) are in period order the wide carve-out is DEAD -- 18 rows
-- with it, 18 without, 0 rows only-without. On a book with an OUT-OF-ORDER close
-- it is live: 0 with, 2 without, and the two are the earlier close's own legs
-- (FINDINGS §3.4). It is dead exactly when recon_close_order is green, and a
-- carve-out whose deadness depends on another check's greenness is not one to
-- delete.
CREATE OR REPLACE VIEW close_disclosures AS
SELECT c.tenant_id, c.period_code, c.currency, c.computed_at_xid,
       e.id AS entry_id, e.transaction_id, e.account_id, e.direction,
       e.amount_minor, e.effective_at, e.xact_id, e.recorded_at
FROM ledger_period_closes c
JOIN ledger_entries e
  ON e.tenant_id = c.tenant_id AND e.currency = c.currency
 AND e.effective_at < c.ends_at
 AND e.xact_id >= c.computed_at_xid
 -- ...but not the close's own legs, which the checkpoint carries by identity
 AND e.transaction_id <> c.transaction_id
JOIN ledger_transactions x
  ON x.tenant_id = e.tenant_id AND x.id = e.transaction_id AND x.status = 'posted'
WHERE NOT EXISTS (SELECT 1 FROM ledger_period_closes c2
                  WHERE c2.tenant_id = x.tenant_id AND c2.transaction_id = x.id);


-- ======================================================================
-- PART 4 -- THE SWEEP: one check replaced, one bounded, two bugs fixed
-- ======================================================================

-- ----------------------------------------------------------------------
-- 4a. recon_close_breaks is REPLACED, and its predicate is INVERTED
--
-- The shipped view breaks on `c.computed_at_xid < x.xact_id` --
-- `cursor_precedes_close`. That is a FALSE POSITIVE on any cluster that is not
-- idle: pg_snapshot_xmin is strictly below the caller's own xid whenever any
-- older transaction is running, so an honest close on a busy server fires it.
-- Measured: 16024 < 16025 on a close whose checkpoint reconciles cleanly and
-- whose reader agrees with the journal to the minor unit (FINDINGS §1.1). It is
-- green today only because an idle cluster hands the close the very xid it is
-- about to take, making the two values EQUAL.
--
-- WHAT REPLACES IT, four classes, all O(closes) and none touching
-- ledger_entries. The first two are what the bounded checkpoint check in 4b
-- needs; the second two are the forgery bounds computed_at_xid never had.
--
--  (i)  cursor_not_monotone         -- closing in period order must also close in
--                                     cursor order, or the stored levels stop
--                                     nesting and a DIFFERENCE of levels is not a
--                                     difference of nested sets
--  (ii) previous_close_above_cursor -- this close's cursor must clear the previous
--                                     close's own transaction, or this checkpoint
--                                     silently omits the previous sweep and is not
--                                     the at-close position either. THIS is the
--                                     condition that makes A4's prose true
--  (iii) cursor_above_close         -- pg_snapshot_xmin is <= the caller's own xid
--                                     whenever the caller holds one, so a cursor
--                                     ABOVE the close cannot have been captured by
--                                     it. The INVERSE of the shipped predicate
--  (iv) cursor_above_horizon        -- and a cursor above the CURRENT horizon was
--                                     never captured at all. The same forgery
--                                     recon_cursor_breaks refuses for an entry,
--                                     applied to the one xid8 column that sits
--                                     under a TABLE-WIDE insert grant
--                                     (migrations/00001_baseline.sql:2518)
--
-- WHY xmin AND NOT xmax IN (iv): computed_at_xid is a CAPTURED xmin, and the
-- cluster xmin is non-decreasing -- it is the minimum over the running set, xids
-- are handed out monotonically, and that set only loses members or gains larger
-- ones. So any honestly captured value is at or below the current xmin. xmax
-- would admit a cursor above the horizon, which is the forgery this is for.
--
-- WHAT IT DOES NOT PROTECT AGAINST: a forged cursor BELOW the true one. Measured:
-- computed_at_xid = 1 is caught here (two classes), but a cursor forged low on a
-- book with no arrivals above the true cursor produces an arithmetically
-- consistent checkpoint that buys nothing. That is a performance defect, not a
-- correctness one -- the reader's tail B picks up everything the checkpoint
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
        CASE WHEN p.prev_cursor IS NOT NULL AND p.computed_at_xid < p.prev_cursor
             THEN 'cursor_not_monotone' END,
        CASE WHEN p.prev_txn_xact_id IS NOT NULL
                  AND p.prev_txn_xact_id >= p.computed_at_xid
             THEN 'previous_close_above_cursor' END,
        CASE WHEN p.computed_at_xid > p.txn_xact_id
             THEN 'cursor_above_close' END,
        CASE WHEN p.computed_at_xid > pg_snapshot_xmin(pg_current_snapshot())
             THEN 'cursor_above_horizon' END
    ]) AS r WHERE r IS NOT NULL
) AS b(reason);

COMMENT ON VIEW recon_close_breaks IS
  'Closes whose computed_at_xid cannot have been honestly captured, or whose order breaks the nesting the checkpoint arithmetic and the bounded checkpoint check depend on. Replaces the cursor_precedes_close predicate, which was a false positive on any non-idle cluster (spike 024).';


-- ----------------------------------------------------------------------
-- 4b. recon_checkpoint_breaks_bounded -- O(entries + stored rows), not
--     O(entries x closes)
--
-- The shipped level form joins EACH close to EVERY entry effective before that
-- close's end, so close k re-aggregates the whole prefix up to period k: measured
-- 1 : 3.2 : 5.8 : 8.2 over 3/6/9/12 closes (spike 020).
--
-- THE OBSERVATION THAT BOUNDS IT: the checkpoint is CUMULATIVE -- the recompute
-- has no lower bound on effective_at -- so consecutive checkpoints differ by
-- exactly one close's own arrivals. Assign each entry the index of the FIRST
-- close whose checkpoint contains it (one number, one pass) and compare the
-- DIFFERENCE of consecutive stored levels against the entries at that index.
--
-- The assignment is O(log C) per entry, not O(C): both bounds are monotone under
-- 4a's invariants, so
--     first close whose end is above this entry's effective_at
--        = width_bucket(effective_at, <the ends ascending>) + 1
--     first close whose cursor is above this entry's xact_id
--        = width_bucket(xact_id, <the cursors, same order>) + 1
-- and the entry enters at the LATER of the two. width_bucket over an array is a
-- binary search; xid8 carries a default btree opclass (xid8_ops, verified), so it
-- works on the cursor axis too. LEAST ignores NULLs in PostgreSQL, so the
-- identity term can only pull the index earlier and is inert for an ordinary
-- entry.
--
-- THE TWO CTEs ARE MATERIALIZED DELIBERATELY. As plain references the close index
-- is re-planned at every use -- seven WindowAgg nodes -- and the planner's
-- estimate for the whole view was 8x higher, dominated by that rather than by the
-- single pass over ledger_entries the design is about. They are a dozen rows.
--
-- WHAT IT COSTS IN COVERAGE, AND WHY THE SECOND HALF IS NOT BELT AND BRACES.
-- Comparing DIFFERENCES loses a drift class the level form catches: a deleted
-- TRAILING row for an account with no arrivals in that period gives a stored
-- difference of 0 against recomputed arrivals of 0, and there is nothing to
-- disagree about. MEASURED: without the span half the bounded form reports 0
-- where the level form reports 1; with it, 1 and 1 (FINDINGS §3.2). The span half
-- is O(stored rows) and touches no entry, which is the floor for any check that
-- looks at every stored row at all.
--
-- WHAT IT DOES NOT DO: it does not report the same ROW COUNT or the same reason
-- LABELS as the level form. A single forged value produces TWO rows (the
-- difference at close k and at k+1) and the second is labelled `spurious_row`
-- because it has no arrivals row to pair with. More sensitive, less precisely
-- worded. An operator contract change, and it is documented rather than
-- discovered.
CREATE OR REPLACE VIEW recon_checkpoint_breaks_bounded AS
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
    -- stored row at close k it must have one at every later close of that
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
-- A11 kept: compare VALUES, not presence. A dormant account's 0/0 row has no
-- arrivals to pair with and 0 = 0 is not a break.
WHERE COALESCE(s.d_in,  0) <> COALESCE(r.dr, 0)
   OR COALESCE(s.d_out, 0) <> COALESCE(r.cr, 0)
UNION ALL
SELECT sp.tenant_id, spk.period_code, sp.currency, sp.account_id,
       sp.rows_present, sp.last_k - sp.first_k + 1, 0::bigint, 0::bigint,
       'row_span' AS reason
FROM span sp
LEFT JOIN cl spk
  ON spk.tenant_id = sp.tenant_id AND spk.currency = sp.currency AND spk.k = sp.last_k
WHERE sp.rows_present <> sp.last_k - sp.first_k + 1;

COMMENT ON VIEW recon_checkpoint_breaks_bounded IS
  'The checkpoint against the journal in one pass over ledger_entries plus one pass over the stored rows, instead of one prefix re-aggregation per close. Sound only while recon_close_breaks is green: an out-of-order close makes the stored levels stop nesting and this view report false value_drift (spike 024).';

-- HOW TO ADOPT IT. Not by swapping `reconciliation`'s checkpoint_drift row over on
-- faith: the two forms report the same KEYS and different counts, and the bounded
-- form is only sound under 4a's order invariant. The staged form -- both rows in
-- the summary until the bounded one has run beside the level one on a real book
-- for a while -- is what ADR-0010's "a break list and a statement are different
-- objects" reasoning suggests, and it is cheap:
--
--   UNION ALL SELECT 'checkpoint_drift_bounded', COUNT(*)
--                    FROM recon_checkpoint_breaks_bounded
--
-- ...which makes `reconciliation` ELEVEN rows and is a documented interface
-- change. Whether to stage or to swap is the ADR's call; whether the bounded form
-- is actually FASTER is a number, and it is not one this spike has
-- (MEASUREMENT-PLAN.md).


-- ----------------------------------------------------------------------
-- 4c. recon_cursor_breaks -- one word, and it stops crying wolf
--
-- The shipped view bounds an entry's xact_id by pg_snapshot_XMIN, and its comment
-- asserts "a committed row's commit position is always retired below the horizon
-- by the time the sweep runs". That is FALSE whenever any transaction older than
-- the entry is still running -- which on a busy database is most recent entries.
-- MEASURED: two above_horizon breaks against one honest committed posting, with
-- the sweep run exactly as `openledger reconcile` runs it (BEGIN TRANSACTION READ
-- ONLY, no xid of its own), and `reconciliation` reporting cursor_forgery <> 0 --
-- so the daily sweep EXITS 1 ON A HEALTHY BOOK (FINDINGS §4.1).
--
-- pg_snapshot_XMAX is latestCompletedXid + 1, so no COMMITTED xid can reach it:
-- 0 breaks on the same book at the same instant. The `predates_txn` half is
-- unchanged and was never wrong.
--
-- WHAT IT DOES NOT PROTECT AGAINST: a forged xact_id below the horizon, which is
-- the majority of the value space. This check was always about the impossible
-- shapes only, and the baseline says so.
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
-- 4d. recon_transaction_breaks -- the EMPTY CLOSE carve-out
--
-- A period in which no revenue or expense moved cannot be closed without breaking
-- the sweep. The close posts one leg pair per temporary account with a non-zero
-- balance (ADR-0011 §2, and the HAVING in every implementation of it), so a
-- period with nothing to sweep writes a period_close transaction with ZERO
-- ENTRIES -- and this view flags every entryless transaction as `no_entries`, the
-- ADR-0004 TRUNCATE scar's class. Migration 00003 carved out the VOID and nothing
-- else. MEASURED: a book with a capital injection and no revenue reconciles at
-- ten zeros, and closing its one period takes `openledger reconcile` to exit 1
-- (FINDINGS §4.2).
--
-- The carve-out is EXACTLY as narrow as the void's: zero entries AND
-- kind = 'period_close' AND a ledger_period_closes row naming this transaction.
-- A key lookup, the same device ADR-0011 §2 chose for the income statement's
-- exclusion, and tight -- fk_closes__txn_kind already forces the kind and
-- uq_closes__txn makes the naming one-to-one. An entryless transaction claiming
-- kind='period_close' that no close row names stays a break.
--
-- CREATE OR REPLACE keeps the view's owner, grants and column list; only the
-- WHERE grows. The body is otherwise migration 00003's, verbatim.
CREATE OR REPLACE VIEW recon_transaction_breaks AS
WITH legs AS (
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
  -- ...and the EMPTY CLOSE carve-out (spike 024): a period with no
  -- temporary-account movement has nothing to sweep, so its close is a marker,
  -- exactly as the void is.
  AND NOT (g.transaction_id IS NULL
           AND x.kind = 'period_close'
           AND EXISTS (SELECT 1 FROM ledger_period_closes c
                       WHERE c.tenant_id = x.tenant_id AND c.transaction_id = x.id));


-- ======================================================================
-- PART 5 -- THE REPORT PATH: checkpoint plus two tails
-- ======================================================================
--
-- What ADR-0011 §3 specified and nothing read. The measured benefit is 45-49x at
-- a close boundary and 8-9x mid-period on one account (ADR-0011 §3), ~40-230x on
-- a million-entry book (spike 020) -- and it is ADR-0011 §3's own claim, not this
-- spike's: the timing pass here has not been run.
--
-- WHICH FUNCTIONS TAKE IT, and this is the part of the answer the ADR did not
-- have:
--
--   balance_sheet_at      -- YES. It is a POSITION at one instant, and it is the
--                            only one of the three that actually scans from
--                            inception: three scans, in fact -- the position
--                            aggregate, the earnings plug, and the A14 guard --
--                            and recon_equation_breaks calls it at
--                            ('infinity', report_cursor()) per tenant on EVERY
--                            reconciliation sweep.
--   trial_balance_at      -- YES, but only as prefix(to) - prefix(from), because
--                            it is a FLOW. Bounded by two period lengths instead
--                            of unbounded, and MORE work than today's body for a
--                            window that sits well inside one period. Which side
--                            of that trade a caller is on is a number.
--   income_statement_for  -- NO, and not for want of trying. Three reasons, the
--                            third decisive: it is a flow; the accounts it reports
--                            are exactly the ones the close ZEROES, so every
--                            checkpoint row it would read is 0 by construction
--                            (A4) and the flow is only recoverable by adding back
--                            the closing entries the statement is specified to
--                            EXCLUDE; and its dp CTE already carries
--                            `effective_at >= p_from`, so there is no
--                            from-inception scan to remove. It needs no checkpoint
--                            and gets none.
--
-- THE CLAIM THIS CORRECTS: ADR-0011 §3 and roadmap M5 both say all three "scan
-- ledger_entries from inception". True of balance_sheet_at only; the other two are
-- bounded below by a caller-supplied instant. The first half of the sentence --
-- that none of them reads the checkpoint -- is spike 020's finding and stands.
--
-- PROVEN AGREEMENT: the rewritten bodies agree with the from-inception bodies to
-- the minor unit at all 60 (tenant, cursor, as-of) points of spike 024's grid, on
-- a book with no closes, one close, three closes, a backdated posting, a
-- resolution backdated into a closed period, a reversal of a posted transaction
-- backdated into a closed period, a voided pending, a pending never resolved, two
-- currencies closed to DIFFERENT depths, as-of exactly on each close boundary,
-- as-of mid-period, and as-of 'infinity' -- and under both close conventions.


-- ----------------------------------------------------------------------
-- 5a. the anchor -- which close a report may read, and there are two guards
--
-- Factored out because all the readers need the SAME choice of boundary and a
-- second copy of it is a second place to get these two wrong. Neither is in
-- ADR-0011 §3.
--
--  (a) PER CURRENCY. pk_closes is (tenant_id, period_code, currency), so a tenant
--      closed through March in USD and only through January in EUR is an ordinary
--      state. A boundary chosen per TENANT reads the wrong checkpoint for one of
--      them. This is measured, not hypothetical -- spike 024's book is built that
--      way on purpose.
--
--  (b) THE WHOLE CHECKPOINT MUST BE VISIBLE AT THIS REPORT'S CURSOR, and the last
--      thing to become visible is the CLOSING TRANSACTION, whose xact_id is at or
--      above computed_at_xid. Guarding on computed_at_xid alone admits a
--      checkpoint containing entries the report must not see, and a close that
--      happened after a statement was issued would then restate that statement
--      UPWARD -- which is precisely the property the cursor exists to prevent
--      (ADR-0011 §1). Both predicates are kept: a forged computed_at_xid above the
--      closing transaction is refused by recon_close_breaks but not by the reader,
--      and a reader that trusts a check it does not run is not a reader.
--
-- STABLE, not IMMUTABLE: it reads tables. It is a plain SQL set-returning
-- function so PostgreSQL can inline it (ADR-0011 §4's reason for
-- trial_balance_at's form).
CREATE OR REPLACE FUNCTION checkpoint_anchor(p_tenant text, p_asof timestamptz,
                                             p_cursor xid8)
RETURNS TABLE (currency char(3), period_code text, boundary timestamptz,
               ckpt_cursor xid8, close_txn uuid)
LANGUAGE sql STABLE AS $$
    SELECT s.currency, c.period_code,
           -- NO CLOSE: boundary '-infinity' and cursor 0. The form then degrades
           -- to today's behaviour with no special case -- tail B is empty because
           -- ck_entries__effective_finite forbids an entry at -infinity, tail A is
           -- everything, and the checkpoint term joins nothing.
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
  'The close a report at (as_of, cursor) may read from, per currency: the latest whose period end is at or before as_of and whose whole checkpoint -- including its own closing transaction -- is visible at the cursor. Returns boundary -infinity and cursor 0 for a currency with no close (spike 024).';


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
-- fee_revenue read 1,000 against a true 500 (spike 024, own_xid arm).
--
-- GROSS, not netted, for two reasons: trial_balance_at needs both halves, and
-- "did this account have ANY posted entry below the boundary" is only answerable
-- from a gross sum. ck_entries__amount_positive is CHECK (amount_minor > 0), so
-- debits + credits > 0 iff at least one posted entry -- which is what lets the A14
-- guard read the checkpoint instead of the journal.
--
-- numeric, cast at the boundary, for ADR-0013's reason: a single huge-but-legal
-- row overflows a running bigint SUM and raises the whole SELECT, and a report
-- that dies on one large row reports nothing.
CREATE OR REPLACE FUNCTION checkpoint_position(p_tenant text, p_asof timestamptz,
                                               p_cursor xid8)
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
        -- WANTS ix_entries__tenant_effective (part 5e): both existing indexes put
        -- account_id in second position, and a tenant-wide range on effective_at
        -- has no leading path through either.
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
        -- exists (ADR-0011 §3). PostgreSQL 18's btree skip scan does choose that
        -- index for the TENANT-WIDE form as well as the single-account one it was
        -- measured on -- verified by plan -- so this term is served today.
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
  'Per-account gross debits and credits as at (as_of, cursor), from the period checkpoint plus the two tails ADR-0011 §3 specifies. Exactly equal to the from-inception aggregate: proven to the minor unit at 60 (tenant, cursor, as-of) points (spike 024).';


-- ----------------------------------------------------------------------
-- 5c. balance_sheet_at -- the shipped body with three substitutions
--
-- `pos` reads checkpoint_position instead of aggregating ledger_entries; the
-- earnings plug reads the same rows rather than re-deriving them; and the A14
-- guard asks the same question of the same population. EVERYTHING ELSE IS COPIED
-- VERBATIM: the chart-outward CROSS JOIN fs_lines, the contra routing on position
-- sign, the sign-follows-the-line rule, the constant plug caption, and the
-- ORDER BY. The four numbered reasons in the baseline's own header still hold and
-- are not repeated here.
--
-- THE PLUG READS `pos`, and that is deliberate. A second hand-written subquery
-- over ledger_entries -- which is what the shipped body has -- is a second place
-- for the boundary to be chosen, and the two could disagree about where it is
-- while both looking correct. One anchor, one population.
--
-- A14, over the checkpoint population. `debits + credits > 0` is what makes it
-- equivalent: amount_minor is CHECKed > 0, so an account with any posted entry
-- below the boundary has a non-zero gross checkpoint row, and a dormant account
-- the close wrote 0/0 for is correctly NOT treated as having entries.
-- WHAT IS NOT PROVEN: the RED case. An account type with posted entries and no
-- chart_presentation row at the requested version was not constructed against
-- this form, because schema/chart.sql seeds the chart whole. The migration's own
-- test owes that one.
CREATE OR REPLACE FUNCTION balance_sheet_at(p_tenant text, p_asof timestamptz, p_cursor xid8,
                                            p_chart_version int DEFAULT NULL)
RETURNS TABLE (tenant_id text, currency char(3), chart_version int, fs_line text,
               caption text, sort_order int, amount_minor bigint, side text,
               pinned_cursor xid8)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_cv int;
BEGIN
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
               COALESCE(SUM(CASE WHEN f.side = 'asset' THEN d.v ELSE -d.v END), 0)::bigint
                   AS amount_minor
        FROM scopes s
        JOIN fs_lines f ON f.chart_version = v_cv
        LEFT JOIN dp d ON d.tenant_id = s.tenant_id AND d.currency = s.currency
                      AND d.fs_line = f.code
        WHERE f.statement = 'balance_sheet'
        GROUP BY s.tenant_id, s.currency, f.code, f.caption, f.sort_order, f.side
    ), plug AS (
        SELECT s.tenant_id, s.currency,
               (-COALESCE((
                   SELECT SUM(pp.v) FROM pos pp
                   WHERE pp.tenant_id = s.tenant_id AND pp.currency = s.currency
                     AND pp.category IN ('revenue','expense')
               ), 0))::bigint AS amount_minor
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
-- 5d. trial_balance_at -- a flow, so a DIFFERENCE of two positions
--
--     gross over [from, to)  =  prefix(to) - prefix(from)
--
-- Exact because prefix() sums GROSS debits and credits over
-- {eff < x, xact_id < cursor, posted}, and that set is monotone in x. The two
-- prefixes are evaluated at the same cursor and INDEPENDENT anchors, because from
-- and to can straddle a close.
--
-- WHAT IT COSTS, and it is not free: each prefix carries a tail from its own
-- boundary, so the work is roughly (to - boundary_to) + (from - boundary_from)
-- rather than (to - from). For a window well inside one period that is MORE work
-- than the body it replaces; for a window whose lower bound is deep in history --
-- the position reading, p_from '-infinity' -- it is bounded by two period lengths
-- where the old body was unbounded. Which side of that trade a caller is on is a
-- NUMBER and it is not one this spike has.
--
-- IT STOPS BEING A LANGUAGE sql FUNCTION, and that is a real loss: ADR-0011 §4
-- notes that PostgreSQL inlines a simple SQL set-returning function, which is why
-- trial_balance_at plans as a nested loop over an index scan rather than a
-- Function Scan. It becomes plpgsql for one reason, and the reason was measured:
--
--   THE DIFFERENCE FORM IS WRONG ON AN INVERTED WINDOW. With p_from > p_to the
--   shipped body returns NO ROWS (eff >= from AND eff < to is empty) while the
--   difference form returns NEGATIVE debits and credits -- measured: -10,000 of
--   credits on one account, -300 of debits on another. Nothing in the signature
--   refused an inverted window and nothing would have noticed, because a negative
--   gross debit is not a value any caller checks. So the function now refuses it,
--   which makes its contract STRONGER than the one it replaces -- and costs the
--   inlining.
--
-- The alternative -- clamp silently -- was rejected on ADR-0010's grounds: a
-- caller who passes an inverted window has a bug, and a report that answers it
-- with zeros hides that bug behind a plausible number.
CREATE OR REPLACE FUNCTION trial_balance_at(p_tenant text, p_from timestamptz,
                                            p_to timestamptz, p_cursor xid8)
RETURNS TABLE (tenant_id text, account_id uuid, purpose text, category ledger_category,
               currency char(3), debits bigint, credits bigint,
               balance_debit_positive bigint)
LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF p_from > p_to THEN
        RAISE EXCEPTION 'trial_balance_at: effective_from (%) is after effective_to (%)',
            p_from, p_to USING ERRCODE = '22023';
    END IF;
    RETURN QUERY
    WITH d AS (
        SELECT q.currency, q.account_id, q.debits, q.credits
        FROM checkpoint_position(p_tenant, p_to, p_cursor) q
        UNION ALL
        SELECT q.currency, q.account_id, -q.debits, -q.credits
        FROM checkpoint_position(p_tenant, p_from, p_cursor) q
    ), net AS (
        SELECT d.currency, d.account_id, SUM(d.debits) AS dr, SUM(d.credits) AS cr
        FROM d GROUP BY d.currency, d.account_id
    )
    SELECT p_tenant, n.account_id, a.purpose, t.category, n.currency,
           n.dr::bigint, n.cr::bigint, (n.dr - n.cr)::bigint
    FROM net n
    JOIN ledger_accounts a ON a.tenant_id = p_tenant AND a.id = n.account_id
                          AND a.currency = n.currency
    JOIN account_types   t ON t.code = a.purpose
    -- The old body GROUPed over entries in the window, so an account with no entry
    -- in the window produced no row. The difference form produces a 0/0 row, which
    -- is the same statement said differently -- dropped, so the two outputs are the
    -- same multiset.
    WHERE n.dr <> 0 OR n.cr <> 0;
END $$;


-- ----------------------------------------------------------------------
-- 5e. the two indexes the tenant-wide tails want
--
-- NOT free, and ADR-0013 does not get to wave them through: they are on the hot
-- write table. What is known, and what is not:
--
-- PROVEN BY PLAN (plain EXPLAIN, estimates):
--   tail A tenant-wide gets a SEQ SCAN today (est. 1243.60). Forcing an index puts
--   it on ix_entries__effective by BITMAP SKIP SCAN at est. 946.65 -- usable and
--   ~21x more expensive than the leading-column alternative, at 203 accounts. With
--   ix_entries__tenant_effective: est. 45.44.
--   tail B tenant-wide ALREADY uses ix_entries__asof_commit (est. 730.09) -- PG18's
--   skip scan handles the missing account_id. With ix_entries__tenant_commit:
--   est. 224.62, and effective_at moves from Filter into the Index Cond.
--
-- MEASURED SIZE: 224 kB each against a 3,944 kB heap and 6,448 kB of existing
-- indexes on a 30,024-entry book -- about 7% more index bytes for both, and each
-- is SMALLER than ix_entries__effective (992 kB) because it drops account_id.
--
-- NOT MEASURED: the write cost. Two more btrees to maintain per entry insert, on
-- the statement ADR-0018 spent a whole spike tuning. MEASUREMENT-PLAN.md has the
-- with/without arm, and if it does not pay, tail B keeps its skip scan and tail A
-- keeps its sequential scan -- which is a defensible outcome, not a failure.
--
-- THE SECOND INDEX MAY BE DROPPABLE ON THE PLAN EVIDENCE ALONE: tail B is already
-- served. It is proposed because moving effective_at into the Index Cond turns a
-- heap-recheck filter into an index-only bound, and because the same index is what
-- the bounded reconciliation's commit-axis pass wants -- but of the two, this is
-- the one to cut first if the write cost bites.
CREATE INDEX ix_entries__tenant_effective
    ON ledger_entries (tenant_id, effective_at, xact_id);
CREATE INDEX ix_entries__tenant_commit
    ON ledger_entries (tenant_id, xact_id, effective_at);


-- ======================================================================
-- PART 7 -- THE SUMMARY, REBUILT, AND ITS GRANTS
-- ======================================================================
--
-- Part 0 dropped it. A dropped view takes its ACL with it, so the GRANT is not
-- optional bookkeeping: openledger_recon reads `reconciliation` for a living and
-- `openledger reconcile` is the command that turns it into an exit code.
--
-- TEN ROWS, unchanged. The bounded checkpoint check is NOT wired in here -- see
-- part 4b's adoption note: it reports a different row count and is sound only
-- while recon_close_breaks is green, so swapping it in on faith is exactly the
-- move ADR-0010 warns about. Staging it as an eleventh row is the cheap option and
-- it is the ADR's call.
CREATE VIEW reconciliation AS
SELECT 'balance_cache'      AS check_name, COUNT(*) AS breaks FROM recon_balance_breaks
UNION ALL SELECT 'orphan_entries',           COUNT(*) FROM recon_entry_breaks
UNION ALL SELECT 'unbalanced_transactions',  COUNT(*) FROM recon_transaction_breaks
UNION ALL SELECT 'cross_scope_mirror',       COUNT(*) FROM recon_scope_breaks
UNION ALL SELECT 'journal_to_reports',       COUNT(*) FROM recon_journal_to_reports
                                   WHERE unexplained_debits <> 0 OR unexplained_credits <> 0
UNION ALL SELECT 'checkpoint_drift',         COUNT(*) FROM recon_checkpoint_breaks
UNION ALL SELECT 'close_typing',             COUNT(*) FROM recon_close_breaks
UNION ALL SELECT 'cursor_forgery',           COUNT(*) FROM recon_cursor_breaks
UNION ALL SELECT 'accounting_equation',      COUNT(*) FROM recon_equation_breaks(report_cursor(), 'infinity')
UNION ALL SELECT 'chart_lint',               COUNT(*) FROM chart_lint WHERE severity = 'error';

GRANT SELECT ON recon_checkpoint_breaks, recon_checkpoint_breaks_bounded,
                recon_close_breaks, reconciliation TO openledger_recon;


-- ======================================================================
-- PART 8 -- THE SCHEMA SNAPSHOT'S CHARGE MUST WIDEN  (a test change, not DDL)
-- ======================================================================
--
-- crates/e2e/tests/e2e/schema_snapshot.rs, SECTIONS. This is not optional
-- tidying: ADR-0009 names that test the only backstop for the owner-accident DDL
-- class, and `ALTER TABLE ... DETACH PARTITION` is one statement in exactly that
-- class. MEASURED: after one DETACH, three checkpoint rows vanish from every
-- reader (7 visible through the parent against 10 stored) and the snapshot's line
-- for the detached table is BYTE-IDENTICAL to the attached one. The reconciliation
-- sweep does catch it -- checkpoint_drift = 3, missing_row -- but the sweep is
-- daily and the snapshot is per-push.
--
-- Verified ABSENT from all nineteen sections: relpartbound, relispartition,
-- pg_inherits, pg_partitioned_table, pg_get_partkeydef. So the partition KEY, a
-- partition's BOUND, and whether a relation is ATTACHED AT ALL are invisible today.
-- One section closes all three:
--
--     (
--         // Partitioning: the key, every attachment, and every bound. None of
--         // these is derivable from the sections above -- a DETACHed partition is
--         // still an `r` relation with the same name, which is why one statement
--         // could remove rows from every report with the dump unchanged
--         // (spike 024).
--         "partitions (key, parent, bound)",
--         r#"SELECT p.relname || ' PARTITION BY ' || pg_get_partkeydef(p.oid)
--            FROM pg_class p JOIN pg_namespace n ON n.oid = p.relnamespace
--            WHERE n.nspname = 'public' AND p.relkind = 'p'
--            UNION ALL
--            SELECT c.relname || ' PARTITION OF ' || pt.relname || ' '
--                   || coalesce(pg_get_expr(c.relpartbound, c.oid), '(none)')
--            FROM pg_inherits i
--            JOIN pg_class c  ON c.oid = i.inhrelid
--            JOIN pg_class pt ON pt.oid = i.inhparent
--            JOIN pg_namespace n ON n.oid = c.relnamespace
--            WHERE n.nspname = 'public'
--            ORDER BY 1 COLLATE "C""#,
--     ),
--
-- Empty as "(none)" on a schema with no partitions, which is the assertion the
-- NOT VALID section already makes for its own class. It also catches the roadmap's
-- eventual tenant partitioning for free.
