//! The operator dashboard: served when the flag says so, absent when it does
//! not, and invisible to the API contract either way.
//!
//! **Why the page is served by the binary at all.** The API has no CORS
//! layer, so a page opened from a `file://` URL sends its requests and can
//! read none of the answers. Serving it from the same process makes every
//! `/v1/…` call same-origin, which costs one route and no dependency —
//! against a CORS layer added to the production surface for the sake of a
//! development affordance.
//!
//! **What the third test here is for, and why it is not in `conformance.rs`.**
//! That file holds the committed OpenAPI document against `api::ROUTES` by set
//! equality in BOTH directions: a route the spec forgot fails as loudly as a
//! route the router lost. A dashboard route inside `route_table!` would
//! therefore have had to be documented in the API's own specification — a
//! claim about the contract that an inspection window has no business making.
//! So it is mounted on the finished `Router` instead, outside the table, and
//! the test below is what says so out loud: the surface the conformance
//! guarantee ranges over is exactly the six `/v1` routes, and the page's
//! existence has not added a seventh.

use crate::support::{TestBook, TestResult, header};

/// The committed spec, by the bytes — the same `include_str!` contract
/// `conformance.rs` takes it under: this binary is stale the moment the file
/// changes, so it can never test yesterday's spec.
const SPEC: &str = include_str!("../../../api/openapi.json");

/// Where the page is served, when it is served at all. Spelled here rather
/// than imported so a silent rename in the api crate fails as a test rather
/// than as a passing test of a different path.
const DASHBOARD: &str = "/dashboard";

/// Two strings from the page itself: the title, and the element the design is
/// built around. Enough to tell "the dashboard was served" from "something
/// answered 200".
const TITLE: &str = "openledger — operator dashboard";
const RAIL: &str = "Cursor rail";

/// Every path the committed document describes, as written.
fn the_paths_the_committed_spec_describes() -> Result<Vec<String>, Box<dyn std::error::Error>> {
    let spec: serde_json::Value = serde_json::from_str(SPEC)?;
    let paths = spec
        .get("paths")
        .and_then(serde_json::Value::as_object)
        .ok_or("the committed spec has no paths object")?;
    Ok(paths.keys().cloned().collect())
}

#[tokio::test]
async fn the_dashboard_is_served_as_html_when_the_flag_is_on() -> TestResult {
    let book = TestBook::new_with_the_dashboard("dashboard_on").await?;

    let response = book.request(reqwest::Method::GET, DASHBOARD).await?;

    assert_eq!(
        response.status(),
        200,
        "--dashboard was passed, so {DASHBOARD} must be served"
    );
    assert_eq!(
        header(&response, "content-type")?,
        "text/html; charset=utf-8",
        "the page is HTML, and a browser is the only thing that will ever ask for it"
    );
    let page = response.text().await?;
    assert!(
        page.contains(TITLE) && page.contains(RAIL),
        "{DASHBOARD} answered 200 with something that is not the dashboard"
    );

    book.assert_reconciled().await
}

#[tokio::test]
async fn the_dashboard_is_a_404_when_the_flag_is_off() -> TestResult {
    // `TestBook::new` is the shipped default, and the flag's absence here is
    // the whole point: off, the route is never mounted, so the page is not
    // withheld by a handler — there is no handler.
    let book = TestBook::new("dashboard_off").await?;

    let response = book.request(reqwest::Method::GET, DASHBOARD).await?;

    assert_eq!(
        response.status(),
        404,
        "--dashboard was not passed, so {DASHBOARD} must be a path nothing registered"
    );

    book.assert_reconciled().await
}

#[test]
fn the_dashboard_route_is_in_neither_the_route_table_nor_the_committed_spec() -> TestResult {
    let routed: Vec<&str> = api::ROUTES.iter().map(|route| route.path).collect();

    let documented = the_paths_the_committed_spec_describes()?;

    // The two halves of the conformance guarantee, each asked about this one
    // path. In the table, the page would enter `ROUTES` and fail set equality
    // against the spec; in the spec, it would become part of the published
    // contract. It is in neither, so both stay exactly as they were.
    assert!(
        !routed.contains(&DASHBOARD),
        "{DASHBOARD} is in api::ROUTES — the dashboard has been mounted inside route_table!, \
         which puts an inspection affordance into the API's own surface"
    );
    assert!(
        !documented.iter().any(|path| path == DASHBOARD),
        "{DASHBOARD} is in the committed spec — the dashboard is not part of the API contract \
         and must carry no #[utoipa::path]"
    );
    // And the stronger statement the two assertions above are instances of:
    // every route the conformance test ranges over is a versioned API route.
    assert!(
        routed.iter().all(|path| path.starts_with("/v1/")),
        "api::ROUTES carries a path outside /v1: {routed:?}"
    );
    Ok(())
}
