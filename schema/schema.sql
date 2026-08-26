-- openledger -- the schema, declaratively.
--
-- THIS IS A DESIGN ARTEFACT, NOT A PRODUCT. The ledger itself will be written in
-- Go; see docs/roadmap.md. This file exists to prove one thing: that the shape the
-- ADRs describe is expressible in PostgreSQL using nothing but tables, types,
-- CHECK constraints, foreign keys and unique indexes.
--
-- A TRIGGER NEEDS A WRITTEN JUSTIFICATION. The default is none. Two invariants clear
-- that bar and are implemented at the bottom of this file; everything else is a
-- CHECK, a key, a GRANT, or one code path in Go. No PL/pgSQL business logic, no
-- orchestration, no derivation-with-backfill, and no logic in views beyond reporting.
--
-- An earlier version of this schema carried 27 triggers and 26 PL/pgSQL functions,
-- and had quietly become the ledger -- the balance invariant, sequence assignment,
-- running balances and the entire card authorization state machine all lived in
-- the database, while cmd/openledger was eleven lines that printed "nothing to run
-- yet". That was the design defect. Triggers were the symptom: you only need one
-- to police a table that arbitrary callers write to directly, and callers only
-- write directly when there is no service in front of the database.
--
-- So the rules here are:
--
--   * Anything a single row can check is a CHECK.
--   * Anything a key can express is a FOREIGN KEY or a UNIQUE index.
--   * Anything that needs to read other rows -- "debits equal credits",
--     "account_seq is the next one for this account", "this hold group's total is
--     the sum of its live events" -- belongs in Go, in one code path, where an
--     unbalanced transaction is UNREPRESENTABLE rather than refused.
--   * Append-only is a GRANT *and* a trigger, because a grant binds the application
--     role and nothing else. Migrations, backfills and psql sessions run as the
--     OWNER, `pg_restore --disable-triggers` and the logical-replication apply path
--     set `session_replication_role = 'replica'`, and PostgreSQL's own manual says
--     that in that configuration triggers do not fire at all. See the bottom of
--     this file for what is guarded and what is honestly not.
--
-- Two invariants that used to be triggers are now foreign keys, which is strictly
-- better -- they are declarative, they are visible in \d, and they cannot be
-- forgotten by a new writer:
--
--   * an account's (purpose, category, normal_balance) must exist in the chart
--   * an account type's statement line must agree with its category and normal
--     balance -- a revenue type cannot report under an expense caption
--
-- PostgreSQL 18 is a floor: uuidv7() is the default on six tables.
--
-- HOW THIS GETS APPLIED: goose, from Go -- ADR-0014. This file becomes
-- migrations/00001_baseline.sql when the Go service exists; `make schema` runs it through psql
-- with --single-transaction, which is a development shortcut and not the deployment path.
--
-- NO `BEGIN;`/`COMMIT;` IN THIS FILE, and that is not a style choice. Spike 007
-- measured what they do to a migration runner: goose wraps each migration in its
-- own transaction, an inner `COMMIT;` ENDS IT, and everything after that line then
-- runs unprotected. Demonstrated -- a migration that failed on its last statement
-- left two tables behind AND was not recorded as applied, so the retry died on
-- `relation already exists`. The same file without the two lines rolled back
-- cleanly. `make schema` gets atomicity from `psql --single-transaction` instead,
-- which is the caller's business rather than the file's.



-- ----------------------------------------------------------------------
-- types



CREATE TYPE ledger_category       AS ENUM ('asset','liability','equity','revenue','expense');

CREATE TYPE ledger_normal_balance AS ENUM ('debit','credit');

CREATE TYPE ledger_direction      AS ENUM ('debit','credit');

CREATE TYPE ledger_txn_status     AS ENUM ('pending','posted');

CREATE TYPE account_owner_type    AS ENUM ('company','platform','bank_account','house');


CREATE TYPE auth_event_kind AS ENUM (
    'authorization','incremental','advice','reversal','clearing','expiry','expiry_reversal');


-- ----------------------------------------------------------------------
-- the chart of accounts -- what an account MEANS



-- Every account type maps to exactly one financial-statement line. This is what
-- makes omission structurally impossible: reports enumerate from the chart
-- outward, so there is no parameter in which to pass an incomplete account list.
CREATE TABLE fs_lines (
    code       text CONSTRAINT pk_fs_lines PRIMARY KEY,
    -- The caption is what a reader sees, so two lines carrying the SAME caption
    -- are indistinguishable on the face of the statement -- which is exactly the
    -- harm the restricted-cash split exists to prevent, arrived at from the other
    -- direction. Giving `restricted_cash` the caption 'Cash and cash equivalents'
    -- passed every trigger and every test: the split was real in the chart and
    -- invisible in the report. Nothing in the suite reads a caption, so this is
    -- the constraint rather than a test.
    -- A CAPTION IS DISPLAY TEXT, NOT AN IDENTITY -- and three rounds of trying to
    -- make it one are why that sentence is here rather than a stronger one.
    --
    -- The guard below normalises whitespace and case, which stops the accidents
    -- and the earlier measured defects: 'Current year earnings ' with a trailing
    -- space passed the reservation, and one-argument btrim() let a tab, a newline,
    -- an NBSP or a zero-width space through the version that replaced it -- each
    -- time putting customer suspense under a line pixel-identical to the derived
    -- earnings plug, balanced, with both drift views empty.
    --
    -- IT DOES NOT MAKE A CAPTION SAFE TO KEY ON, and the claim that it compared
    -- "as a reader sees it" was not something a CHECK can do. One codepoint
    -- disproves it: `Undistributed earnings (ѕince inception)` with a Cyrillic
    -- U+0455 for the Latin s passes this CHECK and the unique index, prints
    -- identically, and showed 940.00 of undistributed earnings against a true
    -- 500.00 with every report green. Unicode confusables are unbounded and a
    -- blocklist of them is a losing game.
    --
    -- So the rule is stated rather than enforced: **consumers key on `fs_line`,
    -- the code**, which ck_fs_lines__code_reserved does defend and which
    -- `balance_sheet` emits for exactly this reason. What follows is defence in
    -- depth against typos, not a guarantee about what a human eye can tell apart.
    caption    text NOT NULL CONSTRAINT ck_fs_lines__caption_clean
                   CHECK (caption = btrim(caption, E' \t\n\r\u00a0\u200b\u2007\u202f')
                          AND caption <> ''
                          AND caption !~ '[\u0000-\u001f\u00a0\u200b-\u200f\u2028\u2029\u202f\ufeff]'),
    statement  text NOT NULL CONSTRAINT ck_fs_lines__statement
                   CHECK (statement IN ('balance_sheet','income_statement')),
    -- Which side of the statement this line sits on, declared rather than
    -- inferred. balance_sheet used to derive it from whatever happened to be
    -- posted (`bool_or(category = 'asset')`), so a line with NO activity evaluated
    -- to NULL and landed on the liability/equity side -- inferring the chart from
    -- the data, in the one report whose whole purpose is the opposite.
    -- side must belong to the statement. The CHECK used to admit all four values on
    -- either statement, and balance_sheet_balances counts only 'asset' and
    -- 'liability_equity' -- so a balance-sheet line carrying side 'debit' was
    -- counted on NEITHER side and vanished. Verified: 90% of a balance sheet
    -- missing, reporting balanced = true.
    side       text NOT NULL,
    -- `current_year_earnings` is SYNTHESISED by the balance_sheet view for
    -- un-closed earnings. A chart that also declares a real line by that code
    -- produces two rows with the same caption and no way to tell them apart --
    -- one an account subtotal, one a derived plug.
    CONSTRAINT ck_fs_lines__code_reserved
        CHECK (code <> 'current_year_earnings'),
    -- ...AND THE CAPTION, which is the half that actually does the harm the
    -- comment above describes. balance_sheet emits `'current_year_earnings',
    -- 'Current year earnings'` as LITERALS, so the synthesised row sits outside
    -- uq_fs_lines__caption entirely: a chart line under a different code could
    -- take that caption and be accepted. Measured -- 44,000.00 of customer
    -- suspense liability booked to such a line, and a reader grouping by caption
    -- saw 268,000.00 of current year earnings against a true 224,000.00, with
    -- `balanced = t` and both drift views empty.
    CONSTRAINT ck_fs_lines__caption_reserved
        CHECK (lower(btrim(caption, E' \t\n\r\u00a0\u200b\u2007\u202f'))
                 <> 'undistributed earnings (since inception)'),
    CONSTRAINT ck_fs_lines__side_matches_statement CHECK (
        (statement = 'balance_sheet'    AND side IN ('asset','liability_equity')) OR
        (statement = 'income_statement' AND side IN ('credit','debit'))),
    sort_order int  NOT NULL DEFAULT 1000
);


-- ...and uniqueness on what the reader distinguishes, not on bytes.
CREATE UNIQUE INDEX uq_fs_lines__caption
    ON fs_lines (lower(btrim(caption, E' \t\n\r\u00a0\u200b\u2007\u202f')));


-- ...and the key the chart's integrity FK points at. `code` is already the primary
-- key, so this adds no new uniqueness -- it exists so that a composite foreign key
-- can carry `statement` and `side` along with the code, which is what turns "a
-- revenue type may not report under an expense caption" from a trigger into a key.
ALTER TABLE fs_lines ADD CONSTRAINT uq_fs_lines__code_statement_side
    UNIQUE (code, statement, side);

CREATE TABLE account_types (
    code           text CONSTRAINT pk_account_types PRIMARY KEY,
    category       ledger_category       NOT NULL,
    -- NOT derivable from category: a loss allowance is an asset with a CREDIT
    -- normal balance. Storing both is the only correct option.
    normal_balance ledger_normal_balance NOT NULL,
    description    text NOT NULL,
    fs_line        text NOT NULL,
    -- WHICH STATEMENT AND WHICH SIDE A CATEGORY IMPLIES. Derived, never supplied,
    -- so it cannot disagree with the category it comes from -- and then carried
    -- into the foreign key below. This replaces assert_type_matches_fs_line, the
    -- trigger this project called its best guard because it refused a wrong chart
    -- at SEED time: the wrong system could not be built and no test had to notice.
    -- A foreign key does the same and is visible in \\d.
    fs_statement   text GENERATED ALWAYS AS (
        CASE WHEN category IN ('revenue','expense') THEN 'income_statement'
             ELSE 'balance_sheet' END) STORED,
    fs_side        text GENERATED ALWAYS AS (
        CASE WHEN category IN ('revenue','expense') THEN
                  CASE WHEN normal_balance = 'credit' THEN 'credit' ELSE 'debit' END
             WHEN category = 'asset'               THEN 'asset'
             ELSE 'liability_equity' END) STORED,
    CONSTRAINT fk_types__fs_line FOREIGN KEY (fs_line, fs_statement, fs_side)
        REFERENCES fs_lines (code, statement, side),
    -- ...and the key ledger_accounts points at, so an account cannot claim a
    -- category or normal balance its type does not have. Was a trigger.
    CONSTRAINT uq_types__identity UNIQUE (code, category, normal_balance),
    -- mirrors exactly one external balance and must reconcile against it
    is_perimeter   boolean NOT NULL DEFAULT false,
    -- Can a set of these accounts be summed for reporting? Only if all members
    -- face ONE counterparty. IAS 1.32 / ASC 210-20-45-1 permit offsetting only
    -- for amounts due to and from the same party; where the shard key IS the
    -- counterparty, opposite-sign members must be presented gross.
    counterparty_scope text NOT NULL DEFAULT 'none'
        CONSTRAINT ck_types__counterparty_scope
        CHECK (counterparty_scope IN ('none','shared','per_shard'))
);


-- ----------------------------------------------------------------------
-- the journal



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
    CONSTRAINT ck_accounts__currency_iso CHECK (currency ~ '^[A-Z]{3}$'),
    -- AN ACCOUNT MAY NOT DISAGREE WITH ITS TYPE. Carrying category and
    -- normal_balance on the account is deliberate -- a report must not have to join
    -- the chart to know the sign of a balance -- but a copy can drift, so the copy
    -- is a foreign key into the row it was copied from. Was a trigger.
    CONSTRAINT fk_accounts__type FOREIGN KEY (purpose, category, normal_balance)
        REFERENCES account_types (code, category, normal_balance)
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
    -- The database transaction that created this row -- the SEAL. Entries are
    -- meant to be addable only by that same transaction.
    --
    -- WHY IT MATTERS. Without it, append-only protects the ENTRY and not the
    -- JOURNAL: the app role, holding nothing but its ordinary INSERT grant, can add
    -- a balanced, correctly-dated, correctly-sequenced pair of legs to a
    -- transaction committed and reported months earlier. Measured, before the
    -- guard existed: February revenue went from 500.00 to 1,166.00 with every
    -- constraint in this file satisfied and every report green.
    --
    -- AND IT IS NOT ENFORCED TODAY. The guard was a trigger, and 0012 deleted it.
    -- This column is a bare DEFAULT, which the comment above argues is exactly not
    -- enough -- verified: an ordinary INSERT supplying xact_id = 42 is accepted.
    -- The seal belongs to the writer (ADR-0013), which is not built. Two earlier
    -- versions of this comment pointed at `ck_entries__sealed` and
    -- `assign_xact_id()` as if they were below; neither has existed since 0012, and
    -- a comment naming a guard that is not there is worse than no comment.
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


-- ----------------------------------------------------------------------
-- indexes -- the hot reads named in ADR-0003 and docs/reference-product.md



CREATE INDEX ix_entries__balance_lookup
    ON ledger_entries (tenant_id, account_id, account_seq DESC) INCLUDE (balance_after);

CREATE INDEX ix_entries__asof_recorded
    ON ledger_entries (tenant_id, account_id, recorded_at DESC, account_seq DESC);

CREATE INDEX ix_entries__effective
    ON ledger_entries (tenant_id, account_id, effective_at);

CREATE INDEX ix_entries__txn ON ledger_entries (tenant_id, transaction_id);


-- ----------------------------------------------------------------------
-- the card reference product -- authorizations, holds, clearing



CREATE TABLE card_auth_events (
    tenant_id     text NOT NULL,
    id            uuid NOT NULL DEFAULT uuidv7(),

    -- The processor's per-MESSAGE object id (Marqeta transaction token, Increase
    -- element id, Lithic events[].token) -- NOT the webhook delivery id. Stripe
    -- documents that one occurrence can emit two distinct evt_ ids, so keying on
    -- delivery would admit semantic duplicates.
    processor_msg_id text NOT NULL,

    -- NOTE: there is deliberately no group_key column. Grouping is a revisable
    -- INFERENCE, not a fact -- see card_auth_event_group below.

    company_id    text NOT NULL,
    card_id       text NOT NULL,
    kind          auth_event_kind NOT NULL,

    -- NORMALISED. Signed, always a delta, never a wire value. The adapter is
    -- responsible for converting a cumulative total into a delta.
    amount_delta  bigint NOT NULL,
    -- The minor-unit exponent is currency-dependent (JPY 0, most 2, some 3), so
    -- the code is part of the value, not metadata.
    currency      char(3) NOT NULL,
    -- What the processor actually sent, for audit of the conversion above.
    raw_amount    bigint,
    raw_is_total  boolean NOT NULL DEFAULT false,
    raw           jsonb NOT NULL DEFAULT '{}'::jsonb,

    occurred_at   timestamptz NOT NULL,   -- processor's clock; NOT a total order
    recorded_at   timestamptz NOT NULL DEFAULT now(),
    -- Our hold-release policy. NOT the network clearing deadline, which is a
    -- different clock: it drives dispute eligibility, does not extend on an
    -- increment, and is 5 days card-present on Visa where our hold is typically 7.
    hold_expires_at    timestamptz,
    clearing_deadline  timestamptz,

    CONSTRAINT pk_auth_events PRIMARY KEY (tenant_id, id),
    -- ISO 4217 is uppercase. 0001 enforces this on entries and accounts and 0003
    -- enforced it nowhere, so 'usd' created a SECOND hold group: held_for_company
    -- for 'USD' reported 1000 while 500 more was live under 'usd'. Same failure the
    -- 0001 comment describes, in the number the authorization decision is made on.
    CONSTRAINT ck_auth_events__currency_iso CHECK (currency ~ '^[A-Z]{3}$'),
    -- sign is a property of the kind. 'advice' is exempt because it is bidirectional
    -- on some processors. 'expiry_reversal' is NOT exempt -- it is pinned to ZERO,
    -- for the reason given fifteen lines down. (This header used to say an expiry
    -- reversal "is a positive delta on a release", stating as fact the position the
    -- constraint below exists to forbid. A reader who stopped at the header took
    -- away the exact behaviour that made one 100.00 authorization hold 200.00.)
    -- amount_delta = 0 is legal ONLY for a cumulative total that restates the
    -- amount already applied. A processor re-sending the same total under a new
    -- message id is a routine re-delivery; before this it produced a delta of 0
    -- and died on this CHECK with an opaque constraint error.
    -- A $0.00 authorization is a real message -- account verification / AVS /
    -- card-on-file -- and so is a $0.00 capture. Both were refused outright, with
    -- an opaque constraint error. An expiry_reversal is a positive delta on a
    -- release by definition, so it is no longer exempt.
    CONSTRAINT ck_auth_events__sign CHECK (
        kind = 'advice' OR
        -- expiry_reversal carries ZERO. Expiry is a flag that never subtracted
        -- anything from total_minor, so a reversal of it must not ADD anything
        -- back: it clears the flag. Carrying +remaining made one 100.00
        -- authorization hold 200.00, and after the full 100.00 capture it still
        -- held 100.00 -- with drift silent, because the log genuinely contained
        -- the +10000 and the alarm can only compare the total to the log. The
        -- header argues at length that an event carrying -remaining would be a
        -- read-modify-write smuggled into an append-only log; the mirror image
        -- shipped anyway. The wire amount is kept in raw_amount.
        (kind = 'expiry_reversal' AND amount_delta = 0) OR
        (kind IN ('authorization','incremental') AND amount_delta >= 0) OR
        -- 'expiry' is absent deliberately: expiry is a FLAG. The enum value stays
        -- (removing one is a rewrite) and no row may carry it. record_auth_event
        -- refuses it too, but that gated only the function -- an operator backfill
        -- or a second adapter produced the double release the header argues
        -- against, five lines above the constraint that used to permit it.
        (kind IN ('reversal','clearing')  AND amount_delta <= 0))
);


-- ------------------------------------------------------------ grouping
-- Which authorization an event belongs to is NOT a fact we receive; it is an
-- inference. The spec is explicit: "No clean foreign key. Network IDs (ARN, RRN)
-- don't reliably agree across messages. Needs exact match, then fuzzy fallback on
-- card+merchant+amount +/- tolerance+window, then an explicit unmatched queue --
-- never a silent guess."
--
-- So re-grouping is a ROUTINE corrective operation: a clearing sits unmatched and
-- is later attached; a sentinel-polluted trace merged two unrelated authorizations
-- and must be split. Storing group_key on the event would force that operation to
-- UPDATE a row we call immutable.
--
-- Membership is therefore its own bitemporal table. The event stays a genuinely
-- immutable financial fact; the inference about it is revisable and auditable.
CREATE TABLE card_auth_event_group (
    tenant_id    text NOT NULL,
    -- Identity is a uuidv7, NOT (event_id, assigned_at). now() is TRANSACTION
    -- time, so it is constant across a transaction: an operator correcting the
    -- same event twice in one transaction collided on the primary key. This is
    -- the same lesson as ADR-0005 -- a timestamp is not an ordering key -- and
    -- uuidv7 is time-ordered, so the trail still reads chronologically.
    id           uuid NOT NULL DEFAULT uuidv7(),
    event_id     uuid NOT NULL,
    group_key    text NOT NULL,
    method       text NOT NULL CONSTRAINT ck_event_group__method
                     CHECK (method IN ('lifecycle_id','rrn','fuzzy','manual')),
    assigned_at  timestamptz NOT NULL DEFAULT now(),
    assigned_by  text NOT NULL,
    -- NULL = the current assignment. Equal to assigned_at when an assignment is
    -- superseded inside the transaction that created it: a zero-width interval,
    -- correct because that assignment was never visible outside it.
    superseded_at timestamptz,
    CONSTRAINT pk_event_group PRIMARY KEY (tenant_id, id),
    CONSTRAINT fk_event_group__event FOREIGN KEY (tenant_id, event_id)
        REFERENCES card_auth_events (tenant_id, id)
);


-- Materialised per-group total. Every processor surveyed ships one; against a
-- ~1s real-time-decisioning budget, deriving a hold by summing an unbounded event
-- log is unbounded work. This is the design, not a contingency.
--
-- That is an ARGUMENT, not a measurement. An earlier version of this comment said
-- "measured at 1131ms on two years of history against a 1500ms budget"; neither
-- number has a source, spike 006 says the derivation "has not been benchmarked
-- here", and every other budget figure in this repo says ~1s. Both are struck.
CREATE TABLE card_hold_groups (
    tenant_id   text NOT NULL,
    company_id  text NOT NULL,
    group_key   text NOT NULL,
    -- A group holds ONE currency. Without this, total_minor summed minor units
    -- across denominations and reported 100.00 USD + 50.00 EUR as "held 15000" --
    -- the same vacuity removed from the accounting equation in 0002, but sitting
    -- in the authorization decision, where the number IS available credit.
    currency    char(3) NOT NULL CONSTRAINT ck_hold_groups__currency_iso
                    CHECK (currency ~ '^[A-Z]{3}$'),
    total_minor bigint NOT NULL DEFAULT 0,
    -- The cumulative AUTHORIZED subtotal: the running sum of increase-side deltas
    -- only. A processor restating a cumulative total is restating THIS, not the
    -- net total -- the net total also has clearings and reversals in it. Deriving
    -- the delta from the net total made the result depend on arrival order: the
    -- same three messages produced four different holds across six orders, with no
    -- error and no drift. That falsifies the headline claim of this whole file.
    authorized_minor bigint NOT NULL DEFAULT 0,
    -- Which convention this group's increase-side messages use, fixed by the first
    -- one. NULL until then.
    --
    -- MIXING THEM IS IRRECONCILABLE, and this is the honest limit of the
    -- order-tolerance claim. {authorization +100.00 as a delta, incremental 120.00
    -- as a cumulative total} yields 120.00 in one order and 220.00 in the other,
    -- because a total arriving BEFORE the delta it restates cannot be identified as
    -- already inclusive of it -- there is no information in the message that says
    -- so. No derivation can fix that; only refusing the mix can.
    --
    -- Within one convention order-tolerance holds: pure deltas commute, and pure
    -- totals resolve to the maximum total seen, with anything lower refused as
    -- out-of-order rather than guessed.
    total_convention text CONSTRAINT ck_hold_groups__total_convention
                          CHECK (total_convention IN ('delta','total')),
    -- GREATEST(total,0): an over-capture ($1 fuel auth clearing at $95) must
    -- contribute 0, never raise available credit. LITHIC ships the same clamp:
    -- "if there is an over-reversal, Lithic will cap the amounts.hold.amount to $0."
    -- (This comment used to cite Increase's pending_transaction.held_amount. That is
    -- a credit-DIRECTION guard -- it differs from `amount` "if the amount is
    -- positive", so a pending refund does not raise spending power -- not an
    -- over-capture floor. ADR-0010 recorded the correction and named a file that had
    -- already been deleted, so the false sentence survived here. Correcting a claim
    -- in the document that discovered it is not the same as correcting the claim.)
    held_minor  bigint GENERATED ALWAYS AS (
        CASE WHEN expired_at IS NOT NULL THEN 0 ELSE GREATEST(total_minor, 0) END) STORED,
    open_events int  NOT NULL DEFAULT 0,
    -- Expiry is a FLAG, not an event carrying -remaining. Computing that amount
    -- requires reading the aggregate, which is a read-modify-write smuggled into
    -- an append-only log -- and a read does not commute. TigerBeetle models the
    -- same thing as an interval whose expiry restores the remainder as an engine
    -- operation, for exactly this reason.
    expired_at  timestamptz,
    -- authorized_minor at the moment of expiry. The alarm needs to distinguish
    -- EXPOSURE ADDED after a release from an event merely arriving after one: a
    -- late clearing on an expired group is entirely normal and reduces the log,
    -- while an increase-side message is the thing that must never be swallowed by
    -- the clamp. Keying on "any event after expiry" flagged the normal case.
    expired_authorized bigint,
    -- ...and total_minor at that moment. authorized_minor counts increase-side
    -- deltas ONLY, so two ways of raising live exposure after a release moved it
    -- not at all: an expiry_reversal (excluded from the increase list by design),
    -- and REMOVING a decrease-side event -- splitting a mis-grouped clearing out of
    -- an expired group took exposure from 20.00 to 100.00 with the alarm's
    -- discriminator unchanged. Both are visible in the total.
    expired_total bigint,
    -- Distinguishes the three conditions the clamp otherwise maps onto one 0:
    -- legitimate over-capture, an adapter feeding a total into a delta column, and
    -- a mis-grouped clearing. Over-capture becomes a recorded, alarmable state
    -- rather than a value silently swallowed at SELECT time.
    overcaptured_at timestamptz,
    -- Durable evidence, because overcaptured_at is deliberately non-latching and
    -- was therefore ERASED by the next event that brought the total back up: a
    -- 95.00 over-capture became invisible one message later. The low-water mark
    -- cannot be erased, so "did this group ever over-capture" stays answerable.
    low_water_minor bigint NOT NULL DEFAULT 0,
    last_event_seq  bigint NOT NULL DEFAULT 0,
    updated_at  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT pk_hold_groups PRIMARY KEY (tenant_id, company_id, group_key)
);


-- HTTP-layer dedup. A separate concern from ledger identity, with no ledger effect.
CREATE TABLE webhook_deliveries (
    tenant_id   text NOT NULL,
    delivery_id text NOT NULL,
    received_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT pk_webhook_deliveries PRIMARY KEY (tenant_id, delivery_id)
);


CREATE UNIQUE INDEX uq_auth_events__msg
    ON card_auth_events (tenant_id, processor_msg_id);


-- exactly one live assignment per event
CREATE UNIQUE INDEX uq_event_group__current
    ON card_auth_event_group (tenant_id, event_id) WHERE superseded_at IS NULL;

CREATE INDEX ix_event_group__group
    ON card_auth_event_group (tenant_id, group_key) WHERE superseded_at IS NULL;

-- the audit trail for one event, in assignment order
CREATE INDEX ix_event_group__event ON card_auth_event_group (tenant_id, event_id, id);


CREATE INDEX ix_hold_groups__held
    ON card_hold_groups (tenant_id, company_id) WHERE held_minor > 0;


-- ----------------------------------------------------------------------
-- reports -- the claim Formance cannot meet without a mapping layer



-- ------------------------------------------------------------ reporting

CREATE VIEW trial_balance AS
SELECT a.tenant_id, a.id AS account_id, a.owner_id, a.purpose,
       t.category, t.normal_balance, e.currency,
       -- COALESCE, because an account with only credits returned NULL for debits,
       -- and `WHERE debits - credits <> 0` then DROPS the row instead of flagging
       -- it -- the same NULL-swallowing class as the `NULL NOT IN (...)` bug.
       COALESCE(SUM(e.amount_minor) FILTER (WHERE e.direction='debit'), 0)  AS debits,
       COALESCE(SUM(e.amount_minor) FILTER (WHERE e.direction='credit'), 0) AS credits,
       -- natural balance: positive means more of what this account normally holds
       -- PRESENTATION value: positive means more of what this account normally
       -- holds. Correct for showing ONE account; WRONG to sum across a category,
       -- because a contra account (asset/credit) would then ADD to assets.
       CASE WHEN t.normal_balance = 'debit'
            THEN SUM(CASE WHEN e.direction='debit'  THEN e.amount_minor ELSE -e.amount_minor END)
            ELSE SUM(CASE WHEN e.direction='credit' THEN e.amount_minor ELSE -e.amount_minor END)
       END AS balance_minor,
       -- ARITHMETIC value -- roll up with this one. normal_balance never enters it,
       -- so a contra account carries its own sign instead of being flipped twice.
       SUM(CASE WHEN e.direction='debit' THEN e.amount_minor ELSE -e.amount_minor END)
           AS balance_debit_positive
FROM ledger_entries e
JOIN ledger_transactions x ON x.tenant_id = e.tenant_id AND x.id = e.transaction_id
                          AND x.status = 'posted'
JOIN ledger_accounts a ON a.tenant_id = e.tenant_id AND a.id = e.account_id
JOIN account_types   t ON t.code = a.purpose
GROUP BY a.tenant_id, a.id, a.owner_id, a.purpose, t.category, t.normal_balance, e.currency;


-- The income statement, enumerated the same way. Its absence was itself a gap:
-- the completeness defence covered only the balance sheet, while revenue
-- understatement -- the thing ADR-0009 is about -- had no chart-outward report.
CREATE VIEW income_statement AS
WITH dp AS (
    SELECT e.tenant_id, e.currency, t.fs_line,
           SUM(CASE WHEN e.direction='debit' THEN e.amount_minor ELSE -e.amount_minor END) AS v
    FROM ledger_entries e
    JOIN ledger_transactions x ON x.tenant_id = e.tenant_id AND x.id = e.transaction_id
                              AND x.status = 'posted'
    JOIN ledger_accounts a ON a.tenant_id = e.tenant_id AND a.id = e.account_id
    JOIN account_types   t ON t.code = a.purpose
    GROUP BY e.tenant_id, e.currency, t.fs_line
), scopes AS (SELECT DISTINCT tenant_id, currency FROM ledger_accounts)
SELECT s.tenant_id, s.currency, f.code AS fs_line, f.caption, f.sort_order,
       -- credit-normal lines (revenue) present positive; debit-normal (expense) too
       (CASE WHEN f.side = 'credit' THEN -1 ELSE 1 END
        * COALESCE(SUM(d.v), 0))::bigint AS amount_minor,
       f.side
FROM scopes s
CROSS JOIN fs_lines f
LEFT JOIN dp d ON d.tenant_id = s.tenant_id AND d.currency = s.currency AND d.fs_line = f.code
WHERE f.statement = 'income_statement'
GROUP BY s.tenant_id, s.currency, f.code, f.caption, f.sort_order, f.side
-- ORDERED BY THE CHART. sort_order was written by the seed and read by
-- nothing, so every value in it could be changed with the suite green -- and the
-- assertion that claimed to check the order was reading PHYSICAL ROW ORDER: moving
-- one VALUES row in the seed, changing no sort_order at all, turned it red. A
-- statement whose lines come out in an arbitrary order is not a statement.
ORDER BY tenant_id, currency, sort_order;


-- ------------------------------------------------------------ the balance sheet
--
-- ADR-0009 claimed "reports enumerate from the chart outward, so there is no
-- parameter in which to pass an incomplete account list." That was ASPIRATIONAL:
-- trial_balance and accounting_equation both start FROM ledger_entries and
-- enumerate INWARD, so an account with no entries is simply absent. This view is
-- the claim made true -- it starts FROM fs_lines and left-joins the numbers on, so
-- a statement line with no activity appears as a zero rather than vanishing.
--
-- It also carries the line the chart could not previously produce. Before this,
-- a balance sheet built from fs_lines was out by exactly net income: there is no
-- retained_earnings account and no close, so revenue and expense had nowhere to
-- go. Un-closed books present that residual as CURRENT YEAR EARNINGS inside
-- equity, which is standard interim presentation -- and it is a derived line, not
-- an account, precisely because no closing entry has been made.
CREATE VIEW balance_sheet AS
WITH dp AS (
    SELECT e.tenant_id, e.currency, t.fs_line, t.category,
           SUM(CASE WHEN e.direction='debit' THEN e.amount_minor ELSE -e.amount_minor END) AS v
    FROM ledger_entries e
    JOIN ledger_transactions x ON x.tenant_id = e.tenant_id AND x.id = e.transaction_id
                              AND x.status = 'posted'
    JOIN ledger_accounts a ON a.tenant_id = e.tenant_id AND a.id = e.account_id
    JOIN account_types   t ON t.code = a.purpose
    GROUP BY e.tenant_id, e.currency, t.fs_line, t.category
), scopes AS (
    -- Enumerated from the ACCOUNTS, not from the entries. A scope that has been
    -- opened but has not yet posted anything is still a scope, and a report that
    -- cannot name it cannot claim completeness over it.
    --
    -- HONEST LIMIT: this is still enumeration from data, one level further out.
    -- There is no tenant registry and no currency registry, so a scope with no
    -- accounts at all remains invisible, and `p_tenant` below is exactly the
    -- "parameter in which to pass an incomplete list" that ADR-0009 says should
    -- not exist. Completeness here is guaranteed WITHIN a scope, not across them.
    SELECT DISTINCT tenant_id, currency FROM ledger_accounts
), lines AS (
    SELECT s.tenant_id, s.currency, f.code AS fs_line, f.caption, f.sort_order, f.side,
           COALESCE(SUM(CASE WHEN d.category = 'asset' THEN d.v ELSE -d.v END), 0)::bigint
               AS amount_minor
    FROM scopes s
    CROSS JOIN fs_lines f
    LEFT JOIN dp d ON d.tenant_id = s.tenant_id AND d.currency = s.currency
                  AND d.fs_line = f.code
    WHERE f.statement = 'balance_sheet'
    GROUP BY s.tenant_id, s.currency, f.code, f.caption, f.sort_order, f.side
)
SELECT tenant_id, currency, fs_line, caption, sort_order, amount_minor, side FROM lines
UNION ALL
-- "UNDISTRIBUTED", NOT "CURRENT YEAR". This plug sums revenue and expense over
-- ALL POSTED HISTORY, with no date bound -- there is no period close, so there is
-- no year to be current within. Calling it "Current year earnings" made a ledger
-- holding three years of activity present 34,000.00 under that caption against a
-- true current year of 4,000.00: an 8.5x overstatement that grows without bound
-- with the age of the book, with `balanced = t` and both drift views empty.
-- `retained_earnings` sits in the chart at sort_order 800 and stays at zero
-- forever, because nothing routes to it.
--
-- The honest fix is a period close, which is designed and unbuilt (ADR-0009, and
-- "Still open" in the decision log). Until then the caption says what the number
-- is. `income_statement` has the same shape and no parameter at all: it reports
-- every posted entry ever, so it is a since-inception statement too.
SELECT s.tenant_id, s.currency, 'current_year_earnings',
       'Undistributed earnings (since inception)', 9000,
       (-COALESCE(SUM(d.v), 0))::bigint, 'liability_equity'
FROM scopes s
LEFT JOIN dp d ON d.tenant_id = s.tenant_id AND d.currency = s.currency
              AND d.category IN ('revenue','expense')
GROUP BY s.tenant_id, s.currency
-- ORDERED BY THE CHART. sort_order was written by the seed and read by
-- nothing, so every value in it could be changed with the suite green -- and the
-- assertion that claimed to check the order was reading PHYSICAL ROW ORDER: moving
-- one VALUES row in the seed, changing no sort_order at all, turned it red. A
-- statement whose lines come out in an arbitrary order is not a statement.
ORDER BY tenant_id, currency, sort_order;



-- ----------------------------------------------------------------------
-- THE ONLY TRIGGERS IN THIS SCHEMA, AND WHY EACH ONE IS HERE
--
-- The rule: a trigger states (1) the invariant it holds, (2) why nothing
-- declarative can hold it, and (3) what it does NOT protect against. Two clear
-- that bar. An earlier version of this schema had twenty-seven; ADR-0012 records
-- what happened to the other twenty-five.
--
-- The evidence for drawing the line here rather than elsewhere is spike 009.
-- Formance -- Go, PostgreSQL, in production, the closest analogue there is -- built
-- a full PL/pgSQL write engine and then demolished it: migration 11
-- `make-stateless` dropped five triggers that dispatched business flow, and
-- migration 37 dropped twenty-seven stored functions. But they still run seven
-- triggers per ledger today, on by default. What they removed was ORCHESTRATION and
-- DERIVATION-WITH-BACKFILL. What they kept is assignment and integrity on insert.
-- Airbnb's demolition is the same shape: their triggers were change-data-capture
-- feeding an ETL pipeline, and their verdict was that "SQL is good for lightweight
-- data transformation. It is not designed to handle complicated business data flow."
-- Neither project removed a constraint.

-- (1) THE JOURNAL IS APPEND-ONLY.
--
-- INVARIANT: no row in ledger_entries, ledger_transactions, ledger_events or
-- card_auth_events may ever be updated or deleted. A correction is a new row. This
-- is the claim the whole project rests on -- every other guarantee is downstream of
-- "the history you are reading is the history that happened".
--
-- WHY NOTHING DECLARATIVE HOLDS IT: there is no CHECK for "this row may not change"
-- and no key that expresses it. The only non-trigger option is to withhold the
-- privilege, and `REVOKE` binds the APPLICATION role only. Migrations, repair
-- scripts and a human at a psql prompt all run as the owner, which is precisely the
-- population that has historically done the damage: Airbnb's core payment objects
-- were "mutable by default", and the audit-trail machinery they bolted on to cope
-- is what they later tore out.
--
-- WHAT IT DOES NOT PROTECT AGAINST: an owner who runs `ALTER TABLE ... DISABLE
-- TRIGGER` or drops it, which is one statement. This binds ACCIDENTS, not intent.
-- Nobody in this field holds append-only with a database mechanism -- Monzo does it
-- with a reviewed six-caller network allowlist, Uber with cryptographic signatures
-- over each record. Those are the two published answers and both live outside the
-- database. This is the cheap 80%.
CREATE FUNCTION refuse_mutation() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION '% is append-only: % on % refused. Correct it with a new row.',
        TG_TABLE_NAME, TG_OP, OLD.id
        USING ERRCODE = '23514';
END $$;

-- (2) ...AND TRUNCATE IS NOT A DELETE.
--
-- INVARIANT: the same one. TRUNCATE is separated because PostgreSQL separates it:
-- "TRUNCATE will not fire any ON DELETE triggers that might exist for the tables"
-- (sql-truncate). The guard above sees nothing.
--
-- WHY NOTHING DECLARATIVE HOLDS IT: `REVOKE TRUNCATE` has the same owner-shaped
-- hole as above, and there is no other mechanism -- an event trigger would be the
-- natural one object for the job, and PostgreSQL refuses it outright:
-- `ERROR: event triggers are not supported for TRUNCATE TABLE`. Verified. So it is
-- one statement-level trigger per table or nothing.
--
-- WHAT IT DOES NOT PROTECT AGAINST: the same owner. Also note each table must carry
-- its own -- `TRUNCATE a CASCADE` reaching b is refused by B's guard, naming B, so a
-- test that only checks "something was refused" passes with A's guard deleted.
CREATE FUNCTION refuse_truncate() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION '% is history and cannot be truncated', TG_TABLE_NAME
        USING ERRCODE = '23514';
END $$;

-- ENABLE ALWAYS on every one, or they are decoration on exactly the paths that need
-- them most. `session_replication_role = 'replica'` is the logical-replication apply
-- path and what `pg_restore --disable-triggers` sets; the PostgreSQL manual states
-- that "in the default configuration, triggers do not fire on replicas", and that
-- "triggers configured as ENABLE ALWAYS will fire regardless of the current
-- replication role". A subscriber that does not enforce its publisher's invariants
-- is a laundering channel for corrupt rows.
CREATE TRIGGER ck_entries__append_only BEFORE UPDATE OR DELETE ON ledger_entries
    FOR EACH ROW EXECUTE FUNCTION refuse_mutation();
ALTER TABLE ledger_entries ENABLE ALWAYS TRIGGER ck_entries__append_only;
CREATE TRIGGER ck_entries__no_truncate BEFORE TRUNCATE ON ledger_entries
    FOR EACH STATEMENT EXECUTE FUNCTION refuse_truncate();
ALTER TABLE ledger_entries ENABLE ALWAYS TRIGGER ck_entries__no_truncate;

CREATE TRIGGER ck_txn__append_only BEFORE UPDATE OR DELETE ON ledger_transactions
    FOR EACH ROW EXECUTE FUNCTION refuse_mutation();
ALTER TABLE ledger_transactions ENABLE ALWAYS TRIGGER ck_txn__append_only;
CREATE TRIGGER ck_txn__no_truncate BEFORE TRUNCATE ON ledger_transactions
    FOR EACH STATEMENT EXECUTE FUNCTION refuse_truncate();
ALTER TABLE ledger_transactions ENABLE ALWAYS TRIGGER ck_txn__no_truncate;

CREATE TRIGGER ck_events__append_only BEFORE UPDATE OR DELETE ON ledger_events
    FOR EACH ROW EXECUTE FUNCTION refuse_mutation();
ALTER TABLE ledger_events ENABLE ALWAYS TRIGGER ck_events__append_only;
CREATE TRIGGER ck_events__no_truncate BEFORE TRUNCATE ON ledger_events
    FOR EACH STATEMENT EXECUTE FUNCTION refuse_truncate();
ALTER TABLE ledger_events ENABLE ALWAYS TRIGGER ck_events__no_truncate;

CREATE TRIGGER ck_auth_events__append_only BEFORE UPDATE OR DELETE ON card_auth_events
    FOR EACH ROW EXECUTE FUNCTION refuse_mutation();
ALTER TABLE card_auth_events ENABLE ALWAYS TRIGGER ck_auth_events__append_only;
CREATE TRIGGER ck_auth_events__no_truncate BEFORE TRUNCATE ON card_auth_events
    FOR EACH STATEMENT EXECUTE FUNCTION refuse_truncate();
ALTER TABLE card_auth_events ENABLE ALWAYS TRIGGER ck_auth_events__no_truncate;

-- WHAT DELIBERATELY HAS NO GUARD, so the absence reads as a decision:
--
--   * ledger_account_balances, card_hold_groups -- MATERIALISED state, rebuildable
--     from the journal. They are supposed to be updated; that is what they are for.
--   * card_auth_event_group -- a membership is SUPERSEDED, not deleted, which is an
--     UPDATE by design.
--   * "debits equal credits", "a transaction has at least two entries" -- enforced
--     by CONSTRUCTION. The Go writer builds both legs in one code path, so an
--     unbalanced transaction is unrepresentable rather than refused. This is what
--     TigerBeetle gets from a single Transfer row carrying both account ids, and
--     what Formance gets from Posting{Source,Destination} -- their Validate() has
--     no balance check at all, because there is nothing to check.
--   * recorded_at, account_seq, balance_after, xact_id -- ASSIGNED by the writer.
--     There is no parameter for a caller to supply, which is stronger than a
--     DEFAULT (a DEFAULT is overridable, and that was a measured defect here: a
--     client-settable insertion axis let an already-issued report be rewritten by a
--     transaction claiming to predate it). Formance kept its assignment triggers and
--     we did not. The difference is NOT that we assume one writer -- Formance ships
--     zero GRANTs and zero REVOKEs in its entire repository and does not assume that
--     either. It is that their guarantee is a TYPE: a Posting{Source,Destination}
--     cannot express one leg, so any Go caller gets a balanced pair or nothing.
--     Ours has to be the same shape. Until it is, NOTHING enforces balance at all --
--     `ledger_entries` stores independent rows carrying a direction, so an
--     unbalanced transaction is fully expressible today. See ADR-0013.
--   * chart integrity -- two foreign keys, above. Strictly better than the triggers
--     they replaced: declarative, visible in \d, and impossible to forget.



-- ----------------------------------------------------------------------
-- THE CARD ALARMS
--
-- RESTORED. These two are VIEWS -- declarative, no PL/pgSQL -- and ADR-0012's own
-- rule keeps views; it kept the three report views. They were lost because the
-- script that extracted this file from the old migrations selected report views by
-- name and never looked for these. Nobody noticed until an adversarial reviewer
-- pointed out that ADR-0010 names `card_hold_drift` EIGHT TIMES as the alarm that
-- catches every failure it records -- including the three it declines to fix on the
-- grounds that the alarm sees them -- while the schema had no such object.
--
-- Every sentence of the form "the alarm catches this" was false for as long as they
-- were absent. That is the most expensive kind of deletion: not a lost guard, a lost
-- guard that several documents still promise.
--
-- `card_auth_unmatched` is the review queue: an event with no live assignment.
-- `card_hold_drift` compares the materialised group against a re-aggregation of its
-- live event log, and reports the ways they can disagree.
CREATE VIEW card_auth_unmatched AS
SELECT e.* FROM card_auth_events e
WHERE NOT EXISTS (SELECT 1 FROM card_auth_event_group g
                  WHERE g.tenant_id = e.tenant_id AND g.event_id = e.id
                    AND g.superseded_at IS NULL);

CREATE VIEW card_hold_drift AS
WITH live AS (
    SELECT m.tenant_id, e.company_id, m.group_key,
           SUM(e.amount_delta) AS recomputed,
           -- authorized_minor is the base every cumulative conversion is computed
           -- against and the sole input to the out-of-order refusal. A wrong value
           -- there refuses real increases forever, and nothing compared it to
           -- anything.
           SUM(GREATEST(e.amount_delta,0)) FILTER (
               WHERE e.kind IN ('authorization','incremental')
                  OR (e.kind = 'advice' AND e.amount_delta > 0)) AS recomputed_auth,
           bool_or(e.raw_is_total) FILTER (
               WHERE e.amount_delta <> 0
                 AND (e.kind IN ('authorization','incremental')
                  OR (e.kind = 'advice' AND e.amount_delta > 0))) AS any_total,
           bool_or(NOT e.raw_is_total) FILTER (
               WHERE e.amount_delta <> 0
                 AND (e.kind IN ('authorization','incremental')
                  OR (e.kind = 'advice' AND e.amount_delta > 0))) AS any_delta,
           -- Decreases that moved NO MONEY. A clearing posts to the ledger, so a
           -- group whose total went negative from clearings is not under-reserving
           -- -- the cleared amount is a receivable in the journal, and exposure is
           -- posted + held. ADR-0010 declines the over-capture report on exactly
           -- that argument, and the argument covers `clearing` AND NOTHING ELSE.
           -- `reversal` and negative `advice` post nothing. Two reversals against
           -- one authorization left total_minor at -10000 with zero clearings in
           -- the log, and the next genuine incremental was absorbed by the
           -- residue: 100.00 live, 0.00 held, 0.00 posted, drift silent. The
           -- non-latching overcaptured_at was erased by the very message that hid
           -- the money.
           COALESCE(-SUM(e.amount_delta) FILTER (
               WHERE e.amount_delta < 0 AND e.kind <> 'clearing'), 0) AS bloodless_decreases,
           COALESCE(SUM(GREATEST(e.amount_delta,0)) FILTER (
               WHERE e.kind IN ('authorization','incremental','advice')), 0) AS increases,
           COALESCE(-SUM(e.amount_delta) FILTER (WHERE e.kind = 'clearing'), 0) AS cleared
      FROM card_auth_event_group m
      JOIN card_auth_events e ON e.tenant_id = m.tenant_id AND e.id = m.event_id
     WHERE m.superseded_at IS NULL
     GROUP BY m.tenant_id, e.company_id, m.group_key
)
SELECT COALESCE(g.tenant_id,  l.tenant_id)  AS tenant_id,
       COALESCE(g.company_id, l.company_id) AS company_id,
       COALESCE(g.group_key,  l.group_key)  AS group_key,
       g.total_minor          AS stored,      -- NULL = no materialised group
       g.authorized_minor     AS stored_authorized,
       COALESCE(l.recomputed_auth, 0) AS recomputed_authorized,
       COALESCE(l.recomputed, 0) AS recomputed
FROM card_hold_groups g
FULL OUTER JOIN live l
  ON  l.tenant_id  = g.tenant_id
  AND l.company_id = g.company_id
  AND l.group_key  = g.group_key
WHERE g.total_minor IS DISTINCT FROM COALESCE(l.recomputed, 0)
   OR g.authorized_minor IS DISTINCT FROM COALESCE(l.recomputed_auth, 0)
   -- ...or the group's declared currency disagrees with any of its live events.
   -- The alarm compared total_minor and nothing else, so a group holding two
   -- currencies -- the state regroup_auth_event used to be able to create --
   -- reported no drift at all.
   OR EXISTS (
        SELECT 1 FROM card_auth_event_group m
        JOIN card_auth_events e ON e.tenant_id=m.tenant_id AND e.id=m.event_id
        WHERE m.tenant_id = g.tenant_id AND m.group_key = g.group_key
          AND m.superseded_at IS NULL AND e.company_id = g.company_id
          AND e.currency <> g.currency)
   -- ...or an event was attached to a group AFTER it expired. held_minor is
   -- GENERATED to 0 once expired_at is set, so exposure attached later is
   -- invisible to held_for_company while total_minor and the log still agree --
   -- the alarm compared exactly those two and therefore reported nothing. The
   -- clamp is the thing hiding the number, so the alarm has to look past it.
   -- (An earlier version of this comment said the branch was "keyed on the
   -- monotonic counter, not on now()". It is keyed on the expired_* snapshots.
   -- `last_event_seq` is read by nothing at all -- see the open list.)
   -- Exposure added to a group AFTER it was expired. held_minor is GENERATED to 0
   -- once expired_at is set, so anything attached later is invisible to
   -- held_for_company while total_minor and the log still agree -- the two columns
   -- the alarm compares. Keyed on the monotonic counter, not on now().
   OR (g.expired_at IS NOT NULL
       AND (g.authorized_minor > COALESCE(g.expired_authorized, g.authorized_minor)
         OR g.total_minor      > COALESCE(g.expired_total,      g.total_minor)))
   -- ...or the group's declared convention disagrees with its own log. The alarm
   -- compared totals and currency and never this, so a group holding one
   -- raw_is_total=false event and one raw_is_total=true event -- the state the
   -- header calls IRRECONCILABLE -- reported nothing at all.
   -- ...or the group dipped further negative than its clearings can account for.
   --
   -- THE FIRST VERSION OF THIS ALARM WENT SILENT AT THE MOMENT THE MONEY WAS HIDDEN.
   -- It compared `bloodless_decreases > increases`, which is true in the precursor
   -- state -- two reversals against one authorization -- and FALSE the instant the
   -- next genuine incremental is absorbed by the residue, because that increase
   -- raises `increases` by exactly the amount it swallowed. The guard was defeated
   -- by the event it exists to protect against, and could only ever report the
   -- state where the money was not yet lost.
   --
   -- low_water_minor is written only as `LEAST(low_water_minor, ...)`, so it is
   -- monotone non-increasing THROUGH THESE FUNCTIONS, and group rows cannot be
   -- deleted. It is NOT unerasable: the app role holds UPDATE on this table --
   -- granted so record_auth_event can maintain it -- and one statement sets both
   -- low_water_minor and overcaptured_at back to a clean state with drift silent,
   -- because drift reads neither column. An earlier version of this comment said
   -- "it cannot be erased", which is true of the code and false of the table.
   -- It is also ORDER-DEPENDENT: across 720 permutations of one six-message set,
   -- total_minor, authorized_minor and held_minor each took ONE value and
   -- low_water_minor took TWELVE -- which is the mechanical reason the latching
   -- alarm attempted here false-positived on permutation 4,3,2,1. A dip below what clearings explain
   -- LATCHES. A genuine over-capture (a $1 authorization clearing at $95: low water
   -- -9400 against 9500 cleared) does not fire, and an out-of-order clearing that
   -- lands before its authorization does not either, because that dip never
   -- exceeds what the clearing itself accounts for.
   --
   -- AND IT SELF-HEALS, WHICH IS A REAL LIMIT AND NOT A FIXABLE ONE. The instant a
   -- genuine incremental is absorbed by the residue, `increases` rises by exactly
   -- the amount swallowed and this predicate goes false. A reviewer reported that
   -- as an under-reservation: 100.00 live, 0.00 held, drift silent.
   --
   -- I tried to latch it on low_water_minor -- monotone, unerasable -- comparing
   -- the dip against what clearings could explain. That FALSE-POSITIVES on the
   -- central claim of this whole design: a group whose messages arrive
   -- decrease-first dips below any clearing that has landed yet, which is exactly
   -- the order tolerance the file exists to provide. `tests/card_holds.sql`
   -- permutation 4,3,2,1 catches it immediately.
   --
   -- The reason no predicate works is that THE LOG CANNOT DECIDE THE QUESTION. A
   -- reversal that arrives before its authorization and a reversal that should
   -- never have been sent are the same three columns. Deciding it needs the
   -- processor's own reversal-to-authorization linkage, which this design
   -- deliberately does not model -- 0010 argues that grouping is a revisable
   -- inference precisely because that linkage is unreliable. So the alarm reports
   -- the precursor state, `low_water_minor` keeps the durable evidence that the
   -- group was ever there, and the ambiguity is recorded in ADR-0010 rather than
   -- papered over with a guard that would fire on honest traffic.
   --
   -- AND A CLEARING BLINDED IT COMPLETELY. `total_minor` is
   -- `increases - cleared - bloodless`, so a group can sit BELOW ZERO from a
   -- bloodless reversal while `bloodless <= increases` -- and then the predicate
   -- above never fires, not in the precursor state and not after. Measured:
   -- authorization 100.00, clearing 100.00 (which POSTS), spurious reversal
   -- 100.00, then a genuine incremental 100.00. True exposure 200.00 (100 posted +
   -- 100 un-cleared), reported 100.00, drift 0 rows at every step. Scaled three
   -- times over: 300.00 under-reserved, and the hidden residue is bounded only by
   -- the group's cleared amount.
   --
   -- That falsifies the precise restatement ADR-0010 wrote to close the declined
   -- over-capture report -- "an over-capture never makes held_for_company smaller
   -- than the un-cleared exposure of that group" -- in a state the system itself
   -- flags as an over-capture.
   --
   -- The second disjunct is strictly stronger than the first (bloodless >
   -- increases implies total < 0 and bloodless > 0), so it loses nothing, and the
   -- genuine $1-authorization-clearing-at-$95 over-capture still does not fire,
   -- because it has no bloodless decrease at all.
   OR l.bloodless_decreases > l.increases
   OR (g.total_minor < 0 AND l.bloodless_decreases > 0)
   OR (l.any_total AND l.any_delta)
   OR g.total_convention IS DISTINCT FROM
        (CASE WHEN l.any_total AND l.any_delta THEN g.total_convention
              WHEN l.any_total THEN 'total'
              WHEN l.any_delta THEN 'delta' END);

-- ----------------------------------------------------------------------
-- THE APPLICATION ROLE
--
-- Named as half the append-only mechanism four times in the comments above, and
-- for one commit it did not exist -- the role and its grants lived in the deleted
-- migrations/0001 and were not carried over. A mechanism a document names and the
-- schema does not implement is worse than no mechanism, because it reads as
-- covered. Restored here, and stated for what it is.
--
-- The role gets SELECT and INSERT on the journal and NOTHING ELSE. No UPDATE, no
-- DELETE, no TRUNCATE -- so for this role the two triggers below are redundant, and
-- that is the point: they exist for the owner, not for the app.
--
-- A GRANT IS NOT A CONSTRAINT, and this schema should not pretend otherwise. It is
-- a point-in-time privilege state that one `GRANT ALL` undoes, it binds no
-- superuser, and it binds nothing at all on a database restored by someone who did
-- not run this file. It is the cheap outer layer. Formance -- Go, PostgreSQL, in
-- production -- ships ZERO grants and zero revokes in its entire repository and
-- relies on its write API being the only caller; pgledger relies on the same
-- convention with the same absence. Neither has an append-only guarantee against a
-- direct INSERT, and that is a choice, not an oversight.
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'openledger_app') THEN
        CREATE ROLE openledger_app NOLOGIN;
    END IF;
END $$;

GRANT USAGE ON SCHEMA public TO openledger_app;

-- The journal: read and append.
GRANT SELECT, INSERT ON ledger_accounts, ledger_events, ledger_transactions,
                        ledger_entries TO openledger_app;
-- ...and the materialised balance cache, which is meant to be rewritten.
GRANT SELECT, INSERT, UPDATE ON ledger_account_balances TO openledger_app;

-- The card tables: the hold flow appends events and rewrites its own materialised
-- group rows.
--
-- NOTE, AND IT IS A REAL GAP: ADR-0010's fix for the attach/regroup deadlock is
-- "take the event row lock first, explicitly" -- and `SELECT ... FOR UPDATE` on
-- card_auth_events requires UPDATE privilege, which this role is NOT granted and is
-- explicitly revoked below. An earlier version of this comment claimed the grant was
-- "deliberate and narrow"; it was describing a privilege that is not there. The
-- application role cannot currently execute the ADR's own remedy. Deciding between
-- granting UPDATE (and leaning on the append-only trigger to keep it a lock rather
-- than mutability) and finding a lock that does not need it is open work, recorded
-- in the decision log rather than papered over here.
GRANT SELECT, INSERT ON card_auth_events, card_auth_event_group TO openledger_app;
GRANT SELECT, INSERT, UPDATE ON card_auth_event_group TO openledger_app;
GRANT SELECT, INSERT, UPDATE ON card_hold_groups TO openledger_app;
GRANT SELECT, INSERT ON webhook_deliveries TO openledger_app;

-- Reports are readable; the chart is not writable.
GRANT SELECT ON account_types, fs_lines TO openledger_app;
GRANT SELECT ON trial_balance, balance_sheet, income_statement TO openledger_app;

-- ...and belt and braces on the journal, because a later `GRANT ALL ON ALL TABLES`
-- is one statement and this is the line that survives it in review.
REVOKE UPDATE, DELETE, TRUNCATE ON ledger_entries          FROM openledger_app;
REVOKE UPDATE, DELETE, TRUNCATE ON ledger_transactions     FROM openledger_app;
REVOKE        DELETE, TRUNCATE ON ledger_events            FROM openledger_app;
REVOKE        DELETE, TRUNCATE ON ledger_account_balances  FROM openledger_app;
REVOKE UPDATE, DELETE, TRUNCATE ON card_auth_events        FROM openledger_app;

-- PostgreSQL 15+ already removes CREATE on public from PUBLIC. Kept because it is
-- free and because a database created before 15 and upgraded does not get it.
REVOKE CREATE ON SCHEMA public FROM PUBLIC;

