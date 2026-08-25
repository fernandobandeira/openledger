-- The equation, evaluated after EACH transaction in posting order.
WITH ordered AS (
  SELECT t.id, t.idempotency_key, row_number() OVER (ORDER BY t.id) rn
  FROM ledger_transactions t
), cum AS (
  SELECT o.rn, o.idempotency_key, ty.category, ty.normal_balance, e.direction, e.amount_minor
  FROM ordered o
  JOIN ordered o2 ON o2.rn <= o.rn
  JOIN ledger_entries e   ON e.transaction_id = o2.id
  JOIN ledger_accounts a  ON a.id = e.account_id
  JOIN account_types ty   ON ty.code = a.purpose
), agg AS (
  SELECT rn, idempotency_key, category,
         SUM(CASE WHEN normal_balance='debit'
                  THEN CASE WHEN direction='debit'  THEN amount_minor ELSE -amount_minor END
                  ELSE CASE WHEN direction='credit' THEN amount_minor ELSE -amount_minor END END) bal
  FROM cum GROUP BY rn, idempotency_key, category
)
SELECT rn AS step, rpad(idempotency_key, 22) AS after_txn,
       COALESCE(SUM(bal) FILTER (WHERE category='asset'),0)/100.0     AS assets,
       COALESCE(SUM(bal) FILTER (WHERE category='liability'),0)/100.0 AS liabs,
       COALESCE(SUM(bal) FILTER (WHERE category='equity'),0)/100.0    AS equity,
       COALESCE(SUM(bal) FILTER (WHERE category='revenue'),0)/100.0   AS revenue,
       COALESCE(SUM(bal) FILTER (WHERE category='expense'),0)/100.0   AS expense,
       CASE WHEN COALESCE(SUM(bal) FILTER (WHERE category='asset'),0)
               = COALESCE(SUM(bal) FILTER (WHERE category='liability'),0)
               + COALESCE(SUM(bal) FILTER (WHERE category='equity'),0)
               + COALESCE(SUM(bal) FILTER (WHERE category='revenue'),0)
               - COALESCE(SUM(bal) FILTER (WHERE category='expense'),0)
            THEN 'BALANCED' ELSE '*** BROKEN ***' END AS equation
FROM agg GROUP BY rn, idempotency_key ORDER BY rn;
