-- 0002 — the chart of accounts, and the invariants that make the books checkable.
--
-- Targets migrations/0001. Supersedes spikes/004-chart-of-accounts/*.sql, which
-- targeted the older spike schema and has now diverged from it.
--
-- Two corrections from adversarial review are baked in here and are the reason
-- this file exists rather than a copy of the spike:
--   * the accounting equation is evaluated PER CURRENCY (see below)
--   * a mis-typed axis raises, rather than silently returning an empty report

BEGIN;

-- Every account type maps to exactly one financial-statement line. This is what
-- makes omission structurally impossible: reports enumerate from the chart
-- outward, so there is no parameter in which to pass an incomplete account list.
CREATE TABLE fs_lines (
    code      text PRIMARY KEY,
    caption   text NOT NULL,
    statement text NOT NULL CHECK (statement IN ('balance_sheet','income_statement'))
);

CREATE TABLE account_types (
    code           text PRIMARY KEY,
    category       ledger_category       NOT NULL,
    -- NOT derivable from category: a loss allowance is an asset with a CREDIT
    -- normal balance. Storing both is the only correct option.
    normal_balance ledger_normal_balance NOT NULL,
    description    text NOT NULL,
    fs_line        text NOT NULL REFERENCES fs_lines(code),
    -- mirrors exactly one external balance and must reconcile against it
    is_perimeter   boolean NOT NULL DEFAULT false,
    -- Can a set of these accounts be summed for reporting? Only if all members
    -- face ONE counterparty. IAS 1.32 / ASC 210-20-45-1 permit offsetting only
    -- for amounts due to and from the same party; where the shard key IS the
    -- counterparty, opposite-sign members must be presented gross.
    counterparty_scope text NOT NULL DEFAULT 'none'
        CHECK (counterparty_scope IN ('none','shared','per_shard'))
);

ALTER TABLE ledger_accounts
    ADD CONSTRAINT fk_accounts__type FOREIGN KEY (purpose) REFERENCES account_types(code);

-- category and normal_balance live on the TYPE. They are duplicated onto the
-- account for query locality, so they must be kept honest -- and the check must
-- fire on BOTH sides, because updating the type alone previously desynchronised
-- them and silently rewrote the income statement.
CREATE FUNCTION assert_account_matches_type() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE t account_types;
BEGIN
    SELECT * INTO t FROM account_types WHERE code = NEW.purpose;
    IF NEW.category <> t.category OR NEW.normal_balance <> t.normal_balance THEN
        RAISE EXCEPTION 'account %/% declares %/% but type % is %/%',
            NEW.owner_id, NEW.purpose, NEW.category, NEW.normal_balance,
            t.code, t.category, t.normal_balance;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER ck_accounts__matches_type
    BEFORE INSERT OR UPDATE ON ledger_accounts
    FOR EACH ROW EXECUTE FUNCTION assert_account_matches_type();

-- The other side of the same invariant: changing a TYPE must not orphan accounts
-- that already declared the old classification.
CREATE FUNCTION assert_type_matches_accounts() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE n bigint;
BEGIN
    SELECT count(*) INTO n FROM ledger_accounts a
     WHERE a.purpose = NEW.code
       AND (a.category <> NEW.category OR a.normal_balance <> NEW.normal_balance);
    IF n > 0 THEN
        RAISE EXCEPTION
          'cannot reclassify % to %/%: % existing account(s) declare the old classification',
          NEW.code, NEW.category, NEW.normal_balance, n;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER ck_types__matches_accounts
    BEFORE UPDATE ON account_types
    FOR EACH ROW EXECUTE FUNCTION assert_type_matches_accounts();

-- ------------------------------------------------------------ reporting

CREATE VIEW trial_balance AS
SELECT a.tenant_id, a.id AS account_id, a.owner_id, a.purpose,
       t.category, t.normal_balance, e.currency,
       SUM(e.amount_minor) FILTER (WHERE e.direction='debit')  AS debits,
       SUM(e.amount_minor) FILTER (WHERE e.direction='credit') AS credits,
       -- natural balance: positive means more of what this account normally holds
       CASE WHEN t.normal_balance = 'debit'
            THEN SUM(CASE WHEN e.direction='debit'  THEN e.amount_minor ELSE -e.amount_minor END)
            ELSE SUM(CASE WHEN e.direction='credit' THEN e.amount_minor ELSE -e.amount_minor END)
       END AS balance_minor
FROM ledger_entries e
JOIN ledger_accounts a ON a.tenant_id = e.tenant_id AND a.id = e.account_id
JOIN account_types   t ON t.code = a.purpose
GROUP BY a.tenant_id, a.id, a.owner_id, a.purpose, t.category, t.normal_balance, e.currency;

-- A = L + E + (R - X), PER CURRENCY and PER TENANT.
--
-- Evaluating this across currencies is not merely imprecise, it is VACUOUS. The
-- identity follows from total debits = total credits, which holds for any union
-- of per-currency-balanced transactions REGARDLESS of denomination -- so a
-- currency-blind check reports `true` for arbitrary currency mixing and can never
-- detect it. Measured before the fix: 100.00 USD + 100.00 EUR reported
-- "assets 200.00, balanced".
CREATE FUNCTION accounting_equation(
    p_tenant text DEFAULT NULL,
    p_as_of  timestamptz DEFAULT NULL,
    p_axis   text DEFAULT 'recorded')
RETURNS TABLE (tenant_id text, currency char(3), assets bigint, liabilities bigint,
               equity bigint, revenue bigint, expense bigint,
               lhs bigint, rhs bigint, balanced boolean)
LANGUAGE plpgsql STABLE AS $$
BEGIN
    -- Fail loudly. A mis-typed axis previously fell through every predicate and
    -- returned an empty, BALANCED report -- the "green check that didn't actually
    -- execute" failure this project cites Formance for.
    IF p_axis NOT IN ('recorded','effective') THEN
        RAISE EXCEPTION 'unknown axis %; expected ''recorded'' or ''effective''', p_axis;
    END IF;

    RETURN QUERY
    WITH e AS (
        SELECT en.tenant_id, en.currency, t.category, t.normal_balance,
               en.direction, en.amount_minor
        FROM ledger_entries en
        JOIN ledger_accounts a ON a.tenant_id = en.tenant_id AND a.id = en.account_id
        JOIN account_types   t ON t.code = a.purpose
        WHERE (p_tenant IS NULL OR en.tenant_id = p_tenant)
          AND (p_as_of IS NULL
               OR (p_axis = 'recorded'  AND en.recorded_at  <= p_as_of)
               OR (p_axis = 'effective' AND en.effective_at <= p_as_of))
    ), n AS (
        SELECT e.tenant_id, e.currency, e.category,
               SUM(CASE WHEN e.normal_balance='debit'
                        THEN CASE WHEN e.direction='debit'  THEN e.amount_minor ELSE -e.amount_minor END
                        ELSE CASE WHEN e.direction='credit' THEN e.amount_minor ELSE -e.amount_minor END
                   END) AS bal
        FROM e GROUP BY e.tenant_id, e.currency, e.category
    )
    SELECT n.tenant_id, n.currency,
           COALESCE(SUM(bal) FILTER (WHERE category='asset'),0)::bigint,
           COALESCE(SUM(bal) FILTER (WHERE category='liability'),0)::bigint,
           COALESCE(SUM(bal) FILTER (WHERE category='equity'),0)::bigint,
           COALESCE(SUM(bal) FILTER (WHERE category='revenue'),0)::bigint,
           COALESCE(SUM(bal) FILTER (WHERE category='expense'),0)::bigint,
           COALESCE(SUM(bal) FILTER (WHERE category='asset'),0)::bigint,
           (COALESCE(SUM(bal) FILTER (WHERE category='liability'),0)
          + COALESCE(SUM(bal) FILTER (WHERE category='equity'),0)
          + COALESCE(SUM(bal) FILTER (WHERE category='revenue'),0)
          - COALESCE(SUM(bal) FILTER (WHERE category='expense'),0))::bigint,
           COALESCE(SUM(bal) FILTER (WHERE category='asset'),0)
             = COALESCE(SUM(bal) FILTER (WHERE category='liability'),0)
             + COALESCE(SUM(bal) FILTER (WHERE category='equity'),0)
             + COALESCE(SUM(bal) FILTER (WHERE category='revenue'),0)
             - COALESCE(SUM(bal) FILTER (WHERE category='expense'),0)
    FROM n GROUP BY n.tenant_id, n.currency ORDER BY n.tenant_id, n.currency;
END $$;

COMMIT;
