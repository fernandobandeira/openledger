-- Spike 024 -- recon_checkpoint_breaks and close_disclosures, corrected for the
-- canonical AT-CLOSE checkpoint. These two MUST land in the same migration as the
-- close's own arithmetic: an at-close checkpoint under the shipped strict
-- recompute reports drift on every close (measured: 12 rows on this book).
--
-- The bound changes from
--     e.xact_id < c.computed_at_xid
-- to
--     e.xact_id < c.computed_at_xid OR e.transaction_id = c.transaction_id
--
-- and that is not the `<=` the cheapest reading suggests. `<=` is only equivalent
-- when computed_at_xid EQUALS the closing transaction's own xact_id, which happens
-- only on an idle cluster -- and the value that makes it equal
-- (pg_current_xact_id) is not a reproducible cursor at all
-- (run-cursor-arms.sh, own_xid arm). Naming the transaction needs no relationship
-- between the two values.
\set ON_ERROR_STOP on

CREATE OR REPLACE VIEW recon_checkpoint_breaks AS
WITH recomputed AS (
    SELECT c.tenant_id, c.period_code, c.currency, e.account_id,
           COALESCE(SUM(e.amount_minor) FILTER (WHERE e.direction = 'debit'), 0)  AS input,
           COALESCE(SUM(e.amount_minor) FILTER (WHERE e.direction = 'credit'), 0) AS output
    FROM ledger_period_closes c
    JOIN ledger_entries e
      ON e.tenant_id = c.tenant_id AND e.currency = c.currency
     AND e.effective_at < c.ends_at
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

-- close_disclosures is the complement of the recompute's bound and has to move
-- with it. The shipped body carries a NOT EXISTS carve-out keeping ANY close
-- transaction's entries out of the disclosure; naming THIS close's transaction is
-- narrower and exact -- and whether the wider carve-out then becomes dead is
-- tested rather than assumed (sql/27_carveout_dead.sql).
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
