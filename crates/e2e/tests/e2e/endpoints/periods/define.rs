//! `POST /v1/periods` — defining a period (ADR-0024).
//!
//! It is the account-opening shape one table over: an accepted operation that
//! moves no money, so it claims an idempotency key and writes `ledger_events`
//! and `ledger_periods` in one database transaction, and inherits ADR-0013
//! §2's replay contract unchanged. What is NOT the same is where the refusals
//! come from: `account_type_unknown` is a read the writer makes before the
//! claim, while **both** of this endpoint's named refusals are constraints
//! only the database can evaluate — an overlap is a statement about other
//! rows, and a zone's existence is the server's own tzdata. So each of the two
//! tests below is a test that the writer surfaces a constraint by name rather
//! than handing back a diagnostic.
//!
//! The zone and the instants are the other half of what is held here. ADR-0011
//! §5 is emphatic and measured — a local midnight is not always a real instant,
//! and the same local date resolves an hour apart across a tzdata update — so
//! the API takes RESOLVED instants and stores the zone as provenance. The
//! register's own row is what the tests read back, because it is what every
//! report will filter on.

use crate::support::{
    PERIODS_PATH, TestBook, TestResult, define_a_period, refusal_detail, refusal_type,
};

const AUGUST: &str = "2026-08";
const AUGUST_STARTS: &str = "2026-08-01T00:00:00Z";
const AUGUST_ENDS: &str = "2026-09-01T00:00:00Z";

/// The body every test here varies one field of.
fn a_definition(key: &str, code: &str, ends_at: &str, tz: &str) -> serde_json::Value {
    serde_json::json!({
        "tenant_id": "t1",
        "idempotency_key": key,
        "code": code,
        "starts_at": AUGUST_STARTS,
        "ends_at": ends_at,
        "tz": tz,
    })
}

#[tokio::test]
async fn a_period_is_defined_and_the_register_holds_the_instants_it_was_sent() -> TestResult {
    let book = TestBook::new("periods_define").await?;

    let created = book
        .post_to(
            PERIODS_PATH,
            &a_definition("period-1", AUGUST, AUGUST_ENDS, "UTC"),
        )
        .await?;

    assert_eq!(created.status(), 201);
    assert_eq!(
        created
            .headers()
            .get("idempotency-replayed")
            .and_then(|value| value.to_str().ok()),
        Some("false")
    );
    let body: serde_json::Value = created.json().await?;
    assert_eq!(
        body.get("period"),
        Some(&serde_json::json!({
            "code": AUGUST,
            "starts_at": AUGUST_STARTS,
            "ends_at": AUGUST_ENDS,
            "tz": "UTC",
        })),
        "the answer is the register's row, not a re-rendering of the request: {body}"
    );
    // And the row itself, because the instants are what every report filters
    // on and the zone is what it is NOT allowed to re-resolve them from.
    let stored: Vec<(String, String)> = sqlx::query_as(
        "SELECT code, tz FROM ledger_periods
          WHERE tenant_id = 't1'
            AND starts_at = $1::timestamptz AND ends_at = $2::timestamptz",
    )
    .bind(AUGUST_STARTS)
    .bind(AUGUST_ENDS)
    .fetch_all(&book.pool)
    .await?;
    assert_eq!(stored, [(AUGUST.to_owned(), "UTC".to_owned())]);

    book.assert_reconciled().await
}

#[tokio::test]
async fn the_same_key_with_the_same_body_replays_and_defines_no_second_period() -> TestResult {
    let book = TestBook::new("periods_define_replay").await?;
    define_a_period(&book, "period-1", AUGUST, AUGUST_STARTS, AUGUST_ENDS).await?;

    let replayed = book
        .post_to(
            PERIODS_PATH,
            &a_definition("period-1", AUGUST, AUGUST_ENDS, "UTC"),
        )
        .await?;

    assert_eq!(replayed.status(), 200);
    assert_eq!(
        replayed
            .headers()
            .get("idempotency-replayed")
            .and_then(|value| value.to_str().ok()),
        Some("true")
    );
    let (periods,): (i64,) =
        sqlx::query_as("SELECT count(*) FROM ledger_periods WHERE tenant_id = 't1'")
            .fetch_one(&book.pool)
            .await?;
    assert_eq!(periods, 1, "a replay must define no second period");

    book.assert_reconciled().await
}

#[tokio::test]
async fn the_same_key_with_a_different_body_is_refused_as_key_reuse() -> TestResult {
    // The shared spine, under the shared name: the key namespace is one per
    // tenant across every write on this surface, deliberately (ADR-0013 §2).
    let book = TestBook::new("periods_define_reuse").await?;
    define_a_period(&book, "period-1", AUGUST, AUGUST_STARTS, AUGUST_ENDS).await?;

    let refused = book
        .post_to(
            PERIODS_PATH,
            &a_definition("period-1", "2026-09", "2026-10-01T00:00:00Z", "UTC"),
        )
        .await?;

    assert_eq!(refused.status(), 422);
    let body: serde_json::Value = refused.json().await?;
    assert_eq!(refusal_type(&body), Some("idempotency_key_reused"));
    let (periods,): (i64,) =
        sqlx::query_as("SELECT count(*) FROM ledger_periods WHERE tenant_id = 't1'")
            .fetch_one(&book.pool)
            .await?;
    assert_eq!(periods, 1, "a refused definition must have written nothing");

    book.assert_reconciled().await
}

#[tokio::test]
async fn a_period_overlapping_one_this_book_already_holds_is_refused_by_name() -> TestResult {
    // `ex_periods__no_overlap`, a GiST exclusion over `tstzrange` — surfaced
    // rather than re-checked, because no read before the insert can see an
    // uncommitted rival period (ADR-0024).
    let book = TestBook::new("periods_define_overlap").await?;
    define_a_period(&book, "period-1", AUGUST, AUGUST_STARTS, AUGUST_ENDS).await?;

    let refused = book
        .post_to(
            PERIODS_PATH,
            // Starts on August's first day, so it covers all of it.
            &a_definition(
                "period-2",
                "2026-08-and-a-bit",
                "2026-09-15T00:00:00Z",
                "UTC",
            ),
        )
        .await?;

    assert_eq!(refused.status(), 422);
    let body: serde_json::Value = refused.json().await?;
    assert_eq!(
        refusal_type(&body),
        Some("period_overlaps"),
        "a constraint violation reached the caller instead of a named refusal: {body}"
    );

    book.assert_reconciled().await
}

#[tokio::test]
async fn a_code_this_book_already_uses_is_refused_by_name_rather_than_as_a_constraint() -> TestResult
{
    // NOT in ADR-0024's refusal table, and reachable ahead of every refusal
    // that is: `pk_periods` is `(tenant_id, code)` and PostgreSQL checks it
    // BEFORE `ex_periods__no_overlap`, so redefining a code — here with a
    // boundary that overlaps nothing — was an unnamed `23505` and a 500. It is
    // the direct analogue of ADR-0021's `account_exists` one table over, which
    // is why it wears that grammar.
    let book = TestBook::new("periods_define_exists").await?;
    define_a_period(&book, "period-1", AUGUST, AUGUST_STARTS, AUGUST_ENDS).await?;

    let refused = book
        .post_to(
            PERIODS_PATH,
            &serde_json::json!({
                "tenant_id": "t1",
                "idempotency_key": "period-2",
                "code": AUGUST,
                "starts_at": "2027-01-01T00:00:00Z",
                "ends_at": "2027-02-01T00:00:00Z",
                "tz": "UTC",
            }),
        )
        .await?;

    assert_eq!(
        refused.status(),
        422,
        "a 500 here is the defect this closes"
    );
    let body: serde_json::Value = refused.json().await?;
    assert_eq!(refusal_type(&body), Some("period_exists"));
    let (periods,): (i64,) =
        sqlx::query_as("SELECT count(*) FROM ledger_periods WHERE tenant_id = 't1'")
            .fetch_one(&book.pool)
            .await?;
    assert_eq!(periods, 1, "a refused definition must have written nothing");

    book.assert_reconciled().await
}

#[tokio::test]
async fn two_periods_that_meet_at_one_instant_do_not_overlap() -> TestResult {
    // The half-open range is not decoration: `[starts_at, ends_at)` is what
    // lets September begin at the instant August ends, and it is why a close's
    // own transaction is dated one microsecond BELOW `ends_at` rather than at
    // it. The control for the test above — without it, "overlaps" could mean
    // "touches".
    let book = TestBook::new("periods_define_adjacent").await?;
    define_a_period(&book, "period-1", AUGUST, AUGUST_STARTS, AUGUST_ENDS).await?;

    let created = book
        .post_to(
            PERIODS_PATH,
            &serde_json::json!({
                "tenant_id": "t1",
                "idempotency_key": "period-2",
                "code": "2026-09",
                "starts_at": AUGUST_ENDS,
                "ends_at": "2026-10-01T00:00:00Z",
                "tz": "UTC",
            }),
        )
        .await?;

    assert_eq!(created.status(), 201);

    book.assert_reconciled().await
}

#[tokio::test]
async fn a_zone_the_server_does_not_recognise_is_refused_by_name() -> TestResult {
    // `ck_periods__tz_known` — and the zone list is the SERVER's tzdata, never
    // a copy of it in Rust, because a copy drifts against the very database
    // that stores the row (ADR-0011 §5). Note what the refusal is NOT: the
    // zone never resolves the boundary, so this refusal is about provenance
    // being nameable, not about an instant being wrong.
    let book = TestBook::new("periods_define_zone").await?;

    let refused = book
        .post_to(
            PERIODS_PATH,
            &a_definition("period-1", AUGUST, AUGUST_ENDS, "Mars/Olympus"),
        )
        .await?;

    assert_eq!(refused.status(), 422);
    let body: serde_json::Value = refused.json().await?;
    assert_eq!(refusal_type(&body), Some("period_zone_unknown"));
    let (periods,): (i64,) =
        sqlx::query_as("SELECT count(*) FROM ledger_periods WHERE tenant_id = 't1'")
            .fetch_one(&book.pool)
            .await?;
    assert_eq!(periods, 0, "a refused definition must have written nothing");

    book.assert_reconciled().await
}

#[tokio::test]
async fn a_period_that_does_not_end_after_it_starts_is_refused_before_the_database_sees_it()
-> TestResult {
    // `ck_periods__non_empty`'s rule, answered by the writer with a sentence
    // instead of a constraint message — and the one shape a close could give
    // no effective instant at all, since `ends_at - 1 microsecond` would fall
    // outside the period `ck_closes__txn_in_period` requires it to be in.
    let book = TestBook::new("periods_define_empty").await?;

    let refused = book
        .post_to(
            PERIODS_PATH,
            &a_definition("period-1", AUGUST, AUGUST_STARTS, "UTC"),
        )
        .await?;

    assert_eq!(refused.status(), 422);
    let body: serde_json::Value = refused.json().await?;
    assert_eq!(refusal_type(&body), Some("invalid_request"));
    assert_eq!(refusal_detail(&body), "ends_at must be after starts_at");

    book.assert_reconciled().await
}
