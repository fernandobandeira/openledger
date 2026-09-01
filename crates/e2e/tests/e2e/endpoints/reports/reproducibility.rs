//! M5's first acceptance criterion, through the compiled binary and over the
//! wire: **an as-of query at instant T returns the same answer when re-run
//! under concurrent writes.**
//!
//! It had only ever been held at the SQL level, by a harness that speaks no
//! HTTP (spike 019). What a caller actually has is a `pinned_cursor` off a
//! JSON body and a URL to send it back to, and everything between that string
//! and `xact_id < :cursor` — the parse, the plausibility rule, the bind, the
//! scoped read transaction — is what these tests cross.
//!
//! **The control is half the proof.** A reproducibility test on a book that
//! never moved passes on any implementation, including one that ignores the
//! cursor entirely — so every arrangement here posts a sustained load
//! BETWEEN the two issues of the report, re-issues at the stored cursor while
//! those writers are still in flight, and then issues once more with NO
//! cursor. The stored-cursor answers must be identical; the fresh-cursor
//! answer must have MOVED, by exactly what the writers added. Neither half is
//! worth anything without the other.
//!
//! **Sustained writers rather than one burst**, for the reason
//! `concurrency.rs` gives: a burst is drained by a couple of dispatchers into
//! a couple of large batches, and what a report needs to be re-issued *under*
//! is arrivals that keep committing across it.
//!
//! **Proved red before trusted green**, the way `concurrency.rs` records its
//! own injections: make `pin_the_cursor_or_refuse_an_implausible_one` ignore
//! the supplied cursor and return the horizon instead, and both stored-cursor
//! tests below fail while both fresh-cursor controls stay green. That
//! injection is also what earned the SECOND re-issue in the fixture — the one
//! taken after the load has drained. Under the load the cluster horizon is
//! pinned low by the writers' own open transactions, so with the cursor
//! ignored the re-issued trial balance still answered identically and the test
//! passed on a read path that had thrown the caller's cursor away.
//!
//! What is NOT claimed here, because ADR-0019 does not promise it: the ROW
//! SET. The lines of a face are enumerated from tables carrying no `xact_id`,
//! so a new account added at a fixed cursor adds rows with every pre-existing
//! amount unchanged. Nothing below adds an account; the comparison is
//! therefore of whole answers, and it is the amounts it is about.

use uuid::Uuid;

use crate::support::{
    PostAnswer, TestBook, TestResult, a_report_issued, amount_of_the_line,
    assert_every_member_was_accepted, balance_sheet_path, charge, pinned_cursor_of,
    row_of_the_account, trial_balance_path,
};

/// Where the reports look. `support::charge` dates its posting
/// 2026-08-27T12:00:00Z, so the as-of sits after that day and the half-open
/// range covers it — the same window for every report in this file, so that
/// what changes between two answers is the CURSOR and nothing else.
const AS_OF: &str = "2026-09-01T00:00:00Z";
const EFFECTIVE_FROM: &str = "2026-08-01T00:00:00Z";
const EFFECTIVE_TO: &str = "2026-09-01T00:00:00Z";

/// What every charge in this file moves, in minor units.
const AMOUNT: i64 = 100;

/// The book the first report is issued against.
const SEEDED: usize = 3;

/// The load that lands on top of it: [`WRITERS`] clients, each posting
/// [`ROUNDS`] charges one after another, so arrivals keep committing across
/// the re-issued report instead of all landing before it.
const WRITERS: usize = 8;
const ROUNDS: usize = 4;

/// The receivable's position at the stored cursor, and at a fresh one. Both
/// exact, both in minor units: a reproducibility claim that only says "the
/// same" cannot tell a correct answer from two identically wrong ones.
const SEEDED_MINOR: i64 = SEEDED as i64 * AMOUNT;
const ADDED_MINOR: i64 = (WRITERS * ROUNDS) as i64 * AMOUNT;

/// One report issued and stored, a book that MOVED underneath it, and the
/// same report re-issued twice — once at the stored cursor while the writers
/// were still going, once with no cursor at all after they had finished.
///
/// Four tests hold four different properties of this one arrangement and each
/// pays for its own run, exactly as `concurrency.rs` does: a `#[tokio::test]`
/// cannot share a served book with its neighbour, and one test asserting all
/// four is one failure that could mean any of them.
struct AnIssuedReport {
    book: TestBook,
    /// The cursor the first balance sheet pinned — the string a caller stores.
    stored_cursor: String,
    /// The two answers as first issued, both at [`Self::stored_cursor`].
    balance_sheet_when_issued: serde_json::Value,
    trial_balance_when_issued: serde_json::Value,
    /// The same two, re-issued at that same stored cursor WHILE the writers
    /// were posting.
    balance_sheet_re_issued_under_writes: serde_json::Value,
    trial_balance_re_issued_under_writes: serde_json::Value,
    /// The same two AGAIN at the stored cursor, once every writer had landed
    /// and the horizon had retired them. Both re-issues are held, because they
    /// fail for different reasons: under the load the cluster horizon is
    /// pinned low by the writers' own open transactions, so a read path that
    /// IGNORED the stored cursor and re-pinned a fresh one could still answer
    /// identically — measured, by injection. Once the load has drained, a
    /// fresh pin admits all of it, and only a read path that honoured the
    /// supplied cursor can answer the same thing twice.
    balance_sheet_re_issued_after_the_writes: serde_json::Value,
    trial_balance_re_issued_after_the_writes: serde_json::Value,
    /// The same two again, issued with NO cursor once every writer had landed
    /// — the control.
    balance_sheet_at_a_fresh_cursor: serde_json::Value,
    trial_balance_at_a_fresh_cursor: serde_json::Value,
    /// What the writers were answered. Their statuses are each test's to
    /// assert: a 500 here is a deadlock victim, not a report's business.
    answers: Vec<PostAnswer>,
    /// The account every assertion below is stated about.
    receivable: Uuid,
}

async fn a_report_re_issued_across_concurrent_writes(
    name: &str,
) -> Result<AnIssuedReport, Box<dyn std::error::Error>> {
    let book = TestBook::new(name).await?;
    let (receivable, revenue) = book.fixture_accounts().await?;
    let seeded: Vec<serde_json::Value> = (0..SEEDED)
        .map(|n| charge(&format!("seed-{n}"), revenue, receivable))
        .collect();
    let landed = book.post_all_at_once(&seeded).await?;
    assert_every_member_was_accepted(&landed);
    // The cursor a report pins is `report_cursor()`, the CLUSTER's horizon, so
    // a sibling test's open transaction can hold it below this book's newest
    // entry. Waiting for it — bounded, never a bare sleep — is what makes
    // "the position when the report was issued" the seeded three charges
    // rather than however many of them the horizon had reached.
    book.wait_for_the_horizon_to_retire_this_book().await?;

    // The first report, and the cursor it pinned. The balance sheet pins it;
    // the trial balance is then issued AT that value, so one stored cursor
    // covers both answers and the two cannot drift apart.
    let balance_sheet_when_issued =
        a_report_issued(&book, &balance_sheet_path("t1", AS_OF, &[])).await?;
    let stored_cursor = pinned_cursor_of(&balance_sheet_when_issued)?;
    let at_the_stored_cursor = [("cursor", stored_cursor.as_str())];
    let trial_balance_when_issued = a_report_issued(
        &book,
        &trial_balance_path("t1", EFFECTIVE_FROM, EFFECTIVE_TO, &at_the_stored_cursor),
    )
    .await?;

    let (events_before, _, _) = book.write_counts().await?;
    let handles: Vec<_> = (0..WRITERS)
        .map(|writer| {
            let bodies = (0..ROUNDS)
                .map(|round| charge(&format!("charge-{writer}-{round}"), revenue, receivable))
                .collect();
            book.spawn_client(bodies)
        })
        .collect();
    // The writers are LANDING, not merely spawned: the suite's runtime is
    // current-thread, so a spawned task has not necessarily sent a byte until
    // something yields, and a report re-issued before then would be re-issued
    // over a quiet book. The condition is monotonic — a committed post stays
    // committed — so this cannot pass on the luck of a timing window.
    book.wait_until_a_post_of_the_burst_has_landed(events_before)
        .await?;

    let balance_sheet_re_issued_under_writes = a_report_issued(
        &book,
        &balance_sheet_path("t1", AS_OF, &at_the_stored_cursor),
    )
    .await?;
    let trial_balance_re_issued_under_writes = a_report_issued(
        &book,
        &trial_balance_path("t1", EFFECTIVE_FROM, EFFECTIVE_TO, &at_the_stored_cursor),
    )
    .await?;

    let mut answers = Vec::with_capacity(WRITERS * ROUNDS);
    for handle in handles {
        for answer in handle.await? {
            answers.push(answer?);
        }
    }
    book.wait_for_the_horizon_to_retire_this_book().await?;
    let balance_sheet_re_issued_after_the_writes = a_report_issued(
        &book,
        &balance_sheet_path("t1", AS_OF, &at_the_stored_cursor),
    )
    .await?;
    let trial_balance_re_issued_after_the_writes = a_report_issued(
        &book,
        &trial_balance_path("t1", EFFECTIVE_FROM, EFFECTIVE_TO, &at_the_stored_cursor),
    )
    .await?;
    let balance_sheet_at_a_fresh_cursor =
        a_report_issued(&book, &balance_sheet_path("t1", AS_OF, &[])).await?;
    let trial_balance_at_a_fresh_cursor = a_report_issued(
        &book,
        &trial_balance_path("t1", EFFECTIVE_FROM, EFFECTIVE_TO, &[]),
    )
    .await?;

    Ok(AnIssuedReport {
        book,
        stored_cursor,
        balance_sheet_when_issued,
        trial_balance_when_issued,
        balance_sheet_re_issued_under_writes,
        trial_balance_re_issued_under_writes,
        balance_sheet_re_issued_after_the_writes,
        trial_balance_re_issued_after_the_writes,
        balance_sheet_at_a_fresh_cursor,
        trial_balance_at_a_fresh_cursor,
        answers,
        receivable,
    })
}

#[tokio::test]
async fn the_balance_sheet_at_a_stored_cursor_answers_identically_under_concurrent_writes()
-> TestResult {
    let issued = a_report_re_issued_across_concurrent_writes("reports_face_reproducible").await?;

    assert_every_member_was_accepted(&issued.answers);
    // The whole answer, not a chosen field: the cursor it echoes, the chart
    // version it presented at, every line's caption, order and amount.
    assert_eq!(
        issued.balance_sheet_re_issued_under_writes, issued.balance_sheet_when_issued,
        "the same balance sheet at the same cursor answered differently once the book moved"
    );
    // ...and again once the whole load had landed and the horizon had retired
    // it, which is the stricter of the two: a fresh pin here would admit
    // everything the writers added.
    assert_eq!(
        issued.balance_sheet_re_issued_after_the_writes, issued.balance_sheet_when_issued,
        "the same balance sheet at the same cursor answered differently after the writers          finished"
    );
    // ...and it is the position that was actually there, to the minor unit. An
    // implementation that answered zeros both times would satisfy the line
    // above and nothing a caller wants.
    assert_eq!(
        amount_of_the_line(&issued.balance_sheet_when_issued, "receivables")?,
        SEEDED_MINOR.to_string(),
        "the issued face is not the position the seeded charges left"
    );

    issued.book.assert_reconciled().await
}

#[tokio::test]
async fn the_trial_balance_at_a_stored_cursor_answers_identically_under_concurrent_writes()
-> TestResult {
    // The same claim on the other route, and it is a different one to make:
    // `trial_balance_at` returns no `pinned_cursor` column of its own, so on
    // this route the cursor in the answer is the read path echoing what it
    // passed (ADR-0019). A route that dropped the cursor on the floor between
    // parsing it and binding it would still echo it correctly.
    let issued = a_report_re_issued_across_concurrent_writes("reports_trial_reproducible").await?;

    assert_every_member_was_accepted(&issued.answers);
    assert_eq!(
        issued.trial_balance_re_issued_under_writes, issued.trial_balance_when_issued,
        "the same trial balance at the same cursor answered differently once the book moved"
    );
    assert_eq!(
        issued.trial_balance_re_issued_after_the_writes, issued.trial_balance_when_issued,
        "the same trial balance at the same cursor answered differently after the writers          finished"
    );
    assert_eq!(
        row_of_the_account(&issued.trial_balance_when_issued, issued.receivable)?,
        Some((
            SEEDED_MINOR.to_string(),
            "0".to_owned(),
            SEEDED_MINOR.to_string()
        )),
        "the issued trial balance is not what the seeded charges debited"
    );

    issued.book.assert_reconciled().await
}

#[tokio::test]
async fn the_balance_sheet_at_a_fresh_cursor_carries_everything_the_writers_added() -> TestResult {
    // The control. Without it the two tests above are satisfied by a read path
    // that answers the same thing because nothing it reads ever changes —
    // which is exactly what a book with no concurrent writes would prove.
    let issued = a_report_re_issued_across_concurrent_writes("reports_face_moves").await?;

    assert_every_member_was_accepted(&issued.answers);
    assert_ne!(
        issued.balance_sheet_at_a_fresh_cursor, issued.balance_sheet_when_issued,
        "the book did not move under the report, so its reproducibility proves nothing"
    );
    assert_eq!(
        amount_of_the_line(&issued.balance_sheet_at_a_fresh_cursor, "receivables")?,
        (SEEDED_MINOR + ADDED_MINOR).to_string(),
        "a fresh cursor must carry every charge the writers committed"
    );
    // The cursor moved with it: the horizon a fresh report pins is above the
    // one stored before the writers ran, which is what makes the two answers
    // two answers rather than one.
    assert_ne!(
        pinned_cursor_of(&issued.balance_sheet_at_a_fresh_cursor)?,
        issued.stored_cursor,
        "a fresh report pinned the cursor the stored one did"
    );

    issued.book.assert_reconciled().await
}

#[tokio::test]
async fn the_trial_balance_at_a_fresh_cursor_carries_everything_the_writers_added() -> TestResult {
    let issued = a_report_re_issued_across_concurrent_writes("reports_trial_moves").await?;

    assert_every_member_was_accepted(&issued.answers);
    assert_eq!(
        row_of_the_account(&issued.trial_balance_at_a_fresh_cursor, issued.receivable)?,
        Some((
            (SEEDED_MINOR + ADDED_MINOR).to_string(),
            "0".to_owned(),
            (SEEDED_MINOR + ADDED_MINOR).to_string()
        )),
        "a fresh cursor must carry every charge the writers committed"
    );

    issued.book.assert_reconciled().await
}
