-- Spike 024 -- the reader, corrected for the canonical AT-CLOSE checkpoint.
--
-- Applied AFTER 20_candidates.sql, and it replaces only the anchor and the
-- position: the statement wrappers (balance_sheet_at_ckpt, trial_balance_at_ckpt)
-- are unchanged, because the correction is entirely in which entries are admitted.
--
-- Two changes, both forced by the close's own transaction being in its own
-- checkpoint BY IDENTITY rather than through the cursor:
--
--  1. TAIL B MUST EXCLUDE THE CLOSE'S OWN TRANSACTION. Its entries have
--     xact_id >= computed_at_xid (pg_snapshot_xmin is <= the caller's own xid
--     whenever the caller holds one), so `xact_id >= computed_at_xid` picks them
--     up a SECOND time. Measured without the exclusion: fee_revenue read 1,000
--     against a true 500 (run-cursor-arms.sh, own_xid arm).
--
--  2. THE ANCHOR MUST GUARD ON THE CLOSING TRANSACTION'S OWN xact_id, not on
--     computed_at_xid. A report pinned at cursor P may only use a close whose
--     entries it can see, and the close's entries carry the CLOSING
--     TRANSACTION's id, which is >= computed_at_xid. Guarding on
--     computed_at_xid <= P alone admits a checkpoint containing entries above P
--     -- a statement restated upward by a close that happened after it was
--     issued, which is exactly the property the cursor exists to prevent.
\set ON_ERROR_STOP on

DROP FUNCTION IF EXISTS checkpoint_anchor(text, timestamptz, xid8);
CREATE FUNCTION checkpoint_anchor(p_tenant text, p_asof timestamptz, p_cursor xid8)
RETURNS TABLE (currency char(3), period_code text, boundary timestamptz,
               ckpt_cursor xid8, close_txn uuid)
LANGUAGE sql STABLE AS $$
    SELECT s.currency, c.period_code,
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
          AND k.ends_at <= p_asof
          -- the whole checkpoint must be visible at this report's cursor, and
          -- the LAST thing to become visible is the close's own transaction
          AND kx.xact_id < p_cursor
        ORDER BY k.ends_at DESC
        LIMIT 1
    ) c ON true;
$$;

DROP FUNCTION IF EXISTS checkpoint_position(text, timestamptz, xid8);
CREATE FUNCTION checkpoint_position(p_tenant text, p_asof timestamptz, p_cursor xid8)
RETURNS TABLE (currency char(3), account_id uuid, debits numeric, credits numeric)
LANGUAGE sql STABLE AS $$
    WITH a AS (SELECT * FROM checkpoint_anchor(p_tenant, p_asof, p_cursor)),
    terms AS (
        SELECT b.currency, b.account_id, b.input::numeric AS dr, b.output::numeric AS cr
        FROM a
        JOIN ledger_period_balances b
          ON b.tenant_id = p_tenant AND b.currency = a.currency
         AND b.period_code = a.period_code
        UNION ALL
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
        SELECT e.currency, e.account_id,
               CASE WHEN e.direction = 'debit'  THEN e.amount_minor::numeric ELSE 0 END,
               CASE WHEN e.direction = 'credit' THEN e.amount_minor::numeric ELSE 0 END
        FROM a
        JOIN ledger_entries e
          ON e.tenant_id = p_tenant AND e.currency = a.currency
         AND e.effective_at < a.boundary
         AND e.xact_id >= a.ckpt_cursor AND e.xact_id < p_cursor
         -- ...and NOT the close's own transaction, which the checkpoint already
         -- carries. Without this the closing legs are counted twice.
         AND (a.close_txn IS NULL OR e.transaction_id <> a.close_txn)
        JOIN ledger_transactions x
          ON x.tenant_id = e.tenant_id AND x.id = e.transaction_id AND x.status = 'posted'
    )
    SELECT t.currency, t.account_id, SUM(t.dr), SUM(t.cr)
    FROM terms t
    GROUP BY t.currency, t.account_id;
$$;
