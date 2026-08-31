-- 00003 -- one supersession per target, and the void is not a break.
--
-- The reversal slice's schema half (ADR-0016, Reversals and the void), landing
-- as ONE unit with the writer code that speaks it: the adapter maps the new
-- index below by its catalog name, so shipping either half alone regresses the
-- supersession race to a 500 (the sequencing hazard the ADR records).
--
-- (a) ONE SUPERSESSION INDEX REPLACES THE TWO PER-POINTER ONES. The
-- resolve-vs-reverse race has a twin uq_txn__one_resolution and
-- uq_txn__one_reversal cannot see: the two partial indexes are never unique
-- AGAINST EACH OTHER, so a pending could be resolved AND voided -- two
-- writers, one committing each pointer -- with no arithmetic witness anywhere
-- (the bridge retires the pending either way; nothing counts twice; nothing
-- breaks). One index over the sole pointer closes the twin declaratively.
-- ck_txn__not_both is what makes the COALESCE sound: a superseding transaction
-- carries exactly one pointer, so the expression names the sole target.

DROP INDEX uq_txn__one_resolution;
DROP INDEX uq_txn__one_reversal;

CREATE UNIQUE INDEX uq_txn__one_supersession
    ON ledger_transactions (tenant_id, COALESCE(resolves_id, reverses_id))
    WHERE resolves_id IS NOT NULL OR reverses_id IS NOT NULL;

-- (b) THE VOID CARVE-OUT. Reversing a pending is the void: a POSTED
-- transaction carrying reverses_id and NO entries -- the pending never moved
-- the cache, so there is nothing to mirror, and the marker alone retires it
-- from the bridge's population. recon_transaction_breaks flags every
-- entryless transaction as no_entries (the ADR-0004 TRUNCATE scar's class),
-- so the void needs a carve-out EXACTLY this narrow: zero entries AND
-- reverses_id set AND the reversed target pending. An entryless transaction
-- with no reverses_id stays a break, and so does an entryless "reversal" of a
-- POSTED target -- its mirror should have written entries, so their absence
-- is drift, not a void.
--
-- CREATE OR REPLACE keeps the view's owner, grants and column list; only the
-- WHERE grows the carve-out. The body is otherwise the baseline's, verbatim.

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
  -- the void carve-out (ADR-0016): a zero-entry POSTED marker reversing a
  -- PENDING target is the void doing its job, not the TRUNCATE scar.
  AND NOT (g.transaction_id IS NULL
           AND x.reverses_id IS NOT NULL
           AND EXISTS (SELECT 1 FROM ledger_transactions v
                       WHERE v.tenant_id = x.tenant_id
                         AND v.id = x.reverses_id
                         AND v.status = 'pending'));

COMMENT ON VIEW recon_transaction_breaks IS
  'Transactions whose entries do not balance per currency (debits_ne_credits), plus single-leg and entryless ones -- except the void: a zero-entry posted marker reversing a PENDING target is legitimate (ADR-0016), while every other entryless transaction stays a break. The exception list for the balance invariant the writer''s type makes unrepresentable (ADR-0005, ADR-0007).';
