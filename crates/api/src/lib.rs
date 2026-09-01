//! The HTTP surface — a thin mapping over the writer, and deliberately nothing
//! more. The guarantee lives in the posting type the handler deserializes into,
//! never here: an API check is "a check, not a shape" (ADR-0005). What this
//! layer owns is the wire contract ADR-0013 specified before it existed:
//! 422 for the poisoned replay, `Idempotency-Replayed` on every accepted
//! response, and no invented 409 — a concurrent duplicate blocks on the key
//! claim and finds a durable result, so there is no in-flight state to name.
//!
//! Eight endpoints: two writes, and the six reads — a balance, three reports,
//! a transaction read-back (ADR-0019) and one account listing (ADR-0021). The
//! second write is `POST /v1/accounts`, the operation that had no API at all
//! until ADR-0021: accounts were seeded by SQL, which made `psql` a required
//! part of onboarding a ledger whose whole adoption surface is this crate.
//!
//! No authentication by decision, not omission (ADR-0017): the ledger deploys
//! internally only, the trust story is the deployment perimeter's, and the
//! tenant named in the body (on a read, in the query string) is data scoping —
//! which book — never an identity claim.
//!
//! **The read half is a mapping too, and its judgement lives one ring in.**
//! The cursor rule — pin an absent cursor server-side, refuse a plausible-
//! looking one, name the chart version, always answer with the cursor used —
//! is `ledger::ReportService`'s, and the `BEGIN … READ ONLY` / `SET LOCAL
//! ROLE` / `set_config` bracket that fences a read to one tenant is the
//! adapter's. What this crate owns is which status, which header, which error
//! `type` (ADR-0019's grammar, declared per endpoint), and the two parses a
//! query string needs: an RFC 3339 instant and a cursor's text.
//!
//! This crate sees the ledger through its ports, [`ledger::Ledger`] and
//! [`ledger::Reports`], not through PostgreSQL — the composition root
//! (crates/openledger) chooses the adapters. It could not do otherwise:
//! `deny.toml` refuses `api` the `db` crate, so building the read pool here —
//! the obvious shortcut, since the handler is what needs it — is a red
//! `cargo deny check bans` (ADR-0019 E5). The `utoipa` annotations beside the handler are the
//! source of the committed `openapi.json` one directory up; `tests/spec.rs`
//! is what keeps the two from drifting, and the e2e conformance test is what
//! keeps the annotations honest about the router — it consumes [`ROUTES`],
//! which the router itself is built from (spike 021: `utoipa-axum`'s
//! `routes!` macro would have pinned path drift structurally, but the crate
//! is refused — 19 stale months and RUSTSEC-2024-0436 via `paste`).

use axum::Router;
use ledger::{Ledger, Reports};

mod accounts;
mod dashboard;
mod reports;
mod serve;
mod spec;
mod transactions;
mod wire;

pub use dashboard::Dashboard;
pub use serve::{ServeError, run};
pub use spec::openapi_json;

/// The router's state: one field per inbound port. It was written with the
/// second one in mind — *"a struct rather than the bare port so the next port
/// — reads will get their own when the first read endpoint arrives — lands as
/// one more field"* — and that day is ADR-0019's, so `reports` is that field
/// and no handler's `State` extractor was reshaped to make room.
///
/// Two ports, so every handler is generic in both, including the ones that
/// touch only one of them: `State<AppState<L, R>>` names the whole state, and
/// the alternative — a `FromRef` newtype per port — buys a shorter signature
/// with a second layer to keep in step.
#[derive(Clone)]
pub struct AppState<L, R> {
    pub(crate) ledger: L,
    pub(crate) reports: R,
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
    ($ledger:ident, $reports:ident => $( $method:ident $path:literal $handler:expr ),+ $(,)?) => {
        /// Every route [`router`] registers, derived from the same expansion
        /// that registers it. The e2e conformance test consumes this: spec
        /// paths ↔ this table (set equality both ways), and the live probes
        /// walk it.
        pub const ROUTES: &[Route] = &[$( Route { method: stringify!($method), path: $path } ),+];

        /// The registrations themselves, from the same list as [`ROUTES`].
        fn mounted<$ledger, $reports>() -> Router<AppState<$ledger, $reports>>
        where
            $ledger: Ledger + Clone + 'static,
            $reports: Reports + Clone + 'static,
        {
            Router::new()$( .route($path, axum::routing::$method($handler)) )+
        }
    };
}

route_table! { L, R =>
    post "/v1/transactions" transactions::post_transaction::<L, R>,
    get "/v1/transactions/{transaction_id}" transactions::get_transaction::<L, R>,
    post "/v1/accounts" accounts::open_account::<L, R>,
    get "/v1/accounts" accounts::list_accounts::<L, R>,
    get "/v1/accounts/{account_id}/balance" reports::get_account_balance::<L, R>,
    get "/v1/reports/trial-balance" reports::get_trial_balance::<L, R>,
    get "/v1/reports/balance-sheet" reports::get_balance_sheet::<L, R>,
    get "/v1/reports/income-statement" reports::get_income_statement::<L, R>,
}

/// The router, over any implementation of the two ports.
///
/// This is the API and only the API: every route it carries came out of
/// `route_table!` above, so it is exactly what [`ROUTES`] names and exactly
/// what the committed specification describes. The operator dashboard — an
/// inspection affordance, off by default — is mounted onto the result of this
/// by `serve`, outside the table, for the reasons the `dashboard` module
/// states.
///
/// Generic rather than `dyn` — a considered trade, not a habit: both ports'
/// methods are native async fns (RPITIT `+ Send`), which have no `dyn` form
/// without boxing every call's future. With exactly one adapter each the
/// generics are monomorphized once, the composition root names the types in
/// one place, and nothing is boxed on either path. The day a second adapter
/// must be chosen at runtime, box the future in the port and take `Arc<dyn>`
/// here — that decision belongs to the ledger crate, not this one.
pub fn router<L, R>(ledger: L, reports: R) -> Router
where
    L: Ledger + Clone + 'static,
    R: Reports + Clone + 'static,
{
    mounted::<L, R>().with_state(AppState { ledger, reports })
}
