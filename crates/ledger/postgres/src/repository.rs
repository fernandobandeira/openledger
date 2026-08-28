//! The repository: [`PgRepository`] and its [`ledger::Repository`] impl,
//! one SQL statement per method, each operating on the open transaction the
//! service began. The trait is implemented here, where the SQL lives — all
//! of this crate's SQL is in this file, and there is no forwarding layer
//! between the port's shapes and the statements. What order the statements
//! run in — and what each result means for the use-case — is the writer
//! service's (`ledger::LedgerService`, in the core crate above), not this
//! file's.

use ledger::{Delta, Direction, Leg, PostTransaction, Repository, StorageError};
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

impl Repository for PgRepository {
    type Tx = Transaction<'static, Postgres>;

    /// ADR-0013 §1 is honored here: the transaction opens by SETTING
    /// `READ COMMITTED`, never by inheriting whatever the deployment
    /// defaulted to. A default of REPEATABLE READ or stricter silently
    /// loses 64–90% of contended writes, and no retry loop rescues them.
    async fn begin(&self) -> Result<Self::Tx, StorageError> {
        let mut tx = self.pool.begin().await.map_err(storage)?;
        sqlx::query("SET TRANSACTION ISOLATION LEVEL READ COMMITTED")
            .execute(&mut *tx)
            .await
            .map_err(storage)?;
        Ok(tx)
    }

    /// Statement A: claim the key. A returned row means this caller is the
    /// first writer.
    async fn claim_event(
        &self,
        tx: &mut Self::Tx,
        command: &PostTransaction,
        hash: &[u8],
        payload: &serde_json::Value,
    ) -> Result<Option<Uuid>, StorageError> {
        let claimed: Option<(Uuid,)> = sqlx::query_as(
            "INSERT INTO ledger_events
                    (tenant_id, kind, source, idempotency_key, idempotency_hash, payload, effective_at)
             VALUES ($1, 'posting', 'api', $2, $3, $4, $5)
             ON CONFLICT (tenant_id, idempotency_key) DO NOTHING
             RETURNING id",
        )
        .bind(command.tenant_id())
        .bind(command.idempotency_key())
        .bind(hash)
        .bind(payload)
        .bind(command.effective_at())
        .fetch_optional(&mut **tx)
        .await
        .map_err(storage)?;
        Ok(claimed.map(|(id,)| id))
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

    async fn insert_transaction(
        &self,
        tx: &mut Self::Tx,
        command: &PostTransaction,
        event_id: Uuid,
    ) -> Result<Uuid, StorageError> {
        let (transaction_id,): (Uuid,) = sqlx::query_as(
            "INSERT INTO ledger_transactions (tenant_id, event_id, kind, status, effective_at)
             VALUES ($1, $2, 'posting', 'posted', $3)
             RETURNING id",
        )
        .bind(command.tenant_id())
        .bind(event_id)
        .bind(command.effective_at())
        .fetch_one(&mut **tx)
        .await
        .map_err(storage)?;
        Ok(transaction_id)
    }

    /// One upsert per account: the balance row's lock IS the serialization
    /// point, and it returns the last issued seq so the entries can be
    /// numbered by walking backwards from the total. The INSERT arm copies
    /// the account's frozen identity columns from ledger_accounts itself —
    /// which is also the existence check: an unknown account, or a currency
    /// the account does not hold, selects zero rows and upserts nothing,
    /// which this method reports as `None`.
    async fn upsert_balance(
        &self,
        tx: &mut Self::Tx,
        tenant_id: &str,
        account_id: &Uuid,
        currency: &str,
        delta: &Delta,
    ) -> Result<Option<i64>, StorageError> {
        let issued: Option<(i64,)> = sqlx::query_as(
            "INSERT INTO ledger_account_balances
                    (tenant_id, account_id, currency, stripe,
                     owner_type, owner_id_key, purpose, category, normal_balance,
                     input, output, last_seq)
             SELECT a.tenant_id, a.id, a.currency, 0,
                    a.owner_type, a.owner_id_key, a.purpose, a.category, a.normal_balance,
                    $4, $5, $6
             FROM ledger_accounts a
             WHERE a.tenant_id = $1 AND a.id = $2 AND a.currency = $3
             ON CONFLICT (tenant_id, account_id, currency, stripe) DO UPDATE
             SET input      = ledger_account_balances.input + EXCLUDED.input,
                 output     = ledger_account_balances.output + EXCLUDED.output,
                 last_seq   = ledger_account_balances.last_seq + EXCLUDED.last_seq,
                 updated_at = now()
             RETURNING last_seq",
        )
        .bind(tenant_id)
        .bind(account_id)
        .bind(currency)
        .bind(delta.input)
        .bind(delta.output)
        .bind(delta.legs)
        .fetch_optional(&mut **tx)
        .await
        .map_err(storage)?;
        Ok(issued.map(|(last_seq,)| last_seq))
    }

    /// Append all entries in one multi-row statement — `unnest` measured
    /// within 2% of COPY on this table, the composite foreign keys
    /// dominating (ADR-0013 §5). `seqs` is parallel to `legs`, one seq per
    /// row. The domain's `Direction` is rendered into the SQL dialect's
    /// string here, at the bind site, and nowhere else — exhaustively, so a
    /// third variant would refuse to compile rather than default to a side.
    async fn insert_entries(
        &self,
        tx: &mut Self::Tx,
        command: &PostTransaction,
        transaction_id: Uuid,
        legs: &[Leg],
        seqs: &[i64],
    ) -> Result<(), StorageError> {
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
        sqlx::query(
            "INSERT INTO ledger_entries
                    (tenant_id, transaction_id, account_id, direction, amount_minor,
                     currency, stripe, account_seq, effective_at)
             SELECT $1, $2, u.account_id, u.direction::ledger_direction, u.amount_minor,
                    u.currency, 0, u.account_seq, $3
             FROM unnest($4::uuid[], $5::text[], $6::bigint[], $7::text[], $8::bigint[])
                  AS u(account_id, direction, amount_minor, currency, account_seq)",
        )
        .bind(command.tenant_id())
        .bind(transaction_id)
        .bind(command.effective_at())
        .bind(&account_ids)
        .bind(&directions)
        .bind(&amounts)
        .bind(&currencies)
        .bind(seqs)
        .execute(&mut **tx)
        .await
        .map_err(storage)?;
        Ok(())
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
