-- 30 -- PROPOSED DDL, part 3 of 3: the statements read the versioned chart, the
-- balance sheet presents counterparty positions GROSS, and two lint views make a
-- wrong counterparty_scope or is_perimeter detectable.

BEGIN;

-- ------------------------------------------------------------ income statement
--
-- Identical to the baseline's except that fs_line comes from chart_presentation
-- at a version, and the version is emitted. A statement that does not say which
-- chart it was presented under is not reproducible.
CREATE VIEW income_statement AS
WITH cv AS (SELECT chart_version FROM chart_version_current),
dp AS (
    SELECT e.tenant_id, e.currency, p.fs_line,
           SUM(CASE WHEN e.direction='debit' THEN e.amount_minor ELSE -e.amount_minor END) AS v
    FROM ledger_entries e
    JOIN ledger_transactions x ON x.tenant_id = e.tenant_id AND x.id = e.transaction_id
                              AND x.status = 'posted'
    JOIN ledger_accounts a ON a.tenant_id = e.tenant_id AND a.id = e.account_id
                          AND a.currency  = e.currency
    CROSS JOIN cv
    JOIN chart_presentation p ON p.chart_version = cv.chart_version AND p.type_code = a.purpose
    GROUP BY e.tenant_id, e.currency, p.fs_line
), scopes AS (SELECT DISTINCT tenant_id, currency FROM ledger_accounts)
SELECT s.tenant_id, s.currency, cv.chart_version,
       f.code AS fs_line, f.caption, f.sort_order,
       (CASE WHEN f.side = 'credit' THEN -1 ELSE 1 END
        * COALESCE(SUM(d.v), 0))::bigint AS amount_minor,
       f.side
FROM scopes s
CROSS JOIN cv
JOIN fs_lines f ON f.chart_version = cv.chart_version
LEFT JOIN dp d ON d.tenant_id = s.tenant_id AND d.currency = s.currency AND d.fs_line = f.code
WHERE f.statement = 'income_statement'
GROUP BY s.tenant_id, s.currency, cv.chart_version, f.code, f.caption, f.sort_order, f.side
ORDER BY tenant_id, currency, sort_order;


-- ------------------------------------------------------------ the balance sheet
--
-- TWO CHANGES OF SUBSTANCE, and the rest is the baseline's view unchanged.
--
-- 1. THE AGGREGATE IS PER ACCOUNT BEFORE IT IS PER LINE. The baseline summed
--    straight to (tenant, currency, fs_line, category), which is arithmetic
--    netting across every account on the line, and ADR-0007 §13 says netting has
--    rules: IAS 32.42 and ASC 210-20-45-1 permit offset only between the same two
--    parties. For a type whose split key IS the counterparty, one account is one
--    counterparty (uq_accounts__owned), so the position is evaluated per account
--    and each one is routed to its own line. Netting WITHIN one counterparty is
--    left alone -- that is one party and it is permitted.
--
--    What is NOT attempted: offsetting two DIFFERENT types facing the same party.
--    IAS 32.42 requires both a legally enforceable right of set-off AND an
--    intention to settle net, and this schema declares neither, so the
--    presentation stays gross. Gross is the conservative direction and, absent
--    the declaration, the required one.
--
-- 2. THE SIGN FOLLOWS THE LINE, NOT THE ACCOUNT. The baseline signed by
--    `d.category = 'asset'`. A liability position routed to its contra line lands
--    on an ASSET line and must present positive there; signing by the account's
--    category prints it negative on an asset line, which is the same class of
--    mistake as deriving fs_side from normal_balance (ADR-0007 made that one
--    category-only for the same reason). f.side is now three-valued, and asset is
--    the debit-positive side.
CREATE VIEW balance_sheet AS
WITH cv AS (SELECT chart_version FROM chart_version_current),
pos AS (
    SELECT e.tenant_id, e.currency, e.account_id,
           p.category, p.counterparty_scope, p.fs_line, p.fs_line_contra,
           SUM(CASE WHEN e.direction='debit' THEN e.amount_minor ELSE -e.amount_minor END) AS v
    FROM ledger_entries e
    JOIN ledger_transactions x ON x.tenant_id = e.tenant_id AND x.id = e.transaction_id
                              AND x.status = 'posted'
    JOIN ledger_accounts a ON a.tenant_id = e.tenant_id AND a.id = e.account_id
                          AND a.currency  = e.currency
    CROSS JOIN cv
    JOIN chart_presentation p ON p.chart_version = cv.chart_version AND p.type_code = a.purpose
    GROUP BY e.tenant_id, e.currency, e.account_id,
             p.category, p.counterparty_scope, p.fs_line, p.fs_line_contra
), dp AS (
    SELECT tenant_id, currency, category,
           CASE WHEN counterparty_scope = 'per_shard'
                     AND ((category = 'asset'     AND v < 0)
                       OR (category = 'liability' AND v > 0))
                THEN fs_line_contra ELSE fs_line END AS fs_line,
           v
    FROM pos
), scopes AS (
    SELECT DISTINCT tenant_id, currency FROM ledger_accounts
), lines AS (
    SELECT s.tenant_id, s.currency, cv.chart_version,
           f.code AS fs_line, f.caption, f.sort_order, f.side,
           COALESCE(SUM(CASE WHEN f.side = 'asset' THEN d.v ELSE -d.v END), 0)::bigint
               AS amount_minor
    FROM scopes s
    CROSS JOIN cv
    JOIN fs_lines f ON f.chart_version = cv.chart_version
    LEFT JOIN dp d ON d.tenant_id = s.tenant_id AND d.currency = s.currency
                  AND d.fs_line = f.code
    WHERE f.statement = 'balance_sheet'
    GROUP BY s.tenant_id, s.currency, cv.chart_version, f.code, f.caption, f.sort_order, f.side
)
SELECT tenant_id, currency, chart_version, fs_line, caption, sort_order, amount_minor, side
FROM lines
UNION ALL
-- The synthesised un-closed-earnings plug, unchanged except that its side is now
-- 'equity' rather than 'liability_equity'. Undistributed earnings are equity;
-- under the old two-valued side that could not be said.
SELECT s.tenant_id, s.currency, cv.chart_version, 'current_year_earnings',
       'Undistributed earnings (since inception)', 9000,
       (-COALESCE(SUM(d.v), 0))::bigint, 'equity'
FROM scopes s
CROSS JOIN cv
LEFT JOIN dp d ON d.tenant_id = s.tenant_id AND d.currency = s.currency
              AND d.category IN ('revenue','expense')
GROUP BY s.tenant_id, s.currency, cv.chart_version
ORDER BY tenant_id, currency, sort_order;


-- ------------------------------------------------------------ perimeter drift
--
-- is_perimeter's consumer. Compares what a third party says the balance was on
-- their statement date against what our book says on the same BUSINESS date --
-- the effective axis, because a counterparty's statement is dated by their book
-- (ADR-0006). `as_of` is a date and effective_at is a timestamptz, so the bound
-- is `< as_of + 1 day`, inclusive of the whole day.
CREATE VIEW perimeter_drift AS
SELECT at.tenant_id, at.account_id, a.purpose, at.currency, at.as_of, at.source,
       t.is_perimeter,
       at.external_balance_minor,
       COALESCE(ours.v, 0)                             AS ledger_balance_minor,
       COALESCE(ours.v, 0) - at.external_balance_minor AS drift_minor
FROM perimeter_attestations at
JOIN ledger_accounts a ON a.tenant_id = at.tenant_id AND a.id = at.account_id
                      AND a.currency = at.currency
JOIN account_types t ON t.code = a.purpose
LEFT JOIN LATERAL (
    SELECT SUM(CASE WHEN e.direction='debit' THEN e.amount_minor ELSE -e.amount_minor END) AS v
    FROM ledger_entries e
    JOIN ledger_transactions x ON x.tenant_id = e.tenant_id AND x.id = e.transaction_id
                              AND x.status = 'posted'
    WHERE e.tenant_id = at.tenant_id AND e.account_id = at.account_id
      AND e.currency = at.currency
      AND e.effective_at < (at.as_of + 1)::timestamptz
) ours ON true;


-- ------------------------------------------------------------ the chart lint
--
-- WHAT THIS IS FOR. After the two views above, a wrong counterparty_scope CHANGES
-- A REPORTED NUMBER -- declaring due_to_tenants `shared` collapses the gross
-- presentation back to a netted zero -- which is the strongest kind of
-- detectability and also the most dangerous, because the number stays balanced.
-- These rules catch the SHAPE instead: a chart claim that the account register
-- contradicts. They are exception views, so empty is the passing state.
--
-- They are lints and not constraints because every one of them is a statement
-- about a POPULATION of rows in another table, which no CHECK and no key can
-- reach. The one rule that could be made a key -- per_shard implies not house --
-- is a key, in 21_scope_and_perimeter.sql, and appears here too so that a
-- deployment adopting it NOT VALID still sees its legacy rows.
CREATE VIEW chart_lint AS
-- 1. every type must be presented by the current chart. At-most-one is
--    pk_presentation; at-least-one is mandatory participation across two tables,
--    which is not declaratively expressible in PostgreSQL.
SELECT 'type_unpresented' AS rule, 'error' AS severity, t.code AS subject,
       'account type has no chart_presentation row in the current chart version' AS detail
FROM account_types t, chart_version_current cv
WHERE NOT EXISTS (SELECT 1 FROM chart_presentation p
                   WHERE p.chart_version = cv.chart_version AND p.type_code = t.code)
UNION ALL
-- 2. a line nothing can reach. Not an error -- a chart may carry a line ahead of
--    the type that will use it -- but a caption no account can ever reach is a
--    zero on the face of every statement forever, and ADR-0007 §11 makes zeros
--    meaningful, so an unreachable one is noise in the one report whose job is
--    completeness.
SELECT 'line_unreachable', 'info', f.code,
       'fs_line has no account type mapped to it in this chart version'
FROM fs_lines f, chart_version_current cv
WHERE f.chart_version = cv.chart_version
  AND NOT EXISTS (SELECT 1 FROM chart_presentation p
                   WHERE p.chart_version = f.chart_version
                     AND (p.fs_line = f.code OR p.fs_line_contra = f.code))
UNION ALL
-- 3. counterparty_scope = 'per_shard' held in a house account. The grain the
--    gross presentation needs does not exist, and no report can recover it.
SELECT 'per_shard_in_house_account', 'error', t.code,
       'per_shard type held in ' || count(*) || ' house account(s): opposite-sign '
       'positions against different counterparties are already netted at write time'
FROM account_types t
JOIN ledger_accounts a ON a.purpose = t.code AND a.owner_type = 'house'
WHERE t.counterparty_scope = 'per_shard'
GROUP BY t.code
UNION ALL
-- 4. counterparty_scope = 'shared' -- "all members face ONE counterparty" -- on a
--    type whose accounts are keyed to more than one owner inside a scope. The
--    split key demonstrably IS a counterparty distinction, so the declaration is
--    false and the statement is netting parties it may not net. This is the wrong
--    value in the direction the constraint cannot see.
SELECT 'shared_but_split_by_owner', 'error', t.code,
       'counterparty_scope=shared but accounts are keyed to ' || count(DISTINCT a.owner_id)
       || ' distinct owners'
FROM account_types t
JOIN ledger_accounts a ON a.purpose = t.code AND a.owner_type <> 'house'
WHERE t.counterparty_scope = 'shared'
GROUP BY t.code
HAVING count(DISTINCT a.owner_id) > 1
UNION ALL
-- 5. counterparty_scope = 'none' -- no counterparty at all -- on an owner-keyed
--    type. Either the owner is a counterparty and the scope is wrong, or the
--    owner is a reporting dimension and the account register is using the wrong
--    column for it.
SELECT 'none_but_owner_keyed', 'warn', t.code,
       'counterparty_scope=none but ' || count(*) || ' account(s) are owner-keyed'
FROM account_types t
JOIN ledger_accounts a ON a.purpose = t.code AND a.owner_type <> 'house'
WHERE t.counterparty_scope = 'none'
GROUP BY t.code
UNION ALL
-- 6. is_perimeter = true and nobody outside has ever confirmed the balance. The
--    column's whole claim is "must reconcile against an external balance"; an
--    account with posted entries and no attestation has never been reconciled,
--    and until now that was not observable anywhere.
SELECT 'perimeter_unattested', 'error', t.code || ' / ' || a.tenant_id || ' / ' || a.id::text,
       'is_perimeter account carries posted entries and has no attestation'
FROM account_types t
JOIN ledger_accounts a ON a.purpose = t.code
WHERE t.is_perimeter
  AND EXISTS (SELECT 1 FROM ledger_entries e
              JOIN ledger_transactions x ON x.tenant_id=e.tenant_id AND x.id=e.transaction_id
                                        AND x.status='posted'
              WHERE e.tenant_id=a.tenant_id AND e.account_id=a.id)
  AND NOT EXISTS (SELECT 1 FROM perimeter_attestations at
                  WHERE at.tenant_id=a.tenant_id AND at.account_id=a.id)
UNION ALL
-- 7. ...and the other direction. Somebody outside confirms this balance, and the
--    chart says it is not a perimeter account. One of the two is wrong, and it is
--    usually the chart -- this is the shape that caught network_settlement_payable
--    in spike 004, found by reading rather than by a check.
SELECT 'attested_but_not_perimeter', 'warn', a.purpose || ' / ' || at.source,
       'attestation exists for an account whose type declares is_perimeter = false'
FROM perimeter_attestations at
JOIN ledger_accounts a ON a.tenant_id=at.tenant_id AND a.id=at.account_id AND a.currency=at.currency
JOIN account_types t ON t.code = a.purpose
WHERE NOT t.is_perimeter
GROUP BY a.purpose, at.source
UNION ALL
-- 8. the drift itself, on the most recent attestation per account and source.
SELECT 'perimeter_drift', 'error',
       d.purpose || ' / ' || d.tenant_id || ' / ' || d.source,
       'ledger ' || d.ledger_balance_minor || ' against attested '
       || d.external_balance_minor || ' as of ' || d.as_of
FROM perimeter_drift d
WHERE d.drift_minor <> 0
  AND d.as_of = (SELECT max(d2.as_of) FROM perimeter_drift d2
                  WHERE d2.tenant_id=d.tenant_id AND d2.account_id=d.account_id
                    AND d2.currency=d.currency AND d2.source=d.source);

GRANT SELECT ON balance_sheet, income_statement, perimeter_drift, chart_lint TO openledger_app;

COMMIT;
