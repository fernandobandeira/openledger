-- 0001 — the ledger core.
--
-- Written by hand, not promoted from the spikes: those hold three competing posting
-- engines (two of them designs we rejected), two competing hold models, and
-- benchmark scaffolding with hardcoded amounts. They were how we learned; they are
-- not a source tree.
--
-- Scope is the CORE only: accounts, transactions, entries, balances, events. The
-- chart of accounts, holds, striping and the completeness layer are later
-- milestones — shipping them now guarantees rewriting them.
--
-- NAMING: ix_<table>__<cols> / uq_<table>__<cols> / ck_<table>__<rule> (ADR-0006).

BEGIN;

CREATE TYPE ledger_category       AS ENUM ('asset','liability','equity','revenue','expense');
CREATE TYPE ledger_normal_balance AS ENUM ('debit','credit');
CREATE TYPE ledger_direction      AS ENUM ('debit','credit');
CREATE TYPE ledger_txn_status     AS ENUM ('pending','posted');
CREATE TYPE account_owner_type    AS ENUM ('company','platform','bank_account','house');

-- ---------------------------------------------------------------- accounts

CREATE TABLE ledger_accounts (
    tenant_id      text NOT NULL,
    id             uuid NOT NULL DEFAULT uuidv7(),
    owner_type     account_owner_type    NOT NULL,
    owner_id       text,                      -- NULL only when owner_type = 'house'
    purpose        text                  NOT NULL,
    category       ledger_category       NOT NULL,
    -- NOT derivable from category: allowance_for_credit_losses is an asset with a
    -- CREDIT normal balance.
    normal_balance ledger_normal_balance NOT NULL,
    currency       char(3)               NOT NULL,
    metadata       jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at     timestamptz NOT NULL DEFAULT now(),

    -- composite key: tenant leads every key in the schema (ADR-0007). Free now,
    -- expensive later -- it is the prerequisite for both partitioning and sharding.
    CONSTRAINT pk_accounts PRIMARY KEY (tenant_id, id),
    CONSTRAINT ck_accounts__house_has_no_owner
        CHECK ((owner_type = 'house') = (owner_id IS NULL))
);

-- Disjoint sets. A plain UNIQUE would not constrain house rows at all, since
-- owner_id is NULL there and NULL <> NULL.
-- Lets entries reference (account, currency) as a unit, so an entry cannot carry a
-- currency its account does not hold. Verified: without this, USD entries sit
-- happily in EUR accounts and the declared currency is decorative.
CREATE UNIQUE INDEX uq_accounts__id_currency
    ON ledger_accounts (tenant_id, id, currency);

CREATE UNIQUE INDEX uq_accounts__owned
    ON ledger_accounts (tenant_id, owner_type, owner_id, purpose, currency)
    WHERE owner_type <> 'house';
-- House accounts are PER TENANT, not per deployment (ADR-0007): a deployment-global
-- house account makes every tenant contend on one row and blocks tenant-locality.
CREATE UNIQUE INDEX uq_accounts__house
    ON ledger_accounts (tenant_id, purpose, currency)
    WHERE owner_type = 'house';

-- ------------------------------------------------------------ events (ADR-0004)
-- The idempotency spine. Most of the lifecycle writes NO ledger transaction --
-- authorizations, declines, hold expiry, reversals, limit changes -- so idempotency
-- cannot live on ledger_transactions.

CREATE TABLE ledger_events (
    tenant_id        text NOT NULL,
    id               uuid NOT NULL DEFAULT uuidv7(),
    kind             text NOT NULL,
    source           text NOT NULL,          -- processor | treasury | customer | internal
    idempotency_key  text NOT NULL,
    -- sha256 of the canonical request body. Same key + same hash -> replay the
    -- stored result. Same key + DIFFERENT hash -> reject: silently replaying the
    -- wrong result is worse than failing.
    idempotency_hash bytea NOT NULL,
    payload          jsonb NOT NULL,
    effective_at     timestamptz NOT NULL,
    recorded_at      timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT pk_events PRIMARY KEY (tenant_id, id)
);

-- NULLS NOT DISTINCT is load-bearing: without it this would not constrain
-- house-scoped rows at all.
CREATE UNIQUE INDEX uq_events__idempotency
    ON ledger_events (tenant_id, idempotency_key) NULLS NOT DISTINCT;

-- ------------------------------------------------------------ transactions

CREATE TABLE ledger_transactions (
    tenant_id       text NOT NULL,
    id              uuid NOT NULL DEFAULT uuidv7(),
    event_id        uuid,                    -- the event that caused this
    kind            text NOT NULL,
    status          ledger_txn_status NOT NULL,   -- NEVER MUTATES
    -- from the SOURCE's clock, never now(): a clearing's is the network business
    -- date, not our webhook's arrival.
    effective_at    timestamptz NOT NULL,
    recorded_at     timestamptz NOT NULL DEFAULT now(),
    resolves_id     uuid,                    -- pending -> posted is a NEW row
    reverses_id     uuid,
    external_ref    jsonb NOT NULL DEFAULT '{}'::jsonb,
    metadata        jsonb NOT NULL DEFAULT '{}'::jsonb,

    CONSTRAINT pk_txn PRIMARY KEY (tenant_id, id),
    CONSTRAINT fk_txn__event    FOREIGN KEY (tenant_id, event_id)
        REFERENCES ledger_events (tenant_id, id),
    CONSTRAINT fk_txn__resolves FOREIGN KEY (tenant_id, resolves_id)
        REFERENCES ledger_transactions (tenant_id, id),
    CONSTRAINT fk_txn__reverses FOREIGN KEY (tenant_id, reverses_id)
        REFERENCES ledger_transactions (tenant_id, id)
);

-- A transaction may be reversed once, and resolved once. We refuse to mutate, so
-- we cannot use the UPDATE ... WHERE reverted_at IS NULL guard.
CREATE UNIQUE INDEX uq_txn__one_reversal
    ON ledger_transactions (tenant_id, reverses_id) WHERE reverses_id IS NOT NULL;
CREATE UNIQUE INDEX uq_txn__one_resolution
    ON ledger_transactions (tenant_id, resolves_id) WHERE resolves_id IS NOT NULL;

-- ------------------------------------------------------------ entries

CREATE TABLE ledger_entries (
    -- tenant_id is what makes "no transaction spans two tenants" EXPRESSIBLE.
    -- Without it, M1's own acceptance criterion could not be stated.
    tenant_id      text NOT NULL,
    id             uuid NOT NULL DEFAULT uuidv7(),
    transaction_id uuid NOT NULL,
    account_id     uuid NOT NULL,
    direction      ledger_direction NOT NULL,   -- direction carries the sign,
    amount_minor   bigint NOT NULL,             -- never the amount
    currency       char(3) NOT NULL,
    account_seq    bigint NOT NULL,             -- monotonic per account
    -- Running balance on the RECORDED axis only. It cannot answer a business-date
    -- question once anything is backdated (ADR-0003).
    --
    -- SIGN CONVENTION: debit-positive. balance_after is SUM(debits) - SUM(credits)
    -- for this account, so a credit-normal account carries a negative running
    -- balance. This was undefined until the drift view forced the question -- the
    -- golden trace stored it natural-positive, which disagrees. Presentation flips
    -- the sign using the account's normal_balance; storage does not.
    balance_after  bigint NOT NULL,
    recorded_at    timestamptz NOT NULL DEFAULT now(),
    -- denormalised from the transaction so the effective-axis aggregate is a
    -- single-table index scan.
    effective_at   timestamptz NOT NULL,

    CONSTRAINT pk_entries PRIMARY KEY (tenant_id, id),
    CONSTRAINT ck_entries__amount_positive CHECK (amount_minor > 0),
    -- THE cross-tenant guard. A composite FK makes a transaction spanning two
    -- tenants structurally impossible rather than merely discouraged.
    CONSTRAINT fk_entries__txn FOREIGN KEY (tenant_id, transaction_id)
        REFERENCES ledger_transactions (tenant_id, id),
    -- currency is part of the key: an entry inherits its account's currency and
    -- cannot contradict it.
    CONSTRAINT fk_entries__account FOREIGN KEY (tenant_id, account_id, currency)
        REFERENCES ledger_accounts (tenant_id, id, currency),
    CONSTRAINT uq_entries__account_seq UNIQUE (tenant_id, account_id, account_seq)
);

CREATE INDEX ix_entries__balance_lookup
    ON ledger_entries (tenant_id, account_id, account_seq DESC) INCLUDE (balance_after);
CREATE INDEX ix_entries__asof_recorded
    ON ledger_entries (tenant_id, account_id, recorded_at DESC, account_seq DESC);
CREATE INDEX ix_entries__effective
    ON ledger_entries (tenant_id, account_id, effective_at);
CREATE INDEX ix_entries__txn ON ledger_entries (tenant_id, transaction_id);

-- ------------------------------------------------------------ balances
-- The write-side serialization point AND the O(1) current-balance read. One atomic
-- upsert returns the new balance and the next sequence number together, so the row
-- lock IS the serialization -- no SELECT max(), no advisory lock, no retry loop.
--
-- input/output kept separate rather than one signed balance: the upsert stays
-- commutative, gross turnover is free, and no row needs to know the sign convention.

CREATE TABLE ledger_account_balances (
    tenant_id  text    NOT NULL,
    account_id uuid    NOT NULL,
    currency   char(3) NOT NULL,
    input      bigint  NOT NULL DEFAULT 0,
    output     bigint  NOT NULL DEFAULT 0,
    last_seq   bigint  NOT NULL DEFAULT 0,
    updated_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT pk_balances PRIMARY KEY (tenant_id, account_id, currency),
    CONSTRAINT fk_balances__account FOREIGN KEY (tenant_id, account_id)
        REFERENCES ledger_accounts (tenant_id, id),
    CONSTRAINT ck_balances__non_negative CHECK (input >= 0 AND output >= 0)
);

-- ------------------------------------------------------------ the invariant
-- Balanced per currency, enforced by the DATABASE, deferred to COMMIT so a
-- transaction can be built up entry by entry.

CREATE FUNCTION assert_transaction_balances() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE offending record;
BEGIN
    SELECT e.currency,
           SUM(e.amount_minor) FILTER (WHERE e.direction = 'debit')  AS dr,
           SUM(e.amount_minor) FILTER (WHERE e.direction = 'credit') AS cr
      INTO offending
      FROM ledger_entries e
     WHERE e.tenant_id = NEW.tenant_id AND e.transaction_id = NEW.transaction_id
     GROUP BY e.currency
    HAVING COALESCE(SUM(e.amount_minor) FILTER (WHERE e.direction = 'debit'), 0)
        <> COALESCE(SUM(e.amount_minor) FILTER (WHERE e.direction = 'credit'), 0)
     LIMIT 1;

    IF FOUND THEN
        -- COALESCE because a one-legged transaction reports the missing side as
        -- NULL, which reads as though the value were unknown rather than zero.
        RAISE EXCEPTION 'transaction % does not balance in %: debits=% credits=%',
            NEW.transaction_id, offending.currency,
            COALESCE(offending.dr, 0), COALESCE(offending.cr, 0);
    END IF;
    RETURN NULL;
END $$;

CREATE CONSTRAINT TRIGGER ck_entries__balances
    AFTER INSERT ON ledger_entries
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION assert_transaction_balances();

-- ------------------------------------------------------------ append-only
-- ADR-0001 says entries are "never updated or deleted, enforced by revoking the
-- grants, not by convention." Until now that was a description, not an
-- enforcement: a plain UPDATE mutated four committed entries in testing.

-- Roles are CLUSTER-global, not per-database, so a bare CREATE ROLE makes this
-- migration fail on the second database it is applied to. Found by applying it
-- twice.
DO $$ BEGIN
    CREATE ROLE openledger_app NOLOGIN;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
GRANT USAGE ON SCHEMA public TO openledger_app;
GRANT SELECT, INSERT ON ledger_accounts, ledger_events, ledger_transactions,
                        ledger_entries TO openledger_app;
GRANT SELECT, INSERT, UPDATE ON ledger_account_balances TO openledger_app;
-- The ledger is append-only. The balances table is a derived cache and may be
-- updated; the journal may not.
REVOKE UPDATE, DELETE ON ledger_entries      FROM openledger_app;
REVOKE UPDATE, DELETE ON ledger_transactions FROM openledger_app;
REVOKE        DELETE ON ledger_events        FROM openledger_app;
REVOKE        DELETE ON ledger_account_balances FROM openledger_app;

-- ------------------------------------------------------------ the corruption alarm
-- ADR-0003 leans on balance_after and a recomputation always agreeing, calling it a
-- free corruption alarm. It was described and never implemented. Here it is.
-- Compares against the debit-positive convention declared on balance_after above.
CREATE VIEW ledger_balance_drift AS
SELECT e.tenant_id, e.account_id, e.currency,
       last_value(e.balance_after) OVER w AS stored,
       SUM(CASE WHEN e.direction = 'debit' THEN e.amount_minor ELSE -e.amount_minor END)
           OVER w AS recomputed
FROM ledger_entries e
WINDOW w AS (PARTITION BY e.tenant_id, e.account_id, e.currency
             ORDER BY e.account_seq
             ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING);

COMMIT;
