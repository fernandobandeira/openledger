//! What the report routes REFUSE, one test per refusal, each naming the status
//! and the `type` ADR-0019 declares for it.
//!
//! **Why these are not one table-driven test.** A refusal is an instruction to
//! a caller, and ADR-0014's grammar is what carries it: `invalid_request` says
//! *the value is not of the type this parameter takes*, `cursor_invalid` says
//! *the value is a legal `xid8` and still not a cursor this book can be pinned
//! at*, and `chart_version_unknown` says *fix the version, not the range*. Two
//! of these crossed hands the caller the wrong thing to change, so each gets a
//! name of its own that says which one it is.
//!
//! **The two cursors the DATABASE cannot refuse are the reason this file
//! exists.** `0` and `-1` are both legal `xid8`: the first admits nothing and
//! answers a complete, all-zero, perfectly balanced face, and the second
//! silently wraps to `18446744073709551615` and returns the entire UNPINNED
//! book with today's correct numbers. No `CHECK` and no `STRICT` reaches
//! either, and the second is the worse one because it looks right — so the
//! read path refuses them before a report runs, and here is where that is held
//! over HTTP rather than over a fake store.
//!
//! Every test below runs against a book that HAS money on it, deliberately: a
//! refusal that only fires on an empty book is a refusal no caller ever meets,
//! and the unknown-tenant answer in particular has to be an empty answer on a
//! book that is not empty.

use crate::support::{
    TestBook, TestResult, a_report_issued, balance_sheet_path, pinned_cursor_of,
    post_a_charge_dated, refusal_detail, refusal_type, trial_balance_path,
};

/// The charge every book here is built on, and the window every report here
/// asks over.
const CHARGE_MINOR: i64 = 2500;
const CHARGE_DATE: &str = "2026-08-27T12:00:00Z";
const AS_OF: &str = "2026-09-01T00:00:00Z";
const EFFECTIVE_FROM: &str = "2026-08-01T00:00:00Z";
const EFFECTIVE_TO: &str = "2026-09-01T00:00:00Z";

/// The `xid8` maximum, which is what `-1` wraps to. Named because the refusal
/// must say so: a caller who sent `-1` needs to see what the database would
/// have read it as.
const XID8_MAX: &str = "18446744073709551615";

/// How far above the horizon the out-of-range cursor sits. Large enough that
/// no amount of sibling traffic on this cluster can lift the horizon past it
/// between the pin and the read — `pg_snapshot_xmin` moves by one per
/// transaction, and nothing in this suite commits a million of them inside one
/// test.
const WELL_ABOVE: u64 = 1_000_000;

/// A book with one posted charge, and the cursor a report pinned on it — the
/// arrangement seven refusal tests share, none of which is about the charge.
///
/// The charge is not decoration: `0` and every cursor below the book's oldest
/// `xact_id` are refused for being at or below the FLOOR, and a book with no
/// entries has no floor to be below (ADR-0019 — on an empty book any cursor at
/// or under the horizon truthfully answers "nothing").
struct ABookAndItsCursor {
    book: TestBook,
    pinned_cursor: String,
}

async fn a_book_of_one_charge_and_the_cursor_it_pinned(
    name: &str,
) -> Result<ABookAndItsCursor, Box<dyn std::error::Error>> {
    let book = TestBook::new(name).await?;
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
    let issued = a_report_issued(&book, &balance_sheet_path("t1", AS_OF, &[])).await?;
    let pinned_cursor = pinned_cursor_of(&issued)?;

    Ok(ABookAndItsCursor {
        book,
        pinned_cursor,
    })
}

#[tokio::test]
async fn a_cursor_that_is_not_an_xid8_is_refused_as_a_malformed_request() -> TestResult {
    let arranged =
        a_book_of_one_charge_and_the_cursor_it_pinned("reports_cursor_unparseable").await?;

    let (status, body) = arranged
        .book
        .read(&trial_balance_path(
            "t1",
            EFFECTIVE_FROM,
            EFFECTIVE_TO,
            &[("cursor", "not-a-cursor")],
        ))
        .await?;

    // 422 under `invalid_request`, NOT `cursor_invalid`: the latter is reserved
    // for a value the database would have accepted, and telling the two apart
    // is telling "this is not a cursor" from "this is not a cursor for this
    // book".
    assert_eq!(status.as_u16(), 422, "{body}");
    assert_eq!(refusal_type(&body), Some("invalid_request"), "{body}");
    assert!(
        refusal_detail(&body).contains("xid8"),
        "the refusal must say what a cursor is; detail was {:?}",
        refusal_detail(&body)
    );

    arranged.book.assert_reconciled().await
}

#[tokio::test]
async fn a_cursor_of_zero_is_refused_as_an_implausible_cursor() -> TestResult {
    // The all-zero fabrication, refused. A report is filtered `xact_id <
    // cursor`, so `0` admits nothing and the answer is a COMPLETE, perfectly
    // balanced face at 0.00 — which is a lie a reconciliation sweep also reads
    // as clean.
    let arranged = a_book_of_one_charge_and_the_cursor_it_pinned("reports_cursor_zero").await?;

    let (status, body) = arranged
        .book
        .read(&trial_balance_path(
            "t1",
            EFFECTIVE_FROM,
            EFFECTIVE_TO,
            &[("cursor", "0")],
        ))
        .await?;

    assert_eq!(status.as_u16(), 422, "{body}");
    assert_eq!(refusal_type(&body), Some("cursor_invalid"), "{body}");
    assert!(
        refusal_detail(&body).contains("oldest entry"),
        "the refusal must name the bound that was missed; detail was {:?}",
        refusal_detail(&body)
    );

    arranged.book.assert_reconciled().await
}

#[tokio::test]
async fn a_cursor_of_minus_one_is_refused_because_it_wraps_above_every_horizon() -> TestResult {
    // The worse of the two, because it looks right: `'-1'::xid8` is accepted
    // by PostgreSQL, wraps to the xid8 maximum, and returns the entire
    // UNPINNED book with today's correct numbers — an unreproducible report
    // that no caller would question. It is parsed here exactly as the backend
    // parses it, which is what puts it above the horizon where the
    // plausibility rule can refuse it.
    let arranged =
        a_book_of_one_charge_and_the_cursor_it_pinned("reports_cursor_minus_one").await?;

    let (status, body) = arranged
        .book
        .read(&trial_balance_path(
            "t1",
            EFFECTIVE_FROM,
            EFFECTIVE_TO,
            &[("cursor", "-1")],
        ))
        .await?;

    assert_eq!(status.as_u16(), 422, "{body}");
    assert_eq!(refusal_type(&body), Some("cursor_invalid"), "{body}");
    // The refusal must show the value the database would have read, not the
    // one the caller typed: `-1` and `18446744073709551615` are the same
    // cursor, and only one of them explains the answer.
    assert!(
        refusal_detail(&body).contains(XID8_MAX),
        "the refusal must name the value -1 wraps to; detail was {:?}",
        refusal_detail(&body)
    );

    arranged.book.assert_reconciled().await
}

#[tokio::test]
async fn a_cursor_above_the_clusters_horizon_is_refused_as_an_implausible_cursor() -> TestResult {
    // Nothing at or above the horizon has finished committing, so a report
    // pinned there is not reproducible: re-run it later and transactions that
    // were still in flight will have joined the answer.
    let arranged = a_book_of_one_charge_and_the_cursor_it_pinned("reports_cursor_above").await?;
    let above_the_horizon = (arranged.pinned_cursor.parse::<u64>()? + WELL_ABOVE).to_string();

    let (status, body) = arranged
        .book
        .read(&trial_balance_path(
            "t1",
            EFFECTIVE_FROM,
            EFFECTIVE_TO,
            &[("cursor", &above_the_horizon)],
        ))
        .await?;

    assert_eq!(status.as_u16(), 422, "{body}");
    assert_eq!(refusal_type(&body), Some("cursor_invalid"), "{body}");
    assert!(
        refusal_detail(&body).contains("horizon"),
        "the refusal must name the bound that was missed; detail was {:?}",
        refusal_detail(&body)
    );

    arranged.book.assert_reconciled().await
}

#[tokio::test]
async fn an_unknown_chart_version_is_refused_by_name_rather_than_presented_at_another() -> TestResult
{
    // The asymmetry ADR-0019 names in its cost list, held from the loud side: a
    // wrong `chart_version` RAISES while a wrong `tenant_id` is answered with
    // silence. A statement presented at a version the book does not have would
    // be a face whose captions nobody agreed to.
    let arranged = a_book_of_one_charge_and_the_cursor_it_pinned("reports_chart_unknown").await?;

    let (status, body) = arranged
        .book
        .read(&balance_sheet_path(
            "t1",
            AS_OF,
            &[("chart_version", "999")],
        ))
        .await?;

    assert_eq!(status.as_u16(), 422, "{body}");
    assert_eq!(refusal_type(&body), Some("chart_version_unknown"), "{body}");
    assert!(
        refusal_detail(&body).contains("999"),
        "the refusal must name the version asked for; detail was {:?}",
        refusal_detail(&body)
    );

    arranged.book.assert_reconciled().await
}

#[tokio::test]
async fn a_malformed_instant_is_refused_naming_the_parameter_the_caller_has_to_fix() -> TestResult {
    // Named, because a 400 under a deserializer's path tells a caller which
    // library refused them and not which parameter to correct. `as_of` is an
    // `ends_at` and never a business date, so the value below is wrong in the
    // ordinary way — someone sent a date.
    let arranged =
        a_book_of_one_charge_and_the_cursor_it_pinned("reports_instant_malformed").await?;

    let (status, body) = arranged
        .book
        .read(&balance_sheet_path("t1", "2026-09-01", &[]))
        .await?;

    assert_eq!(status.as_u16(), 422, "{body}");
    assert_eq!(refusal_type(&body), Some("invalid_request"), "{body}");
    assert!(
        refusal_detail(&body).contains("as_of"),
        "the refusal must name the parameter; detail was {:?}",
        refusal_detail(&body)
    );

    arranged.book.assert_reconciled().await
}

#[tokio::test]
async fn an_unknown_tenant_is_answered_with_an_empty_book_and_never_a_404() -> TestResult {
    // ADR-0019: there is no tenant registry to consult, so inventing the
    // status would mean inventing the registry. Five conditions produce this
    // one observable — unknown tenant, typo'd tenant, tenant with no accounts,
    // a reader scoped elsewhere, an unscoped session — and two of the five are
    // the fail-closed path working correctly.
    //
    // On a book that HOLDS money, which is what makes the empty answer worth
    // asserting: `t1` has a posted charge on it and this read is another
    // tenant's, so an empty list here is the fence answering rather than an
    // empty database.
    let arranged = a_book_of_one_charge_and_the_cursor_it_pinned("reports_tenant_unknown").await?;

    let (status, body) = arranged
        .book
        .read(&trial_balance_path(
            "no-such-tenant",
            EFFECTIVE_FROM,
            EFFECTIVE_TO,
            &[],
        ))
        .await?;

    assert_eq!(status.as_u16(), 200, "{body}");
    let rows = body
        .get("rows")
        .and_then(serde_json::Value::as_array)
        .ok_or_else(|| format!("the answer carried no rows array: {body}"))?;
    assert!(
        rows.is_empty(),
        "an unknown tenant must be answered with no rows: {body}"
    );
    // And it is still answered AT a cursor: the pinned value is how a caller
    // notices a lagging horizon, and it is on every report answer including
    // the empty ones.
    assert!(
        !pinned_cursor_of(&body)?.is_empty(),
        "an empty answer must still carry the cursor it was pinned at: {body}"
    );

    arranged.book.assert_reconciled().await
}
