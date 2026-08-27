-- Spike 013 -- the reconciliation layer, as reporting SQL.
--
-- Seven views. Four BREAK LISTS that must return zero rows on a healthy book, two
-- RECONCILIATION STATEMENTS that always return rows and must foot to zero, and one
-- summary an operator runs as a single query.
--
-- No triggers. ADR-0004 removed the ledger-side drift views along with the
-- PL/pgSQL that fed them; these are their declarative replacement, and they are
-- SELECTs over the shipped schema -- they add no write-path object, hold no lock
-- and change no plan on the hot path.
--
-- ONE MAPPING HAS TO BE STATED BEFORE ANY OF THIS TYPE-CHECKS.
-- `ledger_account_balances.input` / `.output` are described in the schema as
-- "total money in, total money out" and nowhere in migrations/, site/content/ or
-- the glossary is it written which entry DIRECTION each one accumulates. The only
-- place in the tree that decides it is spikes/003-throughput-ceiling/bench_schema.sql:26,
--     input  += CASE WHEN p_dir='debit'  THEN p_amount ELSE 0 END
--     output += CASE WHEN p_dir='credit' THEN p_amount ELSE 0 END
-- so input = SUM(debits), output = SUM(credits), and `input - output` is the
-- DEBIT-POSITIVE arithmetic value of ADR-0007 rule 15 -- a credit-normal account
-- reads negative from the cache and the presentation flip belongs to the reader.
-- These views adopt that mapping and are the first object in the repository that
-- makes it falsifiable: under the other reading (money in the account's NORMAL
-- direction) every credit-normal account reports drift on its first entry.

-- ----------------------------------------------------------------------
-- 1 - the balance cache against the journal
--
-- The cache is derived state and the journal is append-only, so this comparison is
-- genuinely independent -- which the running balance it replaces was not: the
-- writer computed that one FROM the cache, in the same transaction, from the same
-- locked row (spike 009).
--
-- Six break classes, not one. Three of them are the three jobs of that row failing
-- separately, which is the whole argument for leaving the three on one row.
CREATE VIEW recon_balance_breaks AS
WITH j AS (
    SELECT e.tenant_id, e.account_id, e.currency,
           COALESCE(SUM(e.amount_minor) FILTER (WHERE e.direction = 'debit'), 0)  AS journal_input,
           COALESCE(SUM(e.amount_minor) FILTER (WHERE e.direction = 'credit'), 0) AS journal_output,
           COUNT(*)              AS entry_count,
           MAX(e.account_seq)    AS max_seq
    FROM ledger_entries e
    GROUP BY e.tenant_id, e.account_id, e.currency
), pend AS (
    -- Uncorrelated on purpose. Written as a LATERAL off the cache row the planner
    -- estimated 32,676 rows against a true 1,000,000 and took 183 ms / 1,042 ms
    -- instead of 248.9 ms (spike 009).
    SELECT e.tenant_id, e.account_id, e.currency,
           COALESCE(SUM(e.amount_minor) FILTER (WHERE e.direction = 'debit'), 0)  AS pending_input,
           COALESCE(SUM(e.amount_minor) FILTER (WHERE e.direction = 'credit'), 0) AS pending_output
    FROM ledger_entries e
    JOIN ledger_transactions x
      ON x.tenant_id = e.tenant_id AND x.id = e.transaction_id
    WHERE x.status <> 'posted'
    GROUP BY e.tenant_id, e.account_id, e.currency
), joined AS (
    SELECT COALESCE(b.tenant_id,  j.tenant_id)  AS tenant_id,
           COALESCE(b.account_id, j.account_id) AS account_id,
           COALESCE(b.currency,   j.currency)   AS currency,
           b.tenant_id IS NULL AS cache_missing,
           j.tenant_id IS NULL AS journal_empty,
           COALESCE(b.input, 0)    AS cache_input,
           COALESCE(b.output, 0)   AS cache_output,
           COALESCE(b.last_seq, 0) AS cache_last_seq,
           COALESCE(j.journal_input, 0)  AS journal_input,
           COALESCE(j.journal_output, 0) AS journal_output,
           COALESCE(j.entry_count, 0)    AS entry_count,
           COALESCE(j.max_seq, 0)        AS max_seq,
           COALESCE(p.pending_input, 0)  AS pending_input,
           COALESCE(p.pending_output, 0) AS pending_output
    FROM ledger_account_balances b
    FULL JOIN j
           ON j.tenant_id = b.tenant_id AND j.account_id = b.account_id
          AND j.currency  = b.currency
    LEFT JOIN pend p
           ON p.tenant_id  = COALESCE(b.tenant_id,  j.tenant_id)
          AND p.account_id = COALESCE(b.account_id, j.account_id)
          AND p.currency   = COALESCE(b.currency,   j.currency)
)
SELECT tenant_id, account_id, currency,
       cache_input, cache_output, cache_input - cache_output AS cache_balance_minor,
       journal_input, journal_output, journal_input - journal_output AS journal_balance_minor,
       -- the posted half -- what every report counts
       journal_input - pending_input - (journal_output - pending_output) AS posted_balance_minor,
       pending_input, pending_output,
       cache_last_seq, max_seq, entry_count,
       (cache_input - cache_output) - (journal_input - journal_output) AS drift_minor,
       -- turnover drift, because a cache with both sides inflated by the same
       -- amount has the right balance and the wrong gross
       (cache_input + cache_output) - (journal_input + journal_output) AS drift_turnover_minor,
       ARRAY_REMOVE(ARRAY[
         CASE WHEN cache_input <> journal_input OR cache_output <> journal_output
              THEN 'balance_drift' END,
         -- last_seq BELOW the journal fails closed: the next writer is handed a
         -- number an entry already holds and uq_entries__account_seq refuses it.
         CASE WHEN NOT cache_missing AND cache_last_seq < max_seq THEN 'seq_behind' END,
         -- last_seq ABOVE the journal fails SILENTLY: the next entry skips the
         -- difference and gaplessness -- "no entry is missing" -- is gone with no
         -- error anywhere.
         CASE WHEN NOT cache_missing AND cache_last_seq > max_seq THEN 'seq_ahead' END,
         -- 1..N with nothing skipped. ADR-0004: gaplessness is enforced when the
         -- number is ISSUED and checked nowhere afterwards. This is afterwards.
         CASE WHEN entry_count <> max_seq THEN 'seq_gap' END,
         -- no row to lock: the next writer's upsert INSERTs and starts the account
         -- at seq 1 again, on an account that already has history
         CASE WHEN cache_missing THEN 'no_cache_row' END,
         CASE WHEN journal_empty AND (cache_input <> 0 OR cache_output <> 0
                                      OR cache_last_seq <> 0) THEN 'no_entries' END
       ], NULL) AS reasons
FROM joined
WHERE cache_input <> journal_input
   OR cache_output <> journal_output
   OR cache_missing
   OR (NOT cache_missing AND cache_last_seq <> max_seq)
   OR entry_count <> max_seq
   OR (journal_empty AND (cache_input <> 0 OR cache_output <> 0 OR cache_last_seq <> 0));


-- ----------------------------------------------------------------------
-- 2 - entries no report can count
--
-- WHAT AN ORPHAN IS, stated rather than assumed: an entry that all three shipped
-- report views structurally cannot include, for a reason other than its status.
-- All three join the same three tables the same way -- ledger_transactions on
-- (tenant, id), ledger_accounts on (tenant, id, currency), account_types on
-- purpose -- so the orphan population is exactly the entries that fail one of
-- those joins. A pending entry is NOT an orphan: it is excluded on purpose and is
-- a reconciling item (view 6).
--
-- Every one of those joins is backed by a foreign key, so this view is empty on
-- any path that enforces them. It is not empty on the paths that do not:
-- session_replication_role='replica' (logical replication apply, and what
-- `pg_restore --disable-triggers` sets) skips the FK triggers, all 36 of which
-- ship ENABLE ORIGIN -- which is the decision log's own open row, and the
-- baseline's balance_sheet comment describes the resulting entry.
--
-- 'no_report_scope' is deliberately NOT a class here. balance_sheet and
-- income_statement enumerate scopes from ledger_accounts, so an entry whose
-- account row exists is always in scope; a disjunct that can never be true is
-- worse than no disjunct (ADR-0004 found one).
CREATE VIEW recon_entry_breaks AS
SELECT e.tenant_id, e.id AS entry_id, e.transaction_id, e.account_id,
       e.currency, e.direction, e.amount_minor, e.account_seq,
       e.effective_at, e.recorded_at,
       CASE WHEN x.id   IS NULL THEN 'no_transaction'
            WHEN a.id   IS NULL THEN 'no_account'
            WHEN t.code IS NULL THEN 'no_account_type'
       END AS reason
FROM ledger_entries e
LEFT JOIN ledger_transactions x
       ON x.tenant_id = e.tenant_id AND x.id = e.transaction_id
LEFT JOIN ledger_accounts a
       ON a.tenant_id = e.tenant_id AND a.id = e.account_id
      AND a.currency  = e.currency
LEFT JOIN account_types t ON t.code = a.purpose
WHERE x.id IS NULL OR a.id IS NULL OR t.code IS NULL;


-- ----------------------------------------------------------------------
-- 3 - transactions that do not balance
--
-- Nothing in the shipped artefact reports this. ADR-0005 puts balance in the
-- writer's type, where a caller cannot express one leg -- and until that writer
-- exists ledger_entries stores independent rows carrying a direction, so an
-- unbalanced transaction is fully expressible. This view does not enforce it and
-- is not a substitute for the type: it is the exception list that says whether the
-- claim is true of the data.
--
-- PER CURRENCY (ADR-0007 rule 12). A transaction whose USD legs are short by
-- 100.00 and whose EUR legs are long by 100.00 balances in neither currency and in
-- no meaningful sense; grouped currency-blind it would foot to zero.
--
-- A one-entry transaction is caught by the same arithmetic (amount_minor > 0, so a
-- single leg can never be zero); a ZERO-entry transaction has no currency to group
-- by and needs the LEFT JOIN. Both were reached on this schema: ADR-0004 records
-- `TRUNCATE ledger_entries, ledger_account_balances` leaving eleven transactions
-- standing with zero entries, every currency balanced = t.
CREATE VIEW recon_transaction_breaks AS
WITH legs AS (
    -- Aggregated first, then joined, and the order is worth 1.23x: the shipped
    -- schema's ix_entries__txn makes the other form a merge join driven by an
    -- index scan over every entry -- 931 ms against 754 ms at 1,000,000 entries,
    -- medians of three, serial. Spike 009 found 2-4x from the same class of
    -- rewrite on the per-account recompute; here it is smaller and still real.
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
WHERE g.transaction_id IS NULL OR g.debits <> g.credits;


-- ----------------------------------------------------------------------
-- 4 - the two sides of a cross-scope obligation
--
-- Tenant-locality is correctness, not optimization: no transaction spans two
-- tenants, so a movement between scopes is TWO transactions joined by clearing
-- accounts. Each side balances on its own, which is why nothing in a per-tenant
-- report can notice that the two sides disagree. The comparison has to aggregate
-- ACROSS tenants, and it is the only view here that does.
--
-- THE INVARIANT: for a mirrored pair of account types, the deployment-wide sum of
-- the DEBIT-POSITIVE balance over both types is zero, per currency. It works
-- because the pair is opposite-signed by construction -- a claim on the operator is
-- an asset to the tenant and a liability to the operator -- and it is the
-- elimination ADR-0007 says the golden trace asserts "at every step" and no view
-- performs.
--
-- THE PAIRING CANNOT BE DERIVED FROM TODAY'S CHART. `is_perimeter` says an account
-- mirrors an EXTERNAL balance; `counterparty_scope` says whether members may be
-- netted. Neither names the type on the other side, and deriving it from the
-- due_from_/due_to_ naming would be a convention where the project's own rule is
-- that a convention is not a constraint (ADR-0007). So this view reads one
-- proposed column, `account_types.mirror_type`:
--
--     ALTER TABLE account_types
--         ADD COLUMN mirror_type text
--             CONSTRAINT fk_types__mirror REFERENCES account_types (code);
--
-- Nullable, no default, declared on one side of each pair. 02_mirror_column.sql
-- applies it and seeds due_from_treasury -> due_to_tenants.
CREATE VIEW recon_scope_breaks AS
WITH pairs AS (
    SELECT t.code AS near_type, t.mirror_type AS far_type,
           t.counterparty_scope AS near_scope, m.counterparty_scope AS far_scope
    FROM account_types t
    JOIN account_types m ON m.code = t.mirror_type
    WHERE t.mirror_type IS NOT NULL
), sides AS (
    SELECT p.near_type, p.far_type, p.near_scope, p.far_scope,
           tb.currency,
           tb.purpose,
           SUM(tb.balance_debit_positive) AS side_minor,
           COUNT(DISTINCT tb.tenant_id)   AS scopes
    FROM pairs p
    JOIN trial_balance tb ON tb.purpose IN (p.near_type, p.far_type)
    GROUP BY p.near_type, p.far_type, p.near_scope, p.far_scope, tb.currency, tb.purpose
)
SELECT near_type, far_type, currency,
       COALESCE(SUM(side_minor) FILTER (WHERE purpose = near_type), 0) AS near_minor,
       COALESCE(SUM(side_minor) FILTER (WHERE purpose = far_type), 0)  AS far_minor,
       SUM(side_minor)                                                 AS gap_minor,
       COALESCE(SUM(scopes) FILTER (WHERE purpose = near_type), 0)     AS near_scopes,
       COALESCE(SUM(scopes) FILTER (WHERE purpose = far_type), 0)      AS far_scopes,
       -- WHAT THIS COMPARISON CANNOT SEE. Where either side is `per_shard`, one
       -- account holds every counterparty's position, so the figure being compared
       -- is already net of counterparties: the operator owing t1 425.00 while t2
       -- owes it 425.00 presents zero and this view agrees with zero. Making it
       -- gross needs the counterparty in the account key -- roadmap question 5 --
       -- not a change here.
       bool_or(near_scope = 'per_shard' OR far_scope = 'per_shard') AS net_of_counterparties
FROM sides
GROUP BY near_type, far_type, currency
HAVING SUM(side_minor) <> 0;


-- ----------------------------------------------------------------------
-- 5 - the journal against the reports
--
-- A RECONCILIATION STATEMENT, not a break list: it always returns a row per
-- (tenant, currency) and every row must foot. The shape is the one a bank
-- reconciliation has -- open with the source figure, subtract each reconciling
-- item by name, and what is left unexplained is the break.
--
--     journal debits
--       - pending (excluded by every report on purpose, ADR-0007 rule 14)
--       - orphaned (view 2)
--       = what a report SHOULD show
--       - what trial_balance ACTUALLY shows
--       = unexplained, which must be zero
--
-- The last subtraction is the half that matters and the reason this is not simply
-- arithmetic over one CTE: `reported_*` is computed from the journal by this
-- view's own classification, and `tb_*` is read from the shipped view. If the two
-- ever disagree the report has grown a filter this classification does not know
-- about, which is precisely the "dropped balanced sub-book" ADR-0007 is about --
-- a sub-book dropped by a report is invisible to the accounting equation and
-- visible here.
CREATE VIEW recon_journal_to_reports AS
WITH classified AS (
    SELECT e.tenant_id, e.currency, e.direction, e.amount_minor,
           CASE WHEN x.id IS NULL OR a.id IS NULL OR t.code IS NULL THEN 'orphan'
                WHEN x.status <> 'posted'                           THEN 'pending'
                ELSE 'reported' END AS bucket
    FROM ledger_entries e
    LEFT JOIN ledger_transactions x
           ON x.tenant_id = e.tenant_id AND x.id = e.transaction_id
    LEFT JOIN ledger_accounts a
           ON a.tenant_id = e.tenant_id AND a.id = e.account_id
          AND a.currency  = e.currency
    LEFT JOIN account_types t ON t.code = a.purpose
), j AS (
    SELECT tenant_id, currency,
           COALESCE(SUM(amount_minor) FILTER (WHERE direction = 'debit'), 0)  AS journal_debits,
           COALESCE(SUM(amount_minor) FILTER (WHERE direction = 'credit'), 0) AS journal_credits,
           COALESCE(SUM(amount_minor) FILTER (WHERE direction = 'debit'  AND bucket = 'pending'), 0) AS pending_debits,
           COALESCE(SUM(amount_minor) FILTER (WHERE direction = 'credit' AND bucket = 'pending'), 0) AS pending_credits,
           COALESCE(SUM(amount_minor) FILTER (WHERE direction = 'debit'  AND bucket = 'orphan'), 0)  AS orphan_debits,
           COALESCE(SUM(amount_minor) FILTER (WHERE direction = 'credit' AND bucket = 'orphan'), 0)  AS orphan_credits,
           COALESCE(SUM(amount_minor) FILTER (WHERE direction = 'debit'  AND bucket = 'reported'), 0) AS reported_debits,
           COALESCE(SUM(amount_minor) FILTER (WHERE direction = 'credit' AND bucket = 'reported'), 0) AS reported_credits
    FROM classified GROUP BY tenant_id, currency
), r AS (
    SELECT tenant_id, currency,
           SUM(debits) AS tb_debits, SUM(credits) AS tb_credits
    FROM trial_balance GROUP BY tenant_id, currency
)
SELECT COALESCE(j.tenant_id, r.tenant_id) AS tenant_id,
       COALESCE(j.currency,  r.currency)  AS currency,
       COALESCE(j.journal_debits, 0)   AS journal_debits,
       COALESCE(j.journal_credits, 0)  AS journal_credits,
       COALESCE(j.pending_debits, 0)   AS pending_debits,
       COALESCE(j.pending_credits, 0)  AS pending_credits,
       COALESCE(j.orphan_debits, 0)    AS orphan_debits,
       COALESCE(j.orphan_credits, 0)   AS orphan_credits,
       COALESCE(j.reported_debits, 0)  AS reported_debits,
       COALESCE(j.reported_credits, 0) AS reported_credits,
       COALESCE(r.tb_debits, 0)        AS tb_debits,
       COALESCE(r.tb_credits, 0)       AS tb_credits,
       COALESCE(j.reported_debits, 0)  - COALESCE(r.tb_debits, 0)  AS unexplained_debits,
       COALESCE(j.reported_credits, 0) - COALESCE(r.tb_credits, 0) AS unexplained_credits,
       -- the number the decision log measured at 50,000.00 and no view reported
       COALESCE(j.journal_debits, 0) - COALESCE(r.tb_debits, 0)    AS journal_minus_report_debits
FROM j FULL JOIN r ON r.tenant_id = j.tenant_id AND r.currency = j.currency;


-- ----------------------------------------------------------------------
-- 6 - available against posted
--
-- The bridge between the two numbers this system publishes and never relates. The
-- balance cache counts every entry the writer wrote; every report counts only the
-- posted ones; and the difference is a real population -- the pending
-- transactions -- which nothing enumerates. Measured on this schema: one posted
-- 100.00 and one pending 500.00 give a cache of 600.00 and a balance sheet of
-- 100.00 (database.md).
--
-- Not a break list. A row here is a reconciling item, and `reconciles` is the
-- assertion: available = posted + pending, exactly. It goes false only when the
-- cache has drifted, which view 1 already reports -- so this view explains a
-- difference rather than finding one. On an account with pending entries and NO
-- cache row it is NULL rather than false, deliberately: that account is view 1's
-- `no_cache_row`, and a break counted twice is a break argued about twice.
CREATE VIEW recon_pending_bridge AS
WITH pend AS (
    SELECT e.tenant_id, e.account_id, e.currency,
           COALESCE(SUM(e.amount_minor) FILTER (WHERE e.direction = 'debit'), 0)  AS pending_debits,
           COALESCE(SUM(e.amount_minor) FILTER (WHERE e.direction = 'credit'), 0) AS pending_credits,
           COUNT(DISTINCT e.transaction_id) AS pending_txns,
           MIN(x.effective_at)              AS oldest_pending_effective_at
    FROM ledger_entries e
    JOIN ledger_transactions x
      ON x.tenant_id = e.tenant_id AND x.id = e.transaction_id
    WHERE x.status <> 'posted'
    GROUP BY e.tenant_id, e.account_id, e.currency
), posted AS (
    SELECT e.tenant_id, e.account_id, e.currency,
           COALESCE(SUM(CASE WHEN e.direction = 'debit' THEN e.amount_minor
                             ELSE -e.amount_minor END), 0) AS posted_balance_minor
    FROM ledger_entries e
    JOIN ledger_transactions x
      ON x.tenant_id = e.tenant_id AND x.id = e.transaction_id
    WHERE x.status = 'posted'
    GROUP BY e.tenant_id, e.account_id, e.currency
)
SELECT p.tenant_id, p.account_id, a.purpose, p.currency,
       b.input - b.output                              AS available_balance_minor,
       COALESCE(po.posted_balance_minor, 0)            AS posted_balance_minor,
       p.pending_debits - p.pending_credits            AS pending_balance_minor,
       p.pending_debits, p.pending_credits, p.pending_txns,
       p.oldest_pending_effective_at,
       (b.input - b.output)
         = COALESCE(po.posted_balance_minor, 0) + (p.pending_debits - p.pending_credits)
                                                       AS reconciles
FROM pend p
JOIN ledger_accounts a
  ON a.tenant_id = p.tenant_id AND a.id = p.account_id AND a.currency = p.currency
LEFT JOIN posted po
  ON po.tenant_id = p.tenant_id AND po.account_id = p.account_id AND po.currency = p.currency
LEFT JOIN ledger_account_balances b
  ON b.tenant_id = p.tenant_id AND b.account_id = p.account_id AND b.currency = p.currency;


-- ----------------------------------------------------------------------
-- 7 - the one query an operator runs
--
-- `SELECT * FROM reconciliation WHERE breaks <> 0` is the whole interface. Six
-- checks, one row each, always six rows -- a check that returns nothing because it
-- was never run is indistinguishable from a check that passed, and ADR-0004's
-- TRUNCATE finding is exactly that failure: "there was nothing left to disagree
-- with -- silence read as assent".
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
SELECT 'pending_bridge',           COUNT(*) FROM recon_pending_bridge WHERE NOT reconciles;


-- ----------------------------------------------------------------------
-- WHO MAY RUN THIS
--
-- Not openledger_app. That role holds UPDATE on ledger_account_balances -- it can
-- write the thing view 1 checks -- and ADR-0004's own lesson from validating
-- account_seq against the cache is that a check whose subject the checker may
-- rewrite is not a check. A separate read-only role costs one line.
--
-- A GRANT IS NOT A CONSTRAINT and this file does not pretend otherwise: one
-- `GRANT ALL` undoes it and it binds no superuser. It is the same cheap outer
-- layer the baseline gives openledger_app, for the same reason.
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'openledger_recon') THEN
        CREATE ROLE openledger_recon NOLOGIN;
    END IF;
END $$;

GRANT USAGE ON SCHEMA public TO openledger_recon;
GRANT SELECT ON ledger_accounts, ledger_events, ledger_transactions, ledger_entries,
                ledger_account_balances, account_types, fs_lines TO openledger_recon;
GRANT SELECT ON trial_balance, balance_sheet, income_statement TO openledger_recon;
GRANT SELECT ON recon_balance_breaks, recon_entry_breaks, recon_transaction_breaks,
                recon_scope_breaks, recon_journal_to_reports, recon_pending_bridge,
                reconciliation TO openledger_recon;

-- The app role reads the bridge and nothing else: `available` is a number it
-- serves, and the break lists are not its business.
GRANT SELECT ON recon_pending_bridge TO openledger_app;
