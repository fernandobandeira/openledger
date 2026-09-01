//! The committed OpenAPI document against the router's own route table and
//! the running server. This is the project's schema-snapshot instinct applied
//! to the API surface, and it is the working replacement for the structural
//! guarantee `utoipa-axum`'s `routes!` macro would have given (the crate is
//! refused — spike 021): with a plain `axum::Router`, the path in an
//! annotation and the path in the router are two strings nothing compares
//! (spike 021 D1) — except this file.
//!
//! **Two tests, because the two halves cost three orders of magnitude
//! apart.** The set-equality half is a parse and a `BTreeSet` compare: no
//! database, no server, microseconds, and it fails on a mis-annotated route
//! whether or not anything can be spawned. The wire half migrates a scratch
//! database and spawns the compiled binary, so it is held on its own rather
//! than as a second act phase behind the cheap one — where a broken spawn
//! would report itself as a conformance failure and a spec drift would be
//! reported by a test that had already spent a database finding it.
//!
//! What the pair holds: the spec's (method, path) set EQUALS `api::ROUTES` —
//! the table `api::router` is built from, so a table entry is a live route by
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

/// Every (method, path) the router actually serves. `api::router` is BUILT
/// from this same table, so an entry in it is a live route by construction,
/// never a claim — and nothing here counts the entries, so the table is free
/// to grow.
fn the_surface_the_router_serves() -> BTreeSet<(String, String)> {
    api::ROUTES
        .iter()
        .map(|route| (route.method.to_owned(), route.path.to_owned()))
        .collect()
}

/// Every (method, path) the committed document describes, read out of its
/// `paths` object one path item at a time.
fn the_surface_the_committed_spec_describes()
-> Result<BTreeSet<(String, String)>, Box<dyn std::error::Error>> {
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
    Ok(documented)
}

/// A bodiless request at one method and path. Only probes: the status it came
/// back with is the caller's to read, in the caller's own assert phase.
async fn probe(
    book: &TestBook,
    method: &str,
    path: &str,
) -> Result<reqwest::Response, Box<dyn std::error::Error>> {
    Ok(book
        .request(method.to_uppercase().parse::<reqwest::Method>()?, path)
        .await?)
}

/// The documented method reached the route it documents. A bodiless request
/// to a real route is refused for its body (415/422/400/413), never for its
/// path (404) — and never for its METHOD: a 405 here would mean the path is
/// routed but under some other verb, which a bare non-404 check could not
/// tell from success.
fn assert_the_documented_method_reached_its_route(
    response: &reqwest::Response,
    method: &str,
    path: &str,
) {
    assert_ne!(
        response.status(),
        404,
        "{method} {path} is in api::ROUTES (and the spec) but the server answers 404 for it"
    );
    assert_ne!(
        response.status(),
        405,
        "{method} {path} is in api::ROUTES (and the spec) but the server answers 405 — \
         the path is routed under a different method than the documented one"
    );
}

/// An UNdocumented method on a documented path was refused as a method
/// failure (405), not a path failure — the other half of telling the two
/// apart.
fn assert_an_undocumented_method_was_refused_as_a_method(
    response: &reqwest::Response,
    method: &str,
    path: &str,
) {
    assert_eq!(
        response.status(),
        405,
        "{method} {path} is not documented, so the server must answer 405 (method \
         known-path refused), not {}",
        response.status()
    );
}

/// A method `path` does NOT document, or `None` where the table documents all
/// eight — nothing to probe then, and nothing this test can say.
fn a_method_the_table_does_not_document(
    routed: &BTreeSet<(String, String)>,
    path: &str,
) -> Option<&'static str> {
    METHODS
        .into_iter()
        .find(|method| !routed.contains(&((*method).to_owned(), path.to_owned())))
}

#[test]
fn the_committed_spec_documents_exactly_the_routes_the_router_serves() -> TestResult {
    let routed = the_surface_the_router_serves();

    let documented = the_surface_the_committed_spec_describes()?;

    // Set equality both directions: a route the spec forgot fails as loudly
    // as a route the router lost.
    assert_eq!(
        documented, routed,
        "the committed spec and api::ROUTES disagree about the API surface; \
         if you changed the route table, update the annotations and \
         regenerate the spec (make openapi)"
    );
    Ok(())
}

#[tokio::test]
async fn every_documented_route_answers_its_own_method_and_405s_the_others() -> TestResult {
    let book = TestBook::new("conformance").await?;
    let routed = the_surface_the_router_serves();

    for route in api::ROUTES {
        let documented_method = probe(&book, route.method, route.path).await?;

        assert_the_documented_method_reached_its_route(
            &documented_method,
            route.method,
            route.path,
        );

        // ...and the same path under a method the table does NOT document,
        // which is the other half of telling a missing path from a missing
        // method.
        let Some(undocumented) = a_method_the_table_does_not_document(&routed, route.path) else {
            continue;
        };
        let undocumented_method = probe(&book, undocumented, route.path).await?;

        assert_an_undocumented_method_was_refused_as_a_method(
            &undocumented_method,
            undocumented,
            route.path,
        );
    }
    Ok(())
}
