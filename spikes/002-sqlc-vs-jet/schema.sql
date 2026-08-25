-- Spike 002 schema — the surface both generators must handle.
--
-- NOT a migration. This is deliberately chosen to stress codegen: enums, text[],
-- int[], jsonb, bigint money, partial unique indexes, and a deferred constraint
-- trigger. If a generator handles this cleanly it handles the real thing.
--
-- Graduates to migrations/0001 once ADR-0002 lands and M1 starts for real.

BEGIN;

-- ---------------------------------------------------------------- enums
-- Every one of these is a codegen test: does the tool emit typed Go constants,
-- or a bare string?

CREATE TYPE ledger_category      AS ENUM ('asset','liability','equity','revenue','expense');
CREATE TYPE ledger_normal_balance AS ENUM ('debit','credit');
CREATE TYPE ledger_direction     AS ENUM ('debit','credit');
CREATE TYPE ledger_txn_status    AS ENUM ('pending','posted');
CREATE TYPE account_owner_type   AS ENUM ('company','platform','bank_account','house');
CREATE TYPE credit_line_status   AS ENUM ('active','suspended','closed');
CREATE TYPE hold_state           AS ENUM ('open','cleared','voided','expired','closed');
CREATE TYPE hold_decision        AS ENUM ('approved','declined');
-- values match date_trunc()'s field names ON PURPOSE. 'monthly' would throw at
-- runtime -- date_trunc takes 'day'|'month'. per_txn has no window.
CREATE TYPE control_period       AS ENUM ('per_txn','day','month');

-- ---------------------------------------------------------------- the ledger

CREATE TABLE ledger_accounts (
    id             uuid PRIMARY KEY DEFAULT uuidv7(),
    tenant_id      text,                          -- RLS scope. NULL for house/platform-wide.
    owner_type     account_owner_type   NOT NULL, -- the ECONOMIC owner
    owner_id       text,                          -- NULL only when owner_type = 'house'
    purpose        text                 NOT NULL, -- 'customer_receivable' | 'fbo_cash' | ...
    category       ledger_category      NOT NULL, -- rolls up the financial statements
    -- NOT derivable from category. contra accounts diverge:
    -- allowance_for_credit_losses is category 'asset' with a CREDIT normal balance.
    normal_balance ledger_normal_balance NOT NULL,
    currency       char(3)              NOT NULL,
    metadata       jsonb                NOT NULL DEFAULT '{}'::jsonb,
    created_at     timestamptz          NOT NULL DEFAULT now(),

    CONSTRAINT house_accounts_have_no_owner
        CHECK ((owner_type = 'house') = (owner_id IS NULL))
);

-- Two partial indexes over DISJOINT sets, not one index plus a special case.
-- A plain UNIQUE(owner_type, owner_id, purpose, currency) would NOT constrain
-- house rows at all: owner_id is NULL there and NULL != NULL in Postgres, so it
-- would happily allow a second interchange_revenue.
CREATE UNIQUE INDEX ledger_accounts_owned_key
    ON ledger_accounts (owner_type, owner_id, purpose, currency)
    WHERE owner_type <> 'house';
CREATE UNIQUE INDEX ledger_accounts_house_key
    ON ledger_accounts (purpose, currency)
    WHERE owner_type = 'house';
-- (PG15+ could express the first as UNIQUE NULLS NOT DISTINCT, but the partial
--  pair states the intent -- disjoint sets -- more directly.)

CREATE TABLE ledger_transactions (
    id              uuid PRIMARY KEY DEFAULT uuidv7(),
    tenant_id       text,
    -- scoped to the EVENT, not the business object. so pending -> posted is a
    -- NEW row, never an UPDATE. e.g. 'evt_clear_xyz:posting', 'evt_clear_xyz:revshare'
    idempotency_key text NOT NULL,
    -- sha256 of the canonical request body. same key + same hash -> replay the
    -- stored result. same key + DIFFERENT hash -> reject; it is a caller bug, and
    -- replaying the wrong stored result silently is worse than failing.
    idempotency_hash bytea NOT NULL,
    kind            text NOT NULL,
    status          ledger_txn_status NOT NULL,  -- NEVER MUTATES
    -- from the SOURCE's clock, never now(). a clearing's is the network business
    -- date -- Visa's cutoff, not our webhook's arrival.
    effective_at    timestamptz NOT NULL,
    recorded_at     timestamptz NOT NULL DEFAULT now(),
    resolves_id     uuid REFERENCES ledger_transactions(id),  -- pending -> posted
    reverses_id     uuid REFERENCES ledger_transactions(id),
    external_ref    jsonb NOT NULL DEFAULT '{}'::jsonb,
    metadata        jsonb NOT NULL DEFAULT '{}'::jsonb
);

-- Scoped to the tenant, NOT globally unique. Formance shipped a global key and
-- needed a de-duplicating migration to re-scope it; skip that step.
--
-- NULLS NOT DISTINCT is load-bearing (PG15+). tenant_id is NULL on house-scoped
-- transactions, and under default NULLS DISTINCT semantics this index would not
-- constrain those rows AT ALL -- the same NULL != NULL trap the vision doc calls
-- out for house accounts. Verified: without it, T7 silently passes.
CREATE UNIQUE INDEX ledger_transactions_idem_key
    ON ledger_transactions (tenant_id, idempotency_key) NULLS NOT DISTINCT;

-- We refuse to mutate, so we cannot use the UPDATE ... WHERE reverted_at IS NULL
-- guard against double-reversal. These give the same property declaratively:
-- a transaction can be reversed once, and resolved once.
CREATE UNIQUE INDEX ledger_transactions_one_reversal
    ON ledger_transactions (reverses_id) WHERE reverses_id IS NOT NULL;
CREATE UNIQUE INDEX ledger_transactions_one_resolution
    ON ledger_transactions (resolves_id) WHERE resolves_id IS NOT NULL;

CREATE TABLE ledger_entries (
    id             uuid PRIMARY KEY DEFAULT uuidv7(),
    transaction_id uuid NOT NULL REFERENCES ledger_transactions(id),
    account_id     uuid NOT NULL REFERENCES ledger_accounts(id),
    direction      ledger_direction NOT NULL,     -- direction carries the sign,
    amount_minor   bigint NOT NULL CHECK (amount_minor > 0),  -- never the amount
    currency       char(3) NOT NULL,
    account_seq    bigint NOT NULL,               -- monotonic per account
    -- running balance on the RECORDED axis only. See ADR-0003: this cannot answer
    -- an effective-date as-of query once anything is backdated.
    balance_after  bigint NOT NULL,
    recorded_at    timestamptz NOT NULL DEFAULT now(),
    -- denormalized from ledger_transactions so the effective-axis aggregate is a
    -- single-table index scan instead of a join. Immutable, like everything here.
    effective_at   timestamptz NOT NULL,

    UNIQUE (account_id, account_seq)
);

-- current balance AND as-of balance are the same index lookup.
CREATE INDEX ledger_entries_balance_idx
    ON ledger_entries (account_id, account_seq DESC);
CREATE INDEX ledger_entries_asof_idx
    ON ledger_entries (account_id, recorded_at DESC, account_seq DESC);
CREATE INDEX ledger_entries_txn_idx ON ledger_entries (transaction_id);
-- the EFFECTIVE axis. balance as of a business date is an aggregate over this,
-- not a running-balance lookup. See ADR-0003.
CREATE INDEX ledger_entries_effective_idx
    ON ledger_entries (account_id, effective_at);

-- Balance enforced by the DATABASE, per currency, deferred to COMMIT so a
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
     WHERE e.transaction_id = NEW.transaction_id
     GROUP BY e.currency
    HAVING COALESCE(SUM(e.amount_minor) FILTER (WHERE e.direction = 'debit'), 0)
        <> COALESCE(SUM(e.amount_minor) FILTER (WHERE e.direction = 'credit'), 0)
     LIMIT 1;

    IF FOUND THEN
        RAISE EXCEPTION
            'transaction % does not balance in %: debits=% credits=%',
            NEW.transaction_id, offending.currency, offending.dr, offending.cr;
    END IF;
    RETURN NULL;
END $$;

CREATE CONSTRAINT TRIGGER ledger_entries_balance_check
    AFTER INSERT ON ledger_entries
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION assert_transaction_balances();

-- ------------------------------------------------- working set (NOT the ledger)
-- Bounded, mutable, indexed for the hot path.

CREATE TABLE credit_lines (
    company_id            text PRIMARY KEY,
    tenant_id             text NOT NULL,
    -- a POLICY attribute. never a balance, never an account.
    limit_minor           bigint NOT NULL CHECK (limit_minor >= 0),
    receivable_account_id uuid NOT NULL REFERENCES ledger_accounts(id),
    status                credit_line_status NOT NULL DEFAULT 'active',
    updated_at            timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE spend_controls (
    card_id           text PRIMARY KEY,
    company_id        text NOT NULL REFERENCES credit_lines(company_id),
    cap_minor         bigint,               -- optional
    period            control_period,       -- RESETS. a credit line doesn't.
    timezone          text NOT NULL DEFAULT 'UTC',  -- the CUSTOMER's midnight
    -- the array columns. THE crux of ADR-0002.
    allowed_mcc       int[],                -- NULL = no allowlist
    blocked_mcc       int[]  NOT NULL DEFAULT '{}',
    allowed_merchants text[] NOT NULL DEFAULT '{}',
    active            boolean NOT NULL DEFAULT true,

    CONSTRAINT cap_needs_period CHECK ((cap_minor IS NULL) = (period IS NULL))
);

CREATE TABLE card_holds (
    id             uuid PRIMARY KEY DEFAULT uuidv7(),
    auth_id        text NOT NULL UNIQUE,   -- processor auth id. the idempotency story.
    company_id     text NOT NULL REFERENCES credit_lines(company_id),
    card_id        text NOT NULL,
    amount_minor   bigint NOT NULL CHECK (amount_minor > 0),  -- what was authorized
    cleared_minor  bigint NOT NULL DEFAULT 0,                 -- accumulated, partial capture
    state          hold_state    NOT NULL,
    decision       hold_decision NOT NULL,  -- declines land 'closed', never count
    decline_reason text,                    -- picks the network response code (51/57/62)
    expires_at     timestamptz,             -- Temporal timer target. ~7d, longer for T&E.
    created_at     timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT declines_are_closed
        CHECK (decision = 'approved' OR state = 'closed')
);

-- partial -- makes SUM(held) an index scan
CREATE INDEX card_holds_open_idx ON card_holds (company_id) WHERE state = 'open';

CREATE TABLE card_transactions (
    id           uuid PRIMARY KEY DEFAULT uuidv7(),
    card_id      text   NOT NULL,
    company_id   text   NOT NULL REFERENCES credit_lines(company_id),
    hold_id      uuid   REFERENCES card_holds(id),  -- NULL on a forced post
    merchant_id  text   NOT NULL,
    mcc          int    NOT NULL,
    amount_minor bigint NOT NULL,
    posted_at    timestamptz NOT NULL
);

CREATE INDEX card_transactions_budget_idx ON card_transactions (card_id, posted_at DESC);

COMMIT;
