\set ON_ERROR_STOP 0
\echo '=== setup: two accounts ==='
INSERT INTO ledger_accounts (tenant_id, owner_type, owner_id, purpose, category, normal_balance, currency)
VALUES ('t1','company','acme','customer_receivable','asset','debit','USD'),
       (NULL,'house',NULL,'interchange_revenue','revenue','credit','USD');

\echo ''
\echo '=== T1: house uniqueness -- second interchange_revenue MUST fail ==='
INSERT INTO ledger_accounts (owner_type, owner_id, purpose, category, normal_balance, currency)
VALUES ('house',NULL,'interchange_revenue','revenue','credit','USD');

\echo ''
\echo '=== T2: house account with an owner_id MUST fail (check constraint) ==='
INSERT INTO ledger_accounts (owner_type, owner_id, purpose, category, normal_balance, currency)
VALUES ('house','oops','facility_borrowings','liability','credit','USD');

\echo ''
\echo '=== T3: UNBALANCED transaction MUST fail at COMMIT (deferred trigger) ==='
BEGIN;
  INSERT INTO ledger_transactions (idempotency_key, kind, status, effective_at)
  VALUES ('evt_bad:posting','clearing','posted', now());
  INSERT INTO ledger_entries (transaction_id, account_id, direction, amount_minor, currency, account_seq, balance_after)
  SELECT t.id, a.id, 'debit', 30000, 'USD', 1, 30000
    FROM ledger_transactions t, ledger_accounts a
   WHERE t.idempotency_key='evt_bad:posting' AND a.purpose='customer_receivable';
  INSERT INTO ledger_entries (transaction_id, account_id, direction, amount_minor, currency, account_seq, balance_after)
  SELECT t.id, a.id, 'credit', 29999, 'USD', 1, 29999
    FROM ledger_transactions t, ledger_accounts a
   WHERE t.idempotency_key='evt_bad:posting' AND a.purpose='interchange_revenue';
  \echo '  (entries inserted -- trigger is DEFERRED, so nothing has fired yet)'
COMMIT;

\echo ''
\echo '=== T4: BALANCED transaction MUST succeed ==='
BEGIN;
  INSERT INTO ledger_transactions (idempotency_key, kind, status, effective_at)
  VALUES ('evt_good:posting','clearing','posted', now());
  INSERT INTO ledger_entries (transaction_id, account_id, direction, amount_minor, currency, account_seq, balance_after)
  SELECT t.id, a.id, 'debit', 30000, 'USD', 1, 30000
    FROM ledger_transactions t, ledger_accounts a
   WHERE t.idempotency_key='evt_good:posting' AND a.purpose='customer_receivable';
  INSERT INTO ledger_entries (transaction_id, account_id, direction, amount_minor, currency, account_seq, balance_after)
  SELECT t.id, a.id, 'credit', 30000, 'USD', 1, 30000
    FROM ledger_transactions t, ledger_accounts a
   WHERE t.idempotency_key='evt_good:posting' AND a.purpose='interchange_revenue';
COMMIT;
\echo '  entries now in ledger:'
SELECT count(*) AS entries FROM ledger_entries;

\echo ''
\echo '=== T5: negative amount MUST fail (direction carries the sign) ==='
INSERT INTO ledger_entries (transaction_id, account_id, direction, amount_minor, currency, account_seq, balance_after)
SELECT t.id, a.id, 'debit', -5, 'USD', 99, 0 FROM ledger_transactions t, ledger_accounts a
 WHERE t.idempotency_key='evt_good:posting' AND a.purpose='customer_receivable';

\echo ''
\echo '=== T6: duplicate account_seq MUST fail ==='
INSERT INTO ledger_entries (transaction_id, account_id, direction, amount_minor, currency, account_seq, balance_after)
SELECT t.id, a.id, 'debit', 100, 'USD', 1, 0 FROM ledger_transactions t, ledger_accounts a
 WHERE t.idempotency_key='evt_good:posting' AND a.purpose='customer_receivable';

\echo ''
\echo '=== T7: duplicate idempotency_key MUST fail ==='
INSERT INTO ledger_transactions (idempotency_key, kind, status, effective_at)
VALUES ('evt_good:posting','clearing','posted', now());
