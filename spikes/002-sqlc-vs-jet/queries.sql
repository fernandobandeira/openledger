-- ============================================================ 1. AUTH TX

-- name: LockCreditLine :one
SELECT limit_minor, receivable_account_id
FROM credit_lines
WHERE company_id = $1
FOR UPDATE;

-- name: GetHeld :one
-- The two-grain FILTER aggregate. A card's holds are a subset of its company's,
-- so both grains come out of ONE pass.
SELECT
  COALESCE(SUM(GREATEST(amount_minor - cleared_minor, 0)), 0)::bigint AS company_held,
  COALESCE(SUM(GREATEST(amount_minor - cleared_minor, 0))
           FILTER (WHERE card_id = $2), 0)::bigint                    AS card_held
FROM card_holds
WHERE company_id = $1 AND state = 'open';

-- name: InsertHold :one
-- THE INSERT IS THE REDUCTION. No counter to decrement.
-- No row back => duplicate; caller must return the STORED decision.
INSERT INTO card_holds (auth_id, company_id, card_id, amount_minor,
                        state, decision, decline_reason, expires_at)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
ON CONFLICT (auth_id) DO NOTHING
RETURNING decision;

-- name: GetStoredDecision :one
SELECT decision, state FROM card_holds WHERE auth_id = $1;

-- ============================================================ 2. BALANCES

-- name: GetBalance :one
SELECT balance_after FROM ledger_entries
WHERE account_id = $1
ORDER BY account_seq DESC LIMIT 1;

-- name: GetBalanceAsOf :one
SELECT balance_after FROM ledger_entries
WHERE account_id = $1 AND recorded_at <= $2
ORDER BY account_seq DESC LIMIT 1;

-- ============================================================ 3. SPEND CONTROLS (arrays)

-- name: GetSpendControls :one
SELECT * FROM spend_controls WHERE card_id = $1;

-- name: UpsertSpendControls :one
INSERT INTO spend_controls (card_id, company_id, cap_minor, period, timezone,
                            allowed_mcc, blocked_mcc, allowed_merchants, active)
VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)
ON CONFLICT (card_id) DO UPDATE SET
  cap_minor = EXCLUDED.cap_minor, period = EXCLUDED.period,
  allowed_mcc = EXCLUDED.allowed_mcc, blocked_mcc = EXCLUDED.blocked_mcc,
  allowed_merchants = EXCLUDED.allowed_merchants, active = EXCLUDED.active
RETURNING *;

-- ============================================================ 4. EMBED TESTS

-- name: GetAccount :one
-- Does sqlc.embed give us a bare table struct instead of a flattened row?
SELECT sqlc.embed(ledger_accounts) FROM ledger_accounts WHERE id = $1;

-- name: ListEntriesWithAccount :many
-- Two embeds across a join -- the nested-entity case.
SELECT sqlc.embed(ledger_entries), sqlc.embed(ledger_accounts)
FROM ledger_entries
JOIN ledger_accounts ON ledger_accounts.id = ledger_entries.account_id
WHERE ledger_entries.transaction_id = $1
ORDER BY ledger_entries.id;

-- name: GetEntryWithTxnAndAccount :one
-- Three-way embed + a scalar, mixed.
SELECT sqlc.embed(ledger_entries), sqlc.embed(ledger_transactions),
       ledger_accounts.purpose
FROM ledger_entries
JOIN ledger_transactions ON ledger_transactions.id = ledger_entries.transaction_id
JOIN ledger_accounts     ON ledger_accounts.id     = ledger_entries.account_id
WHERE ledger_entries.id = $1;

-- ============================================================ 5. DYNAMIC REPORTING

-- name: ListEntriesFiltered :many
-- sqlc's answer to dynamic filters: sqlc.narg + a NULL-means-any predicate.
SELECT sqlc.embed(ledger_entries)
FROM ledger_entries
JOIN ledger_transactions t ON t.id = ledger_entries.transaction_id
WHERE (sqlc.narg('account_id')::uuid   IS NULL OR ledger_entries.account_id = sqlc.narg('account_id')::uuid)
  AND (sqlc.narg('direction')::ledger_direction IS NULL OR ledger_entries.direction = sqlc.narg('direction')::ledger_direction)
  AND (sqlc.narg('kind')::text         IS NULL OR t.kind = sqlc.narg('kind')::text)
  AND (sqlc.narg('from_ts')::timestamptz IS NULL OR ledger_entries.recorded_at >= sqlc.narg('from_ts')::timestamptz)
  AND (sqlc.narg('to_ts')::timestamptz   IS NULL OR ledger_entries.recorded_at <  sqlc.narg('to_ts')::timestamptz)
ORDER BY ledger_entries.account_seq DESC
LIMIT $1 OFFSET $2;

-- name: RawSumNoCoalesce :one
-- DELIBERATE LANDMINE: sqlc types this int64 (non-nullable), but SQL SUM over
-- zero rows returns NULL. See spike findings.
SELECT SUM(amount_minor)::bigint AS total FROM ledger_entries WHERE account_id = $1;
