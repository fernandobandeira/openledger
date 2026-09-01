//! M5's third acceptance criterion, guarded rather than re-proved:
//! `balance_sheet_at` reads the period checkpoint instead of aggregating from
//! inception. Migration `00004` did that and proved it at the SQL level; what
//! nothing held was that the face a CALLER is answered still agrees with the
//! journal once the checkpoint is what the reader consults.
//!
//! So the oracle here is the from-inception scan — the aggregation the
//! checkpoint replaced — computed over `ledger_entries` at the same cursor,
//! the same as-of and the same chart version the HTTP answer reports. The
//! checkpoint path and the scan are two different computations of one number,
//! and this file is the assertion that they are the same number to the minor
//! unit.
//!
//! **A close does not round the book off, it rewrites where the numbers come
//! from.** After it, the face is read out of `ledger_period_balances` plus two
//! tails — entries effective after the boundary, and entries BACKDATED across
//! it that committed after the checkpoint was computed. A reader that dropped
//! either tail, or that double-counted the closing transaction's own legs
//! (which sit in the checkpoint AND below the cursor), would answer a
//! plausible face. The scan below has no tails and no close to special-case,
//! which is what makes it an oracle rather than a second copy of the
//! implementation.
//!
//! **Proved red before trusted green.** Write the close without its checkpoint
//! (`AClose { checkpointed: false }`) and both tests fail loudly: the face over
//! HTTP reads every line at 0 while the journal scan reads 2500 on
//! `receivables` and 2500 on `retained_earnings`. Which is the checkpoint
//! reader being read from — after a close, the face IS the checkpoint plus its
//! tails, and an unwritten checkpoint is an empty balance sheet rather than a
//! fallback to the old aggregation.

use crate::support::{
    AClose, ASweep, TestBook, TestResult, amount_of_the_line, balance_sheet_path, close_the_period,
    pinned_cursor_of, post_a_charge_dated,
};

/// The charge the closed period holds, and its date — inside August.
const CHARGE_MINOR: i64 = 2500;
const CHARGE_DATE: &str = "2026-08-27T12:00:00Z";

/// The period, and the instant the face is read as at. `as_of` is the period's
/// own `ends_at`, which is the ONE instant that leaves tail A empty and the
/// checkpoint exact — the bounds are half-open on both sides, so one
/// microsecond either way is a different balance sheet (ADR-0020).
const PERIOD: &str = "2026-08";
const PERIOD_STARTS: &str = "2026-08-01T00:00:00Z";
const PERIOD_ENDS: &str = "2026-09-01T00:00:00Z";
const CLOSES_AT: &str = "2026-08-31T00:00:00Z";

/// A book with one charge inside August, August swept and closed, and its
/// checkpoint written — the arrangement both tests read the face against.
///
/// It asserts its own premise, which is not the property under test but is
/// what makes the property meaningful: `checkpoint_anchor` is the function the
/// reader picks its period with, and a NULL period code there means no close
/// was eligible and the form degraded to the from-inception behaviour — under
/// which the oracle below would agree trivially.
async fn a_book_whose_august_was_closed(
    name: &str,
) -> Result<TestBook, Box<dyn std::error::Error>> {
    let book = TestBook::new(name).await?;
    let (receivable, revenue) = book.fixture_accounts().await?;
    let retained_earnings = book
        .account("t1", None, "retained_earnings", "equity", "credit", "none")
        .await?;
    post_a_charge_dated(
        &book,
        "charge-1",
        CHARGE_DATE,
        CHARGE_MINOR,
        revenue,
        receivable,
    )
    .await?;
    close_the_period(
        &book,
        &AClose {
            period: PERIOD,
            starts_at: PERIOD_STARTS,
            ends_at: PERIOD_ENDS,
            closes_at: CLOSES_AT,
            ids: "51",
            computed_at_xid: "pg_current_xact_id()",
            sweeps: Some(ASweep {
                minor: CHARGE_MINOR,
                from_revenue: revenue,
                into_retained_earnings: retained_earnings,
            }),
            recorded: true,
            checkpointed: true,
        },
    )
    .await?;
    book.wait_for_the_horizon_to_retire_this_book().await?;

    let anchored_to: Vec<(Option<String>,)> = sqlx::query_as(
        "SELECT period_code FROM checkpoint_anchor('t1', $1::timestamptz, report_cursor())",
    )
    .bind(PERIOD_ENDS)
    .fetch_all(&book.pool)
    .await?;
    assert_eq!(
        anchored_to,
        [(Some(PERIOD.to_owned()),)],
        "a face as at {PERIOD_ENDS} would not be read off {PERIOD}'s checkpoint, so nothing \
         here guards the checkpoint reader"
    );

    Ok(book)
}

/// The same position, computed the way `balance_sheet_at` computed it BEFORE
/// migration `00004`: every posted entry below the cursor and before the
/// as-of, aggregated from inception, routed through the chart's presentation
/// and its contra lines, with the derived earnings plug appended. No
/// checkpoint, no boundary, no tails.
///
/// Returned as `(fs_line, amount)` decimal strings, sorted by line code, which
/// is the shape the answered face is compared against.
async fn the_face_scanned_from_inception(
    book: &TestBook,
    as_of: &str,
    cursor: &str,
    chart_version: i32,
) -> Result<Vec<(String, String)>, Box<dyn std::error::Error>> {
    let scanned: Vec<(String, String)> = sqlx::query_as(
        "WITH pos AS (
             SELECT e.currency, e.account_id, p.category, p.fs_line, p.fs_line_contra,
                    SUM(CASE WHEN e.direction = 'debit' THEN e.amount_minor
                             ELSE -e.amount_minor END)::numeric AS v
               FROM ledger_entries e
               JOIN ledger_transactions x ON x.tenant_id = e.tenant_id
                                         AND x.id = e.transaction_id AND x.status = 'posted'
               JOIN ledger_accounts a ON a.tenant_id = e.tenant_id AND a.id = e.account_id
                                     AND a.currency = e.currency
               JOIN chart_presentation p ON p.chart_version = $3 AND p.type_code = a.purpose
              WHERE e.tenant_id = 't1' AND e.effective_at < $1::timestamptz
                AND e.xact_id < $2::xid8
              GROUP BY 1, 2, 3, 4, 5
         ), dp AS (
             SELECT pos.currency,
                    CASE WHEN pos.fs_line_contra IS NOT NULL
                              AND ((pos.category = 'asset'     AND pos.v < 0)
                                OR (pos.category = 'liability' AND pos.v > 0))
                         THEN pos.fs_line_contra ELSE pos.fs_line END AS fs_line,
                    pos.v
               FROM pos
         ), scopes AS (
             SELECT DISTINCT l.currency FROM ledger_accounts l WHERE l.tenant_id = 't1'
         )
         SELECT f.code, COALESCE(SUM(CASE WHEN f.side = 'asset' THEN d.v ELSE -d.v END), 0)::text
           FROM scopes s
           JOIN fs_lines f ON f.chart_version = $3 AND f.statement = 'balance_sheet'
           LEFT JOIN dp d ON d.currency = s.currency AND d.fs_line = f.code
          GROUP BY f.code
          UNION ALL
         SELECT 'current_year_earnings',
                (-COALESCE((SELECT SUM(pp.v) FROM pos pp
                             WHERE pp.category IN ('revenue', 'expense')), 0))::text
           FROM scopes
          ORDER BY 1",
    )
    .bind(as_of)
    .bind(cursor)
    .bind(chart_version)
    .fetch_all(&book.pool)
    .await?;
    Ok(scanned)
}

/// The face as it came off the wire, as `(fs_line, amount)` sorted by line
/// code — so the two computations are compared as sets of lines and not as two
/// orderings of one.
fn the_face_as_answered(
    face: &serde_json::Value,
) -> Result<Vec<(String, String)>, Box<dyn std::error::Error>> {
    let lines = face
        .get("lines")
        .and_then(serde_json::Value::as_array)
        .ok_or_else(|| format!("the answer carried no lines array: {face}"))?;
    let mut answered = Vec::with_capacity(lines.len());
    for line in lines {
        let fs_line = line
            .get("fs_line")
            .and_then(serde_json::Value::as_str)
            .ok_or_else(|| format!("a line carried no fs_line: {line}"))?;
        let amount = line
            .get("amount_minor")
            .and_then(serde_json::Value::as_str)
            .ok_or_else(|| format!("a line carried no amount_minor: {line}"))?;
        answered.push((fs_line.to_owned(), amount.to_owned()));
    }
    answered.sort();
    Ok(answered)
}

/// The chart version a face says it was presented at — never assumed, because
/// the oracle has to be computed at the same one, and the read path resolves
/// it rather than letting the SQL default resolve at run time (ADR-0019 B6).
fn chart_version_of(face: &serde_json::Value) -> Result<i32, Box<dyn std::error::Error>> {
    let version = face
        .get("chart_version")
        .and_then(serde_json::Value::as_i64)
        .ok_or_else(|| format!("the face carried no chart_version: {face}"))?;
    Ok(i32::try_from(version)?)
}

#[tokio::test]
async fn the_balance_sheet_read_off_a_checkpoint_agrees_with_the_journal_to_the_minor_unit()
-> TestResult {
    let book = a_book_whose_august_was_closed("reports_checkpoint_agrees").await?;

    let (status, face) = book
        .read(&balance_sheet_path("t1", PERIOD_ENDS, &[]))
        .await?;

    assert_eq!(status.as_u16(), 200, "{face}");
    // The oracle is computed at the cursor and version the ANSWER names, so
    // the two computations cannot end up answering different questions.
    let scanned = the_face_scanned_from_inception(
        &book,
        PERIOD_ENDS,
        &pinned_cursor_of(&face)?,
        chart_version_of(&face)?,
    )
    .await?;
    assert_eq!(
        the_face_as_answered(&face)?,
        scanned,
        "the face read off the checkpoint disagrees with the same position scanned from \
         inception"
    );

    book.assert_reconciled().await
}

#[tokio::test]
async fn the_face_after_a_close_presents_the_swept_earnings_as_retained_rather_than_current()
-> TestResult {
    // The numbers themselves, so the agreement above cannot be an agreement
    // between two identically wrong computations. A close moves the period's
    // temporary positions into retained earnings, and that is visible on the
    // face as exactly this: the receivable still stands, the earnings have
    // changed line, and the DERIVED plug — undistributed earnings since
    // inception — is zero, because the sweep took them.
    let book = a_book_whose_august_was_closed("reports_checkpoint_face").await?;

    let (status, face) = book
        .read(&balance_sheet_path("t1", PERIOD_ENDS, &[]))
        .await?;

    assert_eq!(status.as_u16(), 200, "{face}");
    assert_eq!(
        amount_of_the_line(&face, "receivables")?,
        CHARGE_MINOR.to_string(),
        "the closed period's receivable"
    );
    assert_eq!(
        amount_of_the_line(&face, "retained_earnings")?,
        CHARGE_MINOR.to_string(),
        "the close swept the period's earnings, so they present as retained"
    );
    assert_eq!(
        amount_of_the_line(&face, "current_year_earnings")?,
        "0",
        "earnings the close already swept must not be plugged in a second time"
    );

    book.assert_reconciled().await
}
