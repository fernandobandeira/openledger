-- Q5 · a book big enough to price the inception scan.
--
-- Written in bulk rather than through the binary, and the trade is stated: the
-- HTTP writer would take hours for a million entries, and Q5 is a question
-- about the READ, so what matters is that the rows are indistinguishable from
-- the writer's and that the book still reconciles. It does — the cache is
-- computed from the journal in the same transaction, at the same
-- (account, currency, stripe) grain, and `SELECT * FROM reconciliation` is the
-- gate.
--
-- Shape, per transaction: one event, one transaction, two entries — the
-- two-leg posting the writer emits for one `source → destination` posting
-- (`expand_postings`, crates/ledger/src/postings.rs). effective_at spreads
-- over three years so a business-date range is a real range and not a
-- degenerate one.
--
--   :tenant  the book to write
--   :n       how many transactions (⇒ 2n entries)
--   :stripes how many stripes to spread the balance rows over
--
-- ONE stripe would understate the read: ADR-0018 made the current-balance read
-- a SUM over stripe rows, and a striped account is the normal case for exactly
-- the accounts a report scans most.

\set ON_ERROR_STOP on
\timing off

BEGIN;

-- Two accounts, the same non-perimeter pair the rest of the spike uses, so
-- chart_lint.perimeter_unattested stays out of the ten-check oracle.
INSERT INTO ledger_accounts
       (tenant_id, owner_type, owner_id, purpose, category, normal_balance,
        counterparty_scope, currency, stripe_count)
SELECT :'tenant', 'company', 'co_bulk', 'customer_receivable', 'asset', 'debit',
       'per_shard', 'USD', :stripes
WHERE NOT EXISTS (SELECT 1 FROM ledger_accounts
                  WHERE tenant_id = :'tenant' AND purpose = 'customer_receivable');
INSERT INTO ledger_accounts
       (tenant_id, owner_type, owner_id, purpose, category, normal_balance,
        counterparty_scope, currency, stripe_count)
SELECT :'tenant', 'house', NULL, 'fee_revenue', 'revenue', 'credit',
       'none', 'USD', :stripes
WHERE NOT EXISTS (SELECT 1 FROM ledger_accounts
                  WHERE tenant_id = :'tenant' AND purpose = 'fee_revenue');

CREATE TEMP TABLE ids AS
SELECT (SELECT id FROM ledger_accounts
        WHERE tenant_id = :'tenant' AND purpose = 'customer_receivable') AS recv,
       (SELECT id FROM ledger_accounts
        WHERE tenant_id = :'tenant' AND purpose = 'fee_revenue')        AS rev;

-- The events. `sha256(text)` gives a per-row hash the way the writer's
-- canonical form does; nothing here replays, so only its shape matters.
CREATE TEMP TABLE spec AS
SELECT g AS n,
       -- three years of business dates, ascending, one per transaction
       ('2023-01-01T00:00:00Z'::timestamptz
        + (g::numeric / GREATEST(:n, 1) * 1095) * interval '1 day') AS eff,
       (100 + (g % 900))::bigint AS amt,
       -- the stripe a writer of index (g % 8) would have taken (ADR-0018 §1:
       -- worker affinity, and the only property that matters is that
       -- concurrent writers hold different values)
       ((g % 8) % :stripes)::smallint AS stripe
FROM generate_series(1, :n) g;

INSERT INTO ledger_events
       (tenant_id, kind, source, idempotency_key, idempotency_hash, payload, effective_at)
SELECT :'tenant', 'posting', 'spike023-bulk',
       'bulk-' || s.n, sha256(('bulk-' || s.n)::bytea),
       jsonb_build_object('spike', '023', 'n', s.n), s.eff
FROM spec s;

INSERT INTO ledger_transactions (tenant_id, id, event_id, kind, status, effective_at)
SELECT :'tenant', gen_random_uuid(), e.id, 'posting', 'posted', e.effective_at
FROM ledger_events e
WHERE e.tenant_id = :'tenant' AND e.source = 'spike023-bulk';

-- The balance rows first, so `fk_entries__stripe` is satisfiable and the
-- per-stripe last_seq is the number the entries then count backwards from.
INSERT INTO ledger_account_balances
       (tenant_id, account_id, currency, stripe, owner_type, owner_id_key,
        purpose, category, normal_balance, input, output, last_seq)
SELECT :'tenant', a.id, 'USD', s.stripe, a.owner_type, a.owner_id_key,
       a.purpose, a.category, a.normal_balance,
       CASE WHEN a.purpose = 'customer_receivable' THEN SUM(s.amt) ELSE 0 END,
       CASE WHEN a.purpose = 'fee_revenue'         THEN SUM(s.amt) ELSE 0 END,
       COUNT(*)
FROM spec s
CROSS JOIN ledger_accounts a
WHERE a.tenant_id = :'tenant'
GROUP BY a.id, s.stripe, a.owner_type, a.owner_id_key, a.purpose, a.category,
         a.normal_balance
ON CONFLICT (tenant_id, account_id, currency, stripe) DO UPDATE
SET input    = ledger_account_balances.input    + EXCLUDED.input,
    output   = ledger_account_balances.output   + EXCLUDED.output,
    last_seq = ledger_account_balances.last_seq + EXCLUDED.last_seq;

-- The entries. account_seq is dense per (account, stripe) — gapless is the
-- property `recon_balance_breaks` checks, and it checks it per stripe.
INSERT INTO ledger_entries
       (tenant_id, transaction_id, account_id, direction, amount_minor,
        currency, stripe, account_seq, effective_at)
SELECT :'tenant', x.id, i.acct, i.dir::ledger_direction, s.amt, 'USD', s.stripe,
       row_number() OVER (PARTITION BY i.acct, s.stripe ORDER BY s.n),
       s.eff
FROM spec s
JOIN ledger_events e       ON e.tenant_id = :'tenant'
                          AND e.idempotency_key = 'bulk-' || s.n
JOIN ledger_transactions x ON x.tenant_id = :'tenant' AND x.event_id = e.id
CROSS JOIN LATERAL (
    SELECT (SELECT recv FROM ids) AS acct, 'debit'  AS dir
    UNION ALL
    SELECT (SELECT rev  FROM ids),          'credit'
) i;

COMMIT;

ANALYZE ledger_entries;
ANALYZE ledger_transactions;
ANALYZE ledger_account_balances;

\pset format aligned
SELECT tenant_id, count(*) AS entries,
       count(DISTINCT transaction_id) AS transactions,
       min(effective_at)::date AS first_effective,
       max(effective_at)::date AS last_effective
FROM ledger_entries GROUP BY 1 ORDER BY 1;
