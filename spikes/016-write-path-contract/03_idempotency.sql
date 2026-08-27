-- 03_idempotency.sql -- the replay contract: first write, benign replay, poisoned
-- replay. Three cases, on the shipped baseline, no schema change.
--
-- Run after 00_seed.sql. Every block prints what it did.

\set ON_ERROR_STOP off
\pset pager off

-- ======================================================================
-- 0. WHAT IS BROKEN TODAY, restated as a run rather than as a comment.
-- ======================================================================
\echo '=== 0a. the unique index alone: the second attempt FAILS rather than replaying'
INSERT INTO ledger_events (tenant_id, kind, source, idempotency_key, idempotency_hash, payload, effective_at)
VALUES ('t1','clearing','processor','k-naive', sha256('{"amt":500}'), '{"amt":500}', now());
INSERT INTO ledger_events (tenant_id, kind, source, idempotency_key, idempotency_hash, payload, effective_at)
VALUES ('t1','clearing','processor','k-naive', sha256('{"amt":500}'), '{"amt":500}', now());

\echo '=== 0b. ON CONFLICT DO NOTHING -- what a retry loop actually reaches for --'
\echo '===     swallows a DIFFERENT body under the SAME key. No error, no row, no rejection.'
INSERT INTO ledger_events (tenant_id, kind, source, idempotency_key, idempotency_hash, payload, effective_at)
VALUES ('t1','clearing','processor','k-naive', sha256('{"amt":999999}'), '{"amt":999999}', now())
ON CONFLICT (tenant_id, idempotency_key) DO NOTHING;
\echo '--- the caller got INSERT 0 0 and no way to tell that from a benign replay.'
SELECT idempotency_key, convert_from(payload::text::bytea,'UTF8') AS stored_payload
FROM ledger_events WHERE tenant_id='t1' AND idempotency_key='k-naive';

-- ======================================================================
-- 1. THE CONTRACT. Two statements, one transaction, READ COMMITTED.
--
--    Statement A claims the key. If it returns a row, this caller is the first
--    writer and goes on to do the work in the same transaction.
--    Statement B runs ONLY when A returned nothing, i.e. the key is taken. It is a
--    SEPARATE statement so that under READ COMMITTED it takes a NEW snapshot and
--    can therefore see a row a concurrent writer committed while A was blocked on
--    it. (05 proves a single-statement CTE form cannot; 04 proves REPEATABLE READ
--    cannot either.)
--
--    B returns the stored outcome AND `body_matches`. The stored outcome is two
--    things: the event id -- the durable receipt for the majority of operations,
--    which write no transaction -- and the id of the transaction that event caused,
--    if it caused one. `uq_txn__one_per_event` is what makes the LEFT JOIN
--    single-valued, so this cannot fan out.
-- ======================================================================

\echo ''
\echo '=== 1. CASE ONE -- first write. Statement A returns a row; there is no replay.'
BEGIN;
  -- statement A
  INSERT INTO ledger_events AS e
         (tenant_id, kind, source, idempotency_key, idempotency_hash, payload, effective_at)
  VALUES ('t1','clearing','processor','k-1', sha256('{"amt":500,"kind":"clearing"}'),
          '{"amt":500,"kind":"clearing"}', '2026-08-20T00:00:00Z')
  ON CONFLICT (tenant_id, idempotency_key) DO NOTHING
  RETURNING e.id AS event_id, false AS replayed;
  -- ...the caller got a row, so it is the first writer: do the work.
  INSERT INTO ledger_transactions (tenant_id, id, event_id, kind, status, effective_at)
  SELECT 't1','aaaaaaaa-0000-0000-0000-000000000001', e.id, 'clearing','posted','2026-08-20T00:00:00Z'
  FROM ledger_events e WHERE e.tenant_id='t1' AND e.idempotency_key='k-1';
COMMIT;

\echo ''
\echo '=== 2. CASE TWO -- benign replay: same key, same body.'
BEGIN;
  -- statement A: returns NOTHING. The key is taken.
  INSERT INTO ledger_events AS e
         (tenant_id, kind, source, idempotency_key, idempotency_hash, payload, effective_at)
  VALUES ('t1','clearing','processor','k-1', sha256('{"amt":500,"kind":"clearing"}'),
          '{"amt":500,"kind":"clearing"}', '2026-08-20T00:00:00Z')
  ON CONFLICT (tenant_id, idempotency_key) DO NOTHING
  RETURNING e.id AS event_id, false AS replayed;
  -- statement B: the stored outcome, and whether the body agrees.
  SELECT e.id AS event_id, t.id AS transaction_id, true AS replayed,
         e.idempotency_hash = sha256('{"amt":500,"kind":"clearing"}') AS body_matches
  FROM ledger_events e
  LEFT JOIN ledger_transactions t ON t.tenant_id = e.tenant_id AND t.event_id = e.id
  WHERE e.tenant_id='t1' AND e.idempotency_key='k-1';
COMMIT;

\echo ''
\echo '=== 3. CASE THREE -- poisoned replay: same key, DIFFERENT body. body_matches = f.'
BEGIN;
  INSERT INTO ledger_events AS e
         (tenant_id, kind, source, idempotency_key, idempotency_hash, payload, effective_at)
  VALUES ('t1','clearing','processor','k-1', sha256('{"amt":999999,"kind":"clearing"}'),
          '{"amt":999999,"kind":"clearing"}', '2026-08-20T00:00:00Z')
  ON CONFLICT (tenant_id, idempotency_key) DO NOTHING
  RETURNING e.id AS event_id, false AS replayed;
  SELECT e.id AS event_id, t.id AS transaction_id, true AS replayed,
         e.idempotency_hash = sha256('{"amt":999999,"kind":"clearing"}') AS body_matches
  FROM ledger_events e
  LEFT JOIN ledger_transactions t ON t.tenant_id = e.tenant_id AND t.event_id = e.id
  WHERE e.tenant_id='t1' AND e.idempotency_key='k-1';
ROLLBACK;
\echo '--- body_matches = f is the ONLY signal. The writer turns it into a distinct'
\echo '--- error; nothing in the database can, because the comparison is a read.'

-- ======================================================================
-- 2. THE HALF THAT *IS* DECLARATIVE, and worth having: put the hash in the
--    WHERE clause and a caller that forgets to compare gets NO ROW rather than
--    the wrong stored result. Zero rows is unambiguous here, because statement A
--    already established that the key exists.
-- ======================================================================
\echo ''
\echo '=== 4. the fail-closed form: hash in the predicate. Same body -> 1 row; different body -> 0 rows.'
SELECT 'same body' AS probe, count(*) FROM ledger_events
WHERE tenant_id='t1' AND idempotency_key='k-1'
  AND idempotency_hash = sha256('{"amt":500,"kind":"clearing"}');
SELECT 'different body' AS probe, count(*) FROM ledger_events
WHERE tenant_id='t1' AND idempotency_key='k-1'
  AND idempotency_hash = sha256('{"amt":999999,"kind":"clearing"}');

-- ======================================================================
-- 3. The event id is stable across the replay, which is what makes it a receipt.
-- ======================================================================
\echo ''
\echo '=== 5. one event row, one transaction, after three attempts at key k-1'
SELECT (SELECT count(*) FROM ledger_events       WHERE tenant_id='t1' AND idempotency_key='k-1') AS events,
       (SELECT count(*) FROM ledger_transactions WHERE tenant_id='t1' AND kind='clearing')       AS transactions;
