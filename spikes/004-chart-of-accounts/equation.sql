-- The theorem this whole design rests on:
--
--   IF  (a) every transaction balances (debits = credits) per currency
--   AND (b) every account's category + normal_balance are correct
--   THEN the accounting equation holds automatically, at every instant, on any axis.
--
-- (a) is enforced by ck_entries__balances. (b) is enforced by the chart FK and
-- ck_accounts__matches_type. Neither is a convention -- both are constraints.
--
-- So "is the math right" is not a test we run at the end. It is a property.
-- This view lets us CHECK the property rather than trust it.

CREATE OR REPLACE VIEW trial_balance AS
SELECT a.id AS account_id, a.owner_id, a.purpose, t.category, t.normal_balance, e.currency,
       SUM(CASE WHEN e.direction = 'debit'  THEN e.amount_minor ELSE 0 END) AS debits,
       SUM(CASE WHEN e.direction = 'credit' THEN e.amount_minor ELSE 0 END) AS credits,
       -- the NATURAL balance: positive means "more of what this account normally holds"
       CASE WHEN t.normal_balance = 'debit'
            THEN SUM(CASE WHEN e.direction='debit' THEN e.amount_minor ELSE -e.amount_minor END)
            ELSE SUM(CASE WHEN e.direction='credit' THEN e.amount_minor ELSE -e.amount_minor END)
       END AS balance_minor
FROM ledger_entries e
JOIN ledger_accounts a ON a.id = e.account_id
JOIN account_types   t ON t.code = a.purpose
GROUP BY a.id, a.owner_id, a.purpose, t.category, t.normal_balance, e.currency;

-- A = L + E + (R - X), as of any instant, on either time axis.
-- PER CURRENCY. Evaluating this across currencies is not merely imprecise, it is
-- VACUOUS: A = L + E + (R - X) follows from total debits = total credits, which
-- holds for any union of per-currency-balanced transactions REGARDLESS of
-- denomination. A currency-blind check therefore reports `true` for arbitrary
-- currency mixing and can never detect it. Demonstrated: 100.00 USD + 100.00 EUR
-- read as "assets 200.00, balanced".
--
-- The axis argument is also validated rather than falling through: a mis-cased
-- axis previously returned an empty, balanced report -- exactly the "green check
-- that didn't actually execute" failure this project cites Formance for.
CREATE OR REPLACE FUNCTION accounting_equation(p_as_of timestamptz DEFAULT NULL, p_axis text DEFAULT 'recorded')
RETURNS TABLE (currency char(3), assets bigint, liabilities bigint, equity bigint, revenue bigint,
               expense bigint, lhs bigint, rhs bigint, balanced boolean)
LANGUAGE sql AS $$
WITH validated AS (
    SELECT CASE WHEN p_axis IN ('recorded','effective') THEN p_axis
                ELSE (SELECT 1/0)::text END AS axis   -- fail loudly, never silently
), e AS (
    SELECT en.currency, t.category, t.normal_balance, en.direction, en.amount_minor
    FROM ledger_entries en
    JOIN ledger_accounts a ON a.id = en.account_id
    JOIN account_types   t ON t.code = a.purpose
    CROSS JOIN validated v
    WHERE p_as_of IS NULL
       OR (v.axis = 'recorded'  AND en.recorded_at  <= p_as_of)
       OR (v.axis = 'effective' AND en.effective_at <= p_as_of)
), n AS (
    SELECT e.currency, category,
           SUM(CASE WHEN normal_balance = 'debit'
                    THEN CASE WHEN direction='debit'  THEN amount_minor ELSE -amount_minor END
                    ELSE CASE WHEN direction='credit' THEN amount_minor ELSE -amount_minor END
               END) AS bal
    FROM e GROUP BY e.currency, category
), v AS (
    SELECT n.currency,
           COALESCE(MAX(bal) FILTER (WHERE category='asset'),0)     AS a,
           COALESCE(MAX(bal) FILTER (WHERE category='liability'),0) AS l,
           COALESCE(MAX(bal) FILTER (WHERE category='equity'),0)    AS eq,
           COALESCE(MAX(bal) FILTER (WHERE category='revenue'),0)   AS r,
           COALESCE(MAX(bal) FILTER (WHERE category='expense'),0)   AS x
    FROM n GROUP BY n.currency
)
SELECT v.currency, a, l, eq, r, x, a AS lhs, l + eq + (r - x) AS rhs,
       a = l + eq + (r - x) FROM v ORDER BY v.currency;
$$;
