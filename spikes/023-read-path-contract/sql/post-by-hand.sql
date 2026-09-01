-- One posting, written the way `CLAIM_AND_APPEND` writes it
-- (crates/ledger/postgres/src/repository.rs:389), so that a transaction can be
-- held OPEN across a cursor capture — which is the one thing the HTTP writer
-- cannot do for us and the one thing the ADR-0006 breaker needs.
--
-- Everything the reproducibility experiments read is posted through the
-- compiled binary over HTTP; this file exists only for the adversary session,
-- and it is deliberately the same CTE shape (claim → txn → delta → striped →
-- balance → entry) rather than a convenient shortcut, so that the rows it
-- leaves behind are indistinguishable from the writer's and the book still
-- reconciles.
--
-- Parameters, all via psql :variables:
--   tenant, key, eff, src, dst, amt, stripe
--
-- Direction, per the domain: `amount_minor` LEAVES src (credit) and ARRIVES at
-- dst (debit). The balance row's `input` is the debit side.

WITH claimed AS (
    INSERT INTO ledger_events
           (tenant_id, kind, source, idempotency_key, idempotency_hash,
            payload, effective_at)
    VALUES (:'tenant', 'posting', 'spike023-by-hand', :'key',
            sha256(:'key'::bytea), '{"spike": "023"}'::jsonb, :'eff')
    ON CONFLICT (tenant_id, idempotency_key) DO NOTHING
    RETURNING id
),
txn AS (
    INSERT INTO ledger_transactions
           (tenant_id, event_id, kind, status, effective_at)
    SELECT :'tenant', c.id, 'posting', 'posted', :'eff' FROM claimed c
    RETURNING id
),
leg AS (
    SELECT * FROM (VALUES
        (:'src'::uuid, 'credit', :amt::bigint),
        (:'dst'::uuid, 'debit',  :amt::bigint)
    ) AS l(account_id, direction, amount_minor)
),
delta AS (
    SELECT l.account_id, 'USD'::text AS currency,
           COALESCE(SUM(l.amount_minor) FILTER (WHERE l.direction = 'debit'), 0)::bigint  AS input,
           COALESCE(SUM(l.amount_minor) FILTER (WHERE l.direction = 'credit'), 0)::bigint AS output,
           COUNT(*) AS legs
    FROM claimed c CROSS JOIN leg l
    GROUP BY l.account_id
),
striped AS MATERIALIZED (
    SELECT a.tenant_id, a.id AS account_id, a.currency,
           a.owner_type, a.owner_id_key, a.purpose, a.category, a.normal_balance,
           d.input, d.output, d.legs,
           (:stripe::int % a.stripe_count)::smallint AS stripe
    FROM delta d
    JOIN ledger_accounts a
      ON a.tenant_id = :'tenant' AND a.id = d.account_id AND a.currency = d.currency
),
balance AS (
    INSERT INTO ledger_account_balances
           (tenant_id, account_id, currency, stripe,
            owner_type, owner_id_key, purpose, category, normal_balance,
            input, output, last_seq)
    SELECT s.tenant_id, s.account_id, s.currency, s.stripe,
           s.owner_type, s.owner_id_key, s.purpose, s.category, s.normal_balance,
           s.input, s.output, s.legs
    FROM striped s
    ORDER BY s.account_id, s.currency, s.stripe
    ON CONFLICT (tenant_id, account_id, currency, stripe) DO UPDATE
    SET input      = ledger_account_balances.input + EXCLUDED.input,
        output     = ledger_account_balances.output + EXCLUDED.output,
        last_seq   = ledger_account_balances.last_seq + EXCLUDED.last_seq,
        updated_at = now()
    RETURNING account_id, currency, stripe, last_seq
)
INSERT INTO ledger_entries
       (tenant_id, transaction_id, account_id, direction, amount_minor,
        currency, stripe, account_seq, effective_at)
SELECT :'tenant', t.id, l.account_id, l.direction::ledger_direction, l.amount_minor,
       'USD', b.stripe, b.last_seq, :'eff'
FROM txn t
CROSS JOIN leg l
JOIN balance b ON b.account_id = l.account_id
RETURNING transaction_id, account_id, direction, account_seq, xact_id;
