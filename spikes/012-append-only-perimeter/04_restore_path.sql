-- 04 -- CHANNEL B. The ordinary data-only restore path, and what it leaves behind.
--
-- `pg_dump -a` warns that the circular foreign keys on ledger_transactions
-- (fk_txn__resolves, fk_txn__reverses) need --disable-triggers to restore. That
-- flag emits, per table, a DISABLE/ENABLE pair. Both halves matter.

\echo '=== before: the six declared triggers are ENABLE ALWAYS ==='
SELECT tgname, tgenabled FROM pg_trigger WHERE NOT tgisinternal ORDER BY 1;

\echo '=== exactly what pg_dump -a --disable-triggers emits for one table ==='
ALTER TABLE public.ledger_entries DISABLE TRIGGER ALL;
SELECT tgname, tgenabled FROM pg_trigger
 WHERE tgrelid='ledger_entries'::regclass AND NOT tgisinternal ORDER BY 1;

\echo '=== ...and inside that window, posted history is fully mutable ==='
SELECT count(*) AS before FROM ledger_entries;
DELETE FROM ledger_entries WHERE tenant_id='t1';
UPDATE ledger_entries SET amount_minor = 1 WHERE tenant_id='t2';
SELECT count(*) AS after_delete FROM ledger_entries;

\echo '=== now the ENABLE half of the pair ==='
ALTER TABLE public.ledger_entries ENABLE TRIGGER ALL;
\echo '=== THE TRIGGERS CAME BACK AS ENABLE ORIGIN, NOT ENABLE ALWAYS ==='
SELECT tgname, tgenabled FROM pg_trigger
 WHERE tgrelid='ledger_entries'::regclass AND NOT tgisinternal ORDER BY 1;
