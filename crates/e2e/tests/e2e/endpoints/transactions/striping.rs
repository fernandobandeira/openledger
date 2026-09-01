//! POST /v1/transactions, the striping half of the write path (ADR-0013 §4,
//! ADR-0018 §1): WHICH physical balance row of an account a posting lands
//! on, and what happens when an operator raises `stripe_count` on an account
//! that already has history. One file beside `post.rs`, `pending.rs` and
//! `reverse.rs` because a stripe is invisible on the wire — same request,
//! same response, same contract — and only the book underneath moves, so
//! nothing here re-proves what those files hold.
//!
//! **Nothing here predicts an assignment, and that is the point.** The
//! affinity a posting stripes on belongs to the DISPATCHER that took it, and
//! a post takes whichever of the pool's dispatchers is free (ADR-0018 §1 —
//! the pool is what supplies the concurrent, differing indices striping needs
//! to be worth anything). So which stripe any one post lands on is a race,
//! and a test that names it is asserting the luck of an assignment. What is
//! load-bearing survives the race: the account's TOTAL is the same however
//! the writes were split, each stripe's counter runs gapless from 1 on its
//! own, and under concurrency more than one stripe is occupied — the last
//! being exactly what a single-affinity writer could not do.

use uuid::Uuid;

use crate::support::{PostAnswer, TestBook, TestResult, assert_every_member_was_accepted, charge};

/// How many stripes the striped account in these tests declares. Matched to
/// the dispatcher pool's depth on purpose: a pool of N reaches at most N
/// stripes however many an account declares, so a count above it is inert
/// (ADR-0018's cost list) and one below it collides dispatchers onto shared
/// stripes for no gain here.
const STRIPES: i64 = 32;

/// How many callers post at once where a test needs the pool spread over more
/// than one dispatcher. Above the pool's depth so that arrivals genuinely
/// queue rather than each finding an idle dispatcher of its own.
const CALLERS: usize = 40;

/// Every balance row of one account, stripe by stripe, as
/// `(stripe, input, output, last_seq)` in stripe order. `TestBook::balance`
/// reads THE row of an account; a striped account has more than one, which
/// is the whole point.
async fn balance_rows(
    book: &TestBook,
    account: Uuid,
) -> Result<Vec<(i16, i64, i64, i64)>, sqlx::Error> {
    sqlx::query_as(
        "SELECT stripe, input, output, last_seq FROM ledger_account_balances
         WHERE tenant_id = 't1' AND account_id = $1
         ORDER BY stripe",
    )
    .bind(account)
    .fetch_all(&book.pool)
    .await
}

/// One account's whole position, summed across whatever stripes exist for it:
/// `(input, output, entries)`. This is how a READER sees a striped account —
/// it SUMs the rows that exist rather than enumerating `0..n-1` (ADR-0013 §4),
/// which is what makes a stripe invisible above the balance row.
async fn totals_across_stripes(
    book: &TestBook,
    account: Uuid,
) -> Result<(i64, i64, i64), sqlx::Error> {
    sqlx::query_as(
        "SELECT coalesce(sum(input), 0)::bigint, coalesce(sum(output), 0)::bigint,
                coalesce(sum(last_seq), 0)::bigint
         FROM ledger_account_balances
         WHERE tenant_id = 't1' AND account_id = $1",
    )
    .bind(account)
    .fetch_one(&book.pool)
    .await
}

/// What the account's history was opened with, before any raise — a
/// different amount from the burst's 100 so the opening charge's own entry
/// stays identifiable on a stripe the burst may also have written to.
const OPENING: i64 = 1000;

/// The amount of the FIRST entry stripe 0's counter ever issued for this
/// account, or `None` if that stripe has no entries. `account_seq` 1 within
/// `(account, currency, stripe)` is the counter's own first issue, so this is
/// "the entry that was there before the raise" asked exactly.
async fn first_entry_of_stripe_zero(
    book: &TestBook,
    account: Uuid,
) -> Result<Option<i64>, sqlx::Error> {
    let first: Option<(i64,)> = sqlx::query_as(
        "SELECT amount_minor FROM ledger_entries
         WHERE tenant_id = 't1' AND account_id = $1 AND stripe = 0 AND account_seq = 1",
    )
    .bind(account)
    .fetch_optional(&book.pool)
    .await?;
    Ok(first.map(|(amount,)| amount))
}

/// How many stripes of one account carry a balance row.
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

/// Raise one account's `stripe_count`. The operator's entire intervention:
/// one UPDATE on a hint column, no backfill, no DDL, no downtime.
async fn restripe(book: &TestBook, account: Uuid, stripe_count: i64) -> TestResult {
    sqlx::query("UPDATE ledger_accounts SET stripe_count = $1 WHERE tenant_id = 't1' AND id = $2")
        .bind(i16::try_from(stripe_count)?)
        .bind(account)
        .execute(&book.pool)
        .await?;
    Ok(())
}

/// What [`CALLERS`] charges of 100 add up to — the number every test below
/// states its expectation in, so none of them carries a constant computed
/// somewhere else.
const POSTED: i64 = 100 * CALLERS as i64;

/// [`CALLERS`] charges of 100 over one pair, posted at once — enough at once
/// that arrivals queue behind the pool and more than one dispatcher takes
/// work. Every answer comes back unread: whether the burst was accepted is
/// the test's to assert, in its own assert phase.
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
async fn an_accounts_total_across_its_stripes_is_everything_that_was_posted_to_it() -> TestResult {
    let book = TestBook::new("striping_total").await?;
    let (receivable, revenue) = book.fixture_accounts().await?;
    restripe(&book, receivable, STRIPES).await?;

    let answers = post_concurrent_charges(&book, revenue, receivable).await?;

    assert_every_member_was_accepted(&answers);
    // A stripe is invisible above the balance row: however the writes were
    // split, the account holds exactly what was posted to it, and its counter
    // has moved once per entry.
    assert_eq!(
        totals_across_stripes(&book, receivable).await?,
        (POSTED, 0, CALLERS as i64),
        "the striped account's summed position"
    );
    // The unstriped side is the control, and only for the TOTAL: same
    // postings, and it must agree to the minor unit. That it stayed on one
    // stripe is `concurrent_posts_occupy_more_than_one_stripe_...`'s
    // property, asserted there rather than twice.
    assert_eq!(
        totals_across_stripes(&book, revenue).await?,
        (0, POSTED, CALLERS as i64),
        "the unstriped account's summed position"
    );

    book.assert_reconciled().await
}

#[tokio::test]
async fn account_seq_runs_from_one_without_a_gap_within_each_stripe() -> TestResult {
    let book = TestBook::new("striping_gapless").await?;
    let (receivable, revenue) = book.fixture_accounts().await?;
    restripe(&book, receivable, STRIPES).await?;

    let answers = post_concurrent_charges(&book, revenue, receivable).await?;

    assert_every_member_was_accepted(&answers);
    // Every stripe of every account, each its own run from 1. The grain is
    // the assertion: two stripes of one account BOTH issue a 1, so an
    // account-wide run would be unfalsifiable here (the baseline's own note
    // on uq_entries__account_seq).
    book.assert_every_counter_is_gapless_from_one().await?;
    // ...and the counters and the journal agree, stripe by stripe: an entry
    // takes its stripe from the upsert's RETURNING rather than recomputing
    // it, and `fk_entries__stripe` refuses the write outright if the two ever
    // disagree.
    let (mismatched,): (i64,) = sqlx::query_as(
        "SELECT count(*) FROM ledger_entries e
         WHERE e.tenant_id = 't1'
           AND NOT EXISTS (
                 SELECT 1 FROM ledger_account_balances b
                 WHERE b.tenant_id = e.tenant_id AND b.account_id = e.account_id
                   AND b.currency = e.currency AND b.stripe = e.stripe
                   AND e.account_seq <= b.last_seq)",
    )
    .fetch_one(&book.pool)
    .await?;
    assert_eq!(
        mismatched, 0,
        "an entry names a stripe whose counter never issued its seq"
    );

    book.assert_reconciled().await
}

#[tokio::test]
async fn concurrent_posts_occupy_more_than_one_stripe_of_a_striped_account() -> TestResult {
    // The property striping exists for, and the one a single writer cannot
    // produce: worker affinity is CONSTANT per writer, so one writer puts
    // every write for an account on one stripe and sixty-four stripes become
    // one (ADR-0018 §1). More than one stripe occupied is the observable that
    // the pool's concurrent dispatchers really do hold DIFFERENT indices —
    // which is the only property of the affinity that matters, never which
    // values they are.
    let book = TestBook::new("striping_spread").await?;
    let (receivable, revenue) = book.fixture_accounts().await?;
    restripe(&book, receivable, STRIPES).await?;

    let answers = post_concurrent_charges(&book, revenue, receivable).await?;

    assert_every_member_was_accepted(&answers);
    let occupied = stripes_occupied_by(&book, receivable).await?;
    assert!(
        occupied > 1,
        "{CALLERS} concurrent posts occupied {occupied} stripe(s) of an account declaring \
         {STRIPES} — striping bought nothing, which is what a single writer identity looks like"
    );
    assert!(
        occupied <= STRIPES,
        "an account declaring {STRIPES} stripes holds rows on {occupied}"
    );
    // The unstriped side stayed on stripe 0 throughout: a stripe is one
    // account's, taken modulo that account's own declared count, not the
    // writer's for every account it touches.
    assert_eq!(stripes_occupied_by(&book, revenue).await?, 1);

    book.assert_reconciled().await
}

#[tokio::test]
async fn raising_stripe_count_on_an_account_with_history_opens_a_new_stripe_lazily() -> TestResult {
    // What only this test holds: an operator raises `stripe_count` on an
    // account that already has history, and the raise is a hint — no
    // backfill, no copy-forward. Everything else about a striped account
    // under load (its total, its gaplessness, that more than one stripe is
    // occupied at all) is held by the three tests above and is not re-asked
    // here.
    //
    // **Nothing here names a stripe number except zero, and zero is not a
    // guess**: it is the stripe the OPENING charge is already on, read back
    // before the raise. An earlier version of this test asserted that stripe
    // 0 was UNTOUCHED by the burst — which is the luck of an assignment this
    // file's header forbids: `stripe_affinity_of(0)` is 0, so dispatcher 0
    // writes stripe 0, and the assertion held only because the opening charge
    // had just consumed that dispatcher's turn and put it at the back of
    // tokio's waiter list. A warm-up request, a different pool depth or a
    // multi-thread runtime flips it.
    let book = TestBook::new("striping_raised").await?;
    let (receivable, revenue) = book.fixture_accounts().await?;
    // History first, on the single stripe every account starts with: the
    // account an operator discovers is hot is never an empty one.
    // 1000, not the burst's 100, so the opening charge's own entry can be
    // told apart from anything that lands on stripe 0 after the raise.
    let created = book
        .post(&serde_json::json!({
            "tenant_id": "t1",
            "idempotency_key": "opening-charge",
            "effective_at": "2026-08-27T12:00:00Z",
            "postings": [{
                "source": revenue, "destination": receivable,
                "amount_minor": OPENING, "currency": "USD"
            }],
        }))
        .await?;
    assert_eq!(created.status(), 201);
    assert_eq!(
        balance_rows(&book, receivable).await?,
        vec![(0, OPENING, 0, 1)],
        "the pre-raise history"
    );

    restripe(&book, receivable, STRIPES).await?;
    let answers = post_concurrent_charges(&book, revenue, receivable).await?;

    assert_every_member_was_accepted(&answers);
    // The raise copied nothing forward: the opening charge is still on stripe
    // 0, still the first entry of that counter's run, whatever the burst
    // afterwards added to it.
    let stripe_zero = balance_rows(&book, receivable)
        .await?
        .into_iter()
        .find(|(stripe, ..)| *stripe == 0)
        .ok_or("the stripe that held the pre-raise history is gone")?;
    let (stripe, input, output, last_seq) = stripe_zero;
    assert_eq!((stripe, output), (0, 0), "the pre-raise stripe's own row");
    assert!(
        input >= OPENING && last_seq >= 1,
        "the raise took history off stripe 0: it held {OPENING} in and one entry before the \
         raise, and reads ({input}, {last_seq}) after it"
    );
    // ...and exactly, not just "at least": the first entry stripe 0's counter
    // ever issued is still the opening charge, at the amount it was posted
    // for. A backfill that re-homed history would move it.
    assert_eq!(
        first_entry_of_stripe_zero(&book, receivable).await?,
        Some(OPENING),
        "stripe 0's first entry is no longer the opening charge"
    );
    // ...and a stripe that did not exist before the raise does now: the raise
    // is a hint the next write acts on, not a migration.
    assert!(
        stripes_occupied_by(&book, receivable).await? > 1,
        "the raise opened no stripe beyond the one that already had history"
    );

    // Nothing is stranded: the oracle groups per stripe, so a lazily created
    // stripe reconciles clean on its first write.
    book.assert_reconciled().await
}
