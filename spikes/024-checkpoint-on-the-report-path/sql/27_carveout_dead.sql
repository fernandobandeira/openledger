-- Spike 024 -- with the narrow `e.transaction_id <> c.transaction_id` term in
-- place, is the shipped wide NOT EXISTS carve-out dead?
--
-- Dead means: removing it changes no row. Not "it looks redundant".
\set ON_ERROR_STOP on
CREATE OR REPLACE VIEW close_disclosures_no_wide_carveout AS
SELECT c.tenant_id, c.period_code, c.currency, e.id AS entry_id
FROM ledger_period_closes c
JOIN ledger_entries e
  ON e.tenant_id = c.tenant_id AND e.currency = c.currency
 AND e.effective_at < c.ends_at
 AND e.xact_id >= c.computed_at_xid
 AND e.transaction_id <> c.transaction_id
JOIN ledger_transactions x
  ON x.tenant_id = e.tenant_id AND x.id = e.transaction_id AND x.status = 'posted';

SELECT (SELECT count(*) FROM close_disclosures)                    AS with_wide_carveout,
       (SELECT count(*) FROM close_disclosures_no_wide_carveout)    AS without_it,
       (SELECT count(*) FROM close_disclosures_no_wide_carveout n
         WHERE NOT EXISTS (SELECT 1 FROM close_disclosures d
                            WHERE d.entry_id = n.entry_id AND d.period_code = n.period_code
                              AND d.currency = n.currency AND d.tenant_id = n.tenant_id))
                                                                    AS rows_only_without_it;
-- ...and the population that would make the wide carve-out live: a DIFFERENT
-- close's entries falling below this close's boundary and above its cursor.
SELECT c.period_code AS this_close, c2.period_code AS other_close, count(*) AS entries
FROM ledger_period_closes c
JOIN ledger_period_closes c2
  ON c2.tenant_id = c.tenant_id AND c2.currency = c.currency
 AND c2.transaction_id <> c.transaction_id
JOIN ledger_entries e ON e.tenant_id = c.tenant_id AND e.currency = c.currency
                     AND e.transaction_id = c2.transaction_id
                     AND e.effective_at < c.ends_at
                     AND e.xact_id >= c.computed_at_xid
GROUP BY 1,2 ORDER BY 1,2;
