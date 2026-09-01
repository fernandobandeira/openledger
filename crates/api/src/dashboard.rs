//! The operator dashboard — one HTML file, served beside the API and
//! deliberately not part of it.
//!
//! **Why the binary serves a page at all.** The API has no CORS layer, and
//! adding one to ship a development affordance would be the tail wagging the
//! dog. A page served from the same origin needs none: every `/v1/…` fetch the
//! dashboard makes is a same-origin request, so the whole thing costs one
//! route and no dependency.
//!
//! **Why the route is mounted here rather than in `route_table!`.** That macro
//! expands to both [`crate::ROUTES`] and the router's registrations, and the
//! e2e conformance test holds `ROUTES` against the committed `openapi.json` by
//! set equality *in both directions*. A dashboard route inside the table would
//! therefore have to be documented in the API's own specification — which is a
//! claim about the contract that this page has no business making. It is an
//! inspection window onto a deployment, not an endpoint anyone integrates
//! against, so it is mounted on the finished `Router` instead, carries no
//! `#[utoipa::path]`, and is invisible to every conformance guarantee it must
//! not weaken.

use axum::Router;
use axum::response::Html;

/// Where the page is served, when it is served at all.
pub const PATH: &str = "/dashboard";

/// The page itself, compiled in. One file: no build step, no npm, no CDN, and
/// no asset the binary would have to learn to serve.
const PAGE: &str = include_str!("../../../dashboard/index.html");

/// Whether this deployment serves the dashboard. Off is the default and the
/// safe answer — a deployment that never asked for it must not acquire a route
/// it did not choose — so the choice is named rather than carried as a bare
/// `bool` through three signatures.
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Dashboard {
    Served,
    NotServed,
}

impl Dashboard {
    /// The router with the page mounted on it where this deployment serves it,
    /// and untouched where it does not — so "off" is the absence of a route
    /// and `/dashboard` 404s exactly like any other path nothing registered.
    pub(crate) fn mounted_on(self, router: Router) -> Router {
        match self {
            Self::Served => router.route(PATH, axum::routing::get(page)),
            Self::NotServed => router,
        }
    }
}

/// `Html` is what sets `text/html; charset=utf-8`; the page is `&'static str`,
/// so answering costs a header and a pointer.
async fn page() -> Html<&'static str> {
    Html(PAGE)
}
