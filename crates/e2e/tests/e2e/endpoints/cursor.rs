//! `GET /v1/cursor` — the commit horizon, and nothing else.
//!
//! **Why a route exists for one scalar.** ADR-0019 refused a cursor-minting
//! endpoint because *"every report already returns the cursor it used"*. That
//! is true, and it is what made asking for the horizon ALONE cost a whole
//! report: a dashboard refreshing it issues a trial balance over
//! `0001-01-01`…`9999-12-31` for one number, which on a large book is the
//! ~28-second query ADR-0019's own cost list records. The refusal is qualified
//! rather than overturned, and this file is where the qualification is held.
//!
//! What it holds: that the route answers a cursor at all, that the value is
//! USABLE — a report pinned at it re-runs, which is the only property that
//! makes the endpoint worth having — and that the horizon is the CLUSTER's
//! rather than one book's, which is the sentence the endpoint's own
//! description makes and which a reader would otherwise have to take on faith.
//!
//! It is a resource of its own rather than a file under `reports/`: `/v1/cursor`
//! is not `/v1/reports/*`, it pins nothing, and it names no range, no instant
//! and no chart version.

use crate::support::{
    TestBook, TestResult, a_report_issued, cursor_path, pinned_cursor_of, post_a_charge_dated,
    refusal_type, row_of_the_account, trial_balance_path,
};

const CHARGE_MINOR: i64 = 2500;
const CHARGE_DATE: &str = "2026-08-27T12:00:00Z";
const EFFECTIVE_FROM: &str = "2026-08-01T00:00:00Z";
const EFFECTIVE_TO: &str = "2026-09-01T00:00:00Z";

/// The horizon a route answered.
fn cursor_of(answer: &serde_json::Value) -> Option<&str> {
    answer.get("cursor").and_then(serde_json::Value::as_str)
}

#[tokio::test]
async fn the_horizon_is_answered_on_its_own_and_is_a_cursor_a_report_can_be_pinned_at() -> TestResult
{
    // The endpoint's whole argument in one test: the scalar comes back
    // without a report behind it, and it is the SAME value a report would
    // have pinned itself at — so a caller can store this one and re-run
    // exactly the report they are looking at.
    let book = TestBook::new("cursor_endpoint").await?;
    let (receivable, revenue) = book.fixture_accounts().await?;
    post_a_charge_dated(
        &book,
        "charge-1",
        CHARGE_DATE,
        CHARGE_MINOR,
        revenue,
        receivable,
    )
    .await?;
    book.wait_for_the_horizon_to_retire_this_book().await?;

    let (status, answer) = book.read(&cursor_path("t1")).await?;

    assert_eq!(status.as_u16(), 200, "{answer}");
    let horizon = cursor_of(&answer)
        .ok_or_else(|| format!("the answer carried no cursor: {answer}"))?
        .to_owned();
    // A decimal string, never a JSON number: an `xid8` is a 64-bit unsigned
    // value and a JSON number does not carry one exactly.
    assert!(
        horizon.bytes().all(|byte| byte.is_ascii_digit()) && !horizon.is_empty(),
        "the horizon must be an exact-integer decimal string; it was {horizon:?}"
    );
    // And it is usable: a report pinned at it runs, answers, and says it ran
    // there. A cursor that came back but could not be sent is a scalar, not a
    // cursor.
    let pinned = a_report_issued(
        &book,
        &trial_balance_path("t1", EFFECTIVE_FROM, EFFECTIVE_TO, &[("cursor", &horizon)]),
    )
    .await?;
    assert_eq!(pinned_cursor_of(&pinned)?, horizon, "{pinned}");
    // The charge is inside it — the point of a horizon is that everything
    // strictly below has finished committing, so a report pinned here sees
    // the book as it stands.
    assert_eq!(
        row_of_the_account(&pinned, receivable)?,
        Some((
            CHARGE_MINOR.to_string(),
            "0".to_owned(),
            CHARGE_MINOR.to_string()
        )),
        "{pinned}"
    );

    book.assert_reconciled().await
}

#[tokio::test]
async fn the_horizon_is_the_clusters_and_every_tenant_is_answered_the_same_one() -> TestResult {
    // The sentence the endpoint's description makes, held rather than
    // asserted in prose: `report_cursor()` is `pg_snapshot_xmin`, which is the
    // cluster's, so `tenant_id` is scoping and not a filter — and a tenant
    // nothing has ever written to is answered the same number rather than
    // nothing.
    let book = TestBook::new("cursor_endpoint_cluster_wide").await?;
    let (receivable, revenue) = book.fixture_accounts().await?;
    post_a_charge_dated(
        &book,
        "charge-1",
        CHARGE_DATE,
        CHARGE_MINOR,
        revenue,
        receivable,
    )
    .await?;

    let (status, mine) = book.read(&cursor_path("t1")).await?;
    let (_status, a_strangers) = book.read(&cursor_path("nobody-has-this-book")).await?;

    assert_eq!(status.as_u16(), 200, "{mine}");
    assert_eq!(cursor_of(&mine), cursor_of(&a_strangers), "{mine}");
    assert!(cursor_of(&mine).is_some(), "{mine}");

    book.assert_reconciled().await
}

#[tokio::test]
async fn a_request_that_names_no_book_is_refused_like_every_other_read() -> TestResult {
    // The horizon does not depend on the tenant and the parameter is required
    // anyway: this route runs the same scoped bracket every other read runs,
    // and a read with no scope is not one of the shapes it has.
    let book = TestBook::new("cursor_endpoint_unscoped").await?;
    book.fixture_accounts().await?;

    let (status, body) = book.read("/v1/cursor").await?;

    assert_eq!(status.as_u16(), 400, "{body}");
    assert_eq!(refusal_type(&body), Some("invalid_request"), "{body}");

    book.assert_reconciled().await
}
