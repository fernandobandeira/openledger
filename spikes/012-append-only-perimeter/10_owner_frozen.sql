-- 10 -- CHANNEL E, closed DECLARATIVELY -- no seventh trigger.
--
-- The device is already in this schema twice. `currency` and `effective_at` are
-- denormalised copies on ledger_entries, each held honest by being part of a
-- COMPOSITE FOREIGN KEY back into the row it was copied from. The half that is
-- usually overlooked is the second one: a foreign key's default NO ACTION also
-- refuses an UPDATE of the REFERENCED columns while a dependent row still points at
-- the old value. ADR-0007 records the effect for fk_accounts__type -- "refuses a
-- change to a type's category or normal_balance while accounts reference it". That
-- is a column freeze, spelled declaratively.
--
-- Two details had to be got right:
--
--  1. A composite foreign key is MATCH SIMPLE: one NULL anywhere in the referencing
--     key and the constraint is NOT CHECKED at all. owner_id is NULL for every house
--     account, so the copy has to be NULL-free. Hence a GENERATED ALWAYS column --
--     the same device account_types already uses for fs_statement and fs_side.
--  2. `owner_type::text` is REFUSED as a generation expression ("generation
--     expression is not immutable"): the enum-to-text cast is stable, not immutable.
--     So owner_type travels in the key as itself, and only owner_id needs the
--     coalesce.
--
-- Placement: ledger_account_balances, one row per (account, currency), created the
-- first time money touches the account. ledger_entries would carry the copy per row
-- and it is the biggest table in the schema.

ALTER TABLE ledger_accounts
  ADD COLUMN owner_id_key text GENERATED ALWAYS AS (coalesce(owner_id, '')) STORED;
ALTER TABLE ledger_accounts
  ADD CONSTRAINT uq_accounts__id_owner UNIQUE (tenant_id, id, owner_type, owner_id_key);

ALTER TABLE ledger_account_balances
  ADD COLUMN owner_type   account_owner_type,
  ADD COLUMN owner_id_key text;
UPDATE ledger_account_balances b
   SET owner_type = a.owner_type, owner_id_key = a.owner_id_key
  FROM ledger_accounts a WHERE a.tenant_id = b.tenant_id AND a.id = b.account_id;
ALTER TABLE ledger_account_balances
  ALTER COLUMN owner_type   SET NOT NULL,
  ALTER COLUMN owner_id_key SET NOT NULL,
  ADD CONSTRAINT fk_balances__account_owner
      FOREIGN KEY (tenant_id, account_id, owner_type, owner_id_key)
      REFERENCES ledger_accounts (tenant_id, id, owner_type, owner_id_key);

-- ...and the app role's UPDATE on the cache is narrowed to the columns the writer
-- actually writes, so it cannot launder its own copy first. A column-level GRANT is
-- declarative and needs no trigger.
REVOKE UPDATE ON ledger_account_balances FROM openledger_app;
GRANT  UPDATE (input, output, last_seq, updated_at) ON ledger_account_balances TO openledger_app;

\echo '=== a customer wallet with 500.00 in it ==='
INSERT INTO ledger_accounts (tenant_id,id,owner_type,owner_id,purpose,category,normal_balance,currency)
VALUES ('t1','55555555-5555-5555-5555-555555555555','company','acme','customer_wallet','liability','credit','USD');
INSERT INTO ledger_transactions (tenant_id,id,kind,status,effective_at)
VALUES ('t1','aaaaaaaa-0000-0000-0000-00000000000a','deposit','posted','2026-01-20T00:00:00Z');
INSERT INTO ledger_entries (tenant_id,id,transaction_id,account_id,direction,amount_minor,currency,account_seq,effective_at)
VALUES ('t1','e1000000-0000-0000-0000-00000000000a','aaaaaaaa-0000-0000-0000-00000000000a','11111111-1111-1111-1111-111111111111','debit',50000,'USD',3,'2026-01-20T00:00:00Z'),
       ('t1','e1000000-0000-0000-0000-00000000000b','aaaaaaaa-0000-0000-0000-00000000000a','55555555-5555-5555-5555-555555555555','credit',50000,'USD',1,'2026-01-20T00:00:00Z');
INSERT INTO ledger_account_balances (tenant_id,account_id,currency,input,output,last_seq,owner_type,owner_id_key)
VALUES ('t1','55555555-5555-5555-5555-555555555555','USD',50000,0,1,'company','acme');

\set ON_ERROR_STOP 0
\echo '=== 1. owned -> house (the nulling itself) -- REFUSED, as the database owner ==='
UPDATE ledger_accounts SET owner_type='house', owner_id=NULL
 WHERE id='55555555-5555-5555-5555-555555555555';

\echo '=== 2. owned -> a different owner -- REFUSED (uq_accounts__owned only caught collisions) ==='
UPDATE ledger_accounts SET owner_id='initech'
 WHERE id='55555555-5555-5555-5555-555555555555';

\echo '=== 3. company -> platform, same owner_id -- REFUSED ==='
UPDATE ledger_accounts SET owner_type='platform'
 WHERE id='55555555-5555-5555-5555-555555555555';

\echo '=== 4. house -> owned, the other direction -- REFUSED ==='
UPDATE ledger_accounts SET owner_type='company', owner_id='acme'
 WHERE id='11111111-1111-1111-1111-111111111111';

\echo '=== 5. the app role cannot launder the copy first ==='
SET ROLE openledger_app;
UPDATE ledger_account_balances SET owner_type='house', owner_id_key=''
 WHERE account_id='55555555-5555-5555-5555-555555555555';
\set ON_ERROR_STOP 1
\echo '-- ...and the writer''s own upsert is unaffected --'
UPDATE ledger_account_balances SET input = input + 100, last_seq = last_seq + 1, updated_at = now()
 WHERE account_id='55555555-5555-5555-5555-555555555555';
RESET ROLE;
SELECT account_id, input, last_seq, owner_type, owner_id_key FROM ledger_account_balances
 WHERE account_id='55555555-5555-5555-5555-555555555555';

\echo '=== 6. what is still allowed: metadata, and everything that is not identity ==='
UPDATE ledger_accounts SET metadata = '{"note":"KYC re-verified"}'::jsonb
 WHERE id='55555555-5555-5555-5555-555555555555';

\echo '=== WHAT IT DOES NOT COVER ==='
\echo '-- (a) an account with no balance row yet is not frozen. Nothing has been'
\echo '--     posted to it, so there is no posted history to restate. --'
INSERT INTO ledger_accounts (tenant_id,id,owner_type,owner_id,purpose,category,normal_balance,currency)
VALUES ('t1','77777777-7777-7777-7777-777777777777','company','newco','customer_wallet','liability','credit','USD');
UPDATE ledger_accounts SET owner_id='newco2' WHERE id='77777777-7777-7777-7777-777777777777';
SELECT owner_id FROM ledger_accounts WHERE id='77777777-7777-7777-7777-777777777777';
\echo '-- (b) it says nothing about whether the owner was RIGHT at open.'
\echo '-- (c) DELETE of the balance row would unfreeze it -- but the app role has no'
\echo '--     DELETE on that table (REVOKE, shipped), and the owner is the owner. --'
\echo '-- (d) the owner can still drop the constraint. Same boundary as everything else here. --'
