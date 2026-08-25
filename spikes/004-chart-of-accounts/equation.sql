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
CREATE OR REPLACE FUNCTION accounting_equation(p_as_of timestamptz DEFAULT NULL, p_axis text DEFAULT 'recorded')
RETURNS TABLE (assets bigint, liabilities bigint, equity bigint, revenue bigint, expense bigint,
               lhs bigint, rhs bigint, balanced boolean)
LANGUAGE sql AS $$
WITH e AS (
    SELECT t.category, t.normal_balance, en.direction, en.amount_minor
    FROM ledger_entries en
    JOIN ledger_accounts a ON a.id = en.account_id
    JOIN account_types   t ON t.code = a.purpose
    WHERE p_as_of IS NULL
       OR (p_axis = 'recorded'  AND en.recorded_at  <= p_as_of)
       OR (p_axis = 'effective' AND en.effective_at <= p_as_of)
), n AS (
    SELECT category,
           SUM(CASE WHEN normal_balance = 'debit'
                    THEN CASE WHEN direction='debit'  THEN amount_minor ELSE -amount_minor END
                    ELSE CASE WHEN direction='credit' THEN amount_minor ELSE -amount_minor END
               END) AS bal
    FROM e GROUP BY category
), v AS (
    SELECT COALESCE(MAX(bal) FILTER (WHERE category='asset'),0)     AS a,
           COALESCE(MAX(bal) FILTER (WHERE category='liability'),0) AS l,
           COALESCE(MAX(bal) FILTER (WHERE category='equity'),0)    AS eq,
           COALESCE(MAX(bal) FILTER (WHERE category='revenue'),0)   AS r,
           COALESCE(MAX(bal) FILTER (WHERE category='expense'),0)   AS x
    FROM n
)
SELECT a, l, eq, r, x, a AS lhs, l + eq + (r - x) AS rhs, a = l + eq + (r - x) FROM v;
$$;
