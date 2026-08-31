//! The port, and the errors it can answer with. One trait, one method: the
//! api crate consumes this and never the adapter (the composition root in
//! crates/openledger is where the two meet).

use uuid::Uuid;

use crate::domain::{PostTransaction, Posted};

/// The port. One consumer-facing capability — post a transaction — so one
/// method; anything else the API grows must earn its place here first.
///
/// `post` is a native async fn stated as RPITIT with an explicit `+ Send`
/// bound (an axum handler's future must be `Send`, and bare `async fn` in a
/// trait cannot promise that to a generic caller). The cost of writing it this
/// way is dyn-compatibility: `dyn Ledger` does not exist, so consumers take
/// the port as a generic parameter. With exactly one adapter that trade is
/// free — see the router's comment in the api crate for the consuming side.
pub trait Ledger: Send + Sync {
    /// Post atomically, or return the stored result of having done so —
    /// ADR-0013's replay contract, restated on the port so every adapter
    /// carries it.
    fn post(
        &self,
        command: &PostTransaction,
    ) -> impl Future<Output = Result<Posted, WriteError>> + Send;
}

/// What an adapter can answer instead of `Posted`. Every variant except
/// `Storage` promises "nothing was written", and the writer keeps that
/// promise with a rollback, not a hope.
pub enum WriteError {
    /// Same idempotency key, different body. ADR-0013: a distinct error the
    /// caller must change the request to escape — and no row was written.
    KeyReused,
    /// A posting names an account that does not exist, or a currency its
    /// account does not hold. Nothing was written.
    UnknownAccount { account_id: Uuid, currency: String },
    /// Coalescing the legs overflowed 64-bit minor units — exactly
    /// arithmetic overflow, nothing else wears this name. Nothing was
    /// written.
    Overflow,
    /// `resolves_id` names a transaction that does not exist on this
    /// tenant's book. Nothing was written.
    UnknownResolveTarget { resolves_id: Uuid },
    /// `resolves_id` names a transaction that is not pending — resolving
    /// posted history is the −49,223 counterexample ADR-0004 recorded, and
    /// the writer is the layer that refuses it. Nothing was written.
    ResolveTargetNotPending { resolves_id: Uuid },
    /// The pending transaction `resolves_id` names already has its one
    /// resolution — pending → posted happens once. Nothing was written.
    AlreadyResolved { resolves_id: Uuid },
    /// The writer reached a state its own derivations promise cannot happen
    /// — a leg without a counter in maps derived from those same legs, a
    /// rendering that failed after `PostTransaction::new` validated it.
    /// Nothing the bracket wrote survives it. The caller gets a 500 with no
    /// internals; the string is for the operator's log, which is the only
    /// place it goes.
    Internal(String),
    /// The storage failed. This carried `sqlx::Error` while the adapter lived
    /// in this crate — "opaque wrapper deferred until a second adapter needs
    /// one", the old comment said. The second consumer arrived, but as an
    /// enforcement requirement rather than an adapter: deny.toml's capability
    /// map holds only if THIS crate names no sqlx type anywhere, so the
    /// variant is the opaque boxed error now, and the Postgres error type
    /// stays inside the adapter crate (crates/ledger/postgres).
    Storage(Box<dyn std::error::Error + Send + Sync>),
}
