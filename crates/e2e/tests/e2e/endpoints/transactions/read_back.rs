//! `GET /v1/transactions/{transaction_id}` — the write path's own answers, read
//! back.
//!
//! **Why this endpoint is in scope at all** (ADR-0019 C3): a write-only API is
//! not an adoption surface. The POST answers two UUIDs, and nothing over HTTP
//! could say what they point at — while ADR-0016 made `status`, `resolves_id`
//! and `reverses_id` wire CONCEPTS a caller could not read back. An integrator
//! posting `status: pending` had no way to confirm the book agreed with them.
//!
//! Pinned by nothing, and that is a contract rather than an omission: a
//! transaction and its entries are immutable (`ck_txn__append_only` and
//! `ck_entries__append_only`, both `ENABLE ALWAYS`), so there is no as-of to
//! apply. A `pending` here is what was RECORDED, never a stage the row is
//! passing through — it becomes posted by a new transaction naming it, and
//! this endpoint is where a caller sees that.

use uuid::Uuid;

use crate::support::{
    TestBook, TestResult, post_a_charge_dated, post_a_pending_hold, refusal_detail, refusal_type,
    transaction_path,
};

/// 2⁵³+1 — the smallest integer an IEEE-754 double cannot represent, a legal
/// `bigint`, and the value the wire defect was demonstrated with: posted as a
/// JSON number it came back as 9007199254740992.
const BEYOND_A_DOUBLE: &str = "9007199254740993";

const HOLD_MINOR: i64 = 500;
const CHARGE_MINOR: i64 = 2500;
const CHARGE_DATE: &str = "2026-08-27T12:00:00Z";
const RESOLVED_DATE: &str = "2026-08-29T00:00:00Z";

/// A transaction id nothing ever wrote.
const NEVER_WRITTEN: Uuid = Uuid::from_u128(0xC0FF_EE00_C0FF_EE00_C0FF_EE00_C0FF_EE00);

/// What a transaction read-back said about itself: `status`, the two
/// supersession UUIDs ADR-0016 made wire concepts, and how many legs it
/// carries.
type WhatTheBookHolds = (String, Option<String>, Option<String>, usize);

fn status_resolves_reverses_and_legs(
    read: &serde_json::Value,
) -> Result<WhatTheBookHolds, Box<dyn std::error::Error>> {
    let status = read
        .get("status")
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| format!("the read-back carried no status: {read}"))?
        .to_owned();
    let named = |field: &str| {
        read.get(field)
            .and_then(serde_json::Value::as_str)
            .map(str::to_owned)
    };
    let legs = read
        .get("entries")
        .and_then(serde_json::Value::as_array)
        .ok_or_else(|| format!("the read-back carried no entries array: {read}"))?
        .len();
    Ok((status, named("resolves_id"), named("reverses_id"), legs))
}

#[tokio::test]
async fn a_pending_hold_reads_back_as_pending_and_names_no_supersession() -> TestResult {
    let book = TestBook::new("read_back_pending").await?;
    let (receivable, revenue) = book.fixture_accounts().await?;
    let hold = post_a_pending_hold(&book, revenue, receivable).await?;

    let (status, read) = book.read(&transaction_path("t1", hold)).await?;

    assert_eq!(status.as_u16(), 200, "a hold must read back: {read}");
    // `pending`, sequenced, two legs — and pointing at nothing: a hold
    // resolves nothing and reverses nothing, and the two nulls are how a
    // caller tells a hold from the transaction that retires it.
    assert_eq!(
        status_resolves_reverses_and_legs(&read)?,
        ("pending".to_owned(), None, None, 2),
        "{read}"
    );
    assert_eq!(
        read.get("transaction_id")
            .and_then(serde_json::Value::as_str),
        Some(hold.to_string().as_str()),
        "the read-back is a different transaction: {read}"
    );
    // A leg's amount is a decimal STRING, exactly as every report total is:
    // `bigint` reaches far past 2⁵³ and JSON has no integer type, so a JSON
    // number here was silently rounded by the consumer's parser. Nothing in
    // this suite parses one.
    let leg_amounts: Vec<Option<&str>> = read
        .get("entries")
        .and_then(serde_json::Value::as_array)
        .ok_or("no entries")?
        .iter()
        .map(|entry| {
            entry
                .get("amount_minor")
                .and_then(serde_json::Value::as_str)
        })
        .collect();
    let hold = HOLD_MINOR.to_string();
    assert_eq!(
        leg_amounts,
        [Some(hold.as_str()), Some(hold.as_str())],
        "{read}"
    );

    book.assert_reconciled().await
}

#[tokio::test]
async fn a_resolution_reads_back_as_posted_and_names_the_hold_it_retired() -> TestResult {
    // The pair ADR-0016 is about: the hold is NOT updated, so the only way a
    // caller learns that the money moved is by reading the new transaction and
    // finding the old one named in `resolves_id`.
    let book = TestBook::new("read_back_resolution").await?;
    let (receivable, revenue) = book.fixture_accounts().await?;
    let hold = post_a_pending_hold(&book, revenue, receivable).await?;
    let created = book
        .post(&serde_json::json!({
            "tenant_id": "t1",
            "idempotency_key": "capture-1",
            "effective_at": RESOLVED_DATE,
            "resolves_id": hold,
            "postings": [{
                "source": revenue, "destination": receivable,
                "amount_minor": HOLD_MINOR.to_string(), "currency": "USD"
            }],
        }))
        .await?;
    assert_eq!(created.status(), 201, "seeding the resolution");
    let body: serde_json::Value = created.json().await?;
    let resolution: Uuid = body
        .get("transaction_id")
        .and_then(serde_json::Value::as_str)
        .ok_or("no transaction_id on the resolution's 201")?
        .parse()?;

    let (status, read) = book.read(&transaction_path("t1", resolution)).await?;

    assert_eq!(status.as_u16(), 200, "a resolution must read back: {read}");
    assert_eq!(
        status_resolves_reverses_and_legs(&read)?,
        ("posted".to_owned(), Some(hold.to_string()), None, 2),
        "{read}"
    );

    book.assert_reconciled().await
}

#[tokio::test]
async fn a_reversal_reads_back_as_posted_and_names_the_transaction_it_mirrored() -> TestResult {
    // The other of ADR-0016's two UUIDs. A reversal carries no postings on the
    // way in — the server derives the mirror from the target's own entries — so
    // its legs are the ONLY place a caller can see what was actually written
    // on their behalf.
    let book = TestBook::new("read_back_reversal").await?;
    let (receivable, revenue) = book.fixture_accounts().await?;
    let charge = post_a_charge_dated(
        &book,
        "charge-1",
        CHARGE_DATE,
        CHARGE_MINOR,
        revenue,
        receivable,
    )
    .await?;
    let created = book
        .post(&serde_json::json!({
            "tenant_id": "t1",
            "idempotency_key": "undo-1",
            "effective_at": RESOLVED_DATE,
            "reverses_id": charge,
        }))
        .await?;
    assert_eq!(created.status(), 201, "seeding the reversal");
    let body: serde_json::Value = created.json().await?;
    let reversal: Uuid = body
        .get("transaction_id")
        .and_then(serde_json::Value::as_str)
        .ok_or("no transaction_id on the reversal's 201")?
        .parse()?;

    let (status, read) = book.read(&transaction_path("t1", reversal)).await?;

    assert_eq!(status.as_u16(), 200, "a reversal must read back: {read}");
    assert_eq!(
        status_resolves_reverses_and_legs(&read)?,
        ("posted".to_owned(), None, Some(charge.to_string()), 2),
        "{read}"
    );
    // The mirror, leg by leg: the account that took the debit takes the credit
    // back, at the same amount — compared as the STRING the wire carries,
    // never parsed, because parsing is the step that lost a digit.
    let charge_minor = CHARGE_MINOR.to_string();
    let mirrored: Vec<(Option<&str>, Option<&str>)> = read
        .get("entries")
        .and_then(serde_json::Value::as_array)
        .ok_or("no entries")?
        .iter()
        .map(|entry| {
            (
                entry.get("direction").and_then(serde_json::Value::as_str),
                entry
                    .get("amount_minor")
                    .and_then(serde_json::Value::as_str),
            )
        })
        .collect();
    assert_eq!(
        mirrored
            .iter()
            .filter(|(_, minor)| *minor == Some(charge_minor.as_str()))
            .count(),
        2,
        "a mirror must carry the target's amount on both legs: {read}"
    );
    assert_eq!(
        mirrored
            .iter()
            .filter(|(direction, _)| *direction == Some("credit"))
            .count(),
        1,
        "a mirror must carry one leg of each direction: {read}"
    );

    book.assert_reconciled().await
}

#[tokio::test]
async fn a_transaction_nothing_ever_wrote_is_a_404_naming_it() -> TestResult {
    // 404 for an unknown transaction, where an unknown TENANT on the report
    // routes is 200-with-nothing: there is no tenant registry to consult, so a
    // wrong `tenant_id` here is indistinguishable from a book that does not
    // hold this transaction — and either way the resource is not there.
    let book = TestBook::new("read_back_unknown").await?;
    book.fixture_accounts().await?;

    let (status, body) = book.read(&transaction_path("t1", NEVER_WRITTEN)).await?;

    assert_eq!(status.as_u16(), 404, "{body}");
    assert_eq!(refusal_type(&body), Some("transaction_unknown"), "{body}");
    assert!(
        refusal_detail(&body).contains(&NEVER_WRITTEN.to_string()),
        "the refusal must name the transaction; detail was {:?}",
        refusal_detail(&body)
    );

    book.assert_reconciled().await
}

#[tokio::test]
async fn an_amount_above_two_to_the_fifty_third_reads_back_byte_identical() -> TestResult {
    // The defect this endpoint's wire form was changed for, held as a round
    // trip: 2⁵³+1 is a legal `bigint` and the smallest integer an IEEE-754
    // double cannot represent, so as a JSON number it was accepted and read
    // back one LOWER — silently, with nothing on the wire to say so. As a
    // string it is the same bytes going in and coming out, and this test
    // compares the bytes rather than parsing them, because parsing is the
    // step that lost the digit.
    let book = TestBook::new("read_back_beyond_a_double").await?;
    let (receivable, revenue) = book.fixture_accounts().await?;
    let created = book
        .post(&serde_json::json!({
            "tenant_id": "t1",
            "idempotency_key": "whale-1",
            "effective_at": CHARGE_DATE,
            "postings": [{
                "source": revenue, "destination": receivable,
                "amount_minor": BEYOND_A_DOUBLE, "currency": "USD"
            }],
        }))
        .await?;
    assert_eq!(created.status(), 201, "{:?}", created.text().await);
    let body: serde_json::Value = created.json().await?;
    let charge: Uuid = body
        .get("transaction_id")
        .and_then(serde_json::Value::as_str)
        .ok_or("no transaction_id on the whale's 201")?
        .parse()?;

    let (status, read) = book.read(&transaction_path("t1", charge)).await?;

    assert_eq!(status.as_u16(), 200, "{read}");
    let leg_amounts: Vec<Option<&str>> = read
        .get("entries")
        .and_then(serde_json::Value::as_array)
        .ok_or("no entries")?
        .iter()
        .map(|entry| {
            entry
                .get("amount_minor")
                .and_then(serde_json::Value::as_str)
        })
        .collect();
    assert_eq!(
        leg_amounts,
        [Some(BEYOND_A_DOUBLE), Some(BEYOND_A_DOUBLE)],
        "{read}"
    );
    // And the column agrees with the wire, so this is the ledger's number and
    // not a string the API carried around unexamined.
    let (stored,): (i64,) = sqlx::query_as(
        "SELECT DISTINCT e.amount_minor FROM ledger_entries e WHERE e.transaction_id = $1",
    )
    .bind(charge)
    .fetch_one(&book.pool)
    .await?;
    assert_eq!(stored.to_string(), BEYOND_A_DOUBLE);

    book.assert_reconciled().await
}
