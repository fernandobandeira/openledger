//! The outbound repository port: what the writer service asks of storage —
//! one method per statement the adapter runs, plus the transaction bracket
//! around them. Since single-call posting (roadmap M3, spike 003) the
//! first-writer path IS one statement, so the port carries two: the claim
//! with the whole append riding on it, and the replay lookup.
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
use crate::postings::Append;

/// What the single call answered for one coalesced delta, in account order:
/// the counter the balance upsert returned, or `None` when the upsert's
/// existence check found no such account holding this currency — the
/// service turns the first `None` into the refusal that names it.
pub struct BalanceUpsert {
    pub account_id: Uuid,
    pub currency: String,
    pub last_seq: Option<i64>,
}

/// The first writer's appended posting, as the single call reports it: the
/// claimed event, the transaction it caused, and each delta's balance
/// upsert. Everything it names is still uncommitted — the service closes
/// the bracket.
pub struct Appended {
    pub event_id: Uuid,
    pub transaction_id: Uuid,
    pub balance_upserts: Vec<BalanceUpsert>,
}

/// Why the single call refused to write a RESOLVING transaction — the
/// semantic linkage the schema deliberately does not hold (ADR-0004's
/// counterexample: a posted transaction "resolved" by another posted one
/// took revenue to −49,223 with every declarative check green). The
/// statement diagnoses; the service names the refusal; nothing is written.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ResolveRefusal {
    /// `resolves_id` names no transaction on this tenant's book.
    TargetMissing,
    /// The target exists and is not pending — there is nothing to resolve.
    TargetNotPending,
    /// The target already has its one resolution (`uq_txn__one_resolution`
    /// is the backstop; the sequential case is diagnosed before the index
    /// has to speak).
    AlreadyResolved,
}

/// What the single call answered after claiming the key: the append, or —
/// for a resolving transaction whose target failed the pending-and-
/// unresolved gate — the diagnosis. Either way the key WAS claimed in the
/// open transaction; a refusal is made true by the service's rollback.
pub enum Claimed {
    Appended(Appended),
    ResolutionRefused(ResolveRefusal),
}

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

    /// Statement A, carrying the whole append with it — single-call posting
    /// (roadmap M3, measured by spike 003): claim the idempotency key,
    /// storing the command's hash and `payload` (its JSON rendering) beside
    /// it, and — only when the claim returns a row — insert the transaction,
    /// upsert every delta's balance row in account order, and append the
    /// entries numbered `last_seq - offset`, all in this ONE statement.
    /// `append` is the planned append: legs in posting order, one offset per
    /// leg, deltas iterating in account-id order — and the statement must
    /// preserve that order when it takes the balance row locks.
    ///
    /// `Some` means this caller is the first writer: either the append
    /// already happened (uncommitted), or — for a resolving transaction —
    /// the statement's gate found the target unresolvable and diagnosed it
    /// ([`Claimed::ResolutionRefused`]). On that refused path the gate
    /// withholds only the transaction row and the entries hanging off it:
    /// the key claim and the balance upserts DID run, uncommitted, because
    /// they depend on the claim and not the transaction — which is exactly
    /// why the service answers the refusal only after rolling the bracket
    /// back. `None` means an earlier caller claimed the key and NOTHING
    /// here ran — the claim's replay half stays the separate
    /// [`stored_result`](Repository::stored_result), because folding the
    /// two is the one-statement hole ADR-0013 §2 reproduced.
    fn claim_and_append(
        &self,
        tx: &mut Self::Tx,
        command: &PostTransaction,
        hash: &[u8],
        payload: &serde_json::Value,
        append: &Append,
    ) -> impl Future<Output = Result<Option<Claimed>, StorageError>> + Send;

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

    /// Commit the bracket: the event claim and everything it caused become
    /// durable together.
    fn commit(&self, tx: Self::Tx) -> impl Future<Output = Result<(), StorageError>> + Send;

    /// Abandon the bracket. Every refusal the service answers promises
    /// "nothing was written", and this is how it keeps the promise.
    fn rollback(&self, tx: Self::Tx) -> impl Future<Output = Result<(), StorageError>> + Send;
}
