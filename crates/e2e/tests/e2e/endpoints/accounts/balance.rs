//! `GET /v1/accounts/{account_id}/balance` — one account's posted position,
//! now.
//!
//! **The distinction this endpoint exists to draw** (ADR-0019 C4): a balance
//! row is created LAZILY by the first write, so an unknown account, a dormant
//! one and a currency the account does not hold all return zero rows and a
//! NULL sum from `ledger_account_balances`. Only the account register can tell
//! them apart — which is why the statement reads `ledger_accounts` and joins
//! the cache, and why `404 account_unknown` against `200` with a zero balance
//! is a real distinction rather than a formatting choice. A caller that cannot
//! draw it cannot tell a typo'd id from an account nobody has used yet.
//!
//! **And no stripe appears anywhere.** The answer is a `SUM` over whichever
//! stripe rows exist (ADR-0013 §4) and says so nowhere; shipping this endpoint
//! is precisely how an integrator is stopped from writing the single-row read
//! that under-reports.

use uuid::Uuid;

use crate::support::{
    TestBook, TestResult, account_balance_path, post_a_charge_dated, refusal_detail, refusal_type,
};

const CHARGE_MINOR: i64 = 2500;
const CHARGE_DATE: &str = "2026-08-27T12:00:00Z";

/// An account id no chart ever created — the same shape `batched.rs` uses for
/// the write path's unknown account, so the two refusals can be read side by
/// side: 404 here, 422 there, under one `type` name and deliberately
/// (ADR-0019).
const GHOST: Uuid = Uuid::from_u128(0xDEAD_BEEF_DEAD_BEEF_DEAD_BEEF_DEAD_BEEF);

#[tokio::test]
async fn the_balance_of_a_written_account_is_everything_posted_to_it() -> TestResult {
    let book = TestBook::new("balance_written").await?;
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

    let (status, body) = book
        .read(&account_balance_path("t1", receivable, "USD"))
        .await?;

    assert_eq!(status.as_u16(), 200, "{body}");
    // A decimal STRING, and debit-positive: this side took the debit.
    assert_eq!(
        body.get("posted_minor").and_then(serde_json::Value::as_str),
        Some(CHARGE_MINOR.to_string().as_str()),
        "{body}"
    );
    // `as_of` is the constant `now` rather than an echo of a parameter: it
    // states which question was answered, because this endpoint takes no
    // cursor and pinning it to one would be a second definition of a balance.
    assert_eq!(
        body.get("as_of").and_then(serde_json::Value::as_str),
        Some("now"),
        "{body}"
    );
    // And no stripe on the answer, at any depth.
    assert!(
        !body.to_string().contains("stripe"),
        "a stripe reached the wire: {body}"
    );

    book.assert_reconciled().await
}

#[tokio::test]
async fn the_credit_side_of_the_same_charge_reads_negative_because_the_answer_is_debit_positive()
-> TestResult {
    // The presentation flip is the READER's (ADR-0010): a credit-normal
    // account reads negative here, and this endpoint does not flip it. An
    // endpoint that returned the absolute position would satisfy the test
    // above and mislead every consumer that adds two accounts together.
    let book = TestBook::new("balance_credit_side").await?;
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

    let (status, body) = book
        .read(&account_balance_path("t1", revenue, "USD"))
        .await?;

    assert_eq!(status.as_u16(), 200, "{body}");
    assert_eq!(
        body.get("posted_minor").and_then(serde_json::Value::as_str),
        Some((-CHARGE_MINOR).to_string().as_str()),
        "{body}"
    );

    book.assert_reconciled().await
}

#[tokio::test]
async fn a_dormant_account_answers_a_zero_balance_rather_than_a_404() -> TestResult {
    // An account that exists and has never been written has NO balance row at
    // all — the cache is populated lazily by the first write — so this is the
    // case that forces the read to go through the account register.
    let book = TestBook::new("balance_dormant").await?;
    let (receivable, _revenue) = book.fixture_accounts().await?;

    let (status, body) = book
        .read(&account_balance_path("t1", receivable, "USD"))
        .await?;

    assert_eq!(
        status.as_u16(),
        200,
        "a dormant account is not a 404: {body}"
    );
    assert_eq!(
        body.get("posted_minor").and_then(serde_json::Value::as_str),
        Some("0"),
        "{body}"
    );

    book.assert_reconciled().await
}

#[tokio::test]
async fn an_account_no_chart_ever_created_is_a_404_naming_it() -> TestResult {
    // The other side of the same distinction, and the reason it is 404 rather
    // than the write path's 422: nothing is being asked to change, the named
    // resource simply is not on this book.
    let book = TestBook::new("balance_unknown_account").await?;
    book.fixture_accounts().await?;

    let (status, body) = book.read(&account_balance_path("t1", GHOST, "USD")).await?;

    assert_eq!(status.as_u16(), 404, "{body}");
    assert_eq!(refusal_type(&body), Some("account_unknown"), "{body}");
    assert!(
        refusal_detail(&body).contains(&GHOST.to_string()),
        "the refusal must name the account that does not exist; detail was {:?}",
        refusal_detail(&body)
    );

    book.assert_reconciled().await
}
