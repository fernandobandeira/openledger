//! M5's second acceptance criterion, through the compiled binary and over the
//! wire: **the backdating case — insertion order ≠ effective order — is
//! correct on both axes.**
//!
//! This is the case ADR-0006 exists for. Two charges, and the one recorded
//! SECOND is dated EARLIER, so no answer here can be got right by accident:
//! a read path that confused the two axes, or that filtered `effective_at`
//! where it meant `xact_id`, would report a plausible number on every query
//! below and the wrong one on all of them.
//!
//! - The **effective axis** is the range and the as-of instant: the backdated
//!   charge must be placed by its BUSINESS date, so it appears in the window
//!   its own date falls in and in the position as at an instant after that
//!   date — even though it was written afterwards.
//! - The **recorded axis** is the cursor: the same query, at a cursor pinned
//!   BEFORE the backdated charge committed, must not see it at all, and at a
//!   later cursor must see it. That pair is the criterion; either half alone
//!   is satisfied by a read path that ignores the cursor.
//!
//! Everything is asserted to the minor unit, as a decimal string off the wire.
//! Half-open bounds throughout (`effective_at < as_of`, `[from, to)`), which
//! is why the instants below are period boundaries and never business dates.

use uuid::Uuid;

use crate::support::{
    TestBook, TestResult, a_report_issued, amount_of_the_line, balance_sheet_path,
    pinned_cursor_of, post_a_charge_dated, row_of_the_account, trial_balance_path,
};

/// The charge recorded FIRST and dated LATER — 5.00 on the 20th.
const LATER_MINOR: i64 = 500;
const LATER_DATE: &str = "2026-08-20T00:00:00Z";

/// The charge recorded SECOND and dated EARLIER — 3.00 on the 10th. This is
/// the backdated arrival: an ordinary correction, a late settlement file, a
/// month-end accrual booked after the fact.
const BACKDATED_MINOR: i64 = 300;
const BACKDATED_DATE: &str = "2026-08-10T00:00:00Z";

/// The first half of August: `[1st, 15th)`, which holds the backdated charge's
/// business date and not the later one's.
const FIRST_HALF_FROM: &str = "2026-08-01T00:00:00Z";
const FIRST_HALF_TO: &str = "2026-08-15T00:00:00Z";

/// The whole month: `[1st, 1st)`, which holds both.
const MONTH_FROM: &str = "2026-08-01T00:00:00Z";
const MONTH_TO: &str = "2026-09-01T00:00:00Z";

/// An instant BETWEEN the two business dates — the position at which is the
/// backdated charge and nothing else.
const AS_OF_BETWEEN: &str = "2026-08-15T00:00:00Z";

/// An instant after both — the position at which is both charges, on either
/// cursor, and the number that separates the two recorded-axis answers.
const AS_OF_AFTER: &str = "2026-09-01T00:00:00Z";

/// A book whose insertion order is not its effective order, and the cursor
/// pinned in between.
///
/// Five tests hold five different queries against this one arrangement and
/// each pays for its own run: a `#[tokio::test]` cannot share a served book
/// with its neighbour, and one test asking all five queries is one failure
/// that names none of them.
struct ABackdatedBook {
    book: TestBook,
    /// The account both charges debit — every assertion below is stated about
    /// this one, because it is the side whose position moves.
    receivable: Uuid,
    /// The account both charges credit.
    revenue: Uuid,
    /// A cursor pinned when the book held the LATER-dated charge and nothing
    /// else: the recorded axis, before the backdated arrival committed.
    cursor_before_the_backdating: String,
}

async fn a_book_whose_second_charge_is_dated_before_its_first(
    name: &str,
) -> Result<ABackdatedBook, Box<dyn std::error::Error>> {
    let book = TestBook::new(name).await?;
    let (receivable, revenue) = book.fixture_accounts().await?;
    let later = post_a_charge_dated(
        &book,
        "later-dated",
        LATER_DATE,
        LATER_MINOR,
        revenue,
        receivable,
    )
    .await?;
    book.wait_for_the_horizon_to_retire_this_book().await?;
    // The cursor is taken over the wire, from a report, because that is the
    // only place a caller can get one: `pinned_cursor` is on every report
    // answer whether or not the caller supplied a cursor (ADR-0019).
    let before_the_backdating =
        a_report_issued(&book, &balance_sheet_path("t1", AS_OF_AFTER, &[])).await?;
    let cursor_before_the_backdating = pinned_cursor_of(&before_the_backdating)?;

    let backdated = post_a_charge_dated(
        &book,
        "backdated",
        BACKDATED_DATE,
        BACKDATED_MINOR,
        revenue,
        receivable,
    )
    .await?;
    book.wait_for_the_horizon_to_retire_this_book().await?;

    // The premise, asserted where it is arranged rather than assumed by five
    // tests: the second charge really was RECORDED after the first and really
    // is dated BEFORE it. Without both halves every assertion below is
    // satisfiable by a book whose two orders agree, which is the ordinary case
    // and not this one.
    let (recorded_later_and_dated_earlier,): (bool,) = sqlx::query_as(
        "SELECT (SELECT min(e.xact_id) FROM ledger_entries e WHERE e.transaction_id = $1)
              > (SELECT max(e.xact_id) FROM ledger_entries e WHERE e.transaction_id = $2)
            AND (SELECT min(e.effective_at) FROM ledger_entries e WHERE e.transaction_id = $1)
              < (SELECT min(e.effective_at) FROM ledger_entries e WHERE e.transaction_id = $2)",
    )
    .bind(backdated)
    .bind(later)
    .fetch_one(&book.pool)
    .await?;
    assert!(
        recorded_later_and_dated_earlier,
        "the fixture must record the backdated charge AFTER the later-dated one and date it \
         BEFORE it — insertion order and effective order agree, so this book is not the \
         backdating case"
    );

    Ok(ABackdatedBook {
        book,
        receivable,
        revenue,
        cursor_before_the_backdating,
    })
}

#[tokio::test]
async fn the_effective_axis_places_a_backdated_charge_in_the_window_its_business_date_falls_in()
-> TestResult {
    let backdated =
        a_book_whose_second_charge_is_dated_before_its_first("reports_backdated_window").await?;

    let (status, first_half) = backdated
        .book
        .read(&trial_balance_path(
            "t1",
            FIRST_HALF_FROM,
            FIRST_HALF_TO,
            &[],
        ))
        .await?;

    assert_eq!(status.as_u16(), 200, "{first_half}");
    // The window holds the backdated charge and nothing else: it is placed by
    // its business date, not by when it arrived.
    assert_eq!(
        row_of_the_account(&first_half, backdated.receivable)?,
        Some((
            BACKDATED_MINOR.to_string(),
            "0".to_owned(),
            BACKDATED_MINOR.to_string()
        )),
        "the first half of August must hold the backdated charge alone"
    );
    // ...and the credit side of the same charge, which is what makes the
    // window's answer a trial BALANCE rather than one leg of one.
    assert_eq!(
        row_of_the_account(&first_half, backdated.revenue)?,
        Some((
            "0".to_owned(),
            BACKDATED_MINOR.to_string(),
            (-BACKDATED_MINOR).to_string()
        )),
        "the backdated charge's credit leg is missing from its own window"
    );

    backdated.book.assert_reconciled().await
}

#[tokio::test]
async fn the_effective_axis_over_the_whole_month_carries_both_charges_however_they_arrived()
-> TestResult {
    // The control for the window above: a window that reported 3.00 because it
    // reports 3.00 whatever is asked would pass that test. Widening the range
    // must pick the later charge up, and the total must be exact.
    let backdated =
        a_book_whose_second_charge_is_dated_before_its_first("reports_backdated_month").await?;

    let (status, month) = backdated
        .book
        .read(&trial_balance_path("t1", MONTH_FROM, MONTH_TO, &[]))
        .await?;

    assert_eq!(status.as_u16(), 200, "{month}");
    let both = BACKDATED_MINOR + LATER_MINOR;
    assert_eq!(
        row_of_the_account(&month, backdated.receivable)?,
        Some((both.to_string(), "0".to_owned(), both.to_string())),
        "the month must hold both charges"
    );

    backdated.book.assert_reconciled().await
}

#[tokio::test]
async fn the_balance_sheet_as_of_an_instant_between_the_two_dates_holds_the_backdated_one_only()
-> TestResult {
    // The position rather than the flow, on the same axis: `effective_at <
    // as_of` is half-open, so an as-of on the 15th holds the charge dated the
    // 10th and not the one dated the 20th — and the charge it holds is the one
    // that was written LAST.
    let backdated =
        a_book_whose_second_charge_is_dated_before_its_first("reports_backdated_position").await?;

    let (status, between) = backdated
        .book
        .read(&balance_sheet_path("t1", AS_OF_BETWEEN, &[]))
        .await?;

    assert_eq!(status.as_u16(), 200, "{between}");
    assert_eq!(
        amount_of_the_line(&between, "receivables")?,
        BACKDATED_MINOR.to_string(),
        "the position on the 15th must be the backdated charge alone"
    );
    // The face still balances: the earnings plug carries the credit side, so a
    // backdated charge cannot arrive on one side of the face only.
    assert_eq!(
        amount_of_the_line(&between, "current_year_earnings")?,
        BACKDATED_MINOR.to_string(),
        "the backdated charge's credit leg is missing from the face"
    );

    backdated.book.assert_reconciled().await
}

#[tokio::test]
async fn the_recorded_axis_at_a_cursor_pinned_before_the_backdating_cannot_see_it() -> TestResult {
    // Half of the criterion, and the half a caller stores a cursor FOR: the
    // same query, over a range that covers both business dates, at a cursor
    // pinned before the backdated charge committed. It must answer the book as
    // it was — 5.00 — even though the entry it cannot see is dated ten days
    // earlier than the one it can.
    let backdated =
        a_book_whose_second_charge_is_dated_before_its_first("reports_backdated_recorded").await?;

    let (status, as_it_stood) = backdated
        .book
        .read(&balance_sheet_path(
            "t1",
            AS_OF_AFTER,
            &[("cursor", &backdated.cursor_before_the_backdating)],
        ))
        .await?;

    assert_eq!(status.as_u16(), 200, "{as_it_stood}");
    assert_eq!(
        amount_of_the_line(&as_it_stood, "receivables")?,
        LATER_MINOR.to_string(),
        "a cursor pinned before the backdated charge committed reported it anyway — the \
         recorded axis is not being filtered, or is being filtered on the effective one"
    );
    // The cursor a report echoes is the cursor it was asked for, on both
    // statement routes and the trial balance alike.
    assert_eq!(
        pinned_cursor_of(&as_it_stood)?,
        backdated.cursor_before_the_backdating,
        "the report answered at a cursor other than the one supplied"
    );

    backdated.book.assert_reconciled().await
}

#[tokio::test]
async fn the_recorded_axis_at_a_later_cursor_sees_the_backdated_charge_the_earlier_one_could_not()
-> TestResult {
    // The other half. Without it the test above is satisfied by a read path
    // that never sees a backdated entry at all — the failure mode that loses
    // late arrivals silently, which is the worse of the two.
    let backdated =
        a_book_whose_second_charge_is_dated_before_its_first("reports_backdated_later").await?;

    let (status, now) = backdated
        .book
        .read(&balance_sheet_path("t1", AS_OF_AFTER, &[]))
        .await?;

    assert_eq!(status.as_u16(), 200, "{now}");
    assert_eq!(
        amount_of_the_line(&now, "receivables")?,
        (BACKDATED_MINOR + LATER_MINOR).to_string(),
        "a fresh cursor must see the backdated charge"
    );
    assert_ne!(
        pinned_cursor_of(&now)?,
        backdated.cursor_before_the_backdating,
        "the horizon did not move across the backdated charge's commit, so the two answers \
         above are not two cursors' answers"
    );

    backdated.book.assert_reconciled().await
}
