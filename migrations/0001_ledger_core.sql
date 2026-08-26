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
        CHECK ((owner_type = 'house') = (owner_id IS NULL)),
    CONSTRAINT ck_accounts__currency_iso CHECK (currency ~ '^[A-Z]{3}$')
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

-- NULLS NOT DISTINCT is INERT here and kept only for uniformity: both columns are
-- NOT NULL, so there are no NULLs to make distinct. It was load-bearing when
-- house-scoped rows carried tenant_id NULL; they no longer can. Where the clause
-- still earns its keep is uq_accounts__owned, whose owner_id IS nullable.
-- (Found by mutation testing: removing it changed nothing.)
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
    -- The database transaction that created this row. Entries may only be added
    -- by that same transaction (ck_entries__sealed below).
    --
    -- Without this, append-only protected the ENTRY and not the JOURNAL: the app
    -- role, holding nothing but its ordinary INSERT grant, could add a balanced,
    -- correctly-dated, correctly-sequenced pair of legs to a transaction committed
    -- and reported months earlier. February revenue went from 500.00 to 1,166.00
    -- with the drift view, the accounting equation and the balance sheet all
    -- green, because every constraint in this file was satisfied.
    -- ASSIGNED by ck_txn__xact_id, never accepted. The DEFAULT is kept so the
    -- column is never null if the trigger is ever disabled for a bulk load, but it
    -- is not the mechanism -- see assign_xact_id() below for what a forged value
    -- bought before the trigger existed.
    xact_id         bigint NOT NULL DEFAULT pg_current_xact_id()::text::bigint,

    CONSTRAINT pk_txn PRIMARY KEY (tenant_id, id),
    -- the target of fk_entries__txn_effective, below
    CONSTRAINT uq_txn__id_effective UNIQUE (tenant_id, id, effective_at),
    CONSTRAINT fk_txn__event    FOREIGN KEY (tenant_id, event_id)
        REFERENCES ledger_events (tenant_id, id),
    CONSTRAINT fk_txn__resolves FOREIGN KEY (tenant_id, resolves_id)
        REFERENCES ledger_transactions (tenant_id, id),
    CONSTRAINT fk_txn__reverses FOREIGN KEY (tenant_id, reverses_id)
        REFERENCES ledger_transactions (tenant_id, id),
    -- A transaction cannot reverse or resolve ITSELF, and cannot be both a
    -- resolution and a reversal. All three committed before these existed.
    -- The two IS DISTINCT FROM conjuncts are the whole rule. An earlier version
    -- also compared against a nil-uuid sentinel, which was redundant AND rejected a
    -- transaction whose id happened to be the nil uuid even when it referenced
    -- nothing at all.
    CONSTRAINT ck_txn__no_self_reference
        CHECK (id IS DISTINCT FROM reverses_id AND id IS DISTINCT FROM resolves_id),
    CONSTRAINT ck_txn__not_both
        CHECK (NOT (reverses_id IS NOT NULL AND resolves_id IS NOT NULL))
);

-- A transaction may be reversed once, and resolved once. We refuse to mutate, so
-- we cannot use the UPDATE ... WHERE reverted_at IS NULL guard.
-- One event, at most one transaction. Without this the "idempotency spine" does
-- not by itself prevent double-posting: two transactions were produced from one
-- event row. (An event may still cause NONE -- most of the lifecycle does.)
CREATE UNIQUE INDEX uq_txn__one_per_event
    ON ledger_transactions (tenant_id, event_id) WHERE event_id IS NOT NULL;

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
    -- account_seq orders history: it is the key ledger_balance_drift walks and the
    -- key every as-of reconstruction depends on. Nothing enforced even POSITIVITY
    -- -- a seq of -9999 inserted later silently reordered an account's past.
    -- Gaplessness itself is still only asserted by the suite, not enforced here.
    CONSTRAINT ck_entries__seq_positive CHECK (account_seq > 0),
    -- ISO 4217 is uppercase. Without this 'usd' and 'USD' are different
    -- currencies: each "balances" on its own, a customer's USD balance reads
    -- 100.00 when it is 300.00, and uq_accounts__owned is defeated because the
    -- same owner can then hold two operating_cash accounts.
    CONSTRAINT ck_entries__currency_iso CHECK (currency ~ '^[A-Z]{3}$'),
    -- THE cross-tenant guard. A composite FK makes a transaction spanning two
    -- tenants structurally impossible rather than merely discouraged.
    CONSTRAINT fk_entries__txn FOREIGN KEY (tenant_id, transaction_id)
        REFERENCES ledger_transactions (tenant_id, id),
    -- currency is part of the key: an entry inherits its account's currency and
    -- cannot contradict it.
    CONSTRAINT fk_entries__account FOREIGN KEY (tenant_id, account_id, currency)
        REFERENCES ledger_accounts (tenant_id, id, currency),
    -- effective_at is denormalised from the transaction, and nothing held it
    -- honest: a transaction dated 2026-06-15 accepted 1,000 entries dated
    -- 1999-01-01. This column is the entire basis of ADR-0003 and every
    -- business-date report. Same trick as the currency FK above -- make the
    -- denormalised copy part of a composite key so it CANNOT disagree.
    CONSTRAINT fk_entries__txn_effective FOREIGN KEY (tenant_id, transaction_id, effective_at)
        REFERENCES ledger_transactions (tenant_id, id, effective_at),
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
    -- currency is IN the foreign key, as it is for entries. Without it the cache
    -- -- the copy the hot path reads, and the only one the app role may write --
    -- accepted a second row for the same account under 'usd' or 'JPY', splitting
    -- one account's balance across two rows.
    CONSTRAINT fk_balances__account FOREIGN KEY (tenant_id, account_id, currency)
        REFERENCES ledger_accounts (tenant_id, id, currency),
    CONSTRAINT ck_balances__non_negative CHECK (input >= 0 AND output >= 0),
    CONSTRAINT ck_balances__currency_iso CHECK (currency ~ '^[A-Z]{3}$')
);

-- ------------------------------------------------------------ the invariant
-- Balanced per currency, enforced by the DATABASE, deferred to COMMIT so a
-- transaction can be built up entry by entry.

-- recorded_at is the INSERTION axis. It is now assigned, never accepted.
--
-- effective_at was made honest by putting it inside a composite key. recorded_at
-- -- the other half of the bitemporal claim, the axis every "reproducible as of
-- any date, forever" statement rests on -- had a DEFAULT and nothing else. It was
-- client-supplied, unconstrained, and not even consistent between the two legs of
-- one transaction. Three consequences, all reproduced:
--
--   * an already-issued recorded-axis report could be rewritten months later by
--     inserting a new transaction that CLAIMS to predate it -- no seal broken, no
--     UPDATE, no DELETE, and zero drift
--   * one transaction's legs could carry different recorded_at, so a recorded-axis
--     report of a perfectly balanced journal came back UNBALANCED
--   * and made silent: two honest sales, each with one leg slipped forward, gave a
--     GREEN recorded-axis report that was 50% wrong
--
-- now() is transaction-start time, so all legs of a transaction now share one
-- value by construction, and no caller can choose it.
--
-- WHAT THIS DOES NOT FIX is monotonicity with COMMIT order, and the previous
-- version of this comment got that badly wrong. It said "balance_after cannot
-- answer a recorded-axis as-of question either; THE AGGREGATE CAN." The aggregate
-- cannot. Demonstrated, needing nothing but the app role's INSERT grants:
--
--   Session A: BEGIN; insert a posted transaction and its legs   (txn start T0)
--   Session B: T1 := now();  accounting_equation('acme', T1, 'recorded')
--                -> revenue 110,000.00, balanced
--   Session A: COMMIT                                            (commit at T2 > T1)
--   Session B: the SAME query, the SAME as-of, the SAME axis
--                -> revenue 160,000.00, balanced.  +45%, zero drift.
--
-- Because recorded_at is T0 and T0 < T1, rows that were invisible when the report
-- was issued satisfy `recorded_at <= T1` afterwards. Assigning now() shrank the
-- window from "any instant the caller invents" to "the duration of the writer's
-- transaction" -- which the writer still chooses. That is a smaller hole, not a
-- closed one, and it is consequence #1 of the list above, still live.
--
-- A timestamp cannot order commits. ADR-0005 (proposed) is the fix: a
-- commit-ordered cursor, for which `xact_id` is already stored on every
-- transaction. Until it lands, NEITHER balance_after NOR the aggregate answers a
-- recorded-axis as-of question reproducibly, and no report in this schema should
-- be described as though one does.
CREATE FUNCTION assign_recorded_at() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    NEW.recorded_at := now();
    RETURN NEW;
END $$;

-- ---- ...AND SO IS xact_id, FOR THE SAME REASON --------------------------------
-- This file's whole thesis is that a column with a DEFAULT is not a constraint. It
-- applied that to recorded_at and to account_seq, and left it unapplied to the one
-- column it calls "the seal's whole basis". A DEFAULT only fires when the client
-- omits the column, and `GRANT INSERT ON ledger_transactions` covers every column.
--
-- A reviewer reported this as a live escape: plant a transaction carrying a FUTURE
-- xact_id, let the global counter reach it, then append legs while the live xid
-- equals the forged one, so the seal reads equal and opens. THAT ATTACK DOES NOT
-- WORK, and the retraction is worth as much as the fix.
--
-- Checked directly against the schema as it stood before this trigger existed: the
-- forged value seals the transaction against ITS OWN legs immediately. The plant
-- fails at step one -- `is already committed; its entries are sealed` -- and a
-- transaction with no legs cannot commit, because ck_txn__has_entries fires at
-- COMMIT. A second reviewer, asked to verify the same claim, also could not
-- reproduce it. It was written into this comment on one agent's say-so and is
-- struck.
--
-- The trigger stays, because the principle is this file's own and does not depend
-- on that exploit: a column whose integrity rests on a DEFAULT is not defended.
-- A DEFAULT fires only when the client omits the column, `GRANT INSERT` covers
-- every column, and recorded_at and account_seq were both moved from accepted to
-- assigned for exactly this reason. Leaving the seal's basis as the one exception
-- was an inconsistency waiting for someone to find a use for. What is now true is
-- narrow and checkable: no client can choose the value at INSERT, and the
-- immutability trigger already refused to let one change it afterwards.
CREATE FUNCTION assign_xact_id() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    NEW.xact_id := pg_current_xact_id()::text::bigint;
    RETURN NEW;
END $$;

CREATE TRIGGER ck_txn__xact_id BEFORE INSERT ON ledger_transactions
    FOR EACH ROW EXECUTE FUNCTION assign_xact_id();
ALTER TABLE ledger_transactions ENABLE ALWAYS TRIGGER ck_txn__xact_id;

CREATE TRIGGER ck_entries__recorded_at BEFORE INSERT ON ledger_entries
    FOR EACH ROW EXECUTE FUNCTION assign_recorded_at();
ALTER TABLE ledger_entries ENABLE ALWAYS TRIGGER ck_entries__recorded_at;
CREATE TRIGGER ck_txn__recorded_at BEFORE INSERT ON ledger_transactions
    FOR EACH ROW EXECUTE FUNCTION assign_recorded_at();
ALTER TABLE ledger_transactions ENABLE ALWAYS TRIGGER ck_txn__recorded_at;
CREATE TRIGGER ck_events__recorded_at BEFORE INSERT ON ledger_events
    FOR EACH ROW EXECUTE FUNCTION assign_recorded_at();
ALTER TABLE ledger_events ENABLE ALWAYS TRIGGER ck_events__recorded_at;

-- ---- an account's identity is immutable ------------------------------------
-- purpose, currency and tenant_id were already frozen -- by uq_accounts__owned,
-- uq_accounts__house and the composite FKs entries carry. WHO THE ACCOUNT BELONGS
-- TO was not. One UPDATE moved 110,000 of receivable from a named company to
-- owner_id NULL: every balance identical, the trial balance still balanced,
-- ledger_balance_drift silent -- because none of them read the owner. A receivable
-- owed by nobody is not a receivable, and there is no journal entry to reverse
-- because nothing was posted.
--
-- `metadata` stays mutable on purpose: it is annotation, not identity.
CREATE FUNCTION assert_account_identity_stable() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    -- purpose, category and normal_balance are deliberately NOT here: 0002 owns
    -- those, and its guard is entry-aware -- an account with no history yet may
    -- still be re-typed, and its message names the entry count that blocks it.
    -- Duplicating them here would shadow that message with a worse one and leave
    -- the richer guard permanently unreachable.
    IF (NEW.tenant_id, NEW.id, NEW.owner_type, NEW.owner_id, NEW.currency,
        NEW.created_at)
       IS DISTINCT FROM
       (OLD.tenant_id, OLD.id, OLD.owner_type, OLD.owner_id, OLD.currency,
        OLD.created_at) THEN
        RAISE EXCEPTION
            'account %/% cannot be re-owned: who it belongs to, and in what '
            'currency, is what its posted history means. Open a new account and '
            'transfer the balance',
            OLD.tenant_id, OLD.id
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER ck_accounts__identity_stable BEFORE UPDATE ON ledger_accounts
    FOR EACH ROW EXECUTE FUNCTION assert_account_identity_stable();
ALTER TABLE ledger_accounts ENABLE ALWAYS TRIGGER ck_accounts__identity_stable;

-- ---- a correction must point at something it can actually correct -----------
-- Both columns had a foreign key, so the target had to EXIST. Nothing required it
-- to be in a state the correction makes sense against. Measured: a posted
-- transaction "resolved" by another posted one, and a pending one "reversed" --
-- 49,223 of NEGATIVE revenue, with ledger_balance_drift at 0 and the accounting
-- equation balanced, because both halves were internally consistent journal
-- entries. The referential integrity was real; the semantic linkage was assumed.
--
-- AFTER INSERT is sufficient because a transaction's status can never change:
-- ck_txn__immutable refuses every UPDATE, and pending -> posted is a NEW ROW that
-- points back through resolves_id. That is the whole reason this check is
-- decidable at insert time.
CREATE FUNCTION assert_correction_target() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_status ledger_txn_status;
BEGIN
    IF NEW.resolves_id IS NOT NULL THEN
        SELECT status INTO v_status FROM ledger_transactions
         WHERE tenant_id = NEW.tenant_id AND id = NEW.resolves_id;
        IF v_status <> 'pending' THEN
            RAISE EXCEPTION
                'transaction % cannot resolve %, which is %: resolution moves a '
                'PENDING transaction to its final state', NEW.id, NEW.resolves_id, v_status
                USING ERRCODE = '23514';
        END IF;
    END IF;

    IF NEW.reverses_id IS NOT NULL THEN
        SELECT status INTO v_status FROM ledger_transactions
         WHERE tenant_id = NEW.tenant_id AND id = NEW.reverses_id;
        IF v_status <> 'posted' THEN
            RAISE EXCEPTION
                'transaction % cannot reverse %, which is %: only a POSTED '
                'transaction has entries to reverse', NEW.id, NEW.reverses_id, v_status
                USING ERRCODE = '23514';
        END IF;
    END IF;
    RETURN NULL;
END $$;

CREATE TRIGGER ck_txn__correction_target AFTER INSERT ON ledger_transactions
    FOR EACH ROW WHEN (NEW.resolves_id IS NOT NULL OR NEW.reverses_id IS NOT NULL)
    EXECUTE FUNCTION assert_correction_target();
ALTER TABLE ledger_transactions ENABLE ALWAYS TRIGGER ck_txn__correction_target;

-- ---- the transaction record itself is immutable -----------------------------
-- Two escapes closed at once. The "fewer than two entries" DELETE guard gated on
-- the parent still existing, so deleting the legs AND the transaction row in one
-- statement erased 50,000 of revenue with every check green. And xact_id -- the
-- seal's whole basis -- was an ordinary mutable column: one UPDATE re-opened a
-- committed, already-reported transaction and appended to it.
CREATE FUNCTION assert_transaction_immutable() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'transaction % is history and cannot be deleted; reverse it instead',
            OLD.id USING ERRCODE = '23514';
    END IF;
    -- metadata and external_ref are annotation; everything else is the record
    IF ROW(NEW.tenant_id, NEW.id, NEW.event_id, NEW.kind, NEW.status, NEW.effective_at,
           NEW.recorded_at, NEW.resolves_id, NEW.reverses_id, NEW.xact_id)
       IS DISTINCT FROM
       ROW(OLD.tenant_id, OLD.id, OLD.event_id, OLD.kind, OLD.status, OLD.effective_at,
           OLD.recorded_at, OLD.resolves_id, OLD.reverses_id, OLD.xact_id) THEN
        RAISE EXCEPTION
            'transaction % is immutable; only metadata and external_ref may change',
            OLD.id USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER ck_txn__immutable BEFORE UPDATE OR DELETE ON ledger_transactions
    FOR EACH ROW EXECUTE FUNCTION assert_transaction_immutable();
ALTER TABLE ledger_transactions ENABLE ALWAYS TRIGGER ck_txn__immutable;

-- A transaction's entry set is closed when its creating transaction commits.
CREATE FUNCTION assert_entry_seals() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_xact bigint;
BEGIN
    SELECT xact_id INTO v_xact FROM ledger_transactions
     WHERE tenant_id = NEW.tenant_id AND id = NEW.transaction_id;
    -- If there is no such transaction, say nothing: fk_entries__txn is the right
    -- error for that, and it is the one that names the cross-tenant guard.
    IF v_xact IS NOT NULL
       AND v_xact IS DISTINCT FROM pg_current_xact_id()::text::bigint THEN
        RAISE EXCEPTION
            'transaction % is already committed; its entries are sealed. Correct it '
            'with a reversing transaction, not by appending legs', NEW.transaction_id
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END $$;

-- account_seq is ASSIGNED from the journal, never accepted and never validated
-- against the cache.
--
-- The previous version compared the incoming sequence against
-- ledger_account_balances.last_seq -- a column the app role is granted UPDATE on.
-- So the counter was not issued, it was ASKED: rewind last_seq into a reserved
-- gap in one transaction, back-fill the gap in another, put the counter back, and
-- gross turnover on a closed period went from 1,400.00 to 1,551,400.00 with every
-- running balance correct, the cache in perfect agreement, and zero drift rows.
-- The alarm detects disagreement, never fabrication, so it could not see it.
--
-- Deriving it from the journal under the row lock the balance upsert already holds
-- closes the gap-creation, the gap-filling and the brand-new-account case at once
-- (the old trigger was a no-op when no cache row existed yet, so ANY sequence was
-- accepted, including bigint max, which permanently bricked the account).
CREATE FUNCTION assign_entry_seq() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    -- Take the lock rather than assume the caller did. The comment here used to say
    -- the sequence was derived "under the row lock the balance upsert already
    -- holds" -- but that was an unwritten caller protocol, not a property of this
    -- code: nothing requires a caller to touch ledger_account_balances before
    -- inserting entries. Two concurrent posters that were each legal in isolation
    -- collided on uq_entries__account_seq with a 23505, which is indistinguishable
    -- from a genuine idempotency conflict and which no serialization-failure retry
    -- loop will retry.
    --
    -- Creating the row here is safe and idempotent: it is the same upsert the
    -- posting path performs, minus the amounts.
    INSERT INTO ledger_account_balances (tenant_id, account_id, currency)
    VALUES (NEW.tenant_id, NEW.account_id, NEW.currency)
    ON CONFLICT DO NOTHING;
    PERFORM 1 FROM ledger_account_balances
     WHERE tenant_id = NEW.tenant_id AND account_id = NEW.account_id
       AND currency = NEW.currency FOR UPDATE;

    SELECT COALESCE(MAX(account_seq), 0) + 1 INTO NEW.account_seq
      FROM ledger_entries
     WHERE tenant_id = NEW.tenant_id AND account_id = NEW.account_id
       AND currency = NEW.currency;
    RETURN NEW;
END $$;

CREATE TRIGGER ck_entries__seq BEFORE INSERT ON ledger_entries
    FOR EACH ROW EXECUTE FUNCTION assign_entry_seq();
ALTER TABLE ledger_entries ENABLE ALWAYS TRIGGER ck_entries__seq;

-- Entries are immutable. ck_txn__immutable protects the transaction row; the table
-- with the STRONGER stated guarantee had only a REVOKE, and this file says in
-- terms that "REVOKE is a grant, not a constraint, and migrations run as a
-- privileged role". As the owner, one UPDATE rewrote recorded_at across ten
-- entries and moved an already-issued as-of report; one more made a balanced
-- journal report UNBALANCED by moving only the credit legs.
CREATE FUNCTION assert_entry_immutable() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION
        'ledger entries are immutable: % on entry % refused. Correct the books with '
        'a reversing transaction', TG_OP, OLD.id
        USING ERRCODE = '23514';
END $$;

-- The idempotency spine is a record too. ledger_events was the one table with an
-- assign-on-insert trigger and NO immutability guard, so recorded_at was assigned
-- and then freely re-writable -- along with payload, kind, effective_at and
-- idempotency_hash itself, the column whose entire job is "same key + DIFFERENT
-- hash -> reject". Rewrite the hash and the next replay of that key returns the
-- wrong stored result.
CREATE FUNCTION assert_event_immutable() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION
        '% is an event log and is immutable: % on % refused',
        TG_TABLE_NAME, TG_OP, OLD.id
        USING ERRCODE = '23514';
END $$;

CREATE TRIGGER ck_events__immutable BEFORE UPDATE OR DELETE ON ledger_events
    FOR EACH ROW EXECUTE FUNCTION assert_event_immutable();
ALTER TABLE ledger_events ENABLE ALWAYS TRIGGER ck_events__immutable;

CREATE TRIGGER ck_entries__immutable BEFORE UPDATE OR DELETE ON ledger_entries
    FOR EACH ROW EXECUTE FUNCTION assert_entry_immutable();
ALTER TABLE ledger_entries ENABLE ALWAYS TRIGGER ck_entries__immutable;

CREATE TRIGGER ck_entries__sealed
    BEFORE INSERT ON ledger_entries
    FOR EACH ROW EXECUTE FUNCTION assert_entry_seals();
ALTER TABLE ledger_entries ENABLE ALWAYS TRIGGER ck_entries__sealed;

CREATE FUNCTION assert_transaction_balances() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE offending record; v_tenant text; v_txn uuid;
BEGIN
    -- OLD on DELETE, NEW otherwise. The trigger used to fire on INSERT only, which
    -- left a hole big enough to drive through: deleting one leg of a committed
    -- transaction left 900 debits against 0 credits and nothing complained. REVOKE
    -- is a grant, not a constraint, and migrations run as a privileged role.
    v_tenant := COALESCE(NEW.tenant_id, OLD.tenant_id);
    v_txn    := COALESCE(NEW.transaction_id, OLD.transaction_id);

    SELECT e.currency,
           SUM(e.amount_minor) FILTER (WHERE e.direction = 'debit')  AS dr,
           SUM(e.amount_minor) FILTER (WHERE e.direction = 'credit') AS cr
      INTO offending
      FROM ledger_entries e
     WHERE e.tenant_id = v_tenant AND e.transaction_id = v_txn
     GROUP BY e.currency
    HAVING COALESCE(SUM(e.amount_minor) FILTER (WHERE e.direction = 'debit'), 0)
        <> COALESCE(SUM(e.amount_minor) FILTER (WHERE e.direction = 'credit'), 0)
     LIMIT 1;

    -- Deleting EVERY leg leaves a zero-row GROUP BY, so the check above finds
    -- nothing and passes -- the same "vacuously balanced" reasoning that justified
    -- ck_txn__has_entries on INSERT, in the delete direction. Verified: a committed
    -- 2-leg transaction was reduced to zero entries, the posted row survived, and
    -- with its cached balances also removed the drift view returned nothing, the
    -- balance sheet balanced, and the accounting equation returned no rows at all.
    IF TG_OP = 'DELETE'
       AND EXISTS (SELECT 1 FROM ledger_transactions
                    WHERE tenant_id = v_tenant AND id = v_txn)
       AND (SELECT count(*) FROM ledger_entries
             WHERE tenant_id = v_tenant AND transaction_id = v_txn) < 2 THEN
        RAISE EXCEPTION
            'transaction % would be left with fewer than two entries', v_txn
            USING ERRCODE = '23514';
    END IF;

    -- ...AND A BALANCED SUBSET IS NOT A LEGAL DELETION EITHER. The two conditions
    -- above are "every remaining currency balances" and "at least two legs remain",
    -- and removing a matched PAIR satisfies both. Measured on a four-leg
    -- transaction -- 500.00 of revenue in cash plus 30.00 of interest accrued --
    -- deleting the interest pair left the interest expense line at zero with the
    -- equation balanced, balance_sheet_balances true and both drift views empty,
    -- while the sibling controls (one leg, all legs) still refused in the same
    -- database. Balance is preserved by construction when you remove a balanced
    -- subset, so balance cannot be the test.
    --
    -- The rule that does hold is the one the INSERT path already uses: a
    -- transaction committed in an earlier database transaction is SEALED. Its leg
    -- set is fixed, and correcting it means a reversing transaction. This is
    -- deliberately independent of ck_entries__immutable, because the controls that
    -- reach this branch model corruption arriving with that trigger lifted.
    IF TG_OP = 'DELETE'
       AND (SELECT xact_id FROM ledger_transactions
             WHERE tenant_id = v_tenant AND id = v_txn)
           IS DISTINCT FROM pg_current_xact_id()::text::bigint THEN
        RAISE EXCEPTION
            'transaction % is already committed; its entries are sealed. Correct it '
            'with a reversing transaction, not by removing legs', v_txn
            USING ERRCODE = '23514';
    END IF;

    IF FOUND THEN
        -- COALESCE because a one-legged transaction reports the missing side as
        -- NULL, which reads as though the value were unknown rather than zero.
        -- ERRCODE 23514 (check_violation), not the plpgsql default P0001: a caller
        -- must be able to tell an integrity violation from any other raised error.
        RAISE EXCEPTION 'transaction % does not balance in %: debits=% credits=%',
            v_txn, offending.currency,
            COALESCE(offending.dr, 0), COALESCE(offending.cr, 0)
            USING ERRCODE = '23514';
    END IF;
    RETURN NULL;
END $$;

CREATE CONSTRAINT TRIGGER ck_entries__balances
    AFTER INSERT OR UPDATE OR DELETE ON ledger_entries
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION assert_transaction_balances();

-- ENABLE ALWAYS, not the default ENABLE ORIGIN. `SET session_replication_role =
-- 'replica'` is the logical-replication apply path and what `pg_restore
-- --disable-triggers` uses -- and under it an unbalanced transaction COMMITTED
-- (verified: 500 debits, 0 credits). A subscriber must enforce the same invariant
-- as its publisher, or replication is a laundering channel for corrupt rows.
ALTER TABLE ledger_entries ENABLE ALWAYS TRIGGER ck_entries__balances;

-- ...and the FOREIGN KEYS, which were not. `ENABLE ALWAYS` was applied to the two
-- hand-written constraint triggers and to nothing else, so under
-- session_replication_role='replica' all three composite FKs were skipped:
-- verified, a transaction spanning two tenants, with both legs carrying a currency
-- their account does not hold, dated 27 years before their own transaction --
-- every guard the composite keys exist to provide, on the replication apply path.
-- Referential integrity is implemented as system triggers, so it takes the same
-- treatment.
-- EVERY table that participates in a foreign key, not a hand-written list.
--
-- The list version covered ledger_entries, ledger_transactions and
-- ledger_account_balances -- and missed the REFERENCED side, which lives on
-- ledger_accounts and ledger_events. Under replica, deleting two rows from
-- ledger_accounts removed a whole balanced sub-book: every report INNER JOINs
-- ledger_accounts, so revenue went to zero, the equation and the balance sheet
-- both stayed BALANCED, and eight orphaned entries worth 310,280,000 minor units
-- stayed in the journal with the drift view silent.
--
-- 0002 re-runs this same block, because its foreign keys do not exist yet here.
CREATE PROCEDURE enforce_triggers_on_replicas() LANGUAGE plpgsql AS $$
DECLARE t record;
BEGIN
    FOR t IN
        SELECT c.relname AS tbl, tg.tgname
          FROM pg_trigger tg
          JOIN pg_class c ON c.oid = tg.tgrelid
          JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'public' AND tg.tgisinternal AND tg.tgenabled = 'O'
    LOOP
        EXECUTE format('ALTER TABLE public.%I ENABLE ALWAYS TRIGGER %I', t.tbl, t.tgname);
    END LOOP;
END $$;


CALL enforce_triggers_on_replicas();

-- A transaction with NO entries is vacuously balanced, so the row trigger above
-- never fires for it. Verified: a `posted` clearing with zero entries committed,
-- consuming an idempotency key. Oracle GL refuses the same thing -- "journal
-- entries must have at least two journal entry lines."
CREATE FUNCTION assert_transaction_has_entries() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE n bigint;
BEGIN
    SELECT count(*) INTO n FROM ledger_entries
     WHERE tenant_id = NEW.tenant_id AND transaction_id = NEW.id;
    IF n < 2 THEN
        RAISE EXCEPTION 'transaction % has % entr%; a transaction needs at least two',
            NEW.id, n, CASE WHEN n = 1 THEN 'y' ELSE 'ies' END
            USING ERRCODE = '23514';
    END IF;
    RETURN NULL;
END $$;

CREATE CONSTRAINT TRIGGER ck_txn__has_entries
    AFTER INSERT ON ledger_transactions
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION assert_transaction_has_entries();
ALTER TABLE ledger_transactions ENABLE ALWAYS TRIGGER ck_txn__has_entries;

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
--
-- These REVOKEs are defensive, and their limits are worth stating plainly. A REVOKE
-- is a point-in-time change to a privilege, NOT a standing prohibition: a later
-- `GRANT ALL` re-grants everything, including TRUNCATE.
--
-- An earlier version of this comment then said "nothing in SQL can stop that."
-- THAT WAS FALSE, and a reviewer demonstrated the fix in four lines: a statement
-- trigger. It holds against every escape named here -- a careless GRANT ALL, the
-- replica role, CASCADE, and the table owner. TRUNCATE was worth defending
-- specifically because it empties the journal while leaving ledger_transactions
-- intact, and the drift view then reports NOTHING: there is nothing left to
-- disagree with. Every report came back BALANCED over an empty ledger.
-- TRUNCATE is included deliberately. It is not covered by DELETE, it fires no row
-- trigger, and it was verified reachable: after a careless `GRANT ALL`, the shipped
-- REVOKEs left TRUNCATE in place and `SET ROLE openledger_app; TRUNCATE
-- ledger_entries;` succeeded. That is the whole journal, silently, past every
-- constraint in this file.
-- A child table under INHERITS (ledger_entries) inherits the CHECK constraints and
-- NOTHING else -- no triggers, no foreign keys, no unique indexes -- while its rows
-- remain visible through the parent to every view. Verified: two legs appended to a
-- long-committed transaction through such a child, with the seal, the append-only
-- grant and the drift alarm all intact and silent. The invariants here are
-- per-table, not per-hierarchy -- and an earlier version of this comment ended
-- "and SQL cannot make them otherwise". THAT WAS FALSE, and it is the third
-- "cannot" in this file to fall to a reviewer with eleven lines of SQL. (The
-- first said nothing could stop TRUNCATE. The second said the aggregate could
-- answer a recorded-axis as-of question.)
--
-- What the escape buys, measured as openledger_app in ONE session with no
-- superuser, no SET and no DDL of its own -- only a child table an operator or a
-- future migration created: 500.00 of revenue became 666,500.00, a 1,333x
-- overstatement, with the income statement, the trial balance, the balance sheet,
-- the accounting equation, balance_sheet_balances and BOTH drift views all
-- agreeing, because every view reads the hierarchy while every trigger, unique
-- index and composite foreign key is per-table. The seal was provably still alive
-- on the parent in the same database at the same moment.
--
-- An event trigger closes it -- and the FIRST version of this one did not, which
-- makes it the fourth false "cannot" in this file rather than the fix for the
-- third. It missed two doors, either of which reproduced the harm above verbatim:
--
--   * a FOREIGN TABLE child. Missed twice over: the tag is CREATE FOREIGN TABLE,
--     not CREATE TABLE, and a foreign table is relkind 'f', not 'r'. So fixing
--     either filter alone would still have left it open.
--   * `session_replication_role = 'replica'`. The trigger was ENABLE ORIGIN, and
--     Postgres skips ORIGIN event triggers on the apply path exactly as it skips
--     ORIGIN row triggers. This file spends twenty-five lines hardening every row
--     trigger and every internal FK trigger for that path and left its newest
--     guard off it. `pg_event_trigger` is a different catalog from `pg_trigger`,
--     so the ENABLE ALWAYS census in tests/negative_controls.sql did not see it.
--
-- And the worst case needs no ledger write at all: a child of ledger_ACCOUNTS
-- duplicates every join row, so one INSERT ... SELECT * FROM ONLY ledger_accounts
-- multiplies every number in every report, stays balanced, and leaves nothing for
-- ledger_balance_drift to notice -- that view reads entries and the cache, and
-- never looks at accounts.
--
-- `ddl_command_end` fires after the child exists, so pg_inherits already shows the
-- link and the whole statement rolls back. Ordinary DDL is unaffected.
-- THE LIST OF PROTECTED PARENTS IS A TABLE, NOT A LITERAL IN THIS FUNCTION, because
-- a later migration adds tables with the same exposure and cannot edit this one.
-- It was a literal naming four tables while tests/negative_controls.sql's census
-- named six -- and the two the guard did not name are 0003's. Reproduced: a child
-- of card_hold_groups accepted an INSERT, held_for_company('t9','c9','USD') went
-- from 0 to 999900 through the parent, and ck_hold_groups__no_delete did not apply
-- to the child, so the row could be removed again. held_for_company is the
-- authorization decision, which makes that fabricated credit.
--
-- Each migration declares its own tables here, the same rule this file already
-- states for foreign keys and ENABLE ALWAYS.
CREATE TABLE ledger_uninheritable (
    relname text PRIMARY KEY,
    reason  text NOT NULL
);
INSERT INTO ledger_uninheritable (relname, reason) VALUES
  ('ledger_entries',      'the journal; every view reads it'),
  ('ledger_transactions', 'the journal; every view reads it'),
  ('ledger_events',       'the log every accepted operation lands in'),
  ('ledger_accounts',     'every report joins it, so a child multiplies every number');

CREATE FUNCTION refuse_ledger_inheritance() RETURNS event_trigger
LANGUAGE plpgsql AS $$
DECLARE r record;
BEGIN
    FOR r IN
        SELECT c.oid::regclass AS child, p.oid::regclass AS parent
          FROM pg_inherits i
          JOIN pg_class c ON c.oid = i.inhrelid
          JOIN pg_class p ON p.oid = i.inhparent
          JOIN pg_namespace n ON n.oid = p.relnamespace
         WHERE n.nspname = 'public'
           AND p.relname IN (SELECT u.relname FROM ledger_uninheritable u)
           -- 'f' is a foreign table and 'p' a partitioned one; 'r' alone was the
           -- second half of the foreign-table escape. relpersistence is
           -- deliberately not filtered: an UNLOGGED child persists across an
           -- ordinary restart and is just as visible to every view.
           AND c.relkind IN ('r','f','p') AND NOT c.relispartition
    LOOP
        RAISE EXCEPTION
            'the ledger tables may not be inherited: % would carry none of %''s '
            'triggers, unique indexes or foreign keys, while every view would '
            'read its rows', r.child, r.parent
            USING ERRCODE = '23514';
    END LOOP;
END $$;

CREATE EVENT TRIGGER ck_no_ledger_inheritance ON ddl_command_end
    WHEN TAG IN ('CREATE TABLE', 'ALTER TABLE',
                 'CREATE FOREIGN TABLE', 'ALTER FOREIGN TABLE')
    EXECUTE FUNCTION refuse_ledger_inheritance();
-- ...and ALWAYS, for the same reason every row trigger here is: the replication
-- apply path skips ORIGIN event triggers.
ALTER EVENT TRIGGER ck_no_ledger_inheritance ENABLE ALWAYS;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;

CREATE FUNCTION refuse_truncate() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'the ledger cannot be truncated: % is history', TG_TABLE_NAME
        USING ERRCODE = '23514';
END $$;

CREATE TRIGGER ck_entries__no_truncate BEFORE TRUNCATE ON ledger_entries
    FOR EACH STATEMENT EXECUTE FUNCTION refuse_truncate();
ALTER TABLE ledger_entries ENABLE ALWAYS TRIGGER ck_entries__no_truncate;
CREATE TRIGGER ck_txn__no_truncate BEFORE TRUNCATE ON ledger_transactions
    FOR EACH STATEMENT EXECUTE FUNCTION refuse_truncate();
ALTER TABLE ledger_transactions ENABLE ALWAYS TRIGGER ck_txn__no_truncate;
CREATE TRIGGER ck_events__no_truncate BEFORE TRUNCATE ON ledger_events
    FOR EACH STATEMENT EXECUTE FUNCTION refuse_truncate();
ALTER TABLE ledger_events ENABLE ALWAYS TRIGGER ck_events__no_truncate;
CREATE TRIGGER ck_accounts__no_truncate BEFORE TRUNCATE ON ledger_accounts
    FOR EACH STATEMENT EXECUTE FUNCTION refuse_truncate();
ALTER TABLE ledger_accounts ENABLE ALWAYS TRIGGER ck_accounts__no_truncate;

REVOKE UPDATE, DELETE, TRUNCATE ON ledger_entries      FROM openledger_app;
REVOKE UPDATE, DELETE, TRUNCATE ON ledger_transactions FROM openledger_app;
REVOKE        DELETE, TRUNCATE ON ledger_events        FROM openledger_app;
REVOKE        DELETE, TRUNCATE ON ledger_account_balances FROM openledger_app;

-- ------------------------------------------------------------ the corruption alarm
-- ADR-0003 leans on balance_after and a recomputation always agreeing, calling it a
-- free corruption alarm. It was described and never implemented. Here it is.
-- Compares against the debit-positive convention declared on balance_after above.
-- The corruption alarm, over all THREE copies of every balance.
--
-- Two defects found by mutation testing, both of which made this look like a
-- working alarm while it watched almost nothing:
--
--   * It compared only the LAST balance_after per account, via last_value() over
--     an unbounded frame. Corrupting any INTERMEDIATE running balance was
--     invisible -- and ADR-0003 justifies balance_after precisely as the
--     as-of/point-in-time read, i.e. the rows this did not check. Now per row.
--   * It ignored ledger_account_balances entirely -- the copy the hot path
--     trusts, and the only one the app role may UPDATE. Verified: input-output
--     set to 999999 by hand, alarm silent.
--
-- It also returned one row PER ENTRY (1,000 entries, 1,000 identical rows), so
-- the "free" alarm materialised the whole table.
-- The two journal tables must also agree with EACH OTHER. ck_txn__has_entries is
-- a DEFERRED constraint trigger, so it can only speak at COMMIT of the statement
-- that emptied a transaction -- and `TRUNCATE ledger_entries` is not such a
-- statement. Truncating the entries left 11 transactions standing with zero
-- entries, all three currencies reporting `balanced = t`, and every drift view at
-- zero rows: there was nothing left to disagree with. TRUNCATE is now refused
-- outright, and this is the standing cross-check that would have SEEN it.
CREATE VIEW ledger_transaction_drift AS
SELECT t.tenant_id, t.id, t.status, t.kind, t.effective_at,
       count(e.id) AS entries
  FROM ledger_transactions t
  LEFT JOIN ledger_entries e
    ON e.tenant_id = t.tenant_id AND e.transaction_id = t.id
 GROUP BY t.tenant_id, t.id, t.status, t.kind, t.effective_at
HAVING count(e.id) < 2;

CREATE VIEW ledger_balance_drift AS
WITH j AS (
    SELECT e.tenant_id, e.account_id, e.currency, e.account_seq,
           e.balance_after AS stored,
           SUM(CASE WHEN e.direction = 'debit' THEN e.amount_minor ELSE -e.amount_minor END)
               OVER (PARTITION BY e.tenant_id, e.account_id, e.currency
                     ORDER BY e.account_seq ROWS UNBOUNDED PRECEDING) AS recomputed
    FROM ledger_entries e
), first_bad AS (
    SELECT DISTINCT ON (tenant_id, account_id, currency)
           tenant_id, account_id, currency, account_seq, stored, recomputed
      FROM j WHERE stored <> recomputed
     ORDER BY tenant_id, account_id, currency, account_seq
), latest AS (
    SELECT DISTINCT ON (tenant_id, account_id, currency)
           tenant_id, account_id, currency, recomputed AS journal_total,
           account_seq AS journal_last_seq
      FROM j ORDER BY tenant_id, account_id, currency, account_seq DESC
), gross AS (
    SELECT e.tenant_id, e.account_id, e.currency,
           COALESCE(SUM(e.amount_minor) FILTER (WHERE e.direction='debit'),0)  AS journal_debits,
           COALESCE(SUM(e.amount_minor) FILTER (WHERE e.direction='credit'),0) AS journal_credits
      FROM ledger_entries e GROUP BY e.tenant_id, e.account_id, e.currency
)
SELECT COALESCE(l.tenant_id,  b.tenant_id)  AS tenant_id,
       COALESCE(l.account_id, b.account_id) AS account_id,
       COALESCE(l.currency,   b.currency)   AS currency,
       fb.account_seq  AS first_bad_seq,   -- NULL = the running balances agree
       fb.stored,
       fb.recomputed,
       l.journal_total, l.journal_last_seq, gr.journal_debits, gr.journal_credits,
       (b.input - b.output) AS cached,     -- ledger_account_balances
       CASE WHEN fb.account_seq IS NOT NULL THEN 'running balance diverges at seq '
                                                 || fb.account_seq
            WHEN b.account_id IS NULL       THEN 'no cached balance row'
            WHEN l.account_id IS NULL       THEN 'cached balance with no entries'
            WHEN b.last_seq IS DISTINCT FROM l.journal_last_seq
                                            THEN 'cached last_seq disagrees with the journal'
            WHEN b.input IS DISTINCT FROM gr.journal_debits
              OR b.output IS DISTINCT FROM gr.journal_credits
                                            THEN 'cached gross turnover disagrees with the journal'
            ELSE 'cached balance disagrees with the journal'
       END AS problem
FROM latest l
LEFT JOIN gross gr ON gr.tenant_id=l.tenant_id AND gr.account_id=l.account_id
                  AND gr.currency=l.currency
FULL OUTER JOIN ledger_account_balances b
  ON b.tenant_id = l.tenant_id AND b.account_id = l.account_id AND b.currency = l.currency
LEFT JOIN first_bad fb
  ON fb.tenant_id = COALESCE(l.tenant_id, b.tenant_id)
 AND fb.account_id = COALESCE(l.account_id, b.account_id)
 AND fb.currency   = COALESCE(l.currency, b.currency)
WHERE fb.account_seq IS NOT NULL
   OR (b.input - b.output) IS DISTINCT FROM l.journal_total
   -- input and output are checked INDIVIDUALLY, not just their difference. The
   -- reason they are stored separately is that gross turnover is then free -- and
   -- gross turnover was the one thing nothing validated: adding 9,999,999.99 to
   -- both sides left the difference intact and the alarm silent.
   OR b.input  IS DISTINCT FROM gr.journal_debits
   OR b.output IS DISTINCT FROM gr.journal_credits
   -- last_seq drives the next account_seq. Poisoned downward it is a permanent
   -- per-account denial of service (every later posting hits uq_entries__account_seq);
   -- poisoned upward it silently corrupts balance_after. It was outside the alarm.
   OR b.last_seq IS DISTINCT FROM l.journal_last_seq;

-- ...and the alarms. ledger_transaction_drift is called "the standing cross-check
-- that would have SEEN it" a hundred lines above, and the app role could not read
-- it: `permission denied for view ledger_transaction_drift`. A check the operating
-- role cannot execute is a check that cannot fire.
GRANT SELECT ON ledger_balance_drift, ledger_transaction_drift TO openledger_app;

COMMIT;
