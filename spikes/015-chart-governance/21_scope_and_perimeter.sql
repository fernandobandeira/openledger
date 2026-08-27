-- 21 -- PROPOSED DDL, part 2 of 3: counterparty_scope gets a constraint and
-- is_perimeter gets a consumer. Both were declarative -- documentation stored in
-- a column, read by no view and no function, a wrong value undetectable by
-- anything (10_repro_baseline.sql, R5).

BEGIN;

-- ------------------------------------------- counterparty_scope on the account
--
-- THE GROSS PRESENTATION NEEDS A COUNTERPARTY GRAIN, AND THE ACCOUNT IS IT.
-- uq_accounts__owned makes (tenant_id, owner_type, owner_id, purpose, currency)
-- unique, so for an owner-keyed type one account IS one counterparty, and the
-- report can evaluate the sign per account and route each position to its own
-- line. For a HOUSE account there is no grain at all: uq_accounts__house is
-- (tenant_id, purpose, currency), one row per scope, and both sides of the
-- 425.00-against-425.00 position land in it. That information is destroyed at
-- write time, and NO REPORT CAN RECOVER IT -- which is why the report fix and
-- this constraint ship together and neither works alone.
--
-- Carried onto the account as a copy held honest by a composite foreign key,
-- exactly as category and normal_balance already are, because a CHECK may not
-- read another table.
ALTER TABLE ledger_accounts ADD COLUMN counterparty_scope text NOT NULL DEFAULT 'none';
UPDATE ledger_accounts a SET counterparty_scope = t.counterparty_scope
  FROM account_types t WHERE t.code = a.purpose;
-- No DEFAULT in the baseline: the writer supplies it, like category. The DEFAULT
-- above exists only because this file ALTERs a table that already has rows.
ALTER TABLE ledger_accounts ALTER COLUMN counterparty_scope DROP DEFAULT;
ALTER TABLE ledger_accounts ADD CONSTRAINT fk_accounts__scope
    FOREIGN KEY (purpose, category, counterparty_scope)
    REFERENCES account_types (code, category, counterparty_scope);

-- A TYPE WHOSE SPLIT KEY IS THE COUNTERPARTY MAY NOT BE HELD IN A HOUSE ACCOUNT.
-- NOT VALID here, and ONLY here: 00_fixture.sql deliberately loads the broken
-- book first, and ADR-0007 convention 5 is explicit that a NOT VALID constraint
-- left unvalidated is a lie in the schema. In the baseline this ships inside
-- CREATE TABLE, validated, because there are no rows yet. 40_verify.sql runs
-- VALIDATE CONSTRAINT and shows it naming the offending row -- which is what a
-- deployment adopting this gets, and it is the honest cost: an account row that
-- already carries entries cannot be deleted (fk_entries__account), so remediation
-- is a posted reclassification onto per-counterparty accounts, not a migration.
ALTER TABLE ledger_accounts ADD CONSTRAINT ck_accounts__per_shard_is_owned
    CHECK (counterparty_scope <> 'per_shard' OR owner_type <> 'house') NOT VALID;

-- ------------------------------------------------------ is_perimeter's consumer
--
-- is_perimeter asserts "this account mirrors exactly one EXTERNAL balance and
-- must reconcile against it". The baseline's own comment gets the shape right and
-- draws the wrong conclusion from it: "There is no CHECK either, and a CHECK
-- could not help: the column is a claim about the world, not about the row."
-- Correct -- and the consequence is not that the column is unenforceable, it is
-- that the only thing that can falsify it is DATA ABOUT THE WORLD. So store it.
--
-- One table and one view. The alternative considered and refused was deleting the
-- column: it is the only thing in the schema that names WHICH accounts a drift
-- check is owed for, and the decision log carries "zero drift views are deployed"
-- as open.
CREATE TABLE perimeter_attestations (
    tenant_id  text    NOT NULL,
    account_id uuid    NOT NULL,
    currency   char(3) NOT NULL,
    -- The COUNTERPARTY's statement date, which is a business date, so the
    -- comparison below is on the effective axis (ADR-0006). A bank statement is
    -- dated by the bank's book, never by when we read it.
    as_of      date    NOT NULL,
    source     text    NOT NULL,   -- whose statement: the bank, the network, the trustee
    -- Debit-positive, OUR sign convention, so the comparison needs no
    -- normal_balance and a contra account is not flipped twice (ADR-0007 §15).
    external_balance_minor bigint NOT NULL,
    recorded_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT pk_perimeter_attest PRIMARY KEY (tenant_id, account_id, currency, as_of, source),
    CONSTRAINT fk_perimeter_attest__account FOREIGN KEY (tenant_id, account_id, currency)
        REFERENCES ledger_accounts (tenant_id, id, currency),
    CONSTRAINT ck_perimeter_attest__source CHECK (btrim(source) <> ''),
    CONSTRAINT ck_perimeter_attest__currency_iso CHECK (currency ~ '^[A-Z]{3}$')
);

-- Append-only for the same reason the journal is: an attestation is a record of
-- what a third party said on a date, and a record that can be edited afterwards
-- to match our books is not evidence of anything. Same two functions, same
-- justification, and the same hole (an owner, and DDL).
CREATE TRIGGER ck_perimeter_attest__append_only BEFORE UPDATE OR DELETE ON perimeter_attestations
    FOR EACH ROW EXECUTE FUNCTION refuse_mutation();
ALTER TABLE perimeter_attestations ENABLE ALWAYS TRIGGER ck_perimeter_attest__append_only;
CREATE TRIGGER ck_perimeter_attest__no_truncate BEFORE TRUNCATE ON perimeter_attestations
    FOR EACH STATEMENT EXECUTE FUNCTION refuse_truncate();
ALTER TABLE perimeter_attestations ENABLE ALWAYS TRIGGER ck_perimeter_attest__no_truncate;

GRANT SELECT, INSERT ON perimeter_attestations TO openledger_app;

COMMIT;
