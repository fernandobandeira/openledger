-- 02 -- CHANNEL A. Foreign keys are skipped on the replication apply path.
-- Postgres implements referential integrity as internal triggers. Those triggers
-- ship in the default ENABLE ORIGIN state, and ENABLE ORIGIN triggers do not fire
-- when session_replication_role = 'replica' -- which is the logical-replication
-- apply path, and what `pg_restore --disable-triggers` sets.
--
-- Run against the seeded baseline. Nothing here needs a subscriber: replica role
-- IS the apply path's trigger environment.

\echo '=== before ==='
SELECT count(*) AS entries FROM ledger_entries;

BEGIN;
SET LOCAL session_replication_role = 'replica';

-- (a) an entry in a currency its account does not hold -- fk_entries__account is
--     (tenant_id, account_id, currency) and is meant to make this unrepresentable.
--     Also: a transaction id that does not exist at all (fk_entries__txn), and an
--     effective_at that contradicts its transaction's (fk_entries__txn_effective).
INSERT INTO ledger_entries (tenant_id, id, transaction_id, account_id, direction,
                            amount_minor, currency, account_seq, effective_at)
VALUES ('t1','dead0000-0000-0000-0000-000000000001',
        '00000000-0000-0000-0000-0000deadbeef',   -- no such transaction
        '11111111-1111-1111-1111-111111111111',
        'debit', 5000000, 'EUR',                  -- account holds USD
        99, '1999-01-01T00:00:00Z');              -- 27 years before its transaction

-- (b) a transaction pointing at an event that does not exist, resolving a
--     transaction that does not exist.
INSERT INTO ledger_transactions (tenant_id, id, event_id, kind, status, effective_at)
VALUES ('t1','dead0000-0000-0000-0000-00000000000f',
        '00000000-0000-0000-0000-00000000beef','clearing','posted','2026-03-01T00:00:00Z');

-- (c) an account whose category contradicts its type -- fk_accounts__type.
--     Note the currency: uq_accounts__house is a UNIQUE INDEX, not a trigger, and
--     unique indexes are NOT skipped in replica role. An earlier version of this
--     file reused USD and the whole block rolled back on it. What replica role
--     turns off is exactly the trigger-implemented constraints: foreign keys.
INSERT INTO ledger_accounts (tenant_id, id, owner_type, owner_id, purpose, category, normal_balance, currency)
VALUES ('t1','dead0000-0000-0000-0000-0000000000aa','house',NULL,
        'interchange_revenue','asset','debit','EUR');

COMMIT;

\echo '=== after: every one of the three committed ==='
SELECT count(*) AS entries FROM ledger_entries;
SELECT count(*) AS orphan_entries FROM ledger_entries e
 WHERE NOT EXISTS (SELECT 1 FROM ledger_transactions x
                    WHERE x.tenant_id=e.tenant_id AND x.id=e.transaction_id);
SELECT count(*) AS accounts_contradicting_their_type FROM ledger_accounts a
 WHERE NOT EXISTS (SELECT 1 FROM account_types t
                    WHERE t.code=a.purpose AND t.category=a.category
                      AND t.normal_balance=a.normal_balance);

\echo '=== and the ledger is still ENABLE ALWAYS-protected against DML: ==='
\echo '=== the SAME replica session cannot delete the row it just laundered in ==='
BEGIN;
SET LOCAL session_replication_role = 'replica';
DELETE FROM ledger_entries WHERE id='dead0000-0000-0000-0000-000000000001';
ROLLBACK;
