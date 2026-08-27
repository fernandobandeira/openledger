-- 05_event_id_not_null.sql -- what `event_id` being nullable buys, what the
-- migration step costs, and why the cost is zero today and unpayable later.
--
-- Run after 00_seed.sql and 03_idempotency.sql (which leaves two properly-caused
-- transactions behind and no others).

\set ON_ERROR_STOP off
\pset pager off

\echo '=== 0. starting state: every transaction in this database has an event.'
SELECT count(*) AS transactions, count(event_id) AS with_event,
       count(*) - count(event_id) AS event_less FROM ledger_transactions;

-- ======================================================================
-- Everything in this block is rolled back. It exists to show what the ALTER
-- costs once ONE event-less transaction has committed.
-- ======================================================================
BEGIN;

\echo ''
\echo '=== 1. an event-less transaction inserts without complaint. fk_txn__event does'
\echo '===    not bite, because MATCH SIMPLE skips a key with a NULL column.'
INSERT INTO ledger_transactions (tenant_id, id, event_id, kind, status, effective_at) VALUES
  ('t1','bbbbbbbb-0000-0000-0000-000000000001', NULL, 'orphan','posted','2026-08-20T00:00:00Z'),
  ('t1','bbbbbbbb-0000-0000-0000-000000000002', NULL, 'orphan','posted','2026-08-20T00:00:00Z');
\echo '--- and uq_txn__one_per_event is PARTIAL on event_id IS NOT NULL, so it does not'
\echo '--- constrain them either: two event-less transactions coexist freely.'
SELECT count(*) AS event_less FROM ledger_transactions WHERE event_id IS NULL;

\echo ''
\echo '=== 2. the migration step, with those rows present: refused.'
SAVEPOINT s1;
ALTER TABLE ledger_transactions ALTER COLUMN event_id SET NOT NULL;
ROLLBACK TO s1;

\echo ''
\echo '=== 3. ...and they cannot be removed, because the journal is append-only.'
\echo '===    THIS is the cost: the repair a NOT NULL migration would need is the one'
\echo '===    thing this schema refuses.'
SAVEPOINT s2;
DELETE FROM ledger_transactions WHERE kind = 'orphan';
ROLLBACK TO s2;

\echo ''
\echo '=== 4. so the only routes left are the two the project calls holes:'
\echo '===    disable the append-only trigger, or fabricate the events that caused them.'
SAVEPOINT s3;
ALTER TABLE ledger_transactions DISABLE TRIGGER ck_txn__append_only;
DELETE FROM ledger_transactions WHERE kind = 'orphan';
ALTER TABLE ledger_transactions ENABLE ALWAYS TRIGGER ck_txn__append_only;
ALTER TABLE ledger_transactions ALTER COLUMN event_id SET NOT NULL;
\echo '--- it works, and it required turning off the guarantee to get there.'
ROLLBACK TO s3;

ROLLBACK;

-- ======================================================================
-- On a database that has none -- which is every database this schema has ever
-- produced, because nothing in the tree writes a transaction at all.
-- ======================================================================
\echo ''
\echo '=== 5. THE MIGRATION STEP, on a book with no event-less transactions.'
ALTER TABLE ledger_transactions ALTER COLUMN event_id SET NOT NULL;

\echo ''
\echo '=== 6. AFTER: the event-less insert is refused by the column...'
INSERT INTO ledger_transactions (tenant_id, id, event_id, kind, status, effective_at)
VALUES ('t1','bbbbbbbb-0000-0000-0000-000000000003', NULL, 'orphan','posted','2026-08-20T00:00:00Z');
\echo '===    ...and fk_txn__event is now TOTAL, so a made-up event id is refused too.'
INSERT INTO ledger_transactions (tenant_id, id, event_id, kind, status, effective_at)
VALUES ('t1','bbbbbbbb-0000-0000-0000-000000000004',
        '00000000-0000-0000-0000-000000000000','orphan','posted','2026-08-20T00:00:00Z');

\echo ''
\echo '=== 7. uq_txn__one_per_event needs no change: with the column NOT NULL every row'
\echo '===    satisfies its predicate, so the partial index is total in effect.'
\echo '===    A second transaction from the same event, refused:'
INSERT INTO ledger_transactions (tenant_id, id, event_id, kind, status, effective_at)
SELECT 't1','bbbbbbbb-0000-0000-0000-000000000005', e.id, 'clearing','posted','2026-08-20T00:00:00Z'
FROM ledger_events e WHERE e.tenant_id='t1' AND e.idempotency_key='k-1';

\echo ''
\echo '=== 8. the legitimate shape still works -- one event, one transaction, one'
\echo '===    database transaction.'
BEGIN;
  INSERT INTO ledger_events (tenant_id, id, kind, source, idempotency_key, idempotency_hash, payload, effective_at)
  VALUES ('t1','cccccccc-0000-0000-0000-000000000001','clearing','processor','k-notnull',
          sha256('{"amt":1}'), '{"amt":1}', '2026-08-20T00:00:00Z');
  INSERT INTO ledger_transactions (tenant_id, id, event_id, kind, status, effective_at)
  VALUES ('t1','bbbbbbbb-0000-0000-0000-000000000006','cccccccc-0000-0000-0000-000000000001',
          'clearing','posted','2026-08-20T00:00:00Z');
COMMIT;
SELECT count(*) AS transactions, count(event_id) AS with_event FROM ledger_transactions;

\echo ''
\echo '=== 9. ...and an event that causes NO transaction is still perfectly legal,'
\echo '===    which is the majority of the lifecycle (ADR-0005).'
INSERT INTO ledger_events (tenant_id, kind, source, idempotency_key, idempotency_hash, payload, effective_at)
VALUES ('t1','limit_change','internal','k-nolimit', sha256('{"limit":9}'), '{"limit":9}', now());
SELECT count(*) AS events, count(*) FILTER (WHERE NOT EXISTS (
    SELECT 1 FROM ledger_transactions t WHERE t.tenant_id = e.tenant_id AND t.event_id = e.id))
    AS events_causing_no_transaction
FROM ledger_events e;

\echo ''
\echo '=== 10. put it back, so the rest of this directory runs against the SHIPPED baseline.'
ALTER TABLE ledger_transactions ALTER COLUMN event_id DROP NOT NULL;
