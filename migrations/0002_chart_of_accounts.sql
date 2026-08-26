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
    code       text CONSTRAINT pk_fs_lines PRIMARY KEY,
    -- The caption is what a reader sees, so two lines carrying the SAME caption
    -- are indistinguishable on the face of the statement -- which is exactly the
    -- harm the restricted-cash split exists to prevent, arrived at from the other
    -- direction. Giving `restricted_cash` the caption 'Cash and cash equivalents'
    -- passed every trigger and every test: the split was real in the chart and
    -- invisible in the report. Nothing in the suite reads a caption, so this is
    -- the constraint rather than a test.
    caption    text NOT NULL CONSTRAINT uq_fs_lines__caption UNIQUE,
    statement  text NOT NULL CONSTRAINT ck_fs_lines__statement
                   CHECK (statement IN ('balance_sheet','income_statement')),
    -- Which side of the statement this line sits on, declared rather than
    -- inferred. balance_sheet used to derive it from whatever happened to be
    -- posted (`bool_or(category = 'asset')`), so a line with NO activity evaluated
    -- to NULL and landed on the liability/equity side -- inferring the chart from
    -- the data, in the one report whose whole purpose is the opposite.
    -- side must belong to the statement. The CHECK used to admit all four values on
    -- either statement, and balance_sheet_balances counts only 'asset' and
    -- 'liability_equity' -- so a balance-sheet line carrying side 'debit' was
    -- counted on NEITHER side and vanished. Verified: 90% of a balance sheet
    -- missing, reporting balanced = true.
    side       text NOT NULL,
    -- `current_year_earnings` is SYNTHESISED by the balance_sheet view for
    -- un-closed earnings. A chart that also declares a real line by that code
    -- produces two rows with the same caption and no way to tell them apart --
    -- one an account subtotal, one a derived plug.
    CONSTRAINT ck_fs_lines__code_reserved
        CHECK (code <> 'current_year_earnings'),
    CONSTRAINT ck_fs_lines__side_matches_statement CHECK (
        (statement = 'balance_sheet'    AND side IN ('asset','liability_equity')) OR
        (statement = 'income_statement' AND side IN ('credit','debit'))),
    sort_order int  NOT NULL DEFAULT 1000
);

CREATE TABLE account_types (
    code           text CONSTRAINT pk_account_types PRIMARY KEY,
    category       ledger_category       NOT NULL,
    -- NOT derivable from category: a loss allowance is an asset with a CREDIT
    -- normal balance. Storing both is the only correct option.
    normal_balance ledger_normal_balance NOT NULL,
    description    text NOT NULL,
    fs_line        text NOT NULL CONSTRAINT fk_types__fs_line REFERENCES fs_lines(code),
    -- mirrors exactly one external balance and must reconcile against it
    is_perimeter   boolean NOT NULL DEFAULT false,
    -- Can a set of these accounts be summed for reporting? Only if all members
    -- face ONE counterparty. IAS 1.32 / ASC 210-20-45-1 permit offsetting only
    -- for amounts due to and from the same party; where the shard key IS the
    -- counterparty, opposite-sign members must be presented gross.
    counterparty_scope text NOT NULL DEFAULT 'none'
        CONSTRAINT ck_types__counterparty_scope
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
        -- tenant, not owner_id: a house account has owner_id NULL, so the old
        -- message identified the offender as "<NULL>/operating_cash".
        RAISE EXCEPTION 'account %/%/% declares %/% but type % is %/%',
            NEW.tenant_id, COALESCE(NEW.owner_id,'house'), NEW.purpose,
            NEW.category, NEW.normal_balance, t.code, t.category, t.normal_balance;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER ck_accounts__matches_type
    BEFORE INSERT OR UPDATE ON ledger_accounts
    FOR EACH ROW EXECUTE FUNCTION assert_account_matches_type();
ALTER TABLE ledger_accounts ENABLE ALWAYS TRIGGER ck_accounts__matches_type;

-- An account's PURPOSE decides which statement line its whole history reports
-- under. Re-pointing it at a type with the SAME category and normal_balance
-- passed every check while moving that history somewhere else: operating_cash to
-- customer_receivable is asset/debit to asset/debit, and 1,573.00 moved from Cash
-- to Accounts receivable with the equation, the drift view and the balance sheet
-- all green. The seed ships three such same-shaped pairs.
CREATE FUNCTION assert_purpose_not_repointed() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE n bigint;
BEGIN
    IF NEW.purpose IS DISTINCT FROM OLD.purpose THEN
        SELECT count(*) INTO n FROM ledger_entries
         WHERE tenant_id = OLD.tenant_id AND account_id = OLD.id;
        IF n > 0 THEN
            RAISE EXCEPTION
              'cannot re-point account %/% from % to %: % entr% already report under %',
              OLD.tenant_id, OLD.id, OLD.purpose, NEW.purpose, n,
              CASE WHEN n = 1 THEN 'y' ELSE 'ies' END, OLD.purpose
              USING ERRCODE = '23514';
        END IF;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER ck_accounts__purpose_stable
    BEFORE UPDATE ON ledger_accounts
    FOR EACH ROW EXECUTE FUNCTION assert_purpose_not_repointed();
ALTER TABLE ledger_accounts ENABLE ALWAYS TRIGGER ck_accounts__purpose_stable;

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

    -- fs_line decides which STATEMENT LINE every historical number appears on, and
    -- it was freely mutable: one UPDATE silently moved 9.00 of interchange from
    -- 'revenue' to 'other_income' on an already-issued income statement, with no
    -- ledger row changed and every check green. That falsifies the project's
    -- headline claim that any number is reproducible as of any date.
    --
    -- Blocking the UPDATE is a STOPGAP, not the answer: IAS 1.41 REQUIRES
    -- reclassifying comparatives when presentation changes, so a real system must
    -- version the mapping and resolve it as of the report date. Recorded as open
    -- in ADR-0009; refusing the silent rewrite is strictly better than allowing it.
    IF NEW.fs_line <> OLD.fs_line THEN
        SELECT count(*) INTO n FROM ledger_accounts a WHERE a.purpose = NEW.code;
        IF n > 0 THEN
            RAISE EXCEPTION
              'cannot move % from statement line % to %: % account(s) exist, and '
              'their history is already reported under %. The chart is not versioned '
              '(ADR-0009), so this would silently restate issued statements',
              NEW.code, OLD.fs_line, NEW.fs_line, n, OLD.fs_line;
        END IF;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER ck_types__matches_accounts
    BEFORE UPDATE ON account_types
    FOR EACH ROW EXECUTE FUNCTION assert_type_matches_accounts();
ALTER TABLE account_types ENABLE ALWAYS TRIGGER ck_types__matches_accounts;

-- fs_lines had NO guard at all, while account_types.fs_line had one -- and the
-- identical harm sits one table over. Swapping two captions relabelled an issued
-- balance sheet (1,573.00 presented as "Accounts receivable", 470.00 as "Cash"),
-- and moving a line to the other statement double-counted revenue into equity.
-- `statement` and `side` are structural and are frozen once anything reports
-- under the line; `caption` and `sort_order` are presentation and stay editable,
-- which is the honest split until the chart is versioned (ADR-0009).
CREATE FUNCTION assert_fs_line_stable() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE n bigint;
BEGIN
    IF NEW.statement IS DISTINCT FROM OLD.statement
       OR NEW.side IS DISTINCT FROM OLD.side THEN
        -- account_TYPES, not accounts. The pairing this guards is
        -- (account_types.category <-> fs_lines.statement/side); counting accounts
        -- let a line with types pointing at it but no accounts YET move freely,
        -- straight into a state its sibling guard refuses to create. A facility
        -- draw then presented as revenue, and the equation reported balanced while
        -- the balance sheet reported broken -- two integrity checks disagreeing.
        SELECT count(*) INTO n FROM account_types t WHERE t.fs_line = OLD.code;
        IF n > 0 THEN
            RAISE EXCEPTION
              'cannot move statement line % (% / %) to (% / %): % account type(s) report under it',
              OLD.code, OLD.statement, OLD.side, NEW.statement, NEW.side, n
              USING ERRCODE = '23514';
        END IF;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER ck_fs_lines__stable
    BEFORE UPDATE ON fs_lines
    FOR EACH ROW EXECUTE FUNCTION assert_fs_line_stable();
ALTER TABLE fs_lines ENABLE ALWAYS TRIGGER ck_fs_lines__stable;

-- An account type's CATEGORY must agree with the statement line it reports under.
-- Nothing tied them: pointing a `revenue` type at a cost-of-revenue line put 6,000
-- of revenue on the expense side of the income statement -- revenue understatement,
-- the harm ADR-0009 is entirely about -- with every check green. The stability
-- triggers all guard CHANGES to the mapping; none guarded its creation.
CREATE FUNCTION assert_type_matches_fs_line() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE f fs_lines;
BEGIN
    SELECT * INTO f FROM fs_lines WHERE code = NEW.fs_line;
    IF f.code IS NULL THEN RETURN NEW; END IF;   -- the FK will speak
    IF (NEW.category IN ('asset','liability','equity')) <> (f.statement = 'balance_sheet')
       OR (NEW.category = 'asset'            AND f.side <> 'asset')
       OR (NEW.category IN ('liability','equity') AND f.side <> 'liability_equity')
       OR (NEW.category = 'revenue'          AND f.side <> 'credit')
       OR (NEW.category = 'expense'          AND f.side <> 'debit') THEN
        RAISE EXCEPTION
            'account type % is %, which cannot report under statement line % (% / %)',
            NEW.code, NEW.category, f.code, f.statement, f.side
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER ck_types__matches_fs_line
    BEFORE INSERT OR UPDATE ON account_types
    FOR EACH ROW EXECUTE FUNCTION assert_type_matches_fs_line();
ALTER TABLE account_types ENABLE ALWAYS TRIGGER ck_types__matches_fs_line;

-- ------------------------------------------------------------ reporting

CREATE VIEW trial_balance AS
SELECT a.tenant_id, a.id AS account_id, a.owner_id, a.purpose,
       t.category, t.normal_balance, e.currency,
       -- COALESCE, because an account with only credits returned NULL for debits,
       -- and `WHERE debits - credits <> 0` then DROPS the row instead of flagging
       -- it -- the same NULL-swallowing class as the `NULL NOT IN (...)` bug.
       COALESCE(SUM(e.amount_minor) FILTER (WHERE e.direction='debit'), 0)  AS debits,
       COALESCE(SUM(e.amount_minor) FILTER (WHERE e.direction='credit'), 0) AS credits,
       -- natural balance: positive means more of what this account normally holds
       -- PRESENTATION value: positive means more of what this account normally
       -- holds. Correct for showing ONE account; WRONG to sum across a category,
       -- because a contra account (asset/credit) would then ADD to assets.
       CASE WHEN t.normal_balance = 'debit'
            THEN SUM(CASE WHEN e.direction='debit'  THEN e.amount_minor ELSE -e.amount_minor END)
            ELSE SUM(CASE WHEN e.direction='credit' THEN e.amount_minor ELSE -e.amount_minor END)
       END AS balance_minor,
       -- ARITHMETIC value -- roll up with this one. normal_balance never enters it,
       -- so a contra account carries its own sign instead of being flipped twice.
       SUM(CASE WHEN e.direction='debit' THEN e.amount_minor ELSE -e.amount_minor END)
           AS balance_debit_positive
FROM ledger_entries e
JOIN ledger_transactions x ON x.tenant_id = e.tenant_id AND x.id = e.transaction_id
                          AND x.status = 'posted'
JOIN ledger_accounts a ON a.tenant_id = e.tenant_id AND a.id = e.account_id
JOIN account_types   t ON t.code = a.purpose
GROUP BY a.tenant_id, a.id, a.owner_id, a.purpose, t.category, t.normal_balance, e.currency;

-- A = L + E + (R - X), PER CURRENCY and PER TENANT.
--
-- Two corrections, both found by adversarial review, both of which produced a
-- GREEN check on wrong books:
--
-- 1. PER CURRENCY. Evaluating across currencies is not merely imprecise, it is
--    VACUOUS. The identity follows from total debits = total credits, which holds
--    for any union of per-currency-balanced transactions REGARDLESS of
--    denomination -- so a currency-blind check reports `true` for arbitrary
--    currency mixing and can never detect it. Measured before the fix: 100.00 USD
--    + 100.00 EUR reported "assets 200.00, balanced".
--
-- 2. DEBIT-POSITIVE, and normal_balance does NOT appear. The earlier version
--    normalised each account to ITS OWN normal balance and then summed those into
--    category buckets -- so a contra account got flipped twice.
--    `allowance_for_credit_losses` (asset / CREDIT) contributed +100 to assets
--    instead of -100, and the seed ships that account as the flagship proof that
--    normal_balance is not derivable from category. The equation was wrong on
--    exactly the case the design singles out as its hard one, and still reported
--    `balanced = true` with both sides overstated.
--
--    Signs now come from `direction` alone. Since total debits = total credits,
--    the debit-positive sum over ALL categories is zero, and this identity is a
--    restatement of that fact. normal_balance is a PRESENTATION concern.
CREATE FUNCTION accounting_equation(
    p_tenant text DEFAULT NULL,
    p_as_of  timestamptz DEFAULT NULL,
    p_axis   text DEFAULT 'recorded')
RETURNS TABLE (tenant_id text, currency char(3), assets bigint, liabilities bigint,
               equity bigint, revenue bigint, expense bigint,
               lhs bigint, rhs bigint, balanced boolean)
LANGUAGE plpgsql STABLE AS $fn$
BEGIN
    -- Fail loudly. A mis-typed axis previously fell through every predicate and
    -- returned an empty, BALANCED report -- the "green check that didn't actually
    -- execute" failure this project cites Formance for.
    --
    -- `p_axis IS NULL` must be tested SEPARATELY: `NULL NOT IN (...)` evaluates to
    -- NULL, not TRUE, so a nil *string from Go fell straight through this guard
    -- into exactly the empty balanced report it exists to prevent.
    IF p_axis IS NULL OR p_axis NOT IN ('recorded','effective') THEN
        RAISE EXCEPTION 'unknown axis %; expected recorded or effective',
            COALESCE(p_axis, '<NULL>');
    END IF;

    -- The SAME failure, on the other parameter. The axis was guarded and the
    -- tenant was not, so 'Acme', 'acme ' or any typo returned zero rows -- and
    -- `bool_and(balanced)` over zero rows is NULL, while the idiomatic
    -- `for rows.Next() { if !balanced }` loop passes on an empty result. That is
    -- the green check that did not execute, reached through a different door.
    -- aliased: tenant_id is also an OUT parameter of this function, so an
    -- unqualified reference is ambiguous
    IF p_tenant IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM ledger_accounts la WHERE la.tenant_id = p_tenant) THEN
        RAISE EXCEPTION 'unknown tenant %; it holds no accounts', p_tenant;
    END IF;

    -- ...and an EMPTY ledger is not a balanced one. On a freshly migrated and
    -- seeded database this function returned ZERO ROWS: a caller doing
    -- `bool_and(balanced)` over them gets NULL, not false, and a report that
    -- printed nothing at all read as a report that found nothing wrong. That is
    -- the same shape as the truncation finding -- silence mistaken for assent.
    IF NOT EXISTS (SELECT 1 FROM ledger_accounts) THEN
        RAISE EXCEPTION
            'no accounts exist, so there is nothing to balance; an empty report is '
            'not a balanced one'
            USING ERRCODE = 'data_exception';
    END IF;

    RETURN QUERY
    WITH scopes AS (
        -- Enumerated from the ACCOUNTS, like balance_sheet. Returning zero rows for
        -- a scope that exists is the empty-balanced-report failure by another door:
        -- a VALID tenant with a VALID axis and an as-of before its first entry
        -- returned nothing, and `bool_and(balanced)` over zero rows is NULL while
        -- the idiomatic `for rows.Next() { if !balanced }` loop passes. A scope with
        -- no activity yet is a scope reporting zeros, not a scope that is absent.
        SELECT DISTINCT a.tenant_id, a.currency FROM ledger_accounts a
         WHERE p_tenant IS NULL OR a.tenant_id = p_tenant
    ), e AS (
        SELECT en.tenant_id, en.currency, t.category,
               -- debit-positive, always
               SUM(CASE WHEN en.direction = 'debit' THEN en.amount_minor
                        ELSE -en.amount_minor END) AS dp
        FROM ledger_entries en
        -- POSTED only. `status` was read by nothing: a pending authorization was
        -- recognised as revenue, and its posted resolution then counted it AGAIN --
        -- 500.00 of interchange twice, every check green. `ck_txn__not_both` also
        -- forbids the resolving transaction from being the reversal of the pending
        -- one, so the schema made the single-transaction correction illegal.
        JOIN ledger_transactions x ON x.tenant_id = en.tenant_id
                                  AND x.id = en.transaction_id AND x.status = 'posted'
        JOIN ledger_accounts a ON a.tenant_id = en.tenant_id AND a.id = en.account_id
        JOIN account_types   t ON t.code = a.purpose
        WHERE (p_tenant IS NULL OR en.tenant_id = p_tenant)
          AND (p_as_of IS NULL
               OR (p_axis = 'recorded'  AND en.recorded_at  <= p_as_of)
               OR (p_axis = 'effective' AND en.effective_at <= p_as_of))
        GROUP BY en.tenant_id, en.currency, t.category
    ), c AS (
        -- assets and expenses are debit-normal CATEGORIES, presented as-is;
        -- liabilities, equity and revenue are credit-normal, negated once here,
        -- for presentation only. LEFT JOIN from scopes so a scope with no activity
        -- in range reports zeros rather than vanishing.
        SELECT s.tenant_id, s.currency,
                COALESCE(SUM(dp) FILTER (WHERE category='asset'),0)::bigint       AS a,
               (-COALESCE(SUM(dp) FILTER (WHERE category='liability'),0))::bigint AS l,
               (-COALESCE(SUM(dp) FILTER (WHERE category='equity'),0))::bigint    AS q,
               (-COALESCE(SUM(dp) FILTER (WHERE category='revenue'),0))::bigint   AS r,
                COALESCE(SUM(dp) FILTER (WHERE category='expense'),0)::bigint     AS x
        FROM scopes s
        LEFT JOIN e ON e.tenant_id = s.tenant_id AND e.currency = s.currency
        GROUP BY s.tenant_id, s.currency
    )
    SELECT c.tenant_id, c.currency, c.a, c.l, c.q, c.r, c.x,
           c.a, (c.l + c.q + c.r - c.x), c.a = (c.l + c.q + c.r - c.x)
    FROM c ORDER BY c.tenant_id, c.currency;
END $fn$;

-- ------------------------------------------------------------ the balance sheet
--
-- ADR-0009 claimed "reports enumerate from the chart outward, so there is no
-- parameter in which to pass an incomplete account list." That was ASPIRATIONAL:
-- trial_balance and accounting_equation both start FROM ledger_entries and
-- enumerate INWARD, so an account with no entries is simply absent. This view is
-- the claim made true -- it starts FROM fs_lines and left-joins the numbers on, so
-- a statement line with no activity appears as a zero rather than vanishing.
--
-- It also carries the line the chart could not previously produce. Before this,
-- a balance sheet built from fs_lines was out by exactly net income: there is no
-- retained_earnings account and no close, so revenue and expense had nowhere to
-- go. Un-closed books present that residual as CURRENT YEAR EARNINGS inside
-- equity, which is standard interim presentation -- and it is a derived line, not
-- an account, precisely because no closing entry has been made.
CREATE VIEW balance_sheet AS
WITH dp AS (
    SELECT e.tenant_id, e.currency, t.fs_line, t.category,
           SUM(CASE WHEN e.direction='debit' THEN e.amount_minor ELSE -e.amount_minor END) AS v
    FROM ledger_entries e
    JOIN ledger_transactions x ON x.tenant_id = e.tenant_id AND x.id = e.transaction_id
                              AND x.status = 'posted'
    JOIN ledger_accounts a ON a.tenant_id = e.tenant_id AND a.id = e.account_id
    JOIN account_types   t ON t.code = a.purpose
    GROUP BY e.tenant_id, e.currency, t.fs_line, t.category
), scopes AS (
    -- Enumerated from the ACCOUNTS, not from the entries. A scope that has been
    -- opened but has not yet posted anything is still a scope, and a report that
    -- cannot name it cannot claim completeness over it.
    --
    -- HONEST LIMIT: this is still enumeration from data, one level further out.
    -- There is no tenant registry and no currency registry, so a scope with no
    -- accounts at all remains invisible, and `p_tenant` below is exactly the
    -- "parameter in which to pass an incomplete list" that ADR-0009 says should
    -- not exist. Completeness here is guaranteed WITHIN a scope, not across them.
    SELECT DISTINCT tenant_id, currency FROM ledger_accounts
), lines AS (
    SELECT s.tenant_id, s.currency, f.code AS fs_line, f.caption, f.sort_order, f.side,
           COALESCE(SUM(CASE WHEN d.category = 'asset' THEN d.v ELSE -d.v END), 0)::bigint
               AS amount_minor
    FROM scopes s
    CROSS JOIN fs_lines f
    LEFT JOIN dp d ON d.tenant_id = s.tenant_id AND d.currency = s.currency
                  AND d.fs_line = f.code
    WHERE f.statement = 'balance_sheet'
    GROUP BY s.tenant_id, s.currency, f.code, f.caption, f.sort_order, f.side
)
SELECT tenant_id, currency, fs_line, caption, sort_order, amount_minor, side FROM lines
UNION ALL
SELECT s.tenant_id, s.currency, 'current_year_earnings', 'Current year earnings', 9000,
       (-COALESCE(SUM(d.v), 0))::bigint, 'liability_equity'
FROM scopes s
LEFT JOIN dp d ON d.tenant_id = s.tenant_id AND d.currency = s.currency
              AND d.category IN ('revenue','expense')
GROUP BY s.tenant_id, s.currency;

-- The income statement, enumerated the same way. Its absence was itself a gap:
-- the completeness defence covered only the balance sheet, while revenue
-- understatement -- the thing ADR-0009 is about -- had no chart-outward report.
CREATE VIEW income_statement AS
WITH dp AS (
    SELECT e.tenant_id, e.currency, t.fs_line,
           SUM(CASE WHEN e.direction='debit' THEN e.amount_minor ELSE -e.amount_minor END) AS v
    FROM ledger_entries e
    JOIN ledger_transactions x ON x.tenant_id = e.tenant_id AND x.id = e.transaction_id
                              AND x.status = 'posted'
    JOIN ledger_accounts a ON a.tenant_id = e.tenant_id AND a.id = e.account_id
    JOIN account_types   t ON t.code = a.purpose
    GROUP BY e.tenant_id, e.currency, t.fs_line
), scopes AS (SELECT DISTINCT tenant_id, currency FROM ledger_accounts)
SELECT s.tenant_id, s.currency, f.code AS fs_line, f.caption, f.sort_order,
       -- credit-normal lines (revenue) present positive; debit-normal (expense) too
       (CASE WHEN f.side = 'credit' THEN -1 ELSE 1 END
        * COALESCE(SUM(d.v), 0))::bigint AS amount_minor,
       f.side
FROM scopes s
CROSS JOIN fs_lines f
LEFT JOIN dp d ON d.tenant_id = s.tenant_id AND d.currency = s.currency AND d.fs_line = f.code
WHERE f.statement = 'income_statement'
GROUP BY s.tenant_id, s.currency, f.code, f.caption, f.sort_order, f.side;

-- Assets must equal liabilities + equity, PER SCOPE and PER CURRENCY, with the
-- earnings line included. Unlike the roll-up check it replaced -- which compared
-- SUM(debits) against SUM(debits) across two FK-guaranteed joins and so could
-- never fail -- this one can and did.
CREATE FUNCTION balance_sheet_balances(p_tenant text DEFAULT NULL)
RETURNS TABLE (tenant_id text, currency char(3), assets bigint,
               liabilities_and_equity bigint, balanced boolean)
LANGUAGE plpgsql STABLE AS $fn$
BEGIN
    -- an unknown tenant must RAISE, not return an empty balanced report
    IF p_tenant IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM ledger_accounts a WHERE a.tenant_id = p_tenant) THEN
        RAISE EXCEPTION 'unknown tenant %; it holds no accounts', p_tenant;
    END IF;
    RETURN QUERY
    SELECT b.tenant_id, b.currency,
           COALESCE(SUM(b.amount_minor) FILTER (WHERE b.side = 'asset'), 0)::bigint,
           COALESCE(SUM(b.amount_minor) FILTER (WHERE b.side = 'liability_equity'), 0)::bigint,
           COALESCE(SUM(b.amount_minor) FILTER (WHERE b.side = 'asset'), 0)
             = COALESCE(SUM(b.amount_minor) FILTER (WHERE b.side = 'liability_equity'), 0)
    FROM balance_sheet b
    WHERE p_tenant IS NULL OR b.tenant_id = p_tenant
    GROUP BY b.tenant_id, b.currency
    ORDER BY b.tenant_id, b.currency;
END $fn$;

-- The app role could not open an account: assert_account_matches_type() is
-- SECURITY INVOKER and reads account_types, on which 0002 granted nothing -- so
-- 0001's GRANT INSERT ON ledger_accounts was dead (`permission denied for table
-- account_types`). It also could not read any report, including its own alarm.
GRANT SELECT ON account_types, fs_lines TO openledger_app;
GRANT SELECT ON trial_balance, balance_sheet, income_statement,
                ledger_balance_drift TO openledger_app;

-- ...and re-run the replica hardening, because THESE foreign keys did not exist
-- when 0001 ran it.
CALL enforce_triggers_on_replicas();

COMMIT;
