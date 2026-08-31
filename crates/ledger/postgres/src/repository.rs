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
    Append, Appended, BalanceUpsert, Delta, Direction, Leg, PostTransaction, Repository,
    StorageError,
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
/// order hangs on), but handing it ordered arrays keeps the wire form
/// readable next to the plan.
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

    /// Statement A, carrying the whole append with it — single-call posting.
    /// One CTE pipeline: claim the key (`ON CONFLICT DO NOTHING`), and from
    /// the claimed row insert the transaction, upsert every delta's balance
    /// row, and append the entries. Zero rows back means the key was already
    /// claimed and NONE of the dependent inserts ran — every one of them
    /// selects `FROM` the empty claim. The pieces keep their old contracts:
    ///
    /// - the balance upsert's `INSERT` arm copies the account's frozen
    ///   identity columns from `ledger_accounts` itself, which doubles as
    ///   the existence check — an unknown account, or a currency the account
    ///   does not hold, joins to nothing, upserts nothing, and comes back as
    ///   a `NULL` counter for the service to refuse;
    /// - the upsert takes the balance row locks in account-id order, held by
    ///   the `ORDER BY` on the `SELECT` feeding it — the statement-level
    ///   form of the ordered per-account upserts that ran here before
    ///   (deterministic lock ordering, batch-wide — ADR-0013, spike 003);
    /// - the entries land through one `unnest` — measured within 2% of COPY
    ///   on this table, the composite foreign keys dominating (ADR-0013 §5)
    ///   — numbered `last_seq - seq_offset` beside the counter the upsert
    ///   returned, which is the service's walk-back with the one subtraction
    ///   moved to where the counter lives.
    ///
    /// The final `SELECT` answers one row per delta (`LEFT JOIN` back onto
    /// the deltas the statement was handed), so a missing account is a row
    /// with a `NULL` counter, never a silently shorter answer.
    async fn claim_and_append(
        &self,
        tx: &mut Self::Tx,
        command: &PostTransaction,
        hash: &[u8],
        payload: &serde_json::Value,
        append: &Append,
    ) -> Result<Option<Appended>, StorageError> {
        let deltas = columns_for_deltas(&append.deltas);
        let (leg_accounts, directions, amounts, leg_currencies) = columns_for_entries(&append.legs);
        let rows: Vec<(Uuid, Uuid, Uuid, String, Option<i64>)> = sqlx::query_as(
            "WITH claimed AS (
                 INSERT INTO ledger_events
                        (tenant_id, kind, source, idempotency_key, idempotency_hash,
                         payload, effective_at)
                 VALUES ($1, 'posting', 'api', $2, $3, $4, $5)
                 ON CONFLICT (tenant_id, idempotency_key) DO NOTHING
                 RETURNING id
             ),
             txn AS (
                 INSERT INTO ledger_transactions (tenant_id, event_id, kind, status, effective_at)
                 SELECT $1, c.id, 'posting', 'posted', $5
                 FROM claimed c
                 RETURNING id
             ),
             delta AS (
                 SELECT d.account_id, d.currency, d.input, d.output, d.legs
                 FROM claimed c
                 CROSS JOIN unnest($6::uuid[], $7::text[], $8::bigint[], $9::bigint[],
                                   $10::bigint[])
                      AS d(account_id, currency, input, output, legs)
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
                        l.currency, 0, b.last_seq - l.seq_offset, $5
                 FROM txn t
                 CROSS JOIN unnest($11::uuid[], $12::text[], $13::bigint[], $14::text[],
                                   $15::bigint[])
                      AS l(account_id, direction, amount_minor, currency, seq_offset)
                 JOIN balance b ON b.account_id = l.account_id AND b.currency = l.currency
             )
             SELECT c.id AS event_id, t.id AS transaction_id,
                    d.account_id, d.currency, b.last_seq
             FROM claimed c
             CROSS JOIN txn t
             CROSS JOIN delta d
             LEFT JOIN balance b ON b.account_id = d.account_id AND b.currency = d.currency
             ORDER BY d.account_id, d.currency",
        )
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
        .fetch_all(&mut **tx)
        .await
        .map_err(storage)?;

        let mut rows = rows.into_iter();
        let Some((event_id, transaction_id, account_id, currency, last_seq)) = rows.next() else {
            return Ok(None);
        };
        let mut balance_upserts = Vec::with_capacity(append.deltas.len());
        balance_upserts.push(BalanceUpsert {
            account_id,
            currency,
            last_seq,
        });
        balance_upserts.extend(
            rows.map(|(_, _, account_id, currency, last_seq)| BalanceUpsert {
                account_id,
                currency,
                last_seq,
            }),
        );
        Ok(Some(Appended {
            event_id,
            transaction_id,
            balance_upserts,
        }))
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
