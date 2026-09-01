//! The repository: [`PgRepository`] and its [`ledger::Repository`] impl,
//! one SQL statement per method, each operating on the open transaction the
//! service began. The trait is implemented here, where the SQL lives — all
//! of this crate's SQL is in this file, and there is no forwarding layer
//! between the port's shapes and the statements. What order the statements
//! run in — and what each result means for the use-case — is the writer
//! service's (`ledger::LedgerService`, in the core crate above), not this
//! file's.
//!
//! Since ADR-0021 the file carries a SECOND operation's statements below the
//! posting ones — the chart read an opening derives its triple from, the
//! claim that carries the account insert, and that operation's own replay
//! lookup. Same rule, same bracket, one more `INSERT … ON CONFLICT DO
//! NOTHING` in the same index: nothing about the idempotency spine is new,
//! which is the whole argument the ADR makes for putting an opening on it.
//!
//! Since single-call posting (roadmap M3), "one statement per method" also
//! means "one statement per POSTING" on the first-writer path:
//! [`claim_and_append`](ledger::Repository::claim_and_append) is a CTE
//! pipeline that claims the key and rides the whole append on the claimed
//! row, so the happy path costs three round trips — the explicit `BEGIN`,
//! the statement, `COMMIT` — where eight ran before it (counted per method:
//! BEGIN + SET, claim, transaction, one upsert per account, entries,
//! COMMIT). Spike 003 measured why that is worth having; ADR-0013 §2 is why
//! the REPLAY lookup does not ride along: folding statement B into the
//! claim returns zero rows under the race it exists to handle.

use std::collections::BTreeMap;

use ledger::{
    AccountOwnerType, Append, Appended, BalanceUpsert, BatchMember, ChartTriple, Claimed, Delta,
    Direction, Leg, MemberOutcome, OpenAccount, OpenedAccount, PostTransaction, Repository,
    StorageError, StoredAccount, StoredResult, SupersedeRefusal, TransactionStatus,
};
use sqlx::{PgPool, Postgres, Transaction};
use time::OffsetDateTime;
use uuid::Uuid;

/// The Postgres repository: the `ledger` crate's outbound port, implemented.
#[derive(Clone)]
pub struct PgRepository {
    pool: PgPool,
    /// The value [`CLAIM_AND_APPEND`] stripes this writer's balance upserts
    /// on ([`stripe_affinity_of`]). Carried on the repository rather than
    /// computed per call because worker affinity is exactly the property of
    /// being CONSTANT for one writer and different between concurrent ones
    /// (ADR-0018 §1); a clone is the same writer and keeps it.
    stripe_affinity: i32,
}

impl PgRepository {
    /// One writer of the dispatcher pool, striping on the index it owns for
    /// its lifetime — ADR-0018 §1's *"the affinity value is the
    /// accumulator's dispatcher index"*, and the seam that value arrives
    /// through. It takes [`db::Database`], not a bare pool: the composition
    /// root hands the adapter what db built, and never names an sqlx type
    /// itself.
    ///
    /// **There is no index-free constructor, and that is the point.** A
    /// single process holding a single affinity puts every write for one
    /// account on ONE stripe, and sixty-four stripes are then one stripe:
    /// the measured 4.31× requires concurrent writers holding DIFFERENT
    /// indices, which only the pool can supply. A default would be a writer
    /// with no writer identity, which is what this feature exists to end.
    ///
    /// Nothing is stranded when a restart reshuffles which writer holds
    /// which index: the stripe is below the account (ADR-0013 §4),
    /// `recon_balance_breaks` groups per stripe, and a lazily created stripe
    /// reconciles clean on its first write.
    pub fn for_writer(database: &db::Database, writer_index: u32) -> Self {
        Self {
            pool: database.pool().clone(),
            stripe_affinity: stripe_affinity_of(writer_index),
        }
    }
}

/// The value a writer of this index stripes on: which physical stripe of a
/// hot account's balance row it takes is that value modulo the account's own
/// `stripe_count`, and the modulo runs in the statement because
/// `stripe_count` is a column of the row being upserted. A stripe shards the
/// write lock and nothing else — it never appears in a report, a
/// reconciliation, an API answer or the chart (ADR-0013 §4).
///
/// **Worker affinity is the measured choice** (ADR-0018 §1): at 64 stripes
/// it clears 2,687 clearings/s against an unstriped 623 — 4.31× — ahead of a
/// random key's 2,503 (4.02×), and far ahead of a TENANT key: on the whale
/// workload, where the two keys are measured side by side and nothing but the
/// selection expression changes, the writer key beats the tenant key 2.8× —
/// 1,897 against 677 clearings/s — because the whale hashes to one stripe and
/// sixty-four stripes become one. That is spike 003's whale finding
/// reproduced one table lower down, and it is why spike 004's business-key
/// refinement is refused.
///
/// **The only property that matters is that concurrent writers hold
/// DIFFERENT values**, never which values they are.
///
/// **The mask is not decoration, and it is the ONLY one.** The statements
/// bind this value and take it modulo the account's own `stripe_count`, so
/// what they write is non-negative exactly when what is bound is: this
/// function is what makes `ck_balances__stripe_non_negative` unreachable for
/// every index a caller could hand in, the one that wraps to `i32::MIN`
/// included. Negation is what cannot do the job — `i32::MIN` has no
/// non-negative counterpart, so `abs()` has no answer to give and would have
/// to raise rather than return. Masking always has one.
fn stripe_affinity_of(writer_index: u32) -> i32 {
    // Wraps negative for indices at or above 2^31; the mask is what takes
    // that back, i32::MIN included (it masks to 0).
    let signed = writer_index as i32;
    signed & i32::MAX
}

/// The port's storage error is opaque (crates/ledger names no sqlx type);
/// this is the one place the Postgres error is boxed into it.
fn storage(e: sqlx::Error) -> StorageError {
    Box::new(e)
}

/// The domain's `Direction` as the `ledger_direction` column STORES it — the
/// dialect's word for the side, rendered at the bind site and nowhere else.
/// Exhaustive, so a third variant would refuse to compile rather than default
/// to a side; one function so that the single statement's binds and the
/// batched one's cannot drift into two renderings.
fn direction_as_stored(direction: Direction) -> &'static str {
    match direction {
        Direction::Debit => "debit",
        Direction::Credit => "credit",
    }
}

/// Transpose the legs into the parallel column arrays `unnest` binds — one
/// Vec per SQL array, in the statement's order: account_id, direction,
/// amount_minor, currency.
fn columns_for_entries(legs: &[Leg]) -> (Vec<Uuid>, Vec<String>, Vec<i64>, Vec<String>) {
    let mut account_ids = Vec::with_capacity(legs.len());
    let mut directions = Vec::with_capacity(legs.len());
    let mut amounts = Vec::with_capacity(legs.len());
    let mut currencies = Vec::with_capacity(legs.len());
    for leg in legs {
        account_ids.push(leg.account_id);
        directions.push(direction_as_stored(leg.direction).to_owned());
        amounts.push(leg.amount_minor);
        currencies.push(leg.currency.clone());
    }
    (account_ids, directions, amounts, currencies)
}

/// The coalesced deltas, transposed into the parallel arrays the
/// statement's delta `unnest` binds — and the arrays arrive **already
/// sorted**, because `coalesce` returns a `BTreeMap` keyed
/// `(account_id, currency)`. That is not presentation: on this path the sort
/// is a compile-time guarantee of the Rust, and the statement's own
/// `ORDER BY` is a **second** line of defence rather than the only one —
/// removing it leaves the suite green here, where removing the batched
/// statement's sort fails the concurrency test 4 of 4 with deadlocks
/// reaching callers as 500s (ADR-0018; the roadmap's M2 records both halves).
/// *(This read "that property is unpinned until M2's concurrency proof". The
/// proof landed on 2026-09-01 with the batching it waited on, and what it
/// pinned is a DISAGREEMENT over the order rather than the clause's absence
/// — see the `ORDER BY`'s own note in [`CLAIM_AND_APPEND`]'s doc, which was
/// updated in that commit while this one was not.)*
struct DeltaColumns {
    account_ids: Vec<Uuid>,
    currencies: Vec<String>,
    inputs: Vec<i64>,
    outputs: Vec<i64>,
    legs: Vec<i64>,
}

fn columns_for_deltas(deltas: &BTreeMap<(Uuid, String), Delta>) -> DeltaColumns {
    let mut columns = DeltaColumns {
        account_ids: Vec::with_capacity(deltas.len()),
        currencies: Vec::with_capacity(deltas.len()),
        inputs: Vec::with_capacity(deltas.len()),
        outputs: Vec::with_capacity(deltas.len()),
        legs: Vec::with_capacity(deltas.len()),
    };
    for ((account_id, currency), delta) in deltas {
        columns.account_ids.push(*account_id);
        columns.currencies.push(currency.clone());
        columns.inputs.push(delta.input);
        columns.outputs.push(delta.output);
        columns.legs.push(delta.legs);
    }
    columns
}

/// Each member's claim, transposed into the parallel arrays
/// [`CLAIM_AND_APPEND_BATCH`] binds. Borrowed, not copied: a batch is
/// assembled from callers still waiting, and their commands outlive the
/// statement.
///
/// The member ORDINAL is not a column here. It is the position in these
/// arrays, and the statement reads it with `WITH ORDINALITY` — so a member's
/// identity inside the statement is exactly its index in this slice, and
/// [`columns_for_member_legs`] must number from the same slice or a leg
/// would attach to a stranger's transaction.
struct ClaimColumns<'a> {
    tenant_ids: Vec<&'a str>,
    idempotency_keys: Vec<&'a str>,
    hashes: Vec<&'a [u8]>,
    payloads: Vec<&'a serde_json::Value>,
    /// The caller's own effective date, PER MEMBER. The single statement
    /// binds one scalar because it posts one command; a batch posts N
    /// independent ones and each carries its own claim about when money
    /// moved — the writer will not average them or invent one. `None` is
    /// unreachable on this path (the constructor requires a date outside the
    /// reversal shape, and
    /// [`refuse_a_member_the_batch_cannot_carry`] refuses reversals), and
    /// `ledger_events.effective_at`'s NOT NULL is the backstop if it ever is.
    effective_at: Vec<Option<OffsetDateTime>>,
}

fn columns_for_claims<'a>(members: &'a [BatchMember<'a>]) -> ClaimColumns<'a> {
    let mut columns = ClaimColumns {
        tenant_ids: Vec::with_capacity(members.len()),
        idempotency_keys: Vec::with_capacity(members.len()),
        hashes: Vec::with_capacity(members.len()),
        payloads: Vec::with_capacity(members.len()),
        effective_at: Vec::with_capacity(members.len()),
    };
    for member in members {
        columns.tenant_ids.push(member.command.tenant_id());
        columns
            .idempotency_keys
            .push(member.command.idempotency_key());
        columns.hashes.push(member.hash);
        columns.payloads.push(member.payload);
        columns.effective_at.push(member.command.effective_at());
    }
    columns
}

/// The three columns [`STORED_RESULT_BATCH`] asks about, per member: whose
/// key, and the hash that decides whether the stored result belongs to THIS
/// body. A member is asked about by position, exactly as it is claimed by
/// position — the lookup reads its ordinal off `WITH ORDINALITY` and orders
/// by it, so answer *i* is member *i*'s and no caller can be handed
/// another's transaction.
struct KeyColumns<'a> {
    tenant_ids: Vec<&'a str>,
    idempotency_keys: Vec<&'a str>,
    hashes: Vec<&'a [u8]>,
}

fn columns_for_keys<'a>(members: &'a [BatchMember<'a>]) -> KeyColumns<'a> {
    let mut columns = KeyColumns {
        tenant_ids: Vec::with_capacity(members.len()),
        idempotency_keys: Vec::with_capacity(members.len()),
        hashes: Vec::with_capacity(members.len()),
    };
    for member in members {
        columns.tenant_ids.push(member.command.tenant_id());
        columns
            .idempotency_keys
            .push(member.command.idempotency_key());
        columns.hashes.push(member.hash);
    }
    columns
}

/// Every member's legs, flattened into one set of parallel arrays with two
/// ordinals in front: which member the leg belongs to, and where it sits in
/// that member's own posting order. Together they are what keeps a batch
/// from becoming a mush — the statement groups deltas by member ordinal to
/// gate each member independently, and numbers entries
/// `ORDER BY (member, position)` so each account's run inside the batch is
/// still the order the callers posted in.
///
/// Both ordinals are 1-based, because `WITH ORDINALITY` numbers the claim
/// arrays from 1 and the member ordinal has to join against that.
struct MemberLegColumns<'a> {
    member_ordinals: Vec<i32>,
    leg_positions: Vec<i32>,
    account_ids: Vec<Uuid>,
    directions: Vec<&'static str>,
    amounts: Vec<i64>,
    currencies: Vec<&'a str>,
}

fn columns_for_member_legs<'a>(members: &'a [BatchMember<'a>]) -> MemberLegColumns<'a> {
    let legs = members.iter().map(|member| member.append.legs.len()).sum();
    let mut columns = MemberLegColumns {
        member_ordinals: Vec::with_capacity(legs),
        leg_positions: Vec::with_capacity(legs),
        account_ids: Vec::with_capacity(legs),
        directions: Vec::with_capacity(legs),
        amounts: Vec::with_capacity(legs),
        currencies: Vec::with_capacity(legs),
    };
    for (member_ordinal, member) in (1..).zip(members) {
        for (leg_position, leg) in (1..).zip(&member.append.legs) {
            columns.member_ordinals.push(member_ordinal);
            columns.leg_positions.push(leg_position);
            columns.account_ids.push(leg.account_id);
            columns.directions.push(direction_as_stored(leg.direction));
            columns.amounts.push(leg.amount_minor);
            columns.currencies.push(leg.currency.as_str());
        }
    }
    columns
}

/// Statement A's SQL, whole — the CTE pipeline reads best as one literal,
/// its CTE names narrating the append in order. What each stage holds:
///
/// - `supersede_target` reads the one transaction a RESOLVING or REVERSING
///   command names (`COALESCE` picks the sole pointer — the constructor
///   holds ck_txn__not_both's rule, so at most one is bound) — the
///   diagnosis the final `SELECT` carries back. Its `target_already_superseded`
///   tests BOTH pointers, matching the schema's retirement rule
///   (`recon_pending_bridge` retires a pending on resolved OR reversed), so
///   a voided pending refuses a resolution and a resolved one refuses the
///   void. Honestly stated: this both-pointer read is a deliberately
///   redundant FAST PATH — narrow it to one pointer and the insert trips
///   `uq_txn__one_supersession`, whose mapping produces the identical wire
///   answer, so no test can hold this half red in isolation (ADR-0016's
///   cost list records why it stays anyway: an ordinary refusal beats an
///   aborted transaction on the common case);
/// - `effective` is the transaction's date, decided once: the caller's when
///   given, else the target's (ADR-0016's soft convention — a reversal may
///   defer to the date it un-does; a caller-supplied date BELOW the
///   target's is accepted, cost recorded in the ADR). The trailing `now()`
///   arm is reachable only when a reversal names a missing target, a path
///   the gate refuses and the service rolls back — it never commits;
/// - `claimed` claims the idempotency key (`ON CONFLICT DO NOTHING`), and
///   every dependent insert selects `FROM` it — so when the key is already
///   held, zero rows come back and NONE of the append ran;
/// - `txn` inserts the transaction — gated, for a resolution, on the
///   target being pending and unsuperseded, and, for a reversal, on it
///   being an ordinary posting (`kind = 'posting'`: reversing a
///   period_close would un-close earnings against its standing checkpoint)
///   that neither carries a pointer itself (reversing a resolution strands
///   its pending forever — ADR-0016's worked failure) nor is already
///   superseded. The status arm a reader might expect is total: the enum
///   holds exactly 'pending' and 'posted', and both are reversible (pending
///   = the void). The semantic linkage no foreign key holds (ADR-0004's
///   −49,223 counterexample) lives in this WHERE. The gate withholds only
///   this insert and the entries hanging off it — `delta` and `balance`
///   select `FROM claimed`, so a refused supersession still ran the
///   balance upserts, uncommitted, which is why the service rolls back
///   BEFORE answering the refusal;
/// - `mirror_leg` is the reversal's derivation (ADR-0016): the POSTED
///   target's entries with directions flipped — contra, never storno:
///   amounts stay positive and gross turnover inflates, the recorded cost —
///   each leg's `seq_offset` counted back from its account's last position
///   exactly as the Rust plan counts a caller's legs. A PENDING target
///   derives nothing: the void is the marker transaction alone;
/// - `mirror_delta` coalesces the mirror legs per (account, currency), the
///   SQL twin of the plan's `coalesce`;
/// - `delta` is whichever side exists: the caller-planned arrays (empty for
///   a reversal) unioned with the derived mirror deltas (empty for
///   everything else), both gated on the claim;
/// - `striped` joins `ledger_accounts` for the frozen identity columns the
///   upsert copies anyway, and — on the way past — picks the STRIPE each
///   delta is written to: this writer's affinity
///   ([`stripe_affinity_of`]) modulo the account's own `stripe_count`.
///   Selection therefore costs no extra round trip, and it happens once
///   per statement, AFTER the coalesce, which is worth +7.6% for a
///   volatile key and nothing at all for a constant one — taken because it
///   is free and strictly better (ADR-0018 §1). The join doubles as the
///   existence check it was before: an unknown account, or a currency the
///   account does not hold, matches nothing here and comes back as a
///   `NULL` counter for the service to refuse. `AS MATERIALIZED` is
///   LOAD-BEARING, not stylistic: PostgreSQL inlines a single-reference
///   CTE by default, and the stripe expression is read twice below — as
///   the inserted value and as the `ORDER BY` key the lock ordering hangs
///   on. Inlined, a volatile selection expression may be evaluated
///   independently for the two, inserting at one stripe while sorting as
///   another and silently voiding the deadlock defense; the barrier is
///   stated here rather than depended on as a planner rule. The bound
///   affinity arrives non-negative — [`stripe_affinity_of`] masks it, and
///   is unit-tested at the index that wraps to `i32::MIN` — so the modulo
///   is the whole of the expression: a second mask here would be a check
///   no test could hold red, which is the shape this project refuses;
/// - `balance` upserts each delta's row, one per stripe selected above,
///   and hands the chosen stripe back beside the counter so the entries
///   need not recompute it (`fk_entries__stripe` makes a mismatch a
///   refused write rather than silent drift). The row locks are taken in
///   `(account_id, currency, stripe)` order, held by the `ORDER BY` on the
///   `SELECT` feeding the upsert (deterministic lock ordering, batch-wide
///   — ADR-0013, spike 003); the sort follows the COUNTER's grain, which
///   is the stripe's, for the same reason gaplessness does. **What this
///   clause is pinned against is a DISAGREEMENT, not its own absence**, and
///   the distinction is measured rather than assumed: the e2e suite's
///   `concurrency` module — sustained concurrent writers over eight
///   accounts, both order sources — fails on every run when this sort is
///   made one two writers can disagree about, and passes when it is merely
///   deleted, because the plan then still happens to emit the contended
///   rows in one agreed order. That is the spike harness's own finding
///   (`sql.rs`, and the reason its descending model exists), and it is why
///   the clause stays: an agreement the planner reaches by accident is not
///   one to build a deadlock defense on;
/// - `entry` lands the entries — planned and mirror alike — through one
///   `unnest`-fed insert (within 2% of `COPY` on this table, ADR-0013 §5),
///   numbered `last_seq - seq_offset` beside the counter the upsert
///   returned, on the stripe that counter belongs to;
/// - the final `SELECT` anchors on the CLAIMED ROW, not the deltas
///   (ADR-0016's return-shape requirement): a zero-delta void still answers
///   one row, so zero rows means exactly "the key was already held" and
///   never "nothing needed upserting". Each delta then rides one row
///   (`LEFT JOIN`), so a missing account is a row with a `NULL` counter —
///   and a gated supersession is rows with a `NULL` transaction id plus the
///   target's diagnosis — never a silently shorter answer.
const CLAIM_AND_APPEND: &str = "WITH supersede_target AS (
         SELECT x.effective_at, x.status, x.kind,
                (x.resolves_id IS NOT NULL OR x.reverses_id IS NOT NULL) AS is_superseding,
                EXISTS (SELECT 1 FROM ledger_transactions rr
                        WHERE rr.tenant_id = $1
                          AND (rr.resolves_id = x.id OR rr.reverses_id = x.id))
                    AS target_already_superseded
         FROM ledger_transactions x
         WHERE x.tenant_id = $1 AND x.id = COALESCE($17::uuid, $18::uuid)
     ),
     effective AS (
         SELECT COALESCE($5::timestamptz,
                         (SELECT effective_at FROM supersede_target),
                         now()) AS at
     ),
     claimed AS (
         INSERT INTO ledger_events
                (tenant_id, kind, source, idempotency_key, idempotency_hash,
                 payload, effective_at)
         SELECT $1, 'posting', 'api', $2, $3, $4, e.at
         FROM effective e
         ON CONFLICT (tenant_id, idempotency_key) DO NOTHING
         RETURNING id
     ),
     txn AS (
         INSERT INTO ledger_transactions
                (tenant_id, event_id, kind, status, effective_at,
                 resolves_id, reverses_id)
         SELECT $1, c.id, 'posting', $16::ledger_txn_status,
                (SELECT at FROM effective), $17, $18
         FROM claimed c
         WHERE ($17::uuid IS NULL AND $18::uuid IS NULL)
            OR ($17::uuid IS NOT NULL
                AND EXISTS (SELECT 1 FROM supersede_target g
                            WHERE g.status = 'pending'
                              AND NOT g.target_already_superseded))
            OR ($18::uuid IS NOT NULL
                AND EXISTS (SELECT 1 FROM supersede_target g
                            WHERE g.kind = 'posting'
                              AND NOT g.is_superseding
                              AND NOT g.target_already_superseded))
         RETURNING id
     ),
     mirror_leg AS (
         SELECT e.account_id,
                CASE e.direction WHEN 'debit' THEN 'credit' ELSE 'debit' END
                    AS direction,
                e.amount_minor, e.currency::text AS currency,
                (count(*) OVER (PARTITION BY e.account_id, e.currency)
                 - row_number() OVER (PARTITION BY e.account_id, e.currency
                                      ORDER BY e.account_seq)) AS seq_offset
         FROM ledger_entries e
         WHERE $18::uuid IS NOT NULL
           AND e.tenant_id = $1 AND e.transaction_id = $18
           AND (SELECT status FROM supersede_target) = 'posted'
     ),
     mirror_delta AS (
         SELECT account_id, currency,
                COALESCE(SUM(amount_minor) FILTER (WHERE direction = 'debit'),
                         0)::bigint AS input,
                COALESCE(SUM(amount_minor) FILTER (WHERE direction = 'credit'),
                         0)::bigint AS output,
                COUNT(*) AS legs
         FROM mirror_leg
         GROUP BY account_id, currency
     ),
     delta AS (
         SELECT d.account_id, d.currency, d.input, d.output, d.legs
         FROM claimed c
         CROSS JOIN unnest($6::uuid[], $7::text[], $8::bigint[], $9::bigint[],
                           $10::bigint[])
              AS d(account_id, currency, input, output, legs)
         UNION ALL
         SELECT m.account_id, m.currency, m.input, m.output, m.legs
         FROM claimed c
         CROSS JOIN mirror_delta m
     ),
     striped AS MATERIALIZED (
         SELECT a.tenant_id, a.id AS account_id, a.currency,
                a.owner_type, a.owner_id_key, a.purpose, a.category,
                a.normal_balance, d.input, d.output, d.legs,
                ($19::int % a.stripe_count)::smallint AS stripe
         FROM delta d
         JOIN ledger_accounts a
           ON a.tenant_id = $1 AND a.id = d.account_id AND a.currency = d.currency
     ),
     balance AS (
         INSERT INTO ledger_account_balances
                (tenant_id, account_id, currency, stripe,
                 owner_type, owner_id_key, purpose, category, normal_balance,
                 input, output, last_seq)
         SELECT s.tenant_id, s.account_id, s.currency, s.stripe,
                s.owner_type, s.owner_id_key, s.purpose, s.category, s.normal_balance,
                s.input, s.output, s.legs
         FROM striped s
         ORDER BY s.account_id, s.currency, s.stripe
         ON CONFLICT (tenant_id, account_id, currency, stripe) DO UPDATE
         SET input      = ledger_account_balances.input + EXCLUDED.input,
             output     = ledger_account_balances.output + EXCLUDED.output,
             last_seq   = ledger_account_balances.last_seq + EXCLUDED.last_seq,
             updated_at = now()
         RETURNING account_id, currency, stripe, last_seq
     ),
     entry AS (
         INSERT INTO ledger_entries
                (tenant_id, transaction_id, account_id, direction, amount_minor,
                 currency, stripe, account_seq, effective_at)
         SELECT $1, t.id, l.account_id, l.direction::ledger_direction, l.amount_minor,
                l.currency, b.stripe, b.last_seq - l.seq_offset, (SELECT at FROM effective)
         FROM txn t
         CROSS JOIN (SELECT l.account_id, l.direction, l.amount_minor,
                            l.currency, l.seq_offset
                     FROM unnest($11::uuid[], $12::text[], $13::bigint[],
                                 $14::text[], $15::bigint[])
                          AS l(account_id, direction, amount_minor, currency,
                               seq_offset)
                     UNION ALL
                     SELECT account_id, direction, amount_minor, currency,
                            seq_offset
                     FROM mirror_leg) l
         JOIN balance b ON b.account_id = l.account_id AND b.currency = l.currency
     )
     SELECT c.id AS event_id, t.id AS transaction_id,
            d.account_id, d.currency, b.last_seq,
            g.status::text AS target_status, g.kind AS target_kind,
            g.is_superseding AS target_is_superseding,
            g.target_already_superseded
     FROM claimed c
     LEFT JOIN txn t ON true
     LEFT JOIN delta d ON true
     LEFT JOIN balance b ON b.account_id = d.account_id AND b.currency = d.currency
     LEFT JOIN supersede_target g ON true
     ORDER BY d.account_id, d.currency";

/// Statement A, batched — the same append for N independent commands in ONE
/// statement (ADR-0018 §3). Read it beside [`CLAIM_AND_APPEND`]: same
/// pipeline, same stripe selection, same ordered upsert, with a MEMBER
/// ORDINAL threaded through every stage and the walk-back moved from Rust
/// into a window function. Its SQL is spike 022's `batched()`, measured
/// across 302 configurations against the ten-check oracle.
///
/// **Posted postings only** (ADR-0018 §4), and that is a scope decision, not
/// an omission: status is the literal `'posted'`, there is no `resolves_id`,
/// no `reverses_id`, no supersede gate and no derived mirror. Carrying them
/// would mean reapplying per member, inside SQL, what `plan_append` decides
/// in pure Rust — including ADR-0010's ruling that THE CACHE MEANS POSTED,
/// which lives in `postings.rs` "where it is pure and testable, not in the
/// statement". The caller routes a pending, resolving or reversing command
/// to [`CLAIM_AND_APPEND`]; [`refuse_a_member_the_batch_cannot_carry`] is
/// what makes a routing mistake loud instead of silently posting a claim.
///
/// **Tenant is a per-member array, not a scalar.** A batch is
/// tenant-homogeneous in practice — it is 8% faster that way, because what
/// pays is account OVERLAP inside the batch and homogeneity is the cheapest
/// way to guarantee it (ADR-0018 §3) — but homogeneity is the assembler's
/// policy, not this statement's invariant, so every grouping key here is
/// `(tenant_id, account_id, currency)` and nothing breaks if the policy
/// changes.
///
/// What each stage holds:
///
/// - `member` is the batch itself: one row per member, its ordinal read off
///   `WITH ORDINALITY` — so a member's identity inside the statement is its
///   position in the bound arrays, and every stage below joins on it.
///   `effective_at` is per member for the same reason tenant is: N
///   independent commands each carry their own claim about when money moved;
/// - `member_leg` is every member's legs, flattened, each still carrying
///   which member it came from and where it sat in that member's posting
///   order;
/// - `member_delta` coalesces per `(member, account, currency)` — the SQL
///   twin of `postings::coalesce`, at MEMBER grain because the gate below
///   has to judge each member on its own accounts;
/// - `member_account` asks, once, whether each of those accounts exists
///   holding that currency — the single statement's existence check, which
///   there is the upsert's own join and here has to be its own stage because
///   it must be answered BEFORE anything is claimed;
/// - `admissible` is the gate: a member all of whose accounts exist. **It
///   sits ABOVE the claim, and that placement is the single most important
///   line in this statement.** Gate the downstream inserts instead and the
///   refused member's `ledger_events` row COMMITS with its innocent
///   neighbours: its idempotency key is burned permanently, its retry finds
///   the claim held, the replay lookup finds an event joined to no
///   transaction, and the caller is answered
///   `transaction_id: null, replayed: true` — which ADR-0013 says is the
///   legitimate shape for the majority of accepted operations. **The refusal
///   becomes indistinguishable from success, forever.** And no
///   reconciliation check would catch it: none of the ten reads
///   `ledger_events`, so an orphaned event is invisible to
///   `SELECT * FROM reconciliation` by construction — the oracle reported
///   ten zeros on a book carrying this defect. It was found by counting
///   events directly, and that is how it stays pinned (ADR-0018 §3);
/// - `unknown_account` names the account the gate refused a member for —
///   the first in account order, matching the account the single path's
///   refusal names — so the answer carries a refusal the caller can act on
///   rather than a bare "no";
/// - `key_held_by_an_earlier_write` is what keeps the two paths' PRECEDENCE
///   one precedence. On the single path the claim is asked first: a key an
///   earlier caller holds returns nothing from `ON CONFLICT DO NOTHING` and
///   the account check never runs, so the caller hears `key_reused`. Here
///   the gate is above the claim — which is what makes a refused member's
///   key survive, the defect this statement exists to not have — so a
///   withheld member never reaches the claim to find out. This stage asks
///   for it, and ONLY for the members the gate withheld: an admissible
///   member's fate is the claim's own, and a refused member is the
///   exceptional case, so no batch pays an index probe it did not earn.
///   Honestly bounded: it sees COMMITTED claims, where the single path's
///   `ON CONFLICT DO NOTHING` also blocks on an uncommitted rival. A member
///   whose key is being claimed right now by a transaction that has not
///   committed is still refused by name here, and hears `key_reused` on its
///   retry;
/// - `claimed` claims every ADMISSIBLE member's idempotency key in one
///   `INSERT … ON CONFLICT DO NOTHING`, and every dependent insert selects
///   `FROM` it. **Two members sharing one key abort the whole batch**: the
///   conflict claims one event, the join back by key fans it to both
///   ordinals, two transactions land on one `event_id`,
///   `uq_txn__one_per_event` raises `23505` and nothing is written —
///   measured at 0 events / 0 transactions / 0 entries. Accepted, because it
///   fails CLOSED and costs one retry; the alternative is per-ordinal
///   joining plus a replay path for the loser (ADR-0018 §3). **And this is
///   also where head-of-line blocking lives**: `ON CONFLICT DO NOTHING`
///   waits on a concurrent UNCOMMITTED insert of the same key, so one held
///   claim stalls every member — measured, a 1,500 ms held claim stalled a
///   batch of 25 for 1,519.5 ms. It is the price of one statement, and it is
///   not fixed;
/// - `proceeding` is the members that both passed the gate and won their
///   key, rejoined to their ordinals — the batch's real working set, and the
///   only thing `delta`, `leg_stripe` and `numbered` read;
/// - `txn` inserts one posted transaction per proceeding member;
/// - `delta` re-coalesces ACROSS members: one row per
///   `(tenant, account, currency)` however many members touched it. This is
///   the whole reason a batch beats N statements — six members sharing one
///   tenant's house pair cost ONE upsert — and it is also where the one new
///   failure mode lives: `plan_append` refuses per-member overflow in Rust
///   with `checked_add`, but this sum re-adds at `bigint`, so a CROSS-MEMBER
///   total can overflow where no member does. `22003`, whole batch,
///   **ungated** — recorded as a cost rather than hidden (ADR-0018 §3);
/// - `striped` picks the stripe, once, AFTER the coalesce — worth +7.6% for
///   a volatile key and nothing for a constant one, taken because it is free
///   and strictly better (ADR-0018 §1). Same expression and same
///   `AS MATERIALIZED` reasoning as [`CLAIM_AND_APPEND`]'s: the stripe is
///   read twice below, as the inserted value and as the `ORDER BY` key the
///   lock ordering hangs on, and an inlined CTE may evaluate a volatile
///   expression independently for the two — inserting at one stripe while
///   sorting as another, silently voiding the deadlock defense;
/// - `leg_stripe` carries the chosen stripe back down to LEG grain, because
///   the counter it will be numbered against is per stripe;
/// - `balance` upserts each coalesced delta, **ordered by
///   `(tenant_id, account_id, currency, stripe)`** — the counter's own
///   grain, since `pk_balances` carries the stripe, with tenant leading
///   because it leads every grouping key in a statement whose tenant is per
///   member. This sort is LOAD-BEARING here in a way the single path's is
///   not: with it merely REMOVED, the batched path measured **833 deadlocks
///   per 1,000 statements** in the spike, and the e2e suite's `concurrency`
///   module fails on every run — 95 to 218 deadlocks, reaching callers as
///   500s. Deleting the single path's sort leaves that suite green;
///   deleting this one does not;
/// - `numbered` is ADR-0013's walk-back, moved into a window function
///   because the offsets now have to be counted across members that never
///   saw each other. It partitions on
///   `(tenant, account, currency, stripe)` — the counter's grain, not the
///   account's — and orders by `(member ordinal, leg position)`, so each
///   account's run inside the batch follows the order the callers posted in.
///   The recorded cost: an invariant that was unit-tested Rust
///   (`postings::offsets_back_from_last_seq`) is SQL here, and only an
///   integration test can see it;
/// - `entry` lands every proceeding member's entries in one insert, numbered
///   `last_seq - seq_offset` beside the counter its own stripe's upsert
///   returned;
/// - the final `SELECT` anchors on `member`, never on what was written, so
///   there is **exactly one row per member, in the order given** — a gated
///   member and a member whose key was already held both come back as a row,
///   never as a silently shorter answer. `ORDER BY m.ord` is what makes the
///   answer positional; [`outcome_for_member`] reads each row in turn.
const CLAIM_AND_APPEND_BATCH: &str = "WITH member AS (
         SELECT m.ord::int AS ord, m.tenant_id, m.idempotency_key, m.hash,
                m.payload, m.effective_at
         FROM unnest($1::text[], $2::text[], $3::bytea[], $4::jsonb[],
                     $5::timestamptz[]) WITH ORDINALITY
              AS m(tenant_id, idempotency_key, hash, payload, effective_at, ord)
     ),
     member_leg AS (
         SELECT l.ord, l.leg_ord, m.tenant_id, l.account_id, l.direction,
                l.amount_minor, l.currency
         FROM unnest($6::int[], $7::int[], $8::uuid[], $9::text[], $10::bigint[],
                     $11::text[])
              AS l(ord, leg_ord, account_id, direction, amount_minor, currency)
         JOIN member m ON m.ord = l.ord
     ),
     member_delta AS (
         SELECT ord, tenant_id, account_id, currency,
                COALESCE(SUM(amount_minor) FILTER (WHERE direction = 'debit'),
                         0)::bigint AS input,
                COALESCE(SUM(amount_minor) FILTER (WHERE direction = 'credit'),
                         0)::bigint AS output,
                COUNT(*) AS legs
         FROM member_leg
         GROUP BY ord, tenant_id, account_id, currency
     ),
     member_account AS (
         SELECT md.ord, md.account_id, md.currency, (a.id IS NULL) AS account_missing
         FROM member_delta md
         LEFT JOIN ledger_accounts a
                ON a.tenant_id = md.tenant_id AND a.id = md.account_id
               AND a.currency = md.currency
     ),
     admissible AS (
         SELECT ord
         FROM member_account
         GROUP BY ord
         HAVING COUNT(*) FILTER (WHERE account_missing) = 0
     ),
     unknown_account AS (
         SELECT DISTINCT ON (ord) ord, account_id, currency
         FROM member_account
         WHERE account_missing
         ORDER BY ord, account_id, currency
     ),
     key_held_by_an_earlier_write AS (
         SELECT m.ord
         FROM member m
         LEFT JOIN admissible ad ON ad.ord = m.ord
         JOIN ledger_events e ON e.tenant_id = m.tenant_id
                             AND e.idempotency_key = m.idempotency_key
         WHERE ad.ord IS NULL
     ),
     claimed AS (
         INSERT INTO ledger_events
                (tenant_id, kind, source, idempotency_key, idempotency_hash,
                 payload, effective_at)
         SELECT m.tenant_id, 'posting', 'api', m.idempotency_key, m.hash,
                m.payload, m.effective_at
         FROM member m
         JOIN admissible ad ON ad.ord = m.ord
         ON CONFLICT (tenant_id, idempotency_key) DO NOTHING
         RETURNING tenant_id, id, idempotency_key
     ),
     proceeding AS (
         SELECT c.id AS event_id, m.ord, m.tenant_id, m.effective_at
         FROM claimed c
         JOIN member m ON m.tenant_id = c.tenant_id
                      AND m.idempotency_key = c.idempotency_key
     ),
     txn AS (
         INSERT INTO ledger_transactions
                (tenant_id, event_id, kind, status, effective_at)
         SELECT p.tenant_id, p.event_id, 'posting', 'posted'::ledger_txn_status,
                p.effective_at
         FROM proceeding p
         RETURNING tenant_id, id, event_id
     ),
     delta AS (
         SELECT md.tenant_id, md.account_id, md.currency,
                SUM(md.input) AS input, SUM(md.output) AS output,
                SUM(md.legs) AS legs
         FROM member_delta md
         JOIN proceeding p ON p.ord = md.ord
         GROUP BY md.tenant_id, md.account_id, md.currency
     ),
     striped AS MATERIALIZED (
         SELECT d.tenant_id, d.account_id, d.currency, d.input, d.output, d.legs,
                a.owner_type, a.owner_id_key, a.purpose, a.category,
                a.normal_balance,
                ($12::int % a.stripe_count)::smallint AS stripe
         FROM delta d
         JOIN ledger_accounts a
           ON a.tenant_id = d.tenant_id AND a.id = d.account_id
          AND a.currency = d.currency
     ),
     leg_stripe AS (
         SELECT md.ord, s.tenant_id, s.account_id, s.currency, s.stripe
         FROM member_delta md
         JOIN proceeding p ON p.ord = md.ord
         JOIN striped s ON s.tenant_id = md.tenant_id
                       AND s.account_id = md.account_id
                       AND s.currency = md.currency
     ),
     balance AS (
         INSERT INTO ledger_account_balances
                (tenant_id, account_id, currency, stripe,
                 owner_type, owner_id_key, purpose, category, normal_balance,
                 input, output, last_seq)
         SELECT s.tenant_id, s.account_id, s.currency, s.stripe,
                s.owner_type, s.owner_id_key, s.purpose, s.category, s.normal_balance,
                s.input, s.output, s.legs
         FROM striped s
         ORDER BY s.tenant_id, s.account_id, s.currency, s.stripe
         ON CONFLICT (tenant_id, account_id, currency, stripe) DO UPDATE
         SET input      = ledger_account_balances.input + EXCLUDED.input,
             output     = ledger_account_balances.output + EXCLUDED.output,
             last_seq   = ledger_account_balances.last_seq + EXCLUDED.last_seq,
             updated_at = now()
         RETURNING tenant_id, account_id, currency, stripe, last_seq
     ),
     numbered AS (
         SELECT t.id AS transaction_id, ml.tenant_id, ml.account_id, ml.direction,
                ml.amount_minor, ml.currency, ls.stripe, p.effective_at,
                (COUNT(*)      OVER (PARTITION BY ml.tenant_id, ml.account_id,
                                                  ml.currency, ls.stripe)
                 - ROW_NUMBER() OVER (PARTITION BY ml.tenant_id, ml.account_id,
                                                   ml.currency, ls.stripe
                                      ORDER BY ml.ord, ml.leg_ord)) AS seq_offset
         FROM member_leg ml
         JOIN proceeding p ON p.ord = ml.ord
         JOIN txn t ON t.tenant_id = p.tenant_id AND t.event_id = p.event_id
         JOIN leg_stripe ls ON ls.ord = ml.ord AND ls.tenant_id = ml.tenant_id
                           AND ls.account_id = ml.account_id
                           AND ls.currency = ml.currency
     ),
     entry AS (
         INSERT INTO ledger_entries
                (tenant_id, transaction_id, account_id, direction, amount_minor,
                 currency, stripe, account_seq, effective_at)
         SELECT n.tenant_id, n.transaction_id, n.account_id,
                n.direction::ledger_direction, n.amount_minor, n.currency,
                n.stripe, b.last_seq - n.seq_offset, n.effective_at
         FROM numbered n
         JOIN balance b ON b.tenant_id = n.tenant_id AND b.account_id = n.account_id
                       AND b.currency = n.currency AND b.stripe = n.stripe
     )
     SELECT c.id AS event_id, t.id AS transaction_id,
            (ad.ord IS NOT NULL) AS admissible,
            (h.ord IS NOT NULL) AS key_already_held,
            u.account_id AS unknown_account_id, u.currency AS unknown_currency
     FROM member m
     LEFT JOIN admissible ad ON ad.ord = m.ord
     LEFT JOIN key_held_by_an_earlier_write h ON h.ord = m.ord
     LEFT JOIN unknown_account u ON u.ord = m.ord
     LEFT JOIN claimed c ON c.tenant_id = m.tenant_id
                        AND c.idempotency_key = m.idempotency_key
     LEFT JOIN proceeding p ON p.ord = m.ord
     LEFT JOIN txn t ON t.tenant_id = p.tenant_id AND t.event_id = p.event_id
     ORDER BY m.ord";

/// Statement B, batched — the stored result of N already-claimed keys in ONE
/// lookup, so a batch carrying any replay costs a fourth round trip rather
/// than one per replayed member.
///
/// It is [`Repository::stored_result`]'s statement with the scalars made
/// arrays, and it keeps that statement's two load-bearing properties. The
/// HASH IS IN THE JOIN, never a returned column to compare: a key reused
/// with a different body matches no event and comes back as a `NULL` id, so
/// a caller that forgets to compare gets nothing instead of the wrong stored
/// result (ADR-0013 §2). And the answer ANCHORS ON THE MEMBERS, not on what
/// was found — one row per member, in the order given, `ORDER BY m.ord` —
/// so a member with no stored result is a row with `NULL`s and never a
/// silently shorter answer that would shift every member after it onto
/// somebody else's transaction.
const STORED_RESULT_BATCH: &str = "SELECT e.id AS event_id, t.id AS transaction_id
     FROM unnest($1::text[], $2::text[], $3::bytea[]) WITH ORDINALITY
          AS m(tenant_id, idempotency_key, hash, ord)
     LEFT JOIN ledger_events e
            ON e.tenant_id = m.tenant_id AND e.idempotency_key = m.idempotency_key
           AND e.idempotency_hash = m.hash
     LEFT JOIN ledger_transactions t
            ON t.tenant_id = e.tenant_id AND t.event_id = e.id
     ORDER BY m.ord";

/// The chart's own row for one purpose (ADR-0021) — the three columns
/// `ledger_accounts` copies, read so the writer can bind them rather than
/// letting a caller state them.
///
/// `account_types` is deployment-global and carries no `tenant_id`, so it has
/// no policy and the tenant fence does not reach it — the same standing
/// `chart_versions` has on the read path. No row back is
/// `account_type_unknown`, which the service names.
const CHART_TRIPLE: &str = "SELECT t.category::text AS category,
            t.normal_balance::text AS normal_balance,
            t.counterparty_scope AS counterparty_scope
         FROM account_types t
        WHERE t.code = $1";

/// Statement A for an opening: the claim, with the account insert riding on
/// it — the same shape [`CLAIM_AND_APPEND`] has, one insert instead of an
/// append, and ADR-0021's *"in the same database transaction"* held as ONE
/// statement rather than as two the caller must remember to pair.
///
/// - `claimed` claims the idempotency key (`ON CONFLICT DO NOTHING`) in the
///   same index a posting claims in, and the account insert selects `FROM`
///   it — so when the key is already held, zero rows come back and NOTHING
///   here ran. The key space is shared with postings deliberately (one
///   `uq_events__key` per tenant): the same key used for both operations is
///   `idempotency_key_reused`, because the two canonical byte forms carry
///   different version tags and so hash differently — never a posting
///   replayed as an account;
/// - `effective_at` is `now()`, and it is the one value here the caller does
///   not supply. An opening has no effective date to claim: it moves no
///   money, so there is no instant for it to be *deemed to have happened* at,
///   and the column is `NOT NULL`. The RECORDED axis is what an opening has,
///   and `recorded_at` and `xact_id` are its defaults;
/// - `opened` inserts the account. The three chart columns are BOUND from
///   [`CHART_TRIPLE`]'s answer rather than joined here: the derivation is the
///   writer's decision and `fk_accounts__type` / `fk_accounts__scope` are
///   what verify it, so a join would be a second opinion on a question
///   already asked — and one taken at a different instant than the check;
/// - `stripe_count` and `metadata` coalesce their absences. The literals
///   restate the column defaults, which a `SELECT`-fed `INSERT` has no
///   `DEFAULT` keyword to reach; the schema is still the authority and this
///   is the one place the two are written twice;
/// - `owner_id_key` is never named: it is `GENERATED ALWAYS`, and naming a
///   generated column is a refused insert;
/// - the final `SELECT` anchors on the CLAIMED row, exactly as the posting
///   statement's does, so zero rows means "the key was already held" and
///   nothing else.
///
/// What arrives as an ERROR rather than as rows is the uniqueness race —
/// `23505` on `uq_accounts__owned` or `uq_accounts__house`, classified by
/// [`refusal_from_the_account_race`].
const CLAIM_AND_OPEN_ACCOUNT: &str = "WITH claimed AS (
         INSERT INTO ledger_events
                (tenant_id, kind, source, idempotency_key, idempotency_hash,
                 payload, effective_at)
         VALUES ($1, 'account_opened', 'api', $2, $3, $4, now())
         ON CONFLICT (tenant_id, idempotency_key) DO NOTHING
         RETURNING id
     ),
     opened AS (
         INSERT INTO ledger_accounts
                (tenant_id, owner_type, owner_id, purpose, category, normal_balance,
                 counterparty_scope, currency, stripe_count, metadata)
         SELECT $1, $5::account_owner_type, $6, $7, $8::ledger_category,
                $9::ledger_normal_balance, $10, $11,
                COALESCE($12::smallint, 1), COALESCE($13::jsonb, '{}'::jsonb)
         FROM claimed c
         RETURNING id
     )
     SELECT c.id AS event_id, o.id AS account_id
     FROM claimed c
     LEFT JOIN opened o ON true";

/// Statement B for an opening: the stored result of the claimed key, with the
/// hash in the WHERE for the reason [`Repository::stored_result`]'s has it
/// there (ADR-0013 §2) — a same-key/different-body replay must return NO row.
///
/// The account is found by the NATURAL KEY the replayed body names, because
/// `ledger_accounts` carries no `event_id` column: `uq_accounts__owned` and
/// `uq_accounts__house` are the two keys that refuse a second such account,
/// and this reads them from the other side. `owner_id_key` rather than
/// `owner_id` is what makes one join serve both — it is the NULL-free
/// generated copy the schema keeps for exactly this kind of composite match,
/// and a house account's is the empty string.
///
/// A `NULL` account id is therefore not a legitimate shape but a
/// disagreement: the two rows commit together, so a matching hash with no
/// account is a can't-happen state, and the service answers it as one.
const STORED_ACCOUNT: &str = "SELECT e.id AS event_id, a.id AS account_id
         FROM ledger_events e
         LEFT JOIN ledger_accounts a
                ON a.tenant_id = e.tenant_id
               AND a.owner_type = $4::account_owner_type
               AND a.owner_id_key = COALESCE($5, '')
               AND a.purpose = $6
               AND a.currency = $7
        WHERE e.tenant_id = $1 AND e.idempotency_key = $2 AND e.idempotency_hash = $3";

/// One row of [`CLAIM_AND_APPEND`]'s answer, named so the matches downstream
/// read: the claim, the transaction (`None` when the supersede gate withheld
/// it), one delta's upsert counter (`account_id`/`currency` are `None` on a
/// zero-delta void's single anchored row; `last_seq` is `None` when the
/// account does not exist), and the supersede target's diagnosis — identical
/// on every row, read off the first.
#[derive(sqlx::FromRow)]
struct ClaimedRow {
    event_id: Uuid,
    transaction_id: Option<Uuid>,
    account_id: Option<Uuid>,
    currency: Option<String>,
    last_seq: Option<i64>,
    target_status: Option<String>,
    target_kind: Option<String>,
    target_is_superseding: Option<bool>,
    target_already_superseded: Option<bool>,
}

/// One row of [`CLAIM_AND_APPEND_BATCH`]'s answer — one per member, in the
/// order the members were given. The three shapes it can take are the three
/// [`MemberOutcome`]s: `admissible` false with the account the gate refused
/// it for, a `NULL` `event_id` for a key an earlier caller holds, and
/// otherwise the claim and the transaction it caused.
///
/// There is no balance counter here, and that is the batched statement's
/// shape rather than an oversight: the upsert is coalesced across members,
/// so no row of it belongs to one member. The existence check the single
/// path reads off a `NULL` counter is answered above the claim instead —
/// and `key_already_held` is what lets the reading put the claim back in
/// front of it, where the single path has it.
#[derive(sqlx::FromRow)]
struct MemberRow {
    event_id: Option<Uuid>,
    transaction_id: Option<Uuid>,
    admissible: bool,
    /// Whether an earlier COMMITTED write already holds this member's key.
    /// Asked only of the members the gate withheld, because for everyone
    /// else the claim answers it.
    key_already_held: bool,
    unknown_account_id: Option<Uuid>,
    unknown_currency: Option<String>,
}

/// The domain's status as the `ledger_txn_status` column stores it, rendered
/// at the bind site, exhaustively — the same rule as `Direction` above.
fn status_as_stored(status: TransactionStatus) -> &'static str {
    match status {
        TransactionStatus::Pending => "pending",
        TransactionStatus::Posted => "posted",
    }
}

/// The domain's owner type as the `account_owner_type` column stores it,
/// rendered at the bind site, exhaustively — the same rule as `Direction` and
/// `TransactionStatus` above, and the reason the words appear twice in this
/// workspace: the CANONICAL spelling the idempotency hash covers is the
/// domain's, and the STORED spelling is this dialect's, so a rename on either
/// side cannot silently move the other.
fn owner_type_as_stored(owner_type: AccountOwnerType) -> &'static str {
    match owner_type {
        AccountOwnerType::Company => "company",
        AccountOwnerType::Platform => "platform",
        AccountOwnerType::BankAccount => "bank_account",
        AccountOwnerType::House => "house",
    }
}

/// [`CLAIM_AND_OPEN_ACCOUNT`]'s answer, read. No row is the one fact the
/// statement's anchor makes unambiguous: an earlier caller holds this key, and
/// nothing here ran. A row is this caller's claim and the account it wrote.
///
/// A row whose account id is `NULL` is a disagreement between this adapter and
/// the writer service about the statement — `opened` inserts one row per
/// claimed row, so the join cannot miss — and is answered as storage rather
/// than as an opening that succeeded with no account. Never a caller error.
fn opened_from_the_row(
    claimed: Option<(Uuid, Option<Uuid>)>,
) -> Result<Option<OpenedAccount>, StorageError> {
    let Some((event_id, account_id)) = claimed else {
        return Ok(None);
    };
    let Some(account_id) = account_id else {
        return Err("the opening statement claimed a key and wrote no account row".into());
    };
    Ok(Some(OpenedAccount::Opened {
        event_id,
        account_id,
    }))
}

/// Two callers raced one account — the loser blocked on the winner's
/// uncommitted tuple in `uq_accounts__owned` or `uq_accounts__house` and lost
/// when it committed. **This is the only detection of `account_exists` there
/// is on the concurrent path**, and it has to be: the sequential case could
/// be diagnosed by a read before the insert, but two concurrent creates of one
/// account are real and no read can see the rival's uncommitted row
/// (ADR-0021). The refusal is named by the service; the database transaction
/// is aborted, and the rollback it performs is what makes "nothing was
/// written" true.
///
/// Only the two ACCOUNT indexes are read here. Anything else `23505` could
/// name is a state this statement's own construction rules out, and is
/// answered as storage rather than dressed up as a refusal the caller could
/// act on.
fn refusal_from_the_account_race(error: &sqlx::Error) -> Option<OpenedAccount> {
    match error {
        sqlx::Error::Database(db)
            if db.constraint() == Some("uq_accounts__owned")
                || db.constraint() == Some("uq_accounts__house") =>
        {
            Some(OpenedAccount::AlreadyExists)
        }
        _ => None,
    }
}

/// Two supersessions raced one target — resolve vs resolve, resolve vs
/// reverse, or reverse vs reverse: the loser blocked on the winner's
/// uncommitted `uq_txn__one_supersession` tuple and lost when it committed —
/// the backstop for the one window the gate cannot see at READ COMMITTED.
/// The refusal is the same named answer the sequential case gets; the
/// database transaction is aborted, and the service's rollback is what this
/// path already promises. `None` for every other failure. The mapping hangs
/// on the index's catalog name: rename it and this arm goes dead — the
/// uncommitted-rival e2e tests are what fail then.
fn refusal_from_supersession_race(error: &sqlx::Error) -> Option<Claimed> {
    match error {
        sqlx::Error::Database(db) if db.constraint() == Some("uq_txn__one_supersession") => Some(
            Claimed::SupersessionRefused(SupersedeRefusal::TargetAlreadySuperseded),
        ),
        _ => None,
    }
}

/// A claimed key with no transaction row is the supersede gate speaking:
/// diagnose the refusal from the target columns the statement carried back,
/// under the verb the command asked — the same diagnosis columns mean
/// different refusals to a resolution and a reversal. A gated transaction
/// whose target passes its own gate is a state the statement cannot
/// produce — answered as the storage error it would have to be.
fn diagnose_supersede_refusal(
    command: &PostTransaction,
    row: &ClaimedRow,
) -> Result<SupersedeRefusal, StorageError> {
    if command.resolves_id().is_some() {
        return match (row.target_status.as_deref(), row.target_already_superseded) {
            (None, _) => Ok(SupersedeRefusal::ResolveTargetUnknown),
            (Some(status), _) if status != "pending" => {
                Ok(SupersedeRefusal::ResolveTargetNotPending)
            }
            (_, Some(true)) => Ok(SupersedeRefusal::TargetAlreadySuperseded),
            _ => Err("the single call gated the resolution for no reason it names".into()),
        };
    }
    if command.reverses_id().is_some() {
        return match (
            row.target_kind.as_deref(),
            row.target_is_superseding,
            row.target_already_superseded,
        ) {
            (None, _, _) => Ok(SupersedeRefusal::ReverseTargetUnknown),
            (Some(kind), _, _) if kind != "posting" => {
                Ok(SupersedeRefusal::ReverseTargetNotReversible)
            }
            (_, Some(true), _) => Ok(SupersedeRefusal::ReverseTargetNotReversible),
            (_, _, Some(true)) => Ok(SupersedeRefusal::TargetAlreadySuperseded),
            _ => Err("the single call gated the reversal for no reason it names".into()),
        };
    }
    Err("the single call gated a transaction that supersedes nothing".into())
}

/// Each delta's upsert answer, one per delta-carrying row in the statement's
/// own account order — a `None` counter is the existence check failing,
/// which the service turns into the refusal that names the account. The
/// void's single anchored row carries no delta and yields none.
fn collect_balance_upserts(rows: Vec<ClaimedRow>) -> Vec<BalanceUpsert> {
    rows.into_iter()
        .filter_map(|row| {
            let account_id = row.account_id?;
            let currency = row.currency?;
            Some(BalanceUpsert {
                account_id,
                currency,
                last_seq: row.last_seq,
            })
        })
        .collect()
}

/// What [`CLAIM_AND_APPEND`]'s rows MEAN — the single path's interpretation,
/// the way [`outcome_for_member`] is the batched path's. Zero rows back means
/// the key was already claimed and none of the append ran: the answer anchors
/// on the CLAIMED row, so a zero-delta void is still rows back and is never
/// mistaken for a replay. A `NULL` transaction id means the supersede gate
/// refused, and the refusal is named from the target columns the statement
/// carried back ([`diagnose_supersede_refusal`]). Otherwise the append
/// happened, uncommitted, and the rows carry each delta's counter
/// ([`collect_balance_upserts`]).
fn claimed_from_the_rows(
    command: &PostTransaction,
    rows: Vec<ClaimedRow>,
) -> Result<Option<Claimed>, StorageError> {
    let Some(first) = rows.first() else {
        return Ok(None);
    };
    let event_id = first.event_id;
    let Some(transaction_id) = first.transaction_id else {
        return Ok(Some(Claimed::SupersessionRefused(
            diagnose_supersede_refusal(command, first)?,
        )));
    };
    Ok(Some(Claimed::Appended(Appended {
        event_id,
        transaction_id,
        balance_upserts: collect_balance_upserts(rows),
    })))
}

/// The batch carries plain POSTED postings only (ADR-0018 §4), and this is
/// where that scope is enforced rather than assumed. A pending, resolving or
/// reversing command belongs on [`CLAIM_AND_APPEND`], which has the supersede
/// gate, the derived mirror and the pending rule; this statement has none of
/// them and writes the literal status `'posted'`, so a misrouted member would
/// not be refused — it would be silently POSTED, a claim about money turned
/// into money moved, with `resolves_id` dropped on the floor. The refusal is
/// a storage error rather than a named refusal because it is not the
/// caller's mistake to fix: the caller sent a shape this ledger accepts, and
/// the assembler put it in the wrong statement.
fn refuse_a_member_the_batch_cannot_carry(members: &[BatchMember<'_>]) -> Result<(), StorageError> {
    for (position, member) in members.iter().enumerate() {
        let unbatchable = if member.command.resolves_id().is_some() {
            "resolves another transaction"
        } else if member.command.reverses_id().is_some() {
            "reverses another transaction"
        } else if member.command.status() == TransactionStatus::Pending {
            "is pending"
        } else {
            continue;
        };
        return Err(format!(
            "member {position} of a batch of {} {unbatchable}, and the batched \
             statement carries plain posted postings only",
            members.len()
        )
        .into());
    }
    Ok(())
}

/// What the batched statement answered for one member, read in the order the
/// SINGLE path reads it — **the key claim first, the account gate second** —
/// because a caller must not be able to tell the two paths apart by which
/// refusal it hears (ADR-0018 §3). Post a key with good accounts, then
/// re-post it with a typo'd one: unbatched, the claim's
/// `ON CONFLICT DO NOTHING` returns nothing and the account is never looked
/// at, so the caller hears `key_reused`. Read the gate first here and the
/// same request hears `account_unknown` — the same caller, the same body, a
/// different error type depending only on whether the pool was busy.
///
/// The statement still GATES above the claim, and must: that is what keeps a
/// refused member's key from being burned. Only the reading is reordered,
/// which is why the statement carries `key_already_held` for the members it
/// withheld.
///
/// The two `Err` arms are states the statement cannot produce — a withheld
/// member always has an account to name (every member has at least one leg,
/// the constructor refuses an empty posting set outside the reversal shape
/// this batch does not carry), and a claimed key always gets its transaction
/// (`txn` selects `FROM proceeding`, which selects `FROM claimed`). They are
/// answered as the disagreement they would have to be, never guessed at —
/// the same rule `diagnose_supersede_refusal` follows.
fn outcome_for_member(row: MemberRow) -> Result<MemberOutcome, StorageError> {
    // A withheld member the statement found a committed claim for: the claim
    // wins, and its answer comes from the replay lookup exactly as an
    // admissible member's would.
    if row.key_already_held {
        return Ok(MemberOutcome::KeyAlreadyClaimed);
    }
    if !row.admissible {
        return match (row.unknown_account_id, row.unknown_currency) {
            (Some(account_id), Some(currency)) => Ok(MemberOutcome::AccountUnknown {
                account_id,
                currency,
            }),
            _ => {
                Err("the batched call withheld a member's claim and named no account for it".into())
            }
        };
    }
    // An admissible member's own claim says it: nothing back from
    // `ON CONFLICT DO NOTHING` is an earlier caller holding the key.
    let Some(event_id) = row.event_id else {
        return Ok(MemberOutcome::KeyAlreadyClaimed);
    };
    let Some(transaction_id) = row.transaction_id else {
        return Err("the batched call claimed a member's key and wrote it no transaction".into());
    };
    // The claim and the transaction, and nothing else — the port's batched
    // outcome names no balance upserts, because the upsert this member's
    // deltas fed is shared with every other member that touched the same
    // account and no row of it is this member's to report.
    Ok(MemberOutcome::Appended {
        event_id,
        transaction_id,
    })
}

impl Repository for PgRepository {
    type Tx = Transaction<'static, Postgres>;

    /// ADR-0013 §1 is honored here, in the ADR's own words: the transaction
    /// opens WITH `BEGIN ISOLATION LEVEL READ COMMITTED` — one round trip,
    /// never an inherited deployment default plus a second `SET` statement.
    /// A default of REPEATABLE READ or stricter silently loses 64–90% of
    /// contended writes, and no retry loop rescues them.
    async fn begin(&self) -> Result<Self::Tx, StorageError> {
        self.pool
            .begin_with("BEGIN ISOLATION LEVEL READ COMMITTED")
            .await
            .map_err(storage)
    }

    /// Statement A, carrying the whole append with it — single-call
    /// posting (roadmap M3; pending → posted and reversals ride the same
    /// statement, ADR-0016 — a pending plan already withheld its balance
    /// movement, and a reversal's plan is EMPTY, the statement deriving the
    /// mirror or the void from the target): marshal the plan into the
    /// parallel arrays [`CLAIM_AND_APPEND`] binds, run the one statement,
    /// and interpret its answer ([`claimed_from_the_rows`]) — except the one
    /// answer that arrives as an ERROR rather than as rows: a unique violation
    /// on the supersession index is the race's refusal
    /// ([`refusal_from_supersession_race`]), classified here where the
    /// `sqlx::Error` is.
    ///
    /// This writer's stripe affinity rides along as the last bind and the
    /// statement picks the stripe from it — once, for the whole coalesced set
    /// (ADR-0018 §1); the port's `BalanceUpsert` never learns of it, because
    /// the service's only two questions are whether every delta came back and
    /// whether any counter came back `None`, and neither needs a stripe.
    async fn claim_and_append(
        &self,
        tx: &mut Self::Tx,
        command: &PostTransaction,
        hash: &[u8],
        payload: &serde_json::Value,
        append: &Append,
    ) -> Result<Option<Claimed>, StorageError> {
        let deltas = columns_for_deltas(&append.deltas);
        let (leg_accounts, directions, amounts, leg_currencies) = columns_for_entries(&append.legs);
        let outcome: Result<Vec<ClaimedRow>, sqlx::Error> = sqlx::query_as(CLAIM_AND_APPEND)
            .bind(command.tenant_id())
            .bind(command.idempotency_key())
            .bind(hash)
            .bind(payload)
            .bind(command.effective_at())
            .bind(&deltas.account_ids)
            .bind(&deltas.currencies)
            .bind(&deltas.inputs)
            .bind(&deltas.outputs)
            .bind(&deltas.legs)
            .bind(&leg_accounts)
            .bind(&directions)
            .bind(&amounts)
            .bind(&leg_currencies)
            .bind(&append.seq_offsets)
            .bind(status_as_stored(command.status()))
            .bind(command.resolves_id())
            .bind(command.reverses_id())
            .bind(self.stripe_affinity)
            .fetch_all(&mut **tx)
            .await;
        let rows = match outcome {
            Ok(rows) => rows,
            Err(error) => {
                return match refusal_from_supersession_race(&error) {
                    Some(refused) => Ok(Some(refused)),
                    None => Err(storage(error)),
                };
            }
        };
        claimed_from_the_rows(command, rows)
    }

    /// Statement A, batched (ADR-0018 §3): refuse anything the batch cannot
    /// carry, marshal every member's claim and every member's legs into the
    /// parallel arrays [`CLAIM_AND_APPEND_BATCH`] binds, run the one
    /// statement, and read its answer a member at a time. This writer's
    /// stripe affinity rides along as the last bind exactly as it does on
    /// the single path, and the statement picks the stripe once for the
    /// whole COALESCED set — after the cross-member coalesce, which is where
    /// a batch's stripe belongs (ADR-0018 §1).
    ///
    /// Row count is not checked here. The statement answers one row per
    /// member by construction — its final `SELECT` anchors on `member` — and
    /// the caller asserts it against the members it sent, the way the single
    /// path's caller asserts one upsert per delta: a mismatch is a
    /// disagreement about the statement, which is internal, never a caller
    /// error.
    async fn claim_and_append_batch(
        &self,
        tx: &mut Self::Tx,
        members: &[BatchMember<'_>],
    ) -> Result<Vec<MemberOutcome>, StorageError> {
        refuse_a_member_the_batch_cannot_carry(members)?;
        let claims = columns_for_claims(members);
        let legs = columns_for_member_legs(members);
        let rows: Vec<MemberRow> = sqlx::query_as(CLAIM_AND_APPEND_BATCH)
            .bind(&claims.tenant_ids)
            .bind(&claims.idempotency_keys)
            .bind(&claims.hashes)
            .bind(&claims.payloads)
            .bind(&claims.effective_at)
            .bind(&legs.member_ordinals)
            .bind(&legs.leg_positions)
            .bind(&legs.account_ids)
            .bind(&legs.directions)
            .bind(&legs.amounts)
            .bind(&legs.currencies)
            .bind(self.stripe_affinity)
            .fetch_all(&mut **tx)
            .await
            .map_err(storage)?;
        rows.into_iter().map(outcome_for_member).collect()
    }

    /// Statement B: the stored result of the claimed key. The hash is in the
    /// WHERE, not a returned column: a same-key/different-body replay returns
    /// NO row, and a caller that forgets to compare gets nothing instead of
    /// the wrong stored result (ADR-0013 §2).
    async fn stored_result(
        &self,
        tx: &mut Self::Tx,
        command: &PostTransaction,
        hash: &[u8],
    ) -> Result<Option<StoredResult>, StorageError> {
        sqlx::query_as(
            "SELECT e.id, t.id
             FROM ledger_events e
             LEFT JOIN ledger_transactions t
                    ON t.tenant_id = e.tenant_id AND t.event_id = e.id
             WHERE e.tenant_id = $1 AND e.idempotency_key = $2 AND e.idempotency_hash = $3",
        )
        .bind(command.tenant_id())
        .bind(command.idempotency_key())
        .bind(hash)
        .fetch_optional(&mut **tx)
        .await
        .map_err(storage)
    }

    /// Statement B, batched: the stored results of every member whose key an
    /// earlier caller already held, in one lookup ([`STORED_RESULT_BATCH`]).
    /// A `NULL` event id is that member's key reused with a different body —
    /// the hash is in the join, so nothing is compared here — and the row
    /// order is the member order the arrays were bound in.
    async fn stored_result_batch(
        &self,
        tx: &mut Self::Tx,
        members: &[BatchMember<'_>],
    ) -> Result<Vec<Option<StoredResult>>, StorageError> {
        let keys = columns_for_keys(members);
        let rows: Vec<(Option<Uuid>, Option<Uuid>)> = sqlx::query_as(STORED_RESULT_BATCH)
            .bind(&keys.tenant_ids)
            .bind(&keys.idempotency_keys)
            .bind(&keys.hashes)
            .fetch_all(&mut **tx)
            .await
            .map_err(storage)?;
        Ok(rows
            .into_iter()
            .map(|(event_id, transaction_id)| event_id.map(|event_id| (event_id, transaction_id)))
            .collect())
    }

    /// The chart's own row for a purpose — one statement, inside the opening's
    /// own database transaction, so the triple the writer binds is the triple
    /// that was there when the composite foreign keys check it.
    async fn chart_triple_for_purpose(
        &self,
        tx: &mut Self::Tx,
        purpose: &str,
    ) -> Result<Option<ChartTriple>, StorageError> {
        let found: Option<(String, String, String)> = sqlx::query_as(CHART_TRIPLE)
            .bind(purpose)
            .fetch_optional(&mut **tx)
            .await
            .map_err(storage)?;
        Ok(found.map(
            |(category, normal_balance, counterparty_scope)| ChartTriple {
                category,
                normal_balance,
                counterparty_scope,
            },
        ))
    }

    /// Statement A for an opening: bind the command and the derived triple
    /// into [`CLAIM_AND_OPEN_ACCOUNT`], run the one statement, and read its
    /// answer — except the one answer that arrives as an ERROR rather than as
    /// rows: a unique violation on either account index is the race's
    /// refusal ([`refusal_from_the_account_race`]), classified here where the
    /// `sqlx::Error` is.
    async fn claim_and_open_account(
        &self,
        tx: &mut Self::Tx,
        command: &OpenAccount,
        hash: &[u8],
        payload: &serde_json::Value,
        triple: &ChartTriple,
    ) -> Result<Option<OpenedAccount>, StorageError> {
        let outcome: Result<Option<(Uuid, Option<Uuid>)>, sqlx::Error> =
            sqlx::query_as(CLAIM_AND_OPEN_ACCOUNT)
                .bind(command.tenant_id())
                .bind(command.idempotency_key())
                .bind(hash)
                .bind(payload)
                .bind(owner_type_as_stored(command.owner_type()))
                .bind(command.owner_id())
                .bind(command.purpose())
                .bind(&triple.category)
                .bind(&triple.normal_balance)
                .bind(&triple.counterparty_scope)
                .bind(command.currency())
                .bind(command.stripe_count())
                .bind(command.metadata())
                .fetch_optional(&mut **tx)
                .await;
        let claimed = match outcome {
            Ok(claimed) => claimed,
            Err(error) => {
                return match refusal_from_the_account_race(&error) {
                    Some(refused) => Ok(Some(refused)),
                    None => Err(storage(error)),
                };
            }
        };
        opened_from_the_row(claimed)
    }

    /// Statement B for an opening: the stored result of the claimed key
    /// ([`STORED_ACCOUNT`]).
    async fn stored_account(
        &self,
        tx: &mut Self::Tx,
        command: &OpenAccount,
        hash: &[u8],
    ) -> Result<Option<StoredAccount>, StorageError> {
        sqlx::query_as(STORED_ACCOUNT)
            .bind(command.tenant_id())
            .bind(command.idempotency_key())
            .bind(hash)
            .bind(owner_type_as_stored(command.owner_type()))
            .bind(command.owner_id())
            .bind(command.purpose())
            .bind(command.currency())
            .fetch_optional(&mut **tx)
            .await
            .map_err(storage)
    }

    /// Commit the bracket: the event claim and everything it caused become
    /// durable together.
    async fn commit(&self, tx: Self::Tx) -> Result<(), StorageError> {
        tx.commit().await.map_err(storage)
    }

    /// Abandon the bracket. Every refusal the service answers promises
    /// "nothing was written", and this is how it keeps the promise.
    async fn rollback(&self, tx: Self::Tx) -> Result<(), StorageError> {
        tx.rollback().await.map_err(storage)
    }
}

#[cfg(test)]
mod tests {
    //! The adapter's Rust halves, held without a database in the room: the
    //! affinity one writer stripes on, the marshalling that turns N members
    //! into the batched statement's parallel arrays, the scope check that
    //! keeps an unbatchable command out of a statement that would silently
    //! post it, and the reading of one member's answer.
    //!
    //! What the STATEMENTS do — the modulo against each account's own
    //! `stripe_count`, the stripe threaded from the upsert's `RETURNING`
    //! into the entries, the admissibility gate withholding a claim, the
    //! window function's walk-back across members — is proven against real
    //! PostgreSQL by the e2e suite; nothing here re-proves it, and nothing
    //! here could. What IS here is everything that decides what the
    //! statement is asked and what its answer means.

    use std::collections::{BTreeMap, BTreeSet};

    use ledger::{Invalid, Posting};
    use time::OffsetDateTime;

    use super::*;

    // SOURCE < DESTINATION, so SOURCE leads a coalesced set — the account a
    // gate refusal names first.
    const EVENT: Uuid = Uuid::from_u128(0xE0);
    const TRANSACTION: Uuid = Uuid::from_u128(0xF0);
    const SOURCE: Uuid = Uuid::from_u128(1);
    const DESTINATION: Uuid = Uuid::from_u128(2);
    const TARGET: Uuid = Uuid::from_u128(0xA0);

    /// One command, shaped by what the test is about: the postings follow
    /// the reversal rule the constructor holds (a reversal carries none).
    fn a_command(
        idempotency_key: &str,
        status: TransactionStatus,
        resolves_id: Option<Uuid>,
        reverses_id: Option<Uuid>,
    ) -> Result<PostTransaction, Invalid> {
        let postings = match reverses_id {
            Some(_) => Vec::new(),
            None => vec![Posting::new(SOURCE, DESTINATION, 100, "USD".to_owned())?],
        };
        PostTransaction::new(
            "acme".to_owned(),
            idempotency_key.to_owned(),
            Some(OffsetDateTime::UNIX_EPOCH),
            status,
            resolves_id,
            reverses_id,
            postings,
        )
    }

    fn a_leg(account_id: Uuid, direction: Direction) -> Leg {
        Leg {
            account_id,
            currency: "USD".to_owned(),
            direction,
            amount_minor: 100,
        }
    }

    /// A plan carrying just these legs. The batched statement binds the
    /// legs and re-derives the rest in SQL, so the deltas and offsets a real
    /// `plan_append` would carry are not what these tests are about.
    fn a_plan(legs: Vec<Leg>) -> Append {
        Append {
            legs,
            seq_offsets: Vec::new(),
            deltas: BTreeMap::new(),
        }
    }

    /// One member's answer, rendered as the sentence the outcome makes, so a
    /// table of answers reads as a table of meanings.
    fn spoken(outcome: &MemberOutcome) -> String {
        match outcome {
            MemberOutcome::Appended {
                event_id,
                transaction_id,
            } => format!("appended {event_id} as {transaction_id}"),
            MemberOutcome::AccountUnknown {
                account_id,
                currency,
            } => format!("unknown account {account_id} in {currency}"),
            MemberOutcome::KeyAlreadyClaimed => "key already claimed".to_owned(),
        }
    }

    /// The one property ADR-0018 §1 asks of the affinity: concurrent
    /// writers hold DIFFERENT values. Which values they are is free —
    /// a restart may reshuffle them and strand nothing — so what is held
    /// here is the injectivity, not a table of expected numbers.
    ///
    /// **Below the mask's edge only**, and the name says so rather than
    /// promising an injectivity the mask cannot have: index `2^31` masks to
    /// `0`, which is index `0`'s affinity, so two writers CAN collide once
    /// the pool is bigger than `i32::MAX`. What is held here is that under
    /// that edge — every pool depth this project will ever run — the mask
    /// is the identity and distinct indices stay distinct.
    #[test]
    fn writer_indices_below_the_masks_edge_stripe_on_different_affinities() {
        let indices = [0_u32, 1, 2, 3, 7, 4_242, 1_000_003, i32::MAX as u32];

        let affinities: BTreeSet<i32> = indices.iter().copied().map(stripe_affinity_of).collect();

        assert_eq!(
            affinities.len(),
            indices.len(),
            "two writer indices collided onto one stripe affinity: {affinities:?}"
        );
    }

    /// The mask, at the value that is the whole reason it exists: a writer
    /// index at or above 2^31 wraps to a NEGATIVE `i32`, and `i32::MIN`
    /// exactly is where negation dies — it has no non-negative counterpart,
    /// so `abs()` has no answer to give. Masked instead, every index stripes
    /// non-negative, and since the statements bind this value and take it
    /// modulo the account's own count, no caller can put a negative stripe
    /// in front of `ck_balances__stripe_non_negative`.
    #[test]
    fn an_index_that_wraps_to_i32_min_still_stripes_non_negative() {
        // 2^31 is the first index whose `as i32` is i32::MIN.
        let wrapping = [1_u32 << 31, (1_u32 << 31) + 1, u32::MAX];

        let affinities: Vec<i32> = wrapping.iter().copied().map(stripe_affinity_of).collect();

        assert_eq!(affinities, vec![0, 1, i32::MAX]);
    }

    /// The one thing the two marshalling functions have to agree about: a
    /// member's identity inside the statement is its POSITION in the claim
    /// arrays (`WITH ORDINALITY` numbers them from 1), and every leg carries
    /// that same number. Number the legs off a different sequence and legs
    /// attach to a stranger's transaction — silently, since the arrays are
    /// still the same length and the statement still returns one row per
    /// member. So the property held here is not "the vectors are parallel";
    /// it is that following a leg's ordinal back into the claim arrays lands
    /// on the member the leg actually came from.
    #[test]
    fn a_legs_member_ordinal_indexes_back_into_its_own_members_claim() -> Result<(), Invalid> {
        let first = a_command("key-1", TransactionStatus::Posted, None, None)?;
        let second = a_command("key-2", TransactionStatus::Posted, None, None)?;
        // Deliberately uneven: two legs then four, so a flat leg index and a
        // member ordinal cannot be mistaken for each other.
        let first_plan = a_plan(vec![
            a_leg(SOURCE, Direction::Credit),
            a_leg(DESTINATION, Direction::Debit),
        ]);
        let second_plan = a_plan(vec![
            a_leg(SOURCE, Direction::Credit),
            a_leg(DESTINATION, Direction::Debit),
            a_leg(SOURCE, Direction::Credit),
            a_leg(DESTINATION, Direction::Debit),
        ]);
        let payload = serde_json::json!({});
        let members = [
            BatchMember {
                command: &first,
                hash: b"h1",
                payload: &payload,
                append: &first_plan,
            },
            BatchMember {
                command: &second,
                hash: b"h2",
                payload: &payload,
                append: &second_plan,
            },
        ];

        let claims = columns_for_claims(&members);
        let legs = columns_for_member_legs(&members);

        let key_each_leg_belongs_to: Vec<&str> = legs
            .member_ordinals
            .iter()
            .map(|ordinal| {
                claims
                    .idempotency_keys
                    .get(ordinal.saturating_sub(1) as usize)
                    .copied()
                    .unwrap_or("no such member")
            })
            .collect();
        assert_eq!(
            key_each_leg_belongs_to,
            vec!["key-1", "key-1", "key-2", "key-2", "key-2", "key-2"]
        );
        // ...and the position within each member restarts at 1, because it
        // is what orders the walk-back inside one member's own postings.
        assert_eq!(legs.leg_positions, vec![1, 2, 1, 2, 3, 4]);
        Ok(())
    }

    /// The wire form of a side, at the bind site: `ledger_direction` holds
    /// the words `debit` and `credit`, and a leg is marshalled as the word
    /// the column stores rather than as anything Rust would print. Its own
    /// test because it is a dialect concern — a renamed enum label breaks
    /// this and nothing about member ordinals.
    #[test]
    fn a_legs_direction_is_marshalled_as_the_word_the_column_stores() -> Result<(), Invalid> {
        let command = a_command("key-1", TransactionStatus::Posted, None, None)?;
        let plan = a_plan(vec![
            a_leg(SOURCE, Direction::Credit),
            a_leg(DESTINATION, Direction::Debit),
        ]);
        let payload = serde_json::json!({});
        let members = [BatchMember {
            command: &command,
            hash: b"h1",
            payload: &payload,
            append: &plan,
        }];

        let legs = columns_for_member_legs(&members);

        assert_eq!(legs.directions, vec!["credit", "debit"]);
        Ok(())
    }

    /// The batch's scope (ADR-0018 §4) enforced rather than assumed: the
    /// batched statement has no supersede gate and writes the literal status
    /// `'posted'`, so a misrouted member would not be refused — it would be
    /// posted, its pointer dropped and its pending claim turned into moved
    /// money. Every member is checked, not just the first.
    #[test]
    fn a_command_the_batch_cannot_carry_is_refused_before_the_statement_runs() -> Result<(), Invalid>
    {
        let plain = a_command("key-0", TransactionStatus::Posted, None, None)?;
        let plan = a_plan(vec![a_leg(SOURCE, Direction::Credit)]);
        let payload = serde_json::json!({});
        let carries = |command| BatchMember {
            command,
            hash: b"h",
            payload: &payload,
            append: &plan,
        };
        // Each kind with the sentence the operator reads for it. The
        // diagnosis is the whole value of this refusal — an operator holding
        // "member 1 ... is pending" goes to the accumulator's routing rule,
        // one holding the wrong sentence goes anywhere else — so the strings
        // are asserted rather than an `is_err`, and so is the POSITION: the
        // batch it names is the one that has to be fixed.
        let unbatchable = [
            (
                a_command("key-1", TransactionStatus::Posted, Some(TARGET), None)?,
                "resolves another transaction",
            ),
            (
                a_command("key-2", TransactionStatus::Posted, None, Some(TARGET))?,
                "reverses another transaction",
            ),
            (
                a_command("key-3", TransactionStatus::Pending, None, None)?,
                "is pending",
            ),
        ];

        for (offender, why) in &unbatchable {
            // Second in the batch: the check reads every member, and an
            // innocent first member must not shield the one behind it. Its
            // position — 1, zero-based — is what the sentence must carry.
            let batch = [carries(&plain), carries(offender)];

            let refused = refuse_a_member_the_batch_cannot_carry(&batch);

            assert_eq!(
                refused.err().map(|refusal| refusal.to_string()),
                Some(format!(
                    "member 1 of a batch of 2 {why}, and the batched statement carries plain \
                     posted postings only"
                ))
            );
        }
        Ok(())
    }

    /// The other half of the scope check, and the half that keeps it from
    /// being satisfied by a function that refuses everything: the batch the
    /// statement was built for — plain, posted, resolving and reversing
    /// nothing — passes the gate and rides.
    #[test]
    fn a_plain_posted_posting_is_what_the_batch_carries() -> Result<(), Invalid> {
        let plain = a_command("key-0", TransactionStatus::Posted, None, None)?;
        let plan = a_plan(vec![a_leg(SOURCE, Direction::Credit)]);
        let payload = serde_json::json!({});
        let all_plain = [BatchMember {
            command: &plain,
            hash: b"h",
            payload: &payload,
            append: &plan,
        }];

        let refused = refuse_a_member_the_batch_cannot_carry(&all_plain);

        assert!(
            refused.is_ok(),
            "a plain posted posting is exactly what the batch carries"
        );
        Ok(())
    }

    /// The ORDER the answer is read in, which is the whole property: the key
    /// claim is asked before the account gate, exactly as the single path
    /// asks it, so neither refusal can wear the other's name. Read the gate
    /// first and a member whose key an earlier caller already holds hears
    /// `account_unknown` where the single path says `key_reused` — the same
    /// request answered differently depending only on whether the pool was
    /// busy. Read the claim off the wrong column and a member the gate
    /// withheld is answered as a replay, which is the laundered refusal
    /// ADR-0018 §3 exists to prevent.
    #[test]
    fn a_withheld_member_is_never_read_as_a_replay_nor_a_held_key_as_a_refusal()
    -> Result<(), StorageError> {
        let answers = [
            // Withheld by the gate, key untouched: the account is named.
            MemberRow {
                event_id: None,
                transaction_id: None,
                admissible: false,
                key_already_held: false,
                unknown_account_id: Some(SOURCE),
                unknown_currency: Some("USD".to_owned()),
            },
            // Withheld by the gate AND an earlier caller holds the key. The
            // claim wins, as it does unbatched, and this member goes on to
            // the replay lookup instead of hearing about its account.
            MemberRow {
                event_id: None,
                transaction_id: None,
                admissible: false,
                key_already_held: true,
                unknown_account_id: Some(SOURCE),
                unknown_currency: Some("USD".to_owned()),
            },
            // Admissible, but the key was already held: the claim's
            // ON CONFLICT DO NOTHING returned nothing for this member.
            MemberRow {
                event_id: None,
                transaction_id: None,
                admissible: true,
                key_already_held: false,
                unknown_account_id: None,
                unknown_currency: None,
            },
            // Claimed, and its transaction written.
            MemberRow {
                event_id: Some(EVENT),
                transaction_id: Some(TRANSACTION),
                admissible: true,
                key_already_held: false,
                unknown_account_id: None,
                unknown_currency: None,
            },
        ];

        let outcomes: Vec<MemberOutcome> = answers
            .into_iter()
            .map(outcome_for_member)
            .collect::<Result<_, _>>()?;

        let read: Vec<String> = outcomes.iter().map(spoken).collect();
        assert_eq!(
            read,
            vec![
                format!("unknown account {SOURCE} in USD"),
                "key already claimed".to_owned(),
                "key already claimed".to_owned(),
                // The claim and the transaction, and nothing else: the
                // balance upsert is coalesced across members, so no row of
                // it is this member's and the outcome cannot name one.
                format!("appended {EVENT} as {TRANSACTION}"),
            ]
        );
        Ok(())
    }

    /// The can't-happen answers are answered as the disagreement they would
    /// have to be, never guessed at: a member the gate withheld always has
    /// an account to name, and a claimed key always gets its transaction.
    /// Guess instead — call the first a replay, invent an account for the
    /// second — and the adapter would report a refusal it cannot explain as
    /// something the caller could act on. The SENTENCES are the assertion:
    /// each one is what an operator reads, and they name different faults.
    #[test]
    fn an_answer_the_statement_cannot_produce_is_refused_rather_than_guessed_at() {
        let withheld_naming_nothing = MemberRow {
            event_id: None,
            transaction_id: None,
            admissible: false,
            key_already_held: false,
            unknown_account_id: None,
            unknown_currency: None,
        };
        let claimed_without_a_transaction = MemberRow {
            event_id: Some(EVENT),
            transaction_id: None,
            admissible: true,
            key_already_held: false,
            unknown_account_id: None,
            unknown_currency: None,
        };

        let withheld = outcome_for_member(withheld_naming_nothing);
        let claimed = outcome_for_member(claimed_without_a_transaction);

        assert_eq!(
            withheld.err().map(|refusal| refusal.to_string()),
            Some(
                "the batched call withheld a member's claim and named no account for it".to_owned()
            )
        );
        assert_eq!(
            claimed.err().map(|refusal| refusal.to_string()),
            Some("the batched call claimed a member's key and wrote it no transaction".to_owned())
        );
    }
}
