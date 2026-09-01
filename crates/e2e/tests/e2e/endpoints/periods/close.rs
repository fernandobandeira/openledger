//! `POST /v1/periods/{code}/close` — the close, end to end (ADR-0024).
//!
//! **The bar every test here ends on is `SELECT * FROM reconciliation`: ten
//! checks, ten zeros.** That is not ceremony on this endpoint, it is the
//! property. `checkpoint_drift` reads zero only if the close's own arithmetic
//! and `recon_checkpoint_breaks`' recompute agree, which they do only because
//! the checkpoint is bounded by exactly the predicate the recompute uses —
//! `xact_id < computed_at_xid OR transaction_id = <this close>` — and only
//! because the checkpoint is written AFTER the closing entries exist, so
//! identity admission has something to admit (ADR-0020). `close_typing` reads
//! zero only if the stored cursor is at or above the closing transaction's own
//! commit position and every temporary account's stored row nets to zero.
//! `unbalanced_transactions` reads zero for an ENTRYLESS close only because
//! migration `00004` carved that case out. Each of those is a different way to
//! get the close wrong, and each of them is a non-zero count here.
//!
//! **What is deliberately not re-proved:** that the checkpoint READER agrees
//! with the journal. That is `endpoints/reports/checkpoint.rs`, over a close
//! the SQL fixture wrote. What is new here is the writer, so these tests read
//! the stored rows and the face rather than re-deriving the reader's
//! arithmetic.
//!
//! The book: one charge of 2,500 into revenue and one expense of 400, both
//! inside August, with an earnings account for the sweep to land in.

use uuid::Uuid;

use crate::support::{
    TestBook, TestResult, amount_of_the_line, balance_sheet_path, close_a_period, close_path,
    define_a_period, open_an_account, post_a_charge_dated, refusal_type,
};

const AUGUST: &str = "2026-08";
const AUGUST_STARTS: &str = "2026-08-01T00:00:00Z";
const AUGUST_ENDS: &str = "2026-09-01T00:00:00Z";
/// The instant the closing transaction is dated: `ends_at` minus one
/// microsecond, the last *representable* instant inside a half-open period
/// (ADR-0011 §2).
const CLOSES_AT: &str = "2026-08-31T23:59:59.999999Z";

const REVENUE_MINOR: i64 = 2500;
const EXPENSE_MINOR: i64 = 400;
/// What the sweep leaves in `retained_earnings`, credit-side: revenue earned
/// less expense incurred.
const EARNINGS_MINOR: i64 = REVENUE_MINOR - EXPENSE_MINOR;

/// Every account this file's book holds, in one value so a test names the one
/// it is about rather than unpacking a tuple of four.
struct Accounts {
    receivable: Uuid,
    revenue: Uuid,
    expense: Uuid,
    retained_earnings: Uuid,
}

/// A book with August's revenue and expense on it, August defined, and nothing
/// closed — the arrangement every test below either closes or refuses to.
///
/// The two temporary accounts are the point: a close with ONE swept account
/// cannot tell a per-account sweep from a netted one, and it cannot exercise
/// the earnings account's counter walking back over more than one leg.
async fn a_book_with_augusts_earnings(
    name: &str,
) -> Result<(TestBook, Accounts), Box<dyn std::error::Error>> {
    let book = TestBook::new(name).await?;
    let (receivable, revenue) = book.fixture_accounts().await?;
    let expense = book
        .account("t1", None, "interest_expense", "expense", "debit", "none")
        .await?;
    let retained_earnings = book
        .account("t1", None, "retained_earnings", "equity", "credit", "none")
        .await?;
    post_a_charge_dated(
        &book,
        "charge-1",
        "2026-08-27T12:00:00Z",
        REVENUE_MINOR,
        revenue,
        receivable,
    )
    .await?;
    post_a_charge_dated(
        &book,
        "interest-1",
        "2026-08-28T12:00:00Z",
        EXPENSE_MINOR,
        receivable,
        expense,
    )
    .await?;
    define_a_period(&book, "period-august", AUGUST, AUGUST_STARTS, AUGUST_ENDS).await?;
    Ok((
        book,
        Accounts {
            receivable,
            revenue,
            expense,
            retained_earnings,
        },
    ))
}

/// One account's stored checkpoint row for August, as `(input, output)` —
/// `None` when the close wrote none for it.
async fn checkpoint_row_of(
    book: &TestBook,
    account: Uuid,
) -> Result<Option<(i64, i64)>, sqlx::Error> {
    sqlx::query_as(
        "SELECT input, output FROM ledger_period_balances
          WHERE tenant_id = 't1' AND period_code = $1 AND currency = 'USD'
            AND account_id = $2",
    )
    .bind(AUGUST)
    .bind(account)
    .fetch_optional(&book.pool)
    .await
}

#[tokio::test]
async fn a_close_sweeps_every_temporary_account_and_answers_what_it_moved() -> TestResult {
    let (book, accounts) = a_book_with_augusts_earnings("periods_close").await?;

    let closed = close_a_period(&book, AUGUST, "USD").await?;

    assert_eq!(
        closed
            .get("effective_at")
            .and_then(serde_json::Value::as_str),
        Some(CLOSES_AT),
        "the closing transaction is dated one microsecond inside the period"
    );
    // One entry per temporary account holding a non-zero position, DEBIT
    // POSITIVE: revenue reads negative, expense positive (ADR-0007 §15).
    let mut swept: Vec<(String, String)> = closed
        .get("swept")
        .and_then(serde_json::Value::as_array)
        .ok_or_else(|| format!("the close carried no swept array: {closed}"))?
        .iter()
        .map(|line| {
            (
                line["account_id"].as_str().unwrap_or_default().to_owned(),
                line["position_minor"]
                    .as_str()
                    .unwrap_or_default()
                    .to_owned(),
            )
        })
        .collect();
    swept.sort();
    let mut expected = vec![
        (accounts.revenue.to_string(), (-REVENUE_MINOR).to_string()),
        (accounts.expense.to_string(), EXPENSE_MINOR.to_string()),
    ];
    expected.sort();
    assert_eq!(swept, expected, "{closed}");

    book.assert_reconciled().await
}

#[tokio::test]
async fn every_temporary_account_is_zero_in_the_checkpoint_and_the_earnings_carry_the_sweep()
-> TestResult {
    // A4, as arithmetic on the stored rows. It holds only because the close's
    // own legs are in its own checkpoint — they carry the closing
    // transaction's `xact_id`, which IS the stored cursor, so no inequality
    // can reach them and identity admission is the only mechanism that works
    // (ADR-0020). Compute the checkpoint before the entries exist, or bound it
    // by the cursor alone, and both assertions below read the PRE-close
    // position instead.
    let (book, accounts) = a_book_with_augusts_earnings("periods_close_at_close").await?;

    close_a_period(&book, AUGUST, "USD").await?;

    assert_eq!(
        checkpoint_row_of(&book, accounts.revenue).await?,
        Some((REVENUE_MINOR, REVENUE_MINOR)),
        "the revenue account's stored position is exactly 0 at the close"
    );
    assert_eq!(
        checkpoint_row_of(&book, accounts.expense).await?,
        Some((EXPENSE_MINOR, EXPENSE_MINOR)),
        "the expense account's stored position is exactly 0 at the close"
    );
    assert_eq!(
        checkpoint_row_of(&book, accounts.retained_earnings).await?,
        Some((EXPENSE_MINOR, REVENUE_MINOR)),
        "retained earnings carries the swept earnings, credit-side"
    );
    assert_eq!(
        checkpoint_row_of(&book, accounts.receivable).await?,
        Some((REVENUE_MINOR, EXPENSE_MINOR)),
        "the checkpoint is every account's position, not only the swept ones"
    );

    book.assert_reconciled().await
}

#[tokio::test]
async fn the_closing_transaction_is_a_leg_pair_per_swept_account_on_gapless_counters() -> TestResult
{
    // A close is an ordinary balanced transaction (ADR-0011 §2): one posting
    // per temporary account, destination `retained_earnings`, and no leg
    // constructible on its own (ADR-0005). The earnings account therefore
    // takes TWO legs here, whose `account_seq` walks back from the counter its
    // one balance upsert returned — which is the half a single-account close
    // cannot exercise.
    let (book, accounts) = a_book_with_augusts_earnings("periods_close_entries").await?;

    close_a_period(&book, AUGUST, "USD").await?;

    let legs: Vec<(Uuid, String, i64)> = sqlx::query_as(
        "SELECT e.account_id, e.direction::text, e.amount_minor
           FROM ledger_entries e
           JOIN ledger_transactions x ON x.tenant_id = e.tenant_id AND x.id = e.transaction_id
          WHERE x.kind = 'period_close'
          ORDER BY e.account_id, e.account_seq",
    )
    .fetch_all(&book.pool)
    .await?;
    let mut expected = vec![
        (accounts.revenue, "debit".to_owned(), REVENUE_MINOR),
        (accounts.expense, "credit".to_owned(), EXPENSE_MINOR),
        (
            accounts.retained_earnings,
            "credit".to_owned(),
            REVENUE_MINOR,
        ),
        (
            accounts.retained_earnings,
            "debit".to_owned(),
            EXPENSE_MINOR,
        ),
    ];
    expected.sort();
    let mut sorted = legs.clone();
    sorted.sort();
    assert_eq!(sorted, expected, "the sweep's legs");
    // Gaplessness is what `recon_balance_breaks` reads as `seq_gap`, and the
    // earnings account is where the close could break it: two legs numbered
    // from one counter.
    book.assert_every_counter_is_gapless_from_one().await?;

    book.assert_reconciled().await
}

#[tokio::test]
async fn a_second_close_of_one_period_and_currency_is_refused_by_the_deterministic_key()
-> TestResult {
    // Nothing in the writer checks for this. The key is
    // `tenant:close:period:currency` (ADR-0011 §2), so the second attempt
    // finds `uq_events__idempotency` held and never reaches a single insert —
    // and it is answered `period_already_closed` rather than replayed,
    // because a close happens once and has no stored result to re-render.
    let (book, _accounts) = a_book_with_augusts_earnings("periods_close_twice").await?;
    close_a_period(&book, AUGUST, "USD").await?;

    let refused = book
        .post_to(
            &close_path(AUGUST),
            &serde_json::json!({"tenant_id": "t1", "currency": "USD"}),
        )
        .await?;

    assert_eq!(refused.status(), 422);
    let body: serde_json::Value = refused.json().await?;
    assert_eq!(refusal_type(&body), Some("period_already_closed"));
    let (closes,): (i64,) =
        sqlx::query_as("SELECT count(*) FROM ledger_period_closes WHERE tenant_id = 't1'")
            .fetch_one(&book.pool)
            .await?;
    assert_eq!(closes, 1, "the refused close must have written nothing");

    book.assert_reconciled().await
}

#[tokio::test]
async fn a_period_with_nothing_to_sweep_closes_cleanly() -> TestResult {
    // ADR-0020 found that a period with no revenue or expense could not be
    // closed without breaking `recon_transaction_breaks` — the close writes an
    // entryless transaction and the view flagged it `no_entries`. Migration
    // `00004` carved it out, and this is the writer relying on the carve-out
    // rather than making a quiet month an error (ADR-0024).
    let (book, _accounts) = a_book_with_augusts_earnings("periods_close_entryless").await?;
    define_a_period(
        &book,
        "period-september",
        "2026-09",
        AUGUST_ENDS,
        "2026-10-01T00:00:00Z",
    )
    .await?;
    close_a_period(&book, AUGUST, "USD").await?;

    let closed = close_a_period(&book, "2026-09", "USD").await?;

    assert_eq!(
        closed.get("swept"),
        Some(&serde_json::json!([])),
        "September earned nothing, so there was nothing to sweep: {closed}"
    );
    let (legs,): (i64,) = sqlx::query_as(
        "SELECT count(*) FROM ledger_entries e
           JOIN ledger_transactions x ON x.tenant_id = e.tenant_id AND x.id = e.transaction_id
          WHERE x.kind = 'period_close' AND x.effective_at >= $1::timestamptz",
    )
    .bind(AUGUST_ENDS)
    .fetch_one(&book.pool)
    .await?;
    assert_eq!(legs, 0, "an entryless close posts no legs at all");

    book.assert_reconciled().await
}

#[tokio::test]
async fn a_backdated_posting_into_a_closed_period_is_disclosed_and_does_not_break_the_sweep()
-> TestResult {
    // The whole reason the checkpoint is safe (ADR-0011): a later arrival
    // backdated into a closed period carries a HIGHER `xid8` than the stored
    // cursor, so it lands in the tail rather than invalidating the stored
    // balance — and `close_disclosures` is where it is enumerated, which is
    // this schema's analogue of IAS 1.41's reclassification disclosure. It is
    // not a break, and a close whose stored rows moved under it would be.
    let (book, accounts) = a_book_with_augusts_earnings("periods_close_backdated").await?;
    close_a_period(&book, AUGUST, "USD").await?;

    post_a_charge_dated(
        &book,
        "late-1",
        "2026-08-20T00:00:00Z",
        700,
        accounts.revenue,
        accounts.receivable,
    )
    .await?;

    let disclosed: Vec<(i64, String)> = sqlx::query_as(
        "SELECT amount_minor, direction::text FROM close_disclosures
          WHERE tenant_id = 't1' AND period_code = $1
          ORDER BY direction",
    )
    .bind(AUGUST)
    .fetch_all(&book.pool)
    .await?;
    assert_eq!(
        disclosed,
        [(700, "credit".to_owned()), (700, "debit".to_owned())],
        "the late arrival's own legs, and only those"
    );
    // The sweep is unmoved: the stored rows were computed at a cursor this
    // posting arrived above.
    assert_eq!(
        checkpoint_row_of(&book, accounts.revenue).await?,
        Some((REVENUE_MINOR, REVENUE_MINOR)),
        "a late arrival must not restate an already-stored checkpoint"
    );

    book.assert_reconciled().await
}

#[tokio::test]
async fn a_face_dated_inside_the_period_reads_the_same_before_and_after_the_close() -> TestResult {
    // The close is dated `ends_at - 1 microsecond`, so a statement already
    // issued as at an instant inside the period must not move when the books
    // are closed. This is the reproducibility rule (ADR-0011) meeting the
    // close: closing is a posting, and a posting after an as-of does not
    // change a report before it.
    let (book, _accounts) = a_book_with_augusts_earnings("periods_close_face_inside").await?;
    let as_of = "2026-08-29T00:00:00Z";
    book.wait_for_the_horizon_to_retire_this_book().await?;
    let (_, before) = book.read(&balance_sheet_path("t1", as_of, &[])).await?;

    close_a_period(&book, AUGUST, "USD").await?;

    // Every report pins at `report_cursor()`, which is the CLUSTER's horizon:
    // a close this book has committed sits above it until the horizon
    // retires, and a face read before then is a face the close has not
    // reached. The wait is bounded and monotone (support/book.rs).
    book.wait_for_the_horizon_to_retire_this_book().await?;
    let (status, after) = book.read(&balance_sheet_path("t1", as_of, &[])).await?;
    assert_eq!(status.as_u16(), 200, "{after}");
    for line in ["receivables", "retained_earnings", "current_year_earnings"] {
        assert_eq!(
            amount_of_the_line(&after, line)?,
            amount_of_the_line(&before, line)?,
            "the {line} line moved under a close dated after the as-of"
        );
    }
    assert_eq!(
        amount_of_the_line(&after, "current_year_earnings")?,
        EARNINGS_MINOR.to_string(),
        "earnings inside the period are still un-closed as at this instant"
    );

    book.assert_reconciled().await
}

#[tokio::test]
async fn a_face_at_the_period_end_presents_the_swept_earnings_as_retained() -> TestResult {
    // And at the boundary the close DOES show: the earnings have changed
    // line, and the derived plug — undistributed earnings since inception — is
    // zero, because the sweep took them. The plug's caption never changes
    // (ADR-0011 §A3), only its amount.
    let (book, _accounts) = a_book_with_augusts_earnings("periods_close_face_end").await?;
    book.wait_for_the_horizon_to_retire_this_book().await?;
    let (_, before) = book
        .read(&balance_sheet_path("t1", AUGUST_ENDS, &[]))
        .await?;
    assert_eq!(
        amount_of_the_line(&before, "current_year_earnings")?,
        EARNINGS_MINOR.to_string(),
        "before the close the earnings are the derived plug"
    );

    close_a_period(&book, AUGUST, "USD").await?;

    // The report pins at the cluster horizon, so the close has to be retired
    // below it before a face can be read off its checkpoint at all.
    book.wait_for_the_horizon_to_retire_this_book().await?;
    let (status, after) = book
        .read(&balance_sheet_path("t1", AUGUST_ENDS, &[]))
        .await?;
    assert_eq!(status.as_u16(), 200, "{after}");
    assert_eq!(
        amount_of_the_line(&after, "retained_earnings")?,
        EARNINGS_MINOR.to_string(),
        "the sweep's destination"
    );
    assert_eq!(
        amount_of_the_line(&after, "current_year_earnings")?,
        "0",
        "earnings the close already swept must not be plugged in a second time"
    );
    assert_eq!(
        amount_of_the_line(&after, "receivables")?,
        (REVENUE_MINOR - EXPENSE_MINOR).to_string(),
        "a close moves no asset"
    );

    book.assert_reconciled().await
}

#[tokio::test]
async fn closing_one_currency_leaves_another_unclosed_and_correct() -> TestResult {
    // A close is per `(tenant, period, currency)` because `pk_closes` is
    // (ADR-0024): closing a book that holds two currencies is two calls, and
    // one of them must leave the other exactly where it was.
    let (book, accounts) = a_book_with_augusts_earnings("periods_close_currency").await?;
    let euro_revenue = open_an_account(&book, "eur-rev", "fee_revenue", None, "EUR").await?;
    let euro_receivable = open_an_account(
        &book,
        "eur-recv",
        "customer_receivable",
        Some("co_1"),
        "EUR",
    )
    .await?;
    book.post(&serde_json::json!({
        "tenant_id": "t1",
        "idempotency_key": "eur-charge-1",
        "effective_at": "2026-08-27T12:00:00Z",
        "postings": [{
            "source": euro_revenue, "destination": euro_receivable,
            "amount_minor": "900", "currency": "EUR"
        }],
    }))
    .await?;

    close_a_period(&book, AUGUST, "USD").await?;

    let closed: Vec<(String,)> =
        sqlx::query_as("SELECT currency::text FROM ledger_period_closes WHERE tenant_id = 't1'")
            .fetch_all(&book.pool)
            .await?;
    assert_eq!(closed, [("USD".to_owned(),)], "only the dollar book closed");
    // The euro revenue is untouched — no sweep, no checkpoint row, and the
    // dollar sweep did not reach across the currency.
    assert_eq!(book.balance(euro_revenue).await?, (0, 900, 1));
    assert_eq!(
        checkpoint_row_of(&book, euro_revenue).await?,
        None,
        "the dollar close must write no checkpoint row for a euro account"
    );
    assert_eq!(
        checkpoint_row_of(&book, accounts.revenue).await?,
        Some((REVENUE_MINOR, REVENUE_MINOR)),
        "and the dollar close is still exactly right"
    );

    book.assert_reconciled().await
}

#[tokio::test]
async fn reversing_a_close_this_endpoint_wrote_is_refused() -> TestResult {
    // The gate is ADR-0016's and it already existed; what is new is that the
    // close it refuses was written by this endpoint rather than by SQL.
    // Un-closing would contradict the standing checkpoint, and a close is
    // corrected by a later posting like everything else here.
    let (book, _accounts) = a_book_with_augusts_earnings("periods_close_reverse").await?;
    let closed = close_a_period(&book, AUGUST, "USD").await?;
    let transaction = closed
        .get("transaction_id")
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| format!("the close carried no transaction_id: {closed}"))?;

    let refused = book
        .post(&serde_json::json!({
            "tenant_id": "t1",
            "idempotency_key": "undo-the-close",
            "reverses_id": transaction,
        }))
        .await?;

    assert_eq!(refused.status(), 422, "un-closing must be refused");
    let body: serde_json::Value = refused.json().await?;
    assert_eq!(refusal_type(&body), Some("reverse_target_not_reversible"));

    book.assert_reconciled().await
}

#[tokio::test]
async fn a_period_this_book_does_not_hold_cannot_be_closed() -> TestResult {
    // Refused BEFORE the derived key is claimed, and that ordering is not
    // cosmetic: the key is `tenant:close:period:currency`, so a key burnt by a
    // refused attempt could never be retried under a different name.
    let (book, _accounts) = a_book_with_augusts_earnings("periods_close_unknown").await?;

    let refused = book
        .post_to(
            &close_path("2027-01"),
            &serde_json::json!({"tenant_id": "t1", "currency": "USD"}),
        )
        .await?;

    assert_eq!(refused.status(), 422);
    let body: serde_json::Value = refused.json().await?;
    assert_eq!(refusal_type(&body), Some("period_unknown"));
    let (events,): (i64,) = sqlx::query_as(
        "SELECT count(*) FROM ledger_events WHERE tenant_id = 't1' AND kind = 'period_close'",
    )
    .fetch_one(&book.pool)
    .await?;
    assert_eq!(events, 0, "the derived key must not have been claimed");

    book.assert_reconciled().await
}

#[tokio::test]
async fn a_book_with_no_earnings_account_in_that_currency_cannot_be_closed() -> TestResult {
    // Temporary accounts close DIRECTLY to `retained_earnings` (ADR-0011 §2):
    // there is no income summary account in between to fall back on, so a
    // currency with no earnings account has nowhere for the sweep to land.
    let (book, _accounts) = a_book_with_augusts_earnings("periods_close_no_earnings").await?;

    let refused = book
        .post_to(
            &close_path(AUGUST),
            &serde_json::json!({"tenant_id": "t1", "currency": "EUR"}),
        )
        .await?;

    assert_eq!(refused.status(), 422);
    let body: serde_json::Value = refused.json().await?;
    assert_eq!(refusal_type(&body), Some("retained_earnings_unknown"));

    book.assert_reconciled().await
}

#[tokio::test]
async fn two_periods_closed_in_order_leave_the_book_at_ten_zeros() -> TestResult {
    // `recon_close_order` is the invariant the bounded checkpoint check needs
    // (ADR-0020): consecutive stored levels are only a difference of NESTED
    // sets while the closes are in cursor order, and each close's cursor must
    // clear the previous close's own transaction. One close cannot show that;
    // two can, and this is the writer's side of it.
    let (book, accounts) = a_book_with_augusts_earnings("periods_close_two").await?;
    define_a_period(
        &book,
        "period-september",
        "2026-09",
        AUGUST_ENDS,
        "2026-10-01T00:00:00Z",
    )
    .await?;
    close_a_period(&book, AUGUST, "USD").await?;
    post_a_charge_dated(
        &book,
        "charge-2",
        "2026-09-15T00:00:00Z",
        1000,
        accounts.revenue,
        accounts.receivable,
    )
    .await?;

    close_a_period(&book, "2026-09", "USD").await?;

    // September's checkpoint is CUMULATIVE — it has no lower effective bound
    // — so the revenue account's stored row carries August's swept turnover
    // as well as September's, and nets to zero because both were closed.
    let september: Option<(i64, i64)> = sqlx::query_as(
        "SELECT input, output FROM ledger_period_balances
          WHERE tenant_id = 't1' AND period_code = '2026-09' AND currency = 'USD'
            AND account_id = $1",
    )
    .bind(accounts.revenue)
    .fetch_optional(&book.pool)
    .await?;
    assert_eq!(
        september,
        Some((REVENUE_MINOR + 1000, REVENUE_MINOR + 1000))
    );

    book.assert_reconciled().await
}
