//! POST /v1/transactions, the BATCHED half of the write path (ADR-0018
//! §§2–3): what happens to a caller whose posting shares one statement with
//! other callers' postings. One file beside `post.rs` because a batched post
//! is the same request on the same endpoint — same wire contract, same error
//! grammar, deliberately indistinguishable — and only the statement
//! underneath changes.
//!
//! **Concurrency is how a batch is filled, because there is no window to
//! ask for one.** A dispatcher takes whatever is queued right now and never
//! waits for company that has not arrived, so a batch forms only when
//! requests queue behind an in-flight statement. Every test here therefore
//! posts [`CALLERS`] at once — above the dispatcher pool's depth, so that
//! arrivals genuinely queue rather than each finding an idle dispatcher of
//! its own — and reads back
//! [`TestBook::statements_that_carried_more_than_one_transaction`], the only
//! witness a batch leaves, rather than assuming it got one.
//!
//! **What is deliberately NOT here.** `post.rs` holds the single-post
//! contract — replay, key reuse, unknown-account refusal, the storage
//! failure, cross-tenant key reuse — and none of it is re-proved. Nor is
//! "two members sharing one idempotency key abort the batch": the
//! accumulator's drain makes that unreachable through this endpoint by
//! construction, and `batching.rs`'s
//! `a_drain_never_carries_one_idempotency_key_twice` holds the prevention
//! where it lives. What is held here is only what is new about a SHARED
//! statement: that a batch answers each member on its own, that a refused
//! member costs its batch-mates nothing and costs itself nothing beyond the
//! refusal, and that a key racing itself across a full pool still gets
//! ADR-0013 §2's race rather than a batch-wide abort.

use uuid::Uuid;

use crate::support::{
    PostAnswer, TestBook, TestResult, assert_every_member_was_accepted, charge, header,
};

/// How many callers post at once. Above the dispatcher pool's depth (32,
/// ADR-0018 §2) so that arrivals must queue behind an in-flight statement,
/// which is the only thing that forms a batch.
const CALLERS: usize = 40;

/// The account no chart ever created — a member the batch's gate must
/// withhold.
const GHOST: Uuid = Uuid::from_u128(0xDEAD_BEEF_DEAD_BEEF_DEAD_BEEF_DEAD_BEEF);

/// The idempotency key the refused member of the poison-pill burst carries.
const GHOST_KEY: &str = "charge-ghost";

/// Which member of the burst names the ghost: the middle of the forty, so it
/// has company on both sides rather than heading or tailing a drain. Set past
/// [`CALLERS`] and no member is poisoned, which
/// [`the_refused_member_and_its_batch_mates`] reports as itself rather than
/// passing off as a green run.
const POISONED_MEMBER: usize = 20;

/// A burst of [`CALLERS`] distinct charges, one of which — in the middle,
/// where it has company on both sides — names an account that does not
/// exist. Every answer comes back, in order; nothing is asserted here, so
/// each test states its own expectations in its own assert phase.
///
/// The poison pill is what ADR-0018 §3 is about: a batch cannot roll back for
/// one member without destroying the others, so the promise that a refusal
/// writes nothing is kept by WITHHOLDING that member from the shared
/// statement instead.
async fn post_a_burst_carrying_one_unknown_account(
    book: &TestBook,
    revenue: Uuid,
    receivable: Uuid,
) -> Result<Vec<PostAnswer>, Box<dyn std::error::Error>> {
    let bodies: Vec<serde_json::Value> = (0..CALLERS)
        .map(|n| {
            if n == POISONED_MEMBER {
                charge(GHOST_KEY, GHOST, receivable)
            } else {
                charge(&format!("charge-{n}"), revenue, receivable)
            }
        })
        .collect();
    book.post_all_at_once(&bodies).await
}

/// The burst's two halves, read apart: the refused member's own body, and
/// every other member's answer. Set [`POISONED_MEMBER`] past [`CALLERS`] and
/// there is no refused member — reported as itself rather than passed off as
/// a green run.
fn the_refused_member_and_its_batch_mates(
    answers: Vec<PostAnswer>,
) -> Result<(serde_json::Value, Vec<PostAnswer>), Box<dyn std::error::Error>> {
    let mut refused = None;
    let mut accepted = Vec::with_capacity(answers.len());
    for (n, answer) in answers.into_iter().enumerate() {
        if n == POISONED_MEMBER {
            refused = Some(answer.2);
        } else {
            accepted.push(answer);
        }
    }
    let refused = refused.ok_or("the burst posted no poisoned member")?;
    Ok((refused, accepted))
}

/// A batch that carried company really did form. Asserted rather than
/// assumed, because the wire cannot say so: without this a burst that
/// happened to dispatch every member alone would pass every assertion below
/// while exercising the single statement `post.rs` already covers.
async fn assert_a_statement_carried_more_than_one_member(book: &TestBook) -> TestResult {
    let shared = book
        .statements_that_carried_more_than_one_transaction()
        .await?;
    assert!(
        shared > 0,
        "{CALLERS} concurrent posts filled no batch — every member was dispatched alone, so \
         nothing here touched the batched statement"
    );
    Ok(())
}

#[tokio::test]
async fn concurrent_distinct_postings_each_come_back_with_their_own_transaction() -> TestResult {
    let book = TestBook::new("batched_distinct").await?;
    let (receivable, revenue) = book.fixture_accounts().await?;
    let bodies: Vec<serde_json::Value> = (0..CALLERS)
        .map(|n| charge(&format!("charge-{n}"), revenue, receivable))
        .collect();

    let answers = book.post_all_at_once(&bodies).await?;

    // N callers, N answers, and no two of them the same write: the members of
    // one statement are INDEPENDENT commands that happen to share it, never
    // one write handed out N times.
    assert_every_member_was_accepted(&answers);
    let mut events = std::collections::BTreeSet::new();
    let mut transactions = std::collections::BTreeSet::new();
    for (n, (_, replayed, body)) in answers.iter().enumerate() {
        assert_eq!(replayed.as_deref(), Some("false"), "member {n}");
        events.insert(body.get("event_id").and_then(serde_json::Value::as_str));
        transactions.insert(
            body.get("transaction_id")
                .and_then(serde_json::Value::as_str),
        );
    }
    assert_eq!(events.len(), CALLERS, "two callers were handed one event");
    assert!(
        !transactions.contains(&None) && transactions.len() == CALLERS,
        "two callers were handed one transaction"
    );
    assert_a_statement_carried_more_than_one_member(&book).await?;

    book.assert_reconciled().await
}

#[tokio::test]
async fn a_batch_writes_one_event_one_transaction_and_two_legs_per_member() -> TestResult {
    // The book a shared statement leaves, counted — the triple the test above
    // is not about. A batch that lost or duplicated one member's entries
    // answers every caller correctly and still writes the wrong book, so this
    // is held on its own rather than as a fourth assertion under a name about
    // distinctness.
    let book = TestBook::new("batched_write_counts").await?;
    let (receivable, revenue) = book.fixture_accounts().await?;
    let bodies: Vec<serde_json::Value> = (0..CALLERS)
        .map(|n| charge(&format!("charge-{n}"), revenue, receivable))
        .collect();

    let answers = book.post_all_at_once(&bodies).await?;

    assert_every_member_was_accepted(&answers);
    assert_a_statement_carried_more_than_one_member(&book).await?;
    assert_eq!(
        book.write_counts().await?,
        (CALLERS as i64, CALLERS as i64, 2 * CALLERS as i64),
        "a batch wrote a different book than its members asked for"
    );

    book.assert_reconciled().await
}

#[tokio::test]
async fn a_batch_refuses_its_unknown_account_member_by_name_and_commits_the_rest() -> TestResult {
    let book = TestBook::new("batched_poison_pill").await?;
    let (receivable, revenue) = book.fixture_accounts().await?;

    let answers = post_a_burst_carrying_one_unknown_account(&book, revenue, receivable).await?;

    let (refused, batch_mates) = the_refused_member_and_its_batch_mates(answers)?;
    // The other half of the name, and the half a batch cannot get by rolling
    // back: every innocent member COMMITTED.
    assert_every_member_was_accepted(&batch_mates);
    assert_eq!(refused.get("type"), Some(&"account_unknown".into()));
    let detail = refused.get("detail").and_then(serde_json::Value::as_str);
    assert!(
        detail.is_some_and(|detail| detail.contains(&GHOST.to_string())),
        "the refusal must name the account that does not exist; detail was {detail:?}"
    );
    // The run really did batch. What it cannot show is that the REFUSED
    // member was in one of those batches: a withheld member writes nothing,
    // so it leaves no witness of its own, and if its drain happened to take
    // it alone the single statement rolled back and the wire answer holds for
    // the older reason. Said plainly rather than dressed up — this test is
    // only as strong as the burst is likely to have collected it, and 25 is
    // the ceiling one drain takes.
    assert_a_statement_carried_more_than_one_member(&book).await?;

    book.assert_reconciled().await
}

#[tokio::test]
async fn a_refused_batch_member_leaves_no_ledger_event_behind() -> TestResult {
    // **The event count is the point, and it is the whole test.** The gate
    // sits ABOVE the key claim, so the refused member contributed nothing at
    // all — not the entries, not the transaction, and not the
    // `ledger_events` row. Gating only the downstream inserts leaves that row
    // committed and the member's key permanently burned: its retry finds the
    // claim held, the replay lookup finds an event joined to no transaction,
    // and the caller is answered `transaction_id: null, replayed: true` —
    // which ADR-0013 says is the legitimate shape for the majority of
    // accepted operations. A refusal becomes indistinguishable from a
    // success, forever.
    //
    // And NO reconciliation check reads `ledger_events`, so the ten-zero
    // oracle is structurally blind to it — the spike reported ten zeros on a
    // book carrying exactly this defect (25 events / 24 transactions). This
    // assertion is the only thing in the suite that can see it, which is why
    // it is not a third bullet under a test named for something else.
    let book = TestBook::new("batched_no_orphan_event").await?;
    let (receivable, revenue) = book.fixture_accounts().await?;

    post_a_burst_carrying_one_unknown_account(&book, revenue, receivable).await?;

    let committed = CALLERS as i64 - 1;
    assert_eq!(
        book.write_counts().await?,
        (committed, committed, 2 * committed),
        "a batch's refused member left an event, a transaction or entries behind"
    );

    book.assert_reconciled().await
}

#[tokio::test]
async fn a_reused_key_is_refused_as_a_reused_key_whether_or_not_it_shared_a_statement() -> TestResult
{
    // The one thing a caller must never be able to tell the two paths apart
    // by: WHICH refusal it hears. Post a key, then re-post it with a typo'd
    // account. Unbatched, the claim is asked first — `ON CONFLICT DO NOTHING`
    // returns nothing, the account is never looked at, and the caller hears
    // `idempotency_key_reused`. The batched statement GATES above the claim
    // (which is what keeps a refused member's key from being burned), so its
    // ANSWER has to be read claim-first to say the same thing; read gate-first
    // and this same request hears `account_unknown` instead, depending only
    // on whether the pool happened to be busy.
    //
    // Green on both paths by construction, which is the point — and, like the
    // poison-pill test above, only as strong as the burst is likely to have
    // collected the member: a drain that took it alone exercises the single
    // path, and the assertion holds there for the older reason.
    let book = TestBook::new("batched_reused_key_precedence").await?;
    let (receivable, revenue) = book.fixture_accounts().await?;
    let first = book.post(&charge(GHOST_KEY, revenue, receivable)).await?;
    assert_eq!(first.status(), 201);

    // The same key, a body naming an account that does not exist, in the
    // middle of a burst so it has company on both sides.
    let bodies: Vec<serde_json::Value> = (0..CALLERS)
        .map(|n| {
            if n == POISONED_MEMBER {
                charge(GHOST_KEY, GHOST, receivable)
            } else {
                charge(&format!("charge-{n}"), revenue, receivable)
            }
        })
        .collect();
    let answers = book.post_all_at_once(&bodies).await?;

    let (refused, batch_mates) = the_refused_member_and_its_batch_mates(answers)?;
    assert_every_member_was_accepted(&batch_mates);
    assert_eq!(
        refused.get("type"),
        Some(&"idempotency_key_reused".into()),
        "the key claim must be read before the account gate, as it is unbatched: {refused}"
    );
    assert_a_statement_carried_more_than_one_member(&book).await?;

    book.assert_reconciled().await
}

#[tokio::test]
async fn the_key_of_a_refused_batch_member_is_free_to_use_again() -> TestResult {
    // The other half of the same defect, and the half a caller actually
    // feels: an unburned key is one the caller can retry with. Held
    // separately from the count above because a burned key and a miscounted
    // book fail differently — the count is the operator's evidence, this is
    // the caller's.
    let book = TestBook::new("batched_key_survives").await?;
    let (receivable, revenue) = book.fixture_accounts().await?;
    post_a_burst_carrying_one_unknown_account(&book, revenue, receivable).await?;

    // The same key the batch refused, now naming accounts that exist.
    let retried = book.post(&charge(GHOST_KEY, revenue, receivable)).await?;

    assert_eq!(retried.status(), 201, "the refused member's key was burned");
    assert_eq!(
        header(&retried, "idempotency-replayed")?,
        "false",
        "the refused member's key replayed a write that never happened"
    );
    let body: serde_json::Value = retried.json().await?;
    assert!(
        body.get("transaction_id")
            .is_some_and(serde_json::Value::is_string),
        "the retry answered no transaction — the shape a burned key produces — in {body}"
    );
    // The burst's members plus this one: the retry is a REAL write, not a
    // stored result re-rendered.
    assert_eq!(
        book.write_counts().await?,
        (CALLERS as i64, CALLERS as i64, 2 * CALLERS as i64),
        "the retry did not write"
    );

    book.assert_reconciled().await
}

#[tokio::test]
async fn one_idempotency_key_raced_across_the_whole_pool_never_answers_a_500() -> TestResult {
    // ADR-0013 §2's race, run at a scale the single path cannot reach alone:
    // `post.rs` races twelve callers, which is BELOW the pool's depth, so
    // every one of them finds an idle dispatcher and no two can ever meet in
    // a drain. Above the depth they queue together — and a drain that swept
    // them into one statement would have them claim one event between them,
    // fan it to both ordinals, hit `uq_txn__one_per_event` and abort the
    // whole batch, reaching those callers as 500s (measured on a naive drain:
    // 6 of 40). Leaving a rival key for the next batch is what keeps this
    // ADR-0013 §2's ordinary race instead.
    let book = TestBook::new("batched_one_key_raced").await?;
    let (receivable, revenue) = book.fixture_accounts().await?;
    let bodies: Vec<serde_json::Value> = (0..CALLERS)
        .map(|_| charge("charge-race", revenue, receivable))
        .collect();

    let answers = book.post_all_at_once(&bodies).await?;

    // Zero 500s, and nothing else: the one/N-1 split and the single write are
    // `post.rs::concurrent_identical_posts_...`'s to hold, and re-asserting
    // them here would say the race behaves like a race in a test named for
    // the one thing that regime can newly break.
    let statuses: Vec<u16> = answers
        .iter()
        .map(|(status, _, _)| status.as_u16())
        .collect();
    assert_eq!(
        statuses.iter().filter(|status| **status >= 500).count(),
        0,
        "a batch-wide abort reached a caller as a 500; statuses were {statuses:?}"
    );

    book.assert_reconciled().await
}
