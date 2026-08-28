//! The committed OpenAPI document against the router's own route table and
//! the running server. This is the project's schema-snapshot instinct applied
//! to the API surface, and it is the working replacement for the structural
//! guarantee `utoipa-axum`'s `routes!` macro would have given (the crate is
//! refused — spike 021): with a plain `axum::Router`, the path in an
//! annotation and the path in the router are two strings nothing compares
//! (spike 021 D1) — except this test.
//!
//! What it holds: the spec's (method, path) set EQUALS `api::ROUTES` — the
//! table `api::router` is built from, so a table entry is a live route by
//! construction, and there is no hand copy here to forget. Then the wire, per
//! table entry, telling a missing path from a missing method: the documented
//! method must answer neither 404 (the path is not routed) nor 405 (the path
//! is routed, but under some other method), and an UNdocumented method on the
//! same path must answer exactly 405 — which is what catches a route mounted
//! under the wrong verb, the case a bare non-404 probe was blind to.
//!
//! What it deliberately does not hold: the documented statuses, bodies and
//! headers per response. That half lives in the per-endpoint e2e files,
//! which grow with the surface rather than for free.

use std::collections::BTreeSet;

use crate::support::{TestBook, TestResult};

/// The committed spec, by the bytes: `include_str!` means this test binary is
/// stale the moment the file changes, so it can never test yesterday's spec.
/// The api crate's own `tests/spec.rs` holds the other edge — that these bytes
/// match what the annotations generate.
const SPEC: &str = include_str!("../../../api/openapi.json");

/// The methods an OpenAPI path item can carry; everything else on the item
/// (`parameters`, `summary`, …) is not a route. Also the pool the
/// undocumented-method probe draws from.
const METHODS: [&str; 8] = [
    "get", "put", "post", "delete", "options", "head", "patch", "trace",
];

#[tokio::test]
async fn the_spec_the_route_table_and_the_wire_agree() -> TestResult {
    // The router's own table, exported by the api crate and consumed here —
    // `api::router` is BUILT from this same table, so an entry in it is a
    // live route by construction, never a claim.
    let routed: BTreeSet<(String, String)> = api::ROUTES
        .iter()
        .map(|route| (route.method.to_owned(), route.path.to_owned()))
        .collect();

    let spec: serde_json::Value = serde_json::from_str(SPEC)?;
    let paths = spec
        .get("paths")
        .and_then(serde_json::Value::as_object)
        .ok_or("the committed spec has no paths object")?;
    let mut documented: BTreeSet<(String, String)> = BTreeSet::new();
    for (path, item) in paths {
        let item = item
            .as_object()
            .ok_or_else(|| format!("path item {path} is not an object"))?;
        for method in METHODS.into_iter().filter(|m| item.contains_key(*m)) {
            documented.insert((method.to_owned(), path.clone()));
        }
    }

    // Set equality both directions: a route the spec forgot fails as loudly
    // as a route the router lost.
    assert_eq!(
        documented, routed,
        "the committed spec and api::ROUTES disagree about the API surface; \
         if you changed the route table, update the annotations and \
         regenerate the spec (make openapi)"
    );

    let book = TestBook::new("conformance").await?;
    for route in api::ROUTES {
        // The documented method, on the wire. A bodiless request to a real
        // route is refused for its body (415/422/400/413), never for its
        // path (404) — and never for its METHOD: a 405 here would mean the
        // path is routed but under some other verb, which a bare non-404
        // check could not tell from success.
        let response = book
            .request(
                route.method.to_uppercase().parse::<reqwest::Method>()?,
                route.path,
            )
            .await?;
        assert_ne!(
            response.status(),
            404,
            "{} {} is in api::ROUTES (and the spec) but the server answers 404 for it",
            route.method,
            route.path
        );
        assert_ne!(
            response.status(),
            405,
            "{} {} is in api::ROUTES (and the spec) but the server answers 405 — \
             the path is routed under a different method than the documented one",
            route.method,
            route.path
        );

        // An UNdocumented method on the same path must be refused as a
        // method failure (405), not a path failure — the other half of
        // telling the two apart.
        if let Some(undocumented) = METHODS
            .iter()
            .find(|m| !routed.contains(&((**m).to_owned(), route.path.to_owned())))
        {
            let response = book
                .request(
                    undocumented.to_uppercase().parse::<reqwest::Method>()?,
                    route.path,
                )
                .await?;
            assert_eq!(
                response.status(),
                405,
                "{} {} is not documented, so the server must answer 405 (method \
                 known-path refused), not {}",
                undocumented,
                route.path,
                response.status()
            );
        }
    }
    Ok(())
}
