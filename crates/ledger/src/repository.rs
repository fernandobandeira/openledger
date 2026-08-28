//! The outbound repository port: what the writer service asks of storage —
//! one method per statement the adapter runs, plus the transaction bracket
//! around them.
//!
//! This seam is NOT storage-agnosticism. There is one adapter
//! (`crates/ledger/postgres`, a nested workspace member) and no swappability
//! promise; ADR-0004 still owns why the SQL is abstracted no further than
//! this — it is the product's reasoning about PostgreSQL, not an
//! interchangeable backend. The seam exists to place the COMMAND in the
//! core: the claim-or-replay use-case is orchestration, not SQL, so it lives
//! in `service` behind these methods — and deny.toml's ratchet holds because
//! every signature here names only domain types, `serde_json::Value` (the
//! payload the event log stores), and the opaque storage error. No sqlx.

use uuid::Uuid;

use crate::domain::PostTransaction;
use crate::postings::{Delta, Leg};

/// The opaque storage failure. The port names no backend error type — the
/// Postgres error stays inside the adapter crate, boxed at exactly one
/// function — and the service forwards it unread into
/// [`WriteError::Storage`](crate::WriteError::Storage).
pub type StorageError = Box<dyn std::error::Error + Send + Sync>;

/// The repository. Each method is a native async fn stated as RPITIT with an
/// explicit `+ Send` bound, for the same reason the [`Ledger`](crate::Ledger)
/// port states it that way: the service's future must be `Send` for an axum
/// handler, and a bare `async fn` in a trait cannot promise that to a
/// generic caller.
pub trait Repository: Send + Sync {
    /// The open database transaction the statement methods operate on and
    /// [`commit`](Repository::commit) / [`rollback`](Repository::rollback)
    /// consume. Opaque to the service: it threads the value through and
    /// decides when the bracket closes, nothing more.
    type Tx: Send;

    /// Open the one database transaction a post runs in. ADR-0013 §1 is this
    /// method's contract: the transaction it yields runs at READ COMMITTED
    /// because the adapter SETS it, never because a deployment default
    /// happened to agree — under inherited REPEATABLE READ or stricter,
    /// 64–90% of contended writes fail and no retry loop rescues them. The
    /// invariant is stated here; the SQL that honors it lives in the adapter.
    fn begin(&self) -> impl Future<Output = Result<Self::Tx, StorageError>> + Send;

    /// Statement A: claim the idempotency key, storing the command's hash
    /// and `payload` (its JSON rendering) beside it. A returned event id
    /// means this caller is the first writer.
    fn claim_event(
        &self,
        tx: &mut Self::Tx,
        command: &PostTransaction,
        hash: &[u8],
        payload: &serde_json::Value,
    ) -> impl Future<Output = Result<Option<Uuid>, StorageError>> + Send;

    /// Statement B: the stored `(event_id, transaction_id)` of the already
    /// claimed key — with the hash in the lookup's WHERE, never compared by
    /// the caller: a same-key/different-body replay finds NO row, so a
    /// caller that forgets to compare gets nothing instead of the wrong
    /// stored result (ADR-0013 §2).
    fn stored_result(
        &self,
        tx: &mut Self::Tx,
        command: &PostTransaction,
        hash: &[u8],
    ) -> impl Future<Output = Result<Option<(Uuid, Option<Uuid>)>, StorageError>> + Send;

    /// Insert the posted transaction row for the claimed event; returns its
    /// id.
    fn insert_transaction(
        &self,
        tx: &mut Self::Tx,
        command: &PostTransaction,
        event_id: Uuid,
    ) -> impl Future<Output = Result<Uuid, StorageError>> + Send;

    /// Apply one account's coalesced delta to its balance row — the row lock
    /// IS the serialization point — returning the account's `last_seq` after
    /// this batch, or `None` when the account does not exist or does not
    /// hold this currency (the upsert doubles as the existence check).
    fn upsert_balance(
        &self,
        tx: &mut Self::Tx,
        tenant_id: &str,
        account_id: &Uuid,
        currency: &str,
        delta: &Delta,
    ) -> impl Future<Output = Result<Option<i64>, StorageError>> + Send;

    /// Append all entries in one statement. `seqs` is parallel to `legs`,
    /// one seq per row.
    fn insert_entries(
        &self,
        tx: &mut Self::Tx,
        command: &PostTransaction,
        transaction_id: Uuid,
        legs: &[Leg],
        seqs: &[i64],
    ) -> impl Future<Output = Result<(), StorageError>> + Send;

    /// Commit the bracket: the event claim and everything it caused become
    /// durable together.
    fn commit(&self, tx: Self::Tx) -> impl Future<Output = Result<(), StorageError>> + Send;

    /// Abandon the bracket. Every refusal the service answers promises
    /// "nothing was written", and this is how it keeps the promise.
    fn rollback(&self, tx: Self::Tx) -> impl Future<Output = Result<(), StorageError>> + Send;
}
