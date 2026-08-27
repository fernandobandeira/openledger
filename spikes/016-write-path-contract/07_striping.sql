-- 06_striping.sql -- striping as schema, and the reports it must not disturb.
--
-- THE SHAPE. A stripe is NOT an account. It is a physical partition of one
-- account's balance row -- ADR-0002's own words, "one logical account is stored as
-- N physical balance rows". Put it there and `uq_accounts__house` does not need to
-- change at all: one tenant still holds exactly one `network_settlement_payable`
-- account in USD, so two DIFFERENT house accounts of one purpose stay refused by
-- the index that already refuses them, while N stripes of that ONE account
-- coexist as N rows in `ledger_account_balances`.
--
-- Run after 00_seed.sql. Leaves the DDL applied; 08 drops it again.

\set ON_ERROR_STOP on
\pset pager off

-- ======================================================================
-- THE DDL, proposed for migrations/00002.
-- ======================================================================

-- 1. How many stripes the writer should spread across. A HINT, not an invariant:
--    a reader SUMs the rows that exist, never the range 0..n-1, so lowering this
--    can never strand a balance and raising it needs no backfill -- the next
--    writer that picks a new stripe creates it with the upsert it was going to
--    run anyway. There is no DDL at stripe-open time and no online migration.
ALTER TABLE ledger_accounts
    ADD COLUMN stripe_count smallint NOT NULL DEFAULT 1
        CONSTRAINT ck_accounts__stripe_count CHECK (stripe_count BETWEEN 1 AND 1024);

-- 2. The physical rows. The stripe joins the primary key, which is what lets N of
--    them exist and what makes each one a separate lock.
ALTER TABLE ledger_account_balances
    ADD COLUMN stripe smallint NOT NULL DEFAULT 0
        CONSTRAINT ck_balances__stripe_non_negative CHECK (stripe >= 0);
ALTER TABLE ledger_account_balances DROP CONSTRAINT pk_balances;
ALTER TABLE ledger_account_balances
    ADD CONSTRAINT pk_balances PRIMARY KEY (tenant_id, account_id, currency, stripe);

-- 3. The entry records which stripe's counter issued its account_seq. Without it
--    gaplessness is unfalsifiable: two stripes both issue 5 for one account and
--    uq_entries__account_seq refuses the second, which would serialise every
--    writer again through a unique index -- the bottleneck striping exists to
--    remove, moved one table over.
ALTER TABLE ledger_entries
    ADD COLUMN stripe smallint NOT NULL DEFAULT 0
        CONSTRAINT ck_entries__stripe_non_negative CHECK (stripe >= 0);
ALTER TABLE ledger_entries DROP CONSTRAINT uq_entries__account_seq;
ALTER TABLE ledger_entries
    ADD CONSTRAINT uq_entries__account_seq UNIQUE (tenant_id, account_id, stripe, account_seq);

-- 4. ...and the stripe it names must be one that exists. Same trick as
--    fk_entries__account: make the denormalised copy part of a composite key so it
--    cannot name a counter nothing issued.
ALTER TABLE ledger_entries
    ADD CONSTRAINT fk_entries__stripe
    FOREIGN KEY (tenant_id, account_id, currency, stripe)
    REFERENCES ledger_account_balances (tenant_id, account_id, currency, stripe);

\echo '=== 1. uq_accounts__house is UNTOUCHED. Two different house accounts of one'
\echo '===    purpose are still refused:'
\set ON_ERROR_STOP off
INSERT INTO ledger_accounts (tenant_id, id, owner_type, owner_id, purpose, category, normal_balance, currency)
VALUES ('t1','11111111-0000-0000-0000-0000000000ff','house',NULL,'network_settlement_payable','liability','credit','USD');
\set ON_ERROR_STOP on

\echo ''
\echo '=== 2. ...while 64 stripes of THAT ONE account are just 64 balance rows.'
UPDATE ledger_accounts SET stripe_count = 64
 WHERE tenant_id='t1' AND id='11111111-0000-0000-0000-000000000001';
INSERT INTO ledger_account_balances (tenant_id, account_id, currency, stripe)
SELECT 't1','11111111-0000-0000-0000-000000000001','USD', s FROM generate_series(1,63) s;
SELECT count(*) AS stripe_rows, count(DISTINCT account_id) AS accounts
FROM ledger_account_balances
WHERE tenant_id='t1' AND account_id='11111111-0000-0000-0000-000000000001';
SELECT count(*) AS rows_in_ledger_accounts FROM ledger_accounts
WHERE tenant_id='t1' AND purpose='network_settlement_payable';

-- ======================================================================
-- A striped book: 64 clearings, the house leg spread across the stripes, the
-- customer leg on stripe 0. Written the way the writer would: upsert the stripe
-- for the seq, then the entry.
-- ======================================================================
\echo ''
\echo '=== 3. post 64 clearings onto the striped book'
DO $$
DECLARE
    house    constant uuid := '11111111-0000-0000-0000-000000000001';
    revenue  constant uuid := '11111111-0000-0000-0000-000000000002';
    cust     constant uuid := '11111111-0000-0000-0000-000000000003';
    ev uuid; tx uuid; st smallint; s_h bigint; s_r bigint; s_c bigint; i int;
BEGIN
    FOR i IN 1..64 LOOP
        INSERT INTO ledger_events (tenant_id, kind, source, idempotency_key, idempotency_hash, payload, effective_at)
        VALUES ('t1','clearing','processor','stripe-'||i, sha256(('{"n":'||i||'}')::bytea),
                ('{"n":'||i||'}')::jsonb, '2026-08-20T00:00:00Z')
        RETURNING id INTO ev;

        INSERT INTO ledger_transactions (tenant_id, event_id, kind, status, effective_at)
        VALUES ('t1', ev, 'clearing','posted','2026-08-20T00:00:00Z') RETURNING id INTO tx;

        st := (i - 1) % 64;   -- affinity: writer i owns stripe i

        -- the house leg, on ITS stripe
        INSERT INTO ledger_account_balances AS b (tenant_id, account_id, currency, stripe, input, output, last_seq)
        VALUES ('t1', house, 'USD', st, 491, 0, 1)
        ON CONFLICT (tenant_id, account_id, currency, stripe) DO UPDATE
           SET input = b.input + excluded.input, last_seq = b.last_seq + 1
        RETURNING b.last_seq INTO s_h;
        INSERT INTO ledger_entries (tenant_id, transaction_id, account_id, direction, amount_minor, currency, stripe, account_seq, effective_at)
        VALUES ('t1', tx, house, 'credit', 491, 'USD', st, s_h, '2026-08-20T00:00:00Z');

        -- the revenue leg, unstriped (stripe 0)
        INSERT INTO ledger_account_balances AS b (tenant_id, account_id, currency, stripe, input, output, last_seq)
        VALUES ('t1', revenue,'USD', 0, 9, 0, 1)
        ON CONFLICT (tenant_id, account_id, currency, stripe) DO UPDATE
           SET input = b.input + excluded.input, last_seq = b.last_seq + 1
        RETURNING b.last_seq INTO s_r;
        INSERT INTO ledger_entries (tenant_id, transaction_id, account_id, direction, amount_minor, currency, stripe, account_seq, effective_at)
        VALUES ('t1', tx, revenue,'credit', 9, 'USD', 0, s_r, '2026-08-20T00:00:00Z');

        -- the customer leg, unstriped
        INSERT INTO ledger_account_balances AS b (tenant_id, account_id, currency, stripe, input, output, last_seq)
        VALUES ('t1', cust, 'USD', 0, 500, 0, 1)
        ON CONFLICT (tenant_id, account_id, currency, stripe) DO UPDATE
           SET input = b.input + excluded.input, last_seq = b.last_seq + 1
        RETURNING b.last_seq INTO s_c;
        INSERT INTO ledger_entries (tenant_id, transaction_id, account_id, direction, amount_minor, currency, stripe, account_seq, effective_at)
        VALUES ('t1', tx, cust, 'debit', 500, 'USD', 0, s_c, '2026-08-20T00:00:00Z');
    END LOOP;
END $$;

\echo ''
\echo '=== 4. the balance read: SUM the rows that exist, never the range 0..n-1.'
SELECT count(*) AS stripes_touched, sum(input - output) AS balance_minor, sum(last_seq) AS entries
FROM ledger_account_balances
WHERE tenant_id='t1' AND account_id='11111111-0000-0000-0000-000000000001' AND currency='USD';

\echo ''
\echo '=== 5. ...and it agrees with the journal, recomputed. This is the drift check,'
\echo '===    per stripe and in total.'
SELECT b.stripe, b.input - b.output AS cached,
       COALESCE(SUM(CASE WHEN e.direction='credit' THEN e.amount_minor ELSE -e.amount_minor END),0) AS recomputed
FROM ledger_account_balances b
LEFT JOIN ledger_entries e ON e.tenant_id=b.tenant_id AND e.account_id=b.account_id
                          AND e.currency=b.currency AND e.stripe=b.stripe
WHERE b.tenant_id='t1' AND b.account_id='11111111-0000-0000-0000-000000000001'
GROUP BY b.stripe, b.input, b.output
HAVING (b.input - b.output) <> COALESCE(SUM(CASE WHEN e.direction='credit' THEN e.amount_minor ELSE -e.amount_minor END),0);
\echo '--- zero rows above means no stripe has drifted.'

\echo ''
\echo '=== 6. gaplessness is now per (account, stripe). Every stripe runs 1..n with no hole:'
SELECT count(*) AS stripes_with_a_gap FROM (
    SELECT account_id, stripe, count(*) AS n, max(account_seq) AS hi, min(account_seq) AS lo
    FROM ledger_entries WHERE tenant_id='t1' GROUP BY account_id, stripe
) g WHERE g.lo <> 1 OR g.hi <> g.n;

-- ======================================================================
-- THE REPORTS. Not one of them changes, and this is the whole argument for
-- putting the stripe below the account rather than beside it.
-- ======================================================================
\echo ''
\echo '=== 7. trial_balance still reports ONE row per account, not 64.'
SELECT purpose, owner_id, currency, debits, credits, balance_minor
FROM trial_balance WHERE tenant_id='t1' ORDER BY purpose, owner_id NULLS FIRST;

\echo ''
\echo '=== 8. balance_sheet and income_statement roll the stripes up untouched.'
SELECT fs_line, caption, amount_minor, side FROM balance_sheet WHERE tenant_id='t1' ORDER BY sort_order;
SELECT fs_line, caption, amount_minor FROM income_statement WHERE tenant_id='t1' ORDER BY sort_order;

\echo ''
\echo '=== 9. the accounting equation over the striped book'
SELECT SUM(CASE WHEN side='asset' THEN amount_minor ELSE 0 END) AS assets,
       SUM(CASE WHEN side='liability_equity' THEN amount_minor ELSE 0 END) AS liab_equity,
       SUM(CASE WHEN side='asset' THEN amount_minor ELSE -amount_minor END) AS difference
FROM balance_sheet WHERE tenant_id='t1';

\echo ''
\echo '=== 10. a stripe number OUTSIDE stripe_count is harmless -- the reader sums rows,'
\echo '===     not a range -- which is what makes stripe_count a hint and not an invariant.'
INSERT INTO ledger_account_balances (tenant_id, account_id, currency, stripe, input, output, last_seq)
VALUES ('t1','11111111-0000-0000-0000-000000000001','USD', 999, 100, 0, 0);
SELECT count(*) AS stripe_rows, sum(input - output) AS balance_minor
FROM ledger_account_balances
WHERE tenant_id='t1' AND account_id='11111111-0000-0000-0000-000000000001';
UPDATE ledger_accounts SET stripe_count = 8 WHERE tenant_id='t1' AND id='11111111-0000-0000-0000-000000000001';
SELECT 'after lowering stripe_count 64 -> 8' AS note, sum(input - output) AS balance_minor
FROM ledger_account_balances
WHERE tenant_id='t1' AND account_id='11111111-0000-0000-0000-000000000001';

\echo ''
\echo '=== 11. an entry may not name a stripe that has no counter (fk_entries__stripe)'
\set ON_ERROR_STOP off
INSERT INTO ledger_entries (tenant_id, transaction_id, account_id, direction, amount_minor, currency, stripe, account_seq, effective_at)
SELECT 't1', t.id, '11111111-0000-0000-0000-000000000001','credit', 1, 'USD', 4242, 1, '2026-08-20T00:00:00Z'
FROM ledger_transactions t WHERE t.tenant_id='t1' LIMIT 1;
