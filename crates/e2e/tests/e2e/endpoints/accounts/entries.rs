//! `GET /v1/accounts/{account_id}/entries` — one account's entries, in order,
//! at a cursor (ADR-0023).
//!
//! **This is the listing ADR-0019 refused, and the axis is why it can ship.**
//! That refusal stood on a listing having to *"choose between the recorded
//! axis and the effective axis"*; this one does not choose, it takes the axis
//! as a parameter — so what this file has to hold is exactly the two things
//! that choice was feared for:
//!
//! - **the two axes answer the same SET in different ORDERS**, and a backdated
//!   entry is where they disagree — it sits in its own past on the effective
//!   axis and last on the recorded one. That is the bitemporal point, and the
//!   most valuable assertion here: a read path that confused the two would
//!   answer a plausible page on every query below and the wrong one on this;
//! - **the page key is the axis's ordering key and never `account_seq`.**
//!   `uq_entries__account_seq` is per `(tenant, account, STRIPE, seq)`, so a
//!   striped account has two counters and both issue a 1. The walk below is
//!   over an account with entries on more than one stripe, and it asserts what
//!   paging by that counter would have broken: every entry exactly once, in
//!   the axis's own order.
//!
//! What is deliberately NOT re-proven here: the cursor rule
//! (`endpoints/reports/refusals.rs` holds every value ADR-0019 refuses before
//! it reaches SQL, and this route runs the same rule through the same
//! service), and the tenant fence's credential half
//! (`endpoints/reports/tenant_fence.rs`). What IS held here is that this
//! route's own answer stays inside one book.

use uuid::Uuid;

use crate::support::{
    PostAnswer, TestBook, TestResult, account_entries_path, charge, post_a_charge_dated,
    refusal_detail, refusal_type,
};

/// The charge recorded FIRST and dated LATER — 5.00 on the 20th.
const LATER_MINOR: i64 = 500;
const LATER_DATE: &str = "2026-08-20T00:00:00Z";

/// The charge recorded SECOND and dated EARLIER — 3.00 on the 10th. The
/// backdated arrival: a correction, a late settlement file, a month-end
/// accrual booked after the fact.
const BACKDATED_MINOR: i64 = 300;
const BACKDATED_DATE: &str = "2026-08-10T00:00:00Z";

/// A book whose insertion order is not its effective order, and the two
/// transactions that made it so.
struct ABackdatedAccount {
    book: TestBook,
    /// The account both charges debit — every assertion below is about this
    /// one, because it is the side whose statement the two axes disagree
    /// about.
    receivable: Uuid,
    later: Uuid,
    backdated: Uuid,
}

/// Two charges on one account, the second recorded dated ten days before the
/// first. The premise is asserted where it is arranged: without both halves
/// every assertion below is satisfied by a book whose two orders agree, which
/// is the ordinary case and not this one.
async fn an_account_whose_second_charge_is_dated_before_its_first(
    name: &str,
) -> Result<ABackdatedAccount, Box<dyn std::error::Error>> {
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
         BEFORE it — insertion order and effective order agree, so this account is not the \
         backdating case"
    );

    Ok(ABackdatedAccount {
        book,
        receivable,
        later,
        backdated,
    })
}

/// The `entry_id`s of a page, in the order the page answered them.
fn entries_of(page: &serde_json::Value) -> Vec<String> {
    field_of(page, "entry_id")
}

/// The `transaction_id` each row of a page belongs to, in the page's order —
/// which is how a test names a row by the charge that wrote it without
/// looking the id up in the database first.
fn transactions_of(page: &serde_json::Value) -> Vec<String> {
    field_of(page, "transaction_id")
}

fn field_of(page: &serde_json::Value, field: &str) -> Vec<String> {
    page.get("entries")
        .and_then(serde_json::Value::as_array)
        .map(|entries| {
            entries
                .iter()
                .filter_map(|entry| {
                    entry
                        .get(field)
                        .and_then(serde_json::Value::as_str)
                        .map(str::to_owned)
                })
                .collect()
        })
        .unwrap_or_default()
}

/// The `account_seq` each row of a page carries. Returned on every entry
/// because it is what a drift check walks — and never the page key.
fn seqs_of(page: &serde_json::Value) -> Vec<i64> {
    page.get("entries")
        .and_then(serde_json::Value::as_array)
        .map(|entries| {
            entries
                .iter()
                .filter_map(|entry| entry.get("account_seq").and_then(serde_json::Value::as_i64))
                .collect()
        })
        .unwrap_or_default()
}

/// The key a page hands back for the next one, if it handed one back.
fn next_after_of(page: &serde_json::Value) -> Option<&str> {
    page.get("next_after").and_then(serde_json::Value::as_str)
}

/// The cursor a page says it ran at — every read on this route answers with
/// one, supplied or server-pinned, and a walk sends it back so that the pages
/// after the first are pages of the same book (ADR-0019).
fn pinned_cursor_of(page: &serde_json::Value) -> Result<String, Box<dyn std::error::Error>> {
    Ok(page
        .get("pinned_cursor")
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| format!("the page carried no pinned_cursor: {page}"))?
        .to_owned())
}

/// One account's entry ids as the DATABASE orders them on an axis — the
/// oracle a page is held against, read over the admin connection rather than
/// through the endpoint under test. `ORDER BY` is the axis's own, entry id
/// included, because that tie-break is what makes each order total.
async fn entries_in_order(
    book: &TestBook,
    account: Uuid,
    axis: &str,
) -> Result<Vec<String>, Box<dyn std::error::Error>> {
    let ordered: Vec<(Uuid,)> = match axis {
        "recorded" => {
            sqlx::query_as(
                "SELECT id FROM ledger_entries
                  WHERE tenant_id = 't1' AND account_id = $1
                  ORDER BY xact_id, id",
            )
            .bind(account)
            .fetch_all(&book.pool)
            .await?
        }
        _ => {
            sqlx::query_as(
                "SELECT id FROM ledger_entries
                  WHERE tenant_id = 't1' AND account_id = $1
                  ORDER BY effective_at, xact_id, id",
            )
            .bind(account)
            .fetch_all(&book.pool)
            .await?
        }
    };
    Ok(ordered.into_iter().map(|(id,)| id.to_string()).collect())
}

/// How many stripes of one account carry a balance row — the premise of the
/// striped walk below, asserted rather than assumed.
async fn stripes_occupied_by(book: &TestBook, account: Uuid) -> Result<i64, sqlx::Error> {
    let (occupied,): (i64,) = sqlx::query_as(
        "SELECT count(*) FROM ledger_account_balances
         WHERE tenant_id = 't1' AND account_id = $1",
    )
    .bind(account)
    .fetch_one(&book.pool)
    .await?;
    Ok(occupied)
}

/// Raise one account's `stripe_count` — the operator's whole intervention, a
/// hint column and no backfill (ADR-0018 §1).
async fn restripe(book: &TestBook, account: Uuid, stripe_count: i16) -> TestResult {
    sqlx::query("UPDATE ledger_accounts SET stripe_count = $1 WHERE tenant_id = 't1' AND id = $2")
        .bind(stripe_count)
        .bind(account)
        .execute(&book.pool)
        .await?;
    Ok(())
}

/// How many stripes the striped account declares, and how many callers post
/// at once — matched to `endpoints/transactions/striping.rs`, where the same
/// two numbers are what actually spreads a burst over more than one
/// dispatcher.
const STRIPES: i16 = 32;
const CALLERS: usize = 40;

async fn post_concurrent_charges(
    book: &TestBook,
    revenue: Uuid,
    receivable: Uuid,
) -> Result<Vec<PostAnswer>, Box<dyn std::error::Error>> {
    let bodies: Vec<serde_json::Value> = (0..CALLERS)
        .map(|n| charge(&format!("charge-{n}"), revenue, receivable))
        .collect();
    book.post_all_at_once(&bodies).await
}

#[tokio::test]
async fn the_two_axes_answer_the_same_entries_in_different_orders() -> TestResult {
    let backdated =
        an_account_whose_second_charge_is_dated_before_its_first("entries_both_axes").await?;

    let (recorded_status, recorded) = backdated
        .book
        .read(&account_entries_path(
            "t1",
            backdated.receivable,
            "recorded",
            &[],
        ))
        .await?;
    let (effective_status, effective) = backdated
        .book
        .read(&account_entries_path(
            "t1",
            backdated.receivable,
            "effective",
            &[],
        ))
        .await?;

    assert_eq!(recorded_status.as_u16(), 200, "{recorded}");
    assert_eq!(effective_status.as_u16(), 200, "{effective}");
    // The same set: an axis chooses an order, never a subset. Sorted, because
    // "the same entries" is a set question and the order question is the next
    // assertion.
    let mut on_recorded = entries_of(&recorded);
    let mut on_effective = entries_of(&effective);
    on_recorded.sort();
    on_effective.sort();
    assert_eq!(
        on_recorded, on_effective,
        "the axes disagreed about WHICH entries the account has, not only about their order"
    );
    // ...and each order is the database's own for that axis.
    assert_eq!(
        entries_of(&recorded),
        entries_in_order(&backdated.book, backdated.receivable, "recorded").await?,
        "{recorded}"
    );
    assert_eq!(
        entries_of(&effective),
        entries_in_order(&backdated.book, backdated.receivable, "effective").await?,
        "{effective}"
    );
    // The orders differ, which is what makes naming the axis a decision
    // rather than a formality on this book.
    assert_ne!(
        entries_of(&recorded),
        entries_of(&effective),
        "the two axes answered the same order, so this book cannot tell them apart"
    );
    // Each page echoes the axis it was ordered by.
    assert_eq!(
        recorded.get("axis").and_then(serde_json::Value::as_str),
        Some("recorded")
    );
    assert_eq!(
        effective.get("axis").and_then(serde_json::Value::as_str),
        Some("effective")
    );

    backdated.book.assert_reconciled().await
}

#[tokio::test]
async fn a_backdated_entry_is_last_on_the_recorded_axis_and_first_on_the_effective_one()
-> TestResult {
    // The bitemporal point, in one assertion pair: the SAME entry, in two
    // POSITIONS. It arrived second, so the recorded axis — commit order —
    // puts it last; it is dated ten days earlier, so the effective axis puts
    // it first. A read path that filtered `effective_at` where it meant
    // `xact_id`, or ordered by `recorded_at` (a clock reading, which cannot
    // order commits — ADR-0006), answers one of these two wrongly.
    let backdated =
        an_account_whose_second_charge_is_dated_before_its_first("entries_backdated").await?;

    let (status, recorded) = backdated
        .book
        .read(&account_entries_path(
            "t1",
            backdated.receivable,
            "recorded",
            &[],
        ))
        .await?;
    let (_status, effective) = backdated
        .book
        .read(&account_entries_path(
            "t1",
            backdated.receivable,
            "effective",
            &[],
        ))
        .await?;

    assert_eq!(status.as_u16(), 200, "{recorded}");
    assert_eq!(
        transactions_of(&recorded),
        [backdated.later.to_string(), backdated.backdated.to_string()],
        "the recorded axis must place the backdated charge LAST — it committed last"
    );
    assert_eq!(
        transactions_of(&effective),
        [backdated.backdated.to_string(), backdated.later.to_string()],
        "the effective axis must place the backdated charge FIRST — it is dated first"
    );

    backdated.book.assert_reconciled().await
}

#[tokio::test]
async fn a_striped_accounts_walk_answers_every_entry_exactly_once_and_in_the_axiss_order()
-> TestResult {
    // **The test that would fail if `account_seq` became the page key.** The
    // counter is per `(account, stripe)`, so a striped account's two counters
    // both issue a 1 and interleave; paging by it drops or repeats rows and
    // says nothing. Paging by the axis's own key is exact, and the walk below
    // is the proof: every entry, once, in the order the database agrees is
    // that axis's.
    let book = TestBook::new("entries_striped_walk").await?;
    let (receivable, revenue) = book.fixture_accounts().await?;
    restripe(&book, receivable, STRIPES).await?;
    let answers = post_concurrent_charges(&book, revenue, receivable).await?;
    crate::support::assert_every_member_was_accepted(&answers);
    book.wait_for_the_horizon_to_retire_this_book().await?;
    let occupied = stripes_occupied_by(&book, receivable).await?;
    assert!(
        occupied > 1,
        "{CALLERS} concurrent posts occupied {occupied} stripe(s), so this account cannot show \
         what paging by a per-stripe counter would break"
    );

    let mut walked: Vec<String> = Vec::new();
    let mut seqs: Vec<i64> = Vec::new();
    let mut after: Option<String> = None;
    let mut cursor: Option<String> = None;
    for _ in 0..CALLERS {
        let mut and: Vec<(&str, &str)> = vec![("limit", "7")];
        if let Some(after) = after.as_deref() {
            and.push(("after", after));
        }
        if let Some(cursor) = cursor.as_deref() {
            and.push(("cursor", cursor));
        }
        let (status, page) = book
            .read(&account_entries_path("t1", receivable, "recorded", &and))
            .await?;
        assert_eq!(status.as_u16(), 200, "{page}");
        // Every page after the first is pinned at the FIRST page's cursor, so
        // the walk is one book's — the property a keyset has and an offset
        // does not.
        cursor = Some(pinned_cursor_of(&page)?);
        walked.extend(entries_of(&page));
        seqs.extend(seqs_of(&page));
        after = next_after_of(&page).map(str::to_owned);
        if after.is_none() {
            break;
        }
    }

    // Every entry exactly once, in the axis's order — held against the
    // database's own ordering rather than against the walk's self-consistency,
    // which a walk that dropped a page would also have.
    assert_eq!(
        walked,
        entries_in_order(&book, receivable, "recorded").await?,
        "the keyset walk did not reproduce the account's own recorded order"
    );
    assert_eq!(
        walked.len(),
        CALLERS,
        "the walk saw {} entries",
        walked.len()
    );
    // ...and the counter it did NOT page by is not a total order on this
    // account: more than one stripe is occupied, each counts from 1, so the
    // page carries the same `account_seq` more than once. That duplicate is
    // exactly what a walk keyed on it would have skipped past.
    let mut sorted = seqs.clone();
    sorted.sort_unstable();
    let unique = {
        let mut unique = sorted.clone();
        unique.dedup();
        unique.len()
    };
    assert!(
        unique < seqs.len(),
        "no account_seq repeats across this account's stripes, so the walk cannot show why the \
         counter is not the page key: {seqs:?}"
    );

    book.assert_reconciled().await
}

#[tokio::test]
async fn a_keyset_walk_crosses_a_page_boundary_without_repeating_or_skipping() -> TestResult {
    // The boundary itself, on the plainest book there is: three entries and a
    // page size of two, so it falls inside the account's history rather than
    // at its end. On BOTH axes, because a keyset that is exact on one order
    // and approximate on the other is a keyset on neither.
    let book = TestBook::new("entries_paged").await?;
    let (receivable, revenue) = book.fixture_accounts().await?;
    for (n, dated) in [
        "2026-08-03T00:00:00Z",
        "2026-08-01T00:00:00Z",
        "2026-08-02T00:00:00Z",
    ]
    .into_iter()
    .enumerate()
    {
        post_a_charge_dated(
            &book,
            &format!("charge-{n}"),
            dated,
            100,
            revenue,
            receivable,
        )
        .await?;
    }
    book.wait_for_the_horizon_to_retire_this_book().await?;

    for axis in ["recorded", "effective"] {
        let (status, first) = book
            .read(&account_entries_path(
                "t1",
                receivable,
                axis,
                &[("limit", "2")],
            ))
            .await?;
        assert_eq!(status.as_u16(), 200, "{first}");
        let after = next_after_of(&first)
            .ok_or("a full page must hand back the key of the next one")?
            .to_owned();

        let (status, second) = book
            .read(&account_entries_path(
                "t1",
                receivable,
                axis,
                &[("limit", "2"), ("after", &after)],
            ))
            .await?;

        assert_eq!(status.as_u16(), 200, "{second}");
        let walked: Vec<String> = entries_of(&first)
            .into_iter()
            .chain(entries_of(&second))
            .collect();
        assert_eq!(
            walked,
            entries_in_order(&book, receivable, axis).await?,
            "the {axis} axis's walk: first {first}, second {second}"
        );
        // Two pages of two and one, so the second is short and closes the
        // walk.
        assert_eq!(next_after_of(&second), None, "{second}");
    }

    book.assert_reconciled().await
}

#[tokio::test]
async fn an_unknown_account_is_refused_and_one_with_no_entries_answers_an_empty_page() -> TestResult
{
    // The distinction only `ledger_accounts` can draw (ADR-0019 C4), on a
    // second route: an account that exists and has never been posted to is a
    // 200 with nothing on it, and an account that does not exist is a 404.
    // Flattening the two would tell an integrator their book is empty when
    // their id is wrong.
    let book = TestBook::new("entries_unknown_account").await?;
    let (receivable, _revenue) = book.fixture_accounts().await?;

    let (dormant_status, dormant) = book
        .read(&account_entries_path("t1", receivable, "recorded", &[]))
        .await?;
    let (unknown_status, unknown) = book
        .read(&account_entries_path(
            "t1",
            Uuid::from_u128(0xDEAD),
            "recorded",
            &[],
        ))
        .await?;

    assert_eq!(dormant_status.as_u16(), 200, "{dormant}");
    assert!(entries_of(&dormant).is_empty(), "{dormant}");
    assert_eq!(next_after_of(&dormant), None, "{dormant}");
    assert_eq!(unknown_status.as_u16(), 404, "{unknown}");
    assert_eq!(refusal_type(&unknown), Some("account_unknown"), "{unknown}");
    // The refusal names no currency: this read asked about none, and a
    // refusal that invented one would send a caller looking for a second
    // reason it does not have.
    assert!(
        !refusal_detail(&unknown).contains("hold"),
        "the statement's account_unknown claimed a currency the caller never named: {:?}",
        refusal_detail(&unknown)
    );

    book.assert_reconciled().await
}

#[tokio::test]
async fn a_statement_answers_one_tenants_book_and_never_a_neighbours() -> TestResult {
    // The fence on the route that answers a whole account's history: the
    // read's session is scoped to the tenant the query names, so another
    // tenant's account is not merely empty here — it is not on this book at
    // all, which is the same answer an id that never existed gets.
    let book = TestBook::new("entries_tenant").await?;
    let (receivable, revenue) = book.fixture_accounts_for("t1").await?;
    let (theirs, their_revenue) = book.fixture_accounts_for("t2").await?;
    post_a_charge_dated(
        &book,
        "mine",
        "2026-08-01T00:00:00Z",
        100,
        revenue,
        receivable,
    )
    .await?;
    book.wait_for_the_horizon_to_retire_this_book().await?;

    let (mine_status, mine) = book
        .read(&account_entries_path("t1", receivable, "recorded", &[]))
        .await?;
    let (theirs_status, theirs_page) = book
        .read(&account_entries_path("t1", theirs, "recorded", &[]))
        .await?;

    assert_eq!(mine_status.as_u16(), 200, "{mine}");
    assert_eq!(entries_of(&mine).len(), 1, "{mine}");
    assert_eq!(
        theirs_status.as_u16(),
        404,
        "t2's account answered t1's caller: {theirs_page}"
    );
    assert_eq!(
        refusal_type(&theirs_page),
        Some("account_unknown"),
        "{theirs_page}"
    );
    // ...and nothing of t2's reached the page that did answer, named rather
    // than inferred from a count.
    assert!(
        !mine.to_string().contains(&their_revenue.to_string()),
        "t2's account reached t1's statement: {mine}"
    );

    book.assert_reconciled().await
}

#[tokio::test]
async fn the_axis_is_required_and_one_this_ledger_does_not_have_is_refused() -> TestResult {
    // ADR-0023's central rule on the wire. A missing axis is refused by the
    // deserializer — the parameter is documented required, so a generated
    // client cannot omit it — and an axis that is not one of the two names is
    // refused by the read path, which names both. Neither answers a page: the
    // decision this endpoint exists to make is the caller's.
    let book = TestBook::new("entries_axis_required").await?;
    let (receivable, _revenue) = book.fixture_accounts().await?;

    let (missing_status, missing) = book
        .read(&format!("/v1/accounts/{receivable}/entries?tenant_id=t1"))
        .await?;

    assert_eq!(missing_status.as_u16(), 400, "{missing}");
    assert_eq!(refusal_type(&missing), Some("invalid_request"), "{missing}");

    for axis in ["RECORDED", "commit", "both", ""] {
        let (status, body) = book
            .read(&account_entries_path("t1", receivable, axis, &[]))
            .await?;

        assert_eq!(status.as_u16(), 422, "axis {axis:?} answered {body}");
        assert_eq!(
            refusal_type(&body),
            Some("invalid_request"),
            "axis {axis:?} answered {body}"
        );
        assert!(
            refusal_detail(&body).contains("recorded")
                && refusal_detail(&body).contains("effective"),
            "the refusal must name both axes; detail was {:?}",
            refusal_detail(&body)
        );
    }

    book.assert_reconciled().await
}

#[tokio::test]
async fn the_effective_range_is_half_open_and_the_recorded_axis_refuses_it() -> TestResult {
    // The range is the effective axis's filter, half-open like every range on
    // this surface (ADR-0011 §A3) — so `effective_to` is the first instant
    // NOT on the page. On the recorded axis it is refused rather than
    // ignored: a page ordered and bounded by commit position that quietly
    // dropped rows for a business-date window would be answering a question
    // the caller could not see it had asked.
    let book = TestBook::new("entries_effective_range").await?;
    let (receivable, revenue) = book.fixture_accounts().await?;
    let first = post_a_charge_dated(
        &book,
        "first",
        "2026-08-01T00:00:00Z",
        100,
        revenue,
        receivable,
    )
    .await?;
    post_a_charge_dated(
        &book,
        "second",
        "2026-08-02T00:00:00Z",
        100,
        revenue,
        receivable,
    )
    .await?;
    book.wait_for_the_horizon_to_retire_this_book().await?;

    let (status, windowed) = book
        .read(&account_entries_path(
            "t1",
            receivable,
            "effective",
            &[
                ("effective_from", "2026-08-01T00:00:00Z"),
                ("effective_to", "2026-08-02T00:00:00Z"),
            ],
        ))
        .await?;
    let (refused_status, refused) = book
        .read(&account_entries_path(
            "t1",
            receivable,
            "recorded",
            &[("effective_from", "2026-08-01T00:00:00Z")],
        ))
        .await?;

    assert_eq!(status.as_u16(), 200, "{windowed}");
    // The upper bound is exclusive: the entry dated on the 2nd is the first
    // one NOT reported.
    assert_eq!(
        transactions_of(&windowed),
        [first.to_string()],
        "the window must hold the first charge alone: {windowed}"
    );
    assert_eq!(refused_status.as_u16(), 422, "{refused}");
    assert_eq!(refusal_type(&refused), Some("invalid_request"), "{refused}");

    book.assert_reconciled().await
}
