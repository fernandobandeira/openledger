//! The HTTP surface — a thin mapping over the writer, and deliberately nothing
//! more. The guarantee lives in the posting type the handler deserializes into,
//! never here: an API check is "a check, not a shape" (ADR-0005). What this
//! layer owns is the wire contract ADR-0013 specified before it existed:
//! 422 for the poisoned replay, `Idempotency-Replayed` on every accepted
//! response, and no invented 409 — a concurrent duplicate blocks on the key
//! claim and finds a durable result, so there is no in-flight state to name.
//!
//! One endpoint while the core structure is under review. No authentication
//! yet, and the tenant is named in the body: the trust story is the deployment
//! perimeter's until an auth decision exists.
//!
//! This crate sees the ledger through its port, [`ledger::Ledger`], not
//! through the Postgres writer — the composition root (crates/openledger)
//! chooses the adapter. The `utoipa` annotations beside the handler are the
//! source of the committed `openapi.json` one directory up; `tests/spec.rs`
//! is what keeps the two from drifting, and the e2e conformance test is what
//! keeps the annotations honest about the router — it consumes [`ROUTES`],
//! which the router itself is built from (spike 021: `utoipa-axum`'s
//! `routes!` macro would have pinned path drift structurally, but the crate
//! is refused — 19 stale months and RUSTSEC-2024-0436 via `paste`).

use axum::Router;
use ledger::Ledger;

mod serve;
mod spec;
mod transactions;

pub use serve::{ServeError, run};
pub use spec::openapi_json;

/// The router's state, named: today it holds the one port the write path
/// consumes. A struct rather than the bare port so the next port — reads
/// will get their own when the first read endpoint arrives — lands as one
/// more field, not a re-shaping of every handler's `State` extractor.
#[derive(Clone)]
pub struct AppState<L> {
    pub(crate) ledger: L,
}

/// One row of the route table: the method — lowercase, the spelling an
/// OpenAPI path item uses — and the path as axum registers it.
pub struct Route {
    pub method: &'static str,
    pub path: &'static str,
}

// [`ROUTES`] and the router's registrations are expanded from the ONE list
// in the `route_table!` invocation below, so a table entry IS a live route
// by construction — there is no hand copy anywhere to drift (spike 021 D1's
// two-strings-nothing-compares gap, closed from the router's side; the
// annotation side stays the conformance test's, which holds this table
// against the committed spec and the wire, both directions).
macro_rules! route_table {
    ($ledger:ident => $( $method:ident $path:literal $handler:expr ),+ $(,)?) => {
        /// Every route [`router`] registers, derived from the same expansion
        /// that registers it. The e2e conformance test consumes this: spec
        /// paths ↔ this table (set equality both ways), and the live probes
        /// walk it.
        pub const ROUTES: &[Route] = &[$( Route { method: stringify!($method), path: $path } ),+];

        /// The registrations themselves, from the same list as [`ROUTES`].
        fn mounted<$ledger>() -> Router<AppState<$ledger>>
        where
            $ledger: Ledger + Clone + 'static,
        {
            Router::new()$( .route($path, axum::routing::$method($handler)) )+
        }
    };
}

route_table! { L =>
    post "/v1/transactions" transactions::post_transaction::<L>,
}

/// The router, over any implementation of the port.
///
/// Generic rather than `dyn` — a considered trade, not a habit: the port's
/// `post` is a native async fn (RPITIT `+ Send`), which has no `dyn Ledger`
/// form without boxing every call's future. With exactly one adapter the
/// generic is monomorphized once, the composition root names the type in one
/// place, and nothing is boxed on the write path. The day a second adapter
/// must be chosen at runtime, box the future in the port and take `Arc<dyn>`
/// here — that decision belongs to the ledger crate, not this one.
pub fn router<L>(ledger: L) -> Router
where
    L: Ledger + Clone + 'static,
{
    mounted::<L>().with_state(AppState { ledger })
}
