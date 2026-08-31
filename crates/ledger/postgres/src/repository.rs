//! The repository: [`PgRepository`] and its [`ledger::Repository`] impl,
//! one SQL statement per method, each operating on the open transaction the
//! service began. The trait is implemented here, where the SQL lives — all
//! of this crate's SQL is in this file, and there is no forwarding layer
//! between the port's shapes and the statements. What order the statements
//! run in — and what each result means for the use-case — is the writer
//! service's (`ledger::LedgerService`, in the core crate above), not this
//! file's.
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
    Append, Appended, BalanceUpsert, Claimed, Delta, Direction, Leg, PostTransaction, Repository,
    StorageError, SupersedeRefusal, TransactionStatus,
};
use sqlx::{PgPool, Postgres, Transaction};
use uuid::Uuid;

/// The Postgres repository: the `ledger` crate's outbound port, implemented.
#[derive(Clone)]
pub struct PgRepository {
    pool: PgPool,
}

impl PgRepository {
    /// Takes [`db::Database`], not a bare pool: the composition root hands
    /// the adapter what db built, and never names an sqlx type itself.
    pub fn new(database: &db::Database) -> Self {
        Self {
            pool: database.pool().clone(),
        }
    }
}

/// The port's storage error is opaque (crates/ledger names no sqlx type);
/// this is the one place the Postgres error is boxed into it.
fn storage(e: sqlx::Error) -> StorageError {
    Box::new(e)
}

/// Transpose the legs into the parallel column arrays `unnest` binds — one
/// Vec per SQL array, in the statement's order: account_id, direction,
/// amount_minor, currency. The domain's `Direction` is rendered into the
/// SQL dialect's string here, at the bind site, and nowhere else —
/// exhaustively, so a third variant would refuse to compile rather than
/// default to a side.
fn columns_for_entries(legs: &[Leg]) -> (Vec<Uuid>, Vec<String>, Vec<i64>, Vec<String>) {
    let mut account_ids = Vec::with_capacity(legs.len());
    let mut directions = Vec::with_capacity(legs.len());
    let mut amounts = Vec::with_capacity(legs.len());
    let mut currencies = Vec::with_capacity(legs.len());
    for leg in legs {
        account_ids.push(leg.account_id);
        directions.push(
            match leg.direction {
                Direction::Debit => "debit",
                Direction::Credit => "credit",
            }
            .to_owned(),
        );
        amounts.push(leg.amount_minor);
        currencies.push(leg.currency.clone());
    }
    (account_ids, directions, amounts, currencies)
}

/// The coalesced deltas, transposed into the parallel arrays the
/// statement's delta `unnest` binds, in the map's account-id iteration
/// order — the statement re-sorts anyway (its ORDER BY is what the lock
/// order hangs on; that property is unpinned until M2's concurrency proof —
/// see the ORDER BY's own note in [`CLAIM_AND_APPEND`]'s doc), but handing
/// it ordered arrays keeps the wire form readable next to the plan.
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
/// - `balance` upserts each delta's row. Its `INSERT` arm copies the
///   account's frozen identity columns from `ledger_accounts` itself,
///   which doubles as the existence check — an unknown account, or a
///   currency the account does not hold, joins to nothing and comes back
///   as a `NULL` counter for the service to refuse. The row locks are
///   taken in account-id order, held by the `ORDER BY` on the `SELECT`
///   feeding the upsert (deterministic lock ordering, batch-wide —
///   ADR-0013, spike 003). That ordering is UNPINNED today — removing or
///   inverting the ORDER BY survives the whole suite, because with two
///   accounts the planner emits the legs in account order for free and no
///   deadlock can be produced at all (the roadmap's M2 section, verbatim);
///   its real test — many accounts, half the writers posting legs in
///   reverse order, batching on — is M2's concurrency-proof deliverable,
///   and "a test that does not fail when the sort is removed is not
///   testing the sort";
/// - `entry` lands the entries — planned and mirror alike — through one
///   `unnest`-fed insert (within 2% of `COPY` on this table, ADR-0013 §5),
///   numbered `last_seq - seq_offset` beside the counter the upsert
///   returned;
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
     balance AS (
         INSERT INTO ledger_account_balances
                (tenant_id, account_id, currency, stripe,
                 owner_type, owner_id_key, purpose, category, normal_balance,
                 input, output, last_seq)
         SELECT a.tenant_id, a.id, a.currency, 0,
                a.owner_type, a.owner_id_key, a.purpose, a.category, a.normal_balance,
                d.input, d.output, d.legs
         FROM delta d
         JOIN ledger_accounts a
           ON a.tenant_id = $1 AND a.id = d.account_id AND a.currency = d.currency
         ORDER BY a.id, a.currency
         ON CONFLICT (tenant_id, account_id, currency, stripe) DO UPDATE
         SET input      = ledger_account_balances.input + EXCLUDED.input,
             output     = ledger_account_balances.output + EXCLUDED.output,
             last_seq   = ledger_account_balances.last_seq + EXCLUDED.last_seq,
             updated_at = now()
         RETURNING account_id, currency, last_seq
     ),
     entry AS (
         INSERT INTO ledger_entries
                (tenant_id, transaction_id, account_id, direction, amount_minor,
                 currency, stripe, account_seq, effective_at)
         SELECT $1, t.id, l.account_id, l.direction::ledger_direction, l.amount_minor,
                l.currency, 0, b.last_seq - l.seq_offset, (SELECT at FROM effective)
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

/// The domain's status rendered into the dialect at the bind site,
/// exhaustively — the same rule as `Direction` in `columns_for_entries`.
fn column_for_status(status: TransactionStatus) -> &'static str {
    match status {
        TransactionStatus::Pending => "pending",
        TransactionStatus::Posted => "posted",
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
    /// read its answer. Zero rows back means the key was already claimed
    /// and none of the append ran — the answer anchors on the claimed row,
    /// so a zero-delta void is still rows back, never mistaken for a
    /// replay; a `NULL` transaction id means the supersede gate refused
    /// ([`diagnose_supersede_refusal`]); a unique violation on the
    /// supersession index is the race's refusal
    /// ([`refusal_from_supersession_race`]); otherwise the append happened,
    /// uncommitted, and the rows carry each delta's counter
    /// ([`collect_balance_upserts`]).
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
            .bind(column_for_status(command.status()))
            .bind(command.resolves_id())
            .bind(command.reverses_id())
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

    /// Statement B: the stored result of the claimed key. The hash is in the
    /// WHERE, not a returned column: a same-key/different-body replay returns
    /// NO row, and a caller that forgets to compare gets nothing instead of
    /// the wrong stored result (ADR-0013 §2).
    async fn stored_result(
        &self,
        tx: &mut Self::Tx,
        command: &PostTransaction,
        hash: &[u8],
    ) -> Result<Option<(Uuid, Option<Uuid>)>, StorageError> {
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
