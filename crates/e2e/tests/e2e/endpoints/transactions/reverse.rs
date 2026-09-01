//! POST /v1/transactions, the reversal-and-void half of the contract
//! (ADR-0016, Reversals and the void): a reversal is a NEW posted
//! transaction carrying `reverses_id` and NO postings — the server derives
//! the full mirror from a POSTED target (directions flipped, cache moved
//! back) and the zero-posting void marker from a PENDING one (nothing moves;
//! the bridge retires the hold). One file beside `post.rs` and `pending.rs`
//! because it is the same endpoint's third request shape.
//!
//! THE ORDER OF THIS FILE: the two green paths (the mirror, the void) → the
//! void's return-shape pin (its own creation, never a replay of itself) →
//! the effective-date convention (omitted defaults to the target's; a lower
//! date is accepted; absence outside a reversal is refused) → the refusals,
//! each red against a specific guard: a request carrying postings, a target
//! that does not exist (or exists on another tenant's book), a target that
//! is itself a supersession (the neither-pointer arm — reversing a
//! resolution strands its pending forever, ADR-0016's worked failure), a
//! `period_close` target (the kind arm), a second reversal, the sequential
//! resolve-vs-reverse twin in both orders, the UNCOMMITTED-rival races in
//! both directions (the `uq_txn__one_supersession` backstop and its
//! constraint-name mapping, staged deterministically — 422, never 500), and
//! a key reused with a different or dated `reverses_id` body.

use sqlx::AssertSqlSafe;
use uuid::Uuid;

use crate::support::{TestBook, TestResult, header};

/// One posted 25.00 charge between the fixture pair, the mirror tests'
/// target. Returns the charge's transaction id.
async fn post_one_charge(
    book: &TestBook,
    revenue: Uuid,
    receivable: Uuid,
) -> Result<Uuid, Box<dyn std::error::Error>> {
    let created = book
        .post(&serde_json::json!({
            "tenant_id": "t1",
            "idempotency_key": "charge-1",
            "effective_at": "2026-08-27T12:00:00Z",
            "postings": [{
                "source": revenue, "destination": receivable,
                "amount_minor": 2500, "currency": "USD"
            }],
        }))
        .await?;
    assert_eq!(created.status(), 201, "seeding the charge");
    let body: serde_json::Value = created.json().await?;
    Ok(body
        .get("transaction_id")
        .and_then(serde_json::Value::as_str)
        .ok_or("no transaction_id on the charge 201")?
        .parse()?)
}

/// One pending 5.00 hold between the fixture pair, the void tests' target.
async fn post_a_pending_hold(
    book: &TestBook,
    revenue: Uuid,
    receivable: Uuid,
) -> Result<Uuid, Box<dyn std::error::Error>> {
    let created = book
        .post(&serde_json::json!({
            "tenant_id": "t1",
            "idempotency_key": "hold-1",
            "effective_at": "2026-08-28T00:00:00Z",
            "status": "pending",
            "postings": [{
                "source": revenue, "destination": receivable,
                "amount_minor": 500, "currency": "USD"
            }],
        }))
        .await?;
    assert_eq!(created.status(), 201, "seeding the pending hold");
    let body: serde_json::Value = created.json().await?;
    Ok(body
        .get("transaction_id")
        .and_then(serde_json::Value::as_str)
        .ok_or("no transaction_id on the pending 201")?
        .parse()?)
}

/// The (status, reverses_id, entry count) of one transaction row — what the
/// reversal tests must see: the marker's shape, and the original unmutated.
async fn shape_of(book: &TestBook, id: Uuid) -> Result<(String, Option<Uuid>, i64), sqlx::Error> {
    sqlx::query_as(
        "SELECT x.status::text, x.reverses_id,
                (SELECT count(*) FROM ledger_entries e
                 WHERE e.tenant_id = x.tenant_id AND e.transaction_id = x.id)
         FROM ledger_transactions x WHERE x.tenant_id = 't1' AND x.id = $1",
    )
    .bind(id)
    .fetch_one(&book.pool)
    .await
}

#[tokio::test]
async fn a_mirror_reversal_moves_the_cache_back_and_replays_its_stored_result() -> TestResult {
    let book = TestBook::new("reverse_mirror").await?;
    let (receivable, revenue) = book.fixture_accounts().await?;
    let charge = post_one_charge(&book, revenue, receivable).await?;
    let reversal_body = serde_json::json!({
        "tenant_id": "t1",
        "idempotency_key": "undo-1",
        "effective_at": "2026-08-29T00:00:00Z",
        "reverses_id": charge,
    });

    let reversed = book.post(&reversal_body).await?;

    assert_eq!(reversed.status(), 201);
    assert_eq!(header(&reversed, "idempotency-replayed")?, "false");
    let body: serde_json::Value = reversed.json().await?;
    let reversal: Uuid = body
        .get("transaction_id")
        .and_then(serde_json::Value::as_str)
        .ok_or("no transaction_id on the reversal 201")?
        .parse()?;
    assert_ne!(reversal, charge, "a reversal is a NEW transaction");
    // The new row is posted, names its target, and carries the derived
    // mirror: the target's legs, directions flipped, seqs issued — while
    // the original stands unmutated (status never mutates).
    let (status, reverses, legs) = shape_of(&book, reversal).await?;
    assert_eq!(
        (status.as_str(), reverses, legs),
        ("posted", Some(charge), 2),
        "the reversal must be a posted two-leg mirror naming its target"
    );
    let (status, reverses, legs) = shape_of(&book, charge).await?;
    assert_eq!(
        (status.as_str(), reverses, legs),
        ("posted", None, 2),
        "the reversed original must stand unmutated"
    );
    let (direction, amount, seq): (String, i64, i64) = sqlx::query_as(
        "SELECT direction::text, amount_minor, account_seq FROM ledger_entries
         WHERE tenant_id = 't1' AND transaction_id = $1 AND account_id = $2",
    )
    .bind(reversal)
    .bind(receivable)
    .fetch_one(&book.pool)
    .await?;
    assert_eq!(
        (direction.as_str(), amount, seq),
        ("credit", 2500, 2),
        "the receivable's mirror leg must flip its debit"
    );
    // The cache moves BACK — and gross turnover inflates on both sides, the
    // contra cost ADR-0016 records: input and output both carry the 25.00.
    assert_eq!(book.balance(receivable).await?, (2500, 2500, 2));
    assert_eq!(book.balance(revenue).await?, (2500, 2500, 2));
    let (netted,): (bool,) = sqlx::query_as(
        "SELECT coalesce(bool_and(balance_minor = 0), true) FROM trial_balance
         WHERE tenant_id = 't1'",
    )
    .fetch_one(&book.pool)
    .await?;
    assert!(netted, "a mirrored charge must net to zero on the face");

    // ...and the reversal's key replays its stored result (ADR-0013 §2 is
    // shape-blind), never a second mirror.
    let replayed = book.post(&reversal_body).await?;
    assert_eq!(replayed.status(), 200);
    assert_eq!(header(&replayed, "idempotency-replayed")?, "true");
    let replay: serde_json::Value = replayed.json().await?;
    assert_eq!(replay, body, "the reversal key must replay its own result");
    assert_eq!(book.write_counts().await?, (2, 2, 4));
    book.assert_reconciled().await
}

#[tokio::test]
async fn a_void_retires_the_pending_and_touches_nothing() -> TestResult {
    let book = TestBook::new("reverse_void").await?;
    let (receivable, revenue) = book.fixture_accounts().await?;
    let pending = post_a_pending_hold(&book, revenue, receivable).await?;

    // No postings AND no effective_at: the void defers to the target's date.
    let voided = book
        .post(&serde_json::json!({
            "tenant_id": "t1",
            "idempotency_key": "void-1",
            "reverses_id": pending,
        }))
        .await?;

    assert_eq!(voided.status(), 201);
    let body: serde_json::Value = voided.json().await?;
    let void: Uuid = body
        .get("transaction_id")
        .and_then(serde_json::Value::as_str)
        .ok_or("no transaction_id on the void 201")?
        .parse()?;
    // The marker: POSTED, naming its target, and deliberately entryless —
    // the zero-posting exception ADR-0005 now states — dated the target's
    // own effective_at (the omitted-date default).
    let (status, reverses, legs) = shape_of(&book, void).await?;
    assert_eq!(
        (status.as_str(), reverses, legs),
        ("posted", Some(pending), 0),
        "the void must be a posted zero-entry marker naming its target"
    );
    let (defaulted,): (bool,) = sqlx::query_as(
        "SELECT effective_at = TIMESTAMPTZ '2026-08-28T00:00:00Z'
         FROM ledger_transactions WHERE tenant_id = 't1' AND id = $1",
    )
    .bind(void)
    .fetch_one(&book.pool)
    .await?;
    assert!(
        defaulted,
        "an omitted effective_at must default to the target's"
    );
    // Nothing moved: the pending never touched the cache, so the void has
    // nothing to withhold — counters, balances and the face all stand.
    assert_eq!(book.balance(receivable).await?, (0, 0, 1));
    assert_eq!(book.balance(revenue).await?, (0, 0, 1));
    let (face_rows,): (i64,) =
        sqlx::query_as("SELECT count(*) FROM trial_balance WHERE tenant_id = 't1'")
            .fetch_one(&book.pool)
            .await?;
    assert_eq!(face_rows, 0, "the trial balance must stay clean");
    // ...and the population is retired: the bridge already tests resolved
    // OR reversed, so the marker alone empties it.
    let (bridged,): (i64,) =
        sqlx::query_as("SELECT count(*) FROM recon_pending_bridge WHERE tenant_id = 't1'")
            .fetch_one(&book.pool)
            .await?;
    assert_eq!(bridged, 0, "a voided hold must leave the bridge");
    assert_eq!(book.write_counts().await?, (2, 2, 2));
    // Ten zeros — which is the void carve-out proven green: without it the
    // entryless marker reads as the TRUNCATE scar's no_entries break.
    book.assert_reconciled().await
}

/// The return-shape pin (ADR-0016's requirement 3, the adversary's failure
/// mode #1): the single call's answer anchors on the CLAIMED ROW, so the
/// zero-delta void is rows back — its own creation — and never the zero-rows
/// replay signal. Regressed, the first void answers 200/replayed-true with
/// ids for a marker the rollback then DISCARDS: this test fails on the
/// status, and on the marker's absence.
#[tokio::test]
async fn a_void_is_its_own_creation_never_a_replay_of_itself() -> TestResult {
    let book = TestBook::new("reverse_void_creation").await?;
    let (receivable, revenue) = book.fixture_accounts().await?;
    let pending = post_a_pending_hold(&book, revenue, receivable).await?;
    let void_body = serde_json::json!({
        "tenant_id": "t1",
        "idempotency_key": "void-1",
        "reverses_id": pending,
    });

    let voided = book.post(&void_body).await?;

    assert_eq!(voided.status(), 201, "the first void is a CREATION");
    assert_eq!(header(&voided, "idempotency-replayed")?, "false");
    let body: serde_json::Value = voided.json().await?;
    let (markers,): (i64,) = sqlx::query_as(
        "SELECT count(*) FROM ledger_transactions
         WHERE tenant_id = 't1' AND reverses_id = $1",
    )
    .bind(pending)
    .fetch_one(&book.pool)
    .await?;
    assert_eq!(markers, 1, "the marker must have COMMITTED");
    // ...and only the RETRY is the replay.
    let replayed = book.post(&void_body).await?;
    assert_eq!(replayed.status(), 200);
    assert_eq!(header(&replayed, "idempotency-replayed")?, "true");
    let replay: serde_json::Value = replayed.json().await?;
    assert_eq!(replay, body, "the void's key must replay the stored marker");
    assert_eq!(book.write_counts().await?, (2, 2, 2));
    book.assert_reconciled().await
}

/// The effective-date convention's other halves: a caller-supplied date
/// BELOW the target's is accepted as given (the soft convention — the as-of
/// window between the two dates is ADR-0016's recorded cost, not a refusal),
/// and OUTSIDE a reversal the absence of effective_at stays a refusal — the
/// writer does not invent dates for postings.
#[tokio::test]
async fn a_below_target_date_is_accepted_and_absence_outside_a_reversal_refused() -> TestResult {
    let book = TestBook::new("reverse_dates").await?;
    let (receivable, revenue) = book.fixture_accounts().await?;
    let charge = post_one_charge(&book, revenue, receivable).await?;

    let backdated = book
        .post(&serde_json::json!({
            "tenant_id": "t1",
            "idempotency_key": "undo-backdated",
            "effective_at": "2026-08-20T00:00:00Z",
            "reverses_id": charge,
        }))
        .await?;

    assert_eq!(
        backdated.status(),
        201,
        "a below-target date is the documented soft convention, not an error"
    );
    let body: serde_json::Value = backdated.json().await?;
    let (dated,): (bool,) = sqlx::query_as(
        "SELECT bool_and(effective_at = TIMESTAMPTZ '2026-08-20T00:00:00Z') FROM ledger_entries
         WHERE tenant_id = 't1' AND transaction_id = $1",
    )
    .bind(
        body.get("transaction_id")
            .and_then(serde_json::Value::as_str)
            .ok_or("no transaction_id")?
            .parse::<Uuid>()?,
    )
    .fetch_one(&book.pool)
    .await?;
    assert!(dated, "the supplied date must be taken as given");

    // A plain posting with no effective_at: refused by name, nothing written.
    let undated = book
        .post(&serde_json::json!({
            "tenant_id": "t1",
            "idempotency_key": "undated-charge",
            "postings": [{
                "source": revenue, "destination": receivable,
                "amount_minor": 100, "currency": "USD"
            }],
        }))
        .await?;

    assert_eq!(undated.status(), 422);
    let error: serde_json::Value = undated.json().await?;
    assert_eq!(error.get("type"), Some(&"invalid_request".into()));
    let detail = error.get("detail").and_then(serde_json::Value::as_str);
    assert!(
        detail.is_some_and(|detail| detail.contains("unless the request is a reversal")),
        "the refusal must name the one exception; detail was {detail:?}"
    );
    assert_eq!(book.write_counts().await?, (2, 2, 4));
    book.assert_reconciled().await
}

#[tokio::test]
async fn a_reversal_carrying_postings_or_posted_as_pending_is_refused() -> TestResult {
    let book = TestBook::new("reverse_with_postings").await?;
    let (receivable, revenue) = book.fixture_accounts().await?;
    let charge = post_one_charge(&book, revenue, receivable).await?;

    // The caller restates the mirror by hand — exactly the failure surface
    // the no-postings rule exists to remove.
    let refused = book
        .post(&serde_json::json!({
            "tenant_id": "t1",
            "idempotency_key": "undo-1",
            "effective_at": "2026-08-29T00:00:00Z",
            "reverses_id": charge,
            "postings": [{
                "source": receivable, "destination": revenue,
                "amount_minor": 2500, "currency": "USD"
            }],
        }))
        .await?;

    assert_eq!(refused.status(), 422);
    let error: serde_json::Value = refused.json().await?;
    assert_eq!(error.get("type"), Some(&"invalid_request".into()));
    let detail = error.get("detail").and_then(serde_json::Value::as_str);
    assert!(
        detail.is_some_and(|detail| detail.contains("must not carry postings")),
        "the refusal must say the mirror is derived; detail was {detail:?}"
    );
    // ...and so is a pending "reversal": one request moving the pending
    // population twice (the constructor twin of the pending resolution).
    let pending_reversal = book
        .post(&serde_json::json!({
            "tenant_id": "t1",
            "idempotency_key": "undo-pending",
            "status": "pending",
            "reverses_id": charge,
        }))
        .await?;

    assert_eq!(pending_reversal.status(), 422);
    let error: serde_json::Value = pending_reversal.json().await?;
    assert_eq!(error.get("type"), Some(&"invalid_request".into()));
    let detail = error.get("detail").and_then(serde_json::Value::as_str);
    assert!(
        detail.is_some_and(|detail| detail.contains("cannot itself be pending")),
        "a pending reversal must be refused by shape; detail was {detail:?}"
    );
    assert_eq!(book.write_counts().await?, (1, 1, 2));
    book.assert_reconciled().await
}

#[tokio::test]
async fn reversing_a_missing_or_foreign_target_is_refused() -> TestResult {
    let book = TestBook::new("reverse_ghost").await?;
    let (t2_receivable, t2_revenue) = book.fixture_accounts_for("t2").await?;

    // A target that exists nowhere: 422, named, the claim rolled back.
    let refused = book
        .post(&serde_json::json!({
            "tenant_id": "t1",
            "idempotency_key": "undo-ghost",
            "reverses_id": Uuid::from_u128(0xDEAD_BEEF),
        }))
        .await?;

    assert_eq!(refused.status(), 422);
    let error: serde_json::Value = refused.json().await?;
    assert_eq!(error.get("type"), Some(&"reverse_target_unknown".into()));
    assert_eq!(book.write_counts().await?, (0, 0, 0));

    // A target on ANOTHER tenant's book is the same refusal: the gate reads
    // only this tenant's transactions — drop the tenant from its WHERE and
    // this mirrors another book's money.
    let t2_charge = book
        .post(&serde_json::json!({
            "tenant_id": "t2",
            "idempotency_key": "charge-t2",
            "effective_at": "2026-08-27T12:00:00Z",
            "postings": [{
                "source": t2_revenue, "destination": t2_receivable,
                "amount_minor": 2500, "currency": "USD"
            }],
        }))
        .await?;
    assert_eq!(t2_charge.status(), 201);
    let t2_charge: serde_json::Value = t2_charge.json().await?;
    let cross = book
        .post(&serde_json::json!({
            "tenant_id": "t1",
            "idempotency_key": "undo-cross",
            "reverses_id": t2_charge.get("transaction_id"),
        }))
        .await?;

    assert_eq!(cross.status(), 422);
    let error: serde_json::Value = cross.json().await?;
    assert_eq!(error.get("type"), Some(&"reverse_target_unknown".into()));
    assert_eq!(book.write_counts().await?, (1, 1, 2));
    book.assert_reconciled().await
}

/// The neither-pointer arm of the gate, red in both directions: reversing a
/// RESOLUTION strands its pending forever (the bridge retires the pending
/// because the resolution EXISTS, not because it is live, and the
/// supersession slot stays occupied eternally — ADR-0016's worked failure),
/// and reversing a REVERSAL un-does an undo that a fresh posting should
/// correct instead. Both are `reverse_target_not_reversible`, nothing
/// written.
#[tokio::test]
async fn reversing_a_resolution_or_a_reversal_is_refused() -> TestResult {
    let book = TestBook::new("reverse_supersession").await?;
    let (receivable, revenue) = book.fixture_accounts().await?;
    let pending = post_a_pending_hold(&book, revenue, receivable).await?;
    let resolved = book
        .post(&serde_json::json!({
            "tenant_id": "t1",
            "idempotency_key": "capture-1",
            "effective_at": "2026-08-29T00:00:00Z",
            "resolves_id": pending,
            "postings": [{
                "source": revenue, "destination": receivable,
                "amount_minor": 500, "currency": "USD"
            }],
        }))
        .await?;
    assert_eq!(resolved.status(), 201);
    let resolution: serde_json::Value = resolved.json().await?;
    let charge = post_one_charge(&book, revenue, receivable).await?;
    let reversed = book
        .post(&serde_json::json!({
            "tenant_id": "t1",
            "idempotency_key": "undo-1",
            "reverses_id": charge,
        }))
        .await?;
    assert_eq!(reversed.status(), 201);
    let reversal: serde_json::Value = reversed.json().await?;

    let of_resolution = book
        .post(&serde_json::json!({
            "tenant_id": "t1",
            "idempotency_key": "undo-the-capture",
            "reverses_id": resolution.get("transaction_id"),
        }))
        .await?;
    let of_reversal = book
        .post(&serde_json::json!({
            "tenant_id": "t1",
            "idempotency_key": "undo-the-undo",
            "reverses_id": reversal.get("transaction_id"),
        }))
        .await?;

    for (case, refused) in [("a resolution", of_resolution), ("a reversal", of_reversal)] {
        assert_eq!(refused.status(), 422, "reversing {case} must be refused");
        let error: serde_json::Value = refused.json().await?;
        assert_eq!(
            error.get("type"),
            Some(&"reverse_target_not_reversible".into()),
            "for {case}"
        );
    }
    // The book: hold + capture + charge + its mirror, and nothing from the
    // two refusals.
    assert_eq!(book.write_counts().await?, (4, 4, 8));
    book.assert_reconciled().await
}

/// The kind arm of the gate: a `period_close` transaction cannot be
/// reversed — un-closing retained earnings while the close's checkpoint and
/// cursor stand would contradict the period record (ADR-0016).
///
/// A COMPLETE close, not just a labelled transaction, and since ADR-0020 it
/// has to be: `recon_close_breaks.close_orphan` reports a posted
/// `kind='period_close'` transaction that no `ledger_period_closes` row names,
/// so the period and the close row below are what keep this book's
/// `assert_reconciled` honest rather than decoration. It closes JULY, which
/// this book has nothing in — so the close is legitimately ENTRYLESS (nothing
/// to sweep) and its checkpoint legitimately empty (nothing is effective
/// before the period end), which also exercises ADR-0020's empty-close
/// carve-out end to end.
#[tokio::test]
async fn reversing_a_period_close_is_refused() -> TestResult {
    let book = TestBook::new("reverse_close").await?;
    let (receivable, revenue) = book.fixture_accounts().await?;
    post_one_charge(&book, revenue, receivable).await?;
    sqlx::raw_sql(AssertSqlSafe(
        "INSERT INTO ledger_periods (tenant_id, code, starts_at, ends_at, tz)
         VALUES ('t1', '2026-07', '2026-07-01T00:00:00Z', '2026-08-01T00:00:00Z', 'UTC');
         INSERT INTO ledger_events (tenant_id, id, kind, source, idempotency_key,
                                    idempotency_hash, payload, effective_at)
         VALUES ('t1', '0e2e0000-0000-7000-8000-000000000080', 'period_close', 'internal',
                 'close-2026-07', decode('00', 'hex'), '{}'::jsonb, '2026-07-31T00:00:00Z');
         INSERT INTO ledger_transactions (tenant_id, id, event_id, kind, status, effective_at)
         VALUES ('t1', '0e2e0000-0000-7000-8000-000000000081',
                 '0e2e0000-0000-7000-8000-000000000080', 'period_close', 'posted',
                 '2026-07-31T00:00:00Z');
         INSERT INTO ledger_period_closes (tenant_id, period_code, currency, starts_at,
                                           ends_at, transaction_id, txn_effective_at,
                                           computed_at_xid)
         VALUES ('t1', '2026-07', 'USD', '2026-07-01T00:00:00Z', '2026-08-01T00:00:00Z',
                 '0e2e0000-0000-7000-8000-000000000081', '2026-07-31T00:00:00Z',
                 pg_current_xact_id())"
            .to_owned(),
    ))
    .execute(&book.pool)
    .await?;

    let refused = book
        .post(&serde_json::json!({
            "tenant_id": "t1",
            "idempotency_key": "undo-the-close",
            "reverses_id": "0e2e0000-0000-7000-8000-000000000081",
        }))
        .await?;

    assert_eq!(refused.status(), 422, "un-closing must be refused");
    let error: serde_json::Value = refused.json().await?;
    assert_eq!(
        error.get("type"),
        Some(&"reverse_target_not_reversible".into())
    );
    // Two events, two transactions, and only the charge's two entries: the
    // close of an empty period posts no legs.
    assert_eq!(book.write_counts().await?, (2, 2, 2));
    book.assert_reconciled().await
}

#[tokio::test]
async fn a_second_reversal_of_one_target_is_refused() -> TestResult {
    let book = TestBook::new("reverse_twice").await?;
    let (receivable, revenue) = book.fixture_accounts().await?;
    let charge = post_one_charge(&book, revenue, receivable).await?;
    let first = book
        .post(&serde_json::json!({
            "tenant_id": "t1",
            "idempotency_key": "undo-1",
            "reverses_id": charge,
        }))
        .await?;
    assert_eq!(first.status(), 201);

    // A NEW key, the same target: a posting is un-done once.
    let second = book
        .post(&serde_json::json!({
            "tenant_id": "t1",
            "idempotency_key": "undo-2",
            "reverses_id": charge,
        }))
        .await?;

    assert_eq!(second.status(), 422);
    let error: serde_json::Value = second.json().await?;
    assert_eq!(error.get("type"), Some(&"target_already_superseded".into()));
    assert_eq!(book.write_counts().await?, (2, 2, 4));
    assert_eq!(book.balance(receivable).await?, (2500, 2500, 2));
    book.assert_reconciled().await
}

/// The sequential resolve-vs-reverse twin, both orders: one supersession
/// per pending, whichever verb wins — a resolved hold cannot be voided
/// (the money already posted) and a voided hold cannot be resolved (the
/// hold was undone). Both refusals are the shared `target_already_superseded`.
#[tokio::test]
async fn a_resolved_pending_cannot_be_voided_nor_a_voided_one_resolved() -> TestResult {
    let book = TestBook::new("reverse_vs_resolve").await?;
    let (receivable, revenue) = book.fixture_accounts().await?;
    let resolved_hold = post_a_pending_hold(&book, revenue, receivable).await?;
    let captured = book
        .post(&serde_json::json!({
            "tenant_id": "t1",
            "idempotency_key": "capture-1",
            "effective_at": "2026-08-29T00:00:00Z",
            "resolves_id": resolved_hold,
            "postings": [{
                "source": revenue, "destination": receivable,
                "amount_minor": 500, "currency": "USD"
            }],
        }))
        .await?;
    assert_eq!(captured.status(), 201);
    let voided_hold = book
        .post(&serde_json::json!({
            "tenant_id": "t1",
            "idempotency_key": "hold-2",
            "effective_at": "2026-08-28T00:00:00Z",
            "status": "pending",
            "postings": [{
                "source": revenue, "destination": receivable,
                "amount_minor": 700, "currency": "USD"
            }],
        }))
        .await?;
    assert_eq!(voided_hold.status(), 201);
    let voided_hold: serde_json::Value = voided_hold.json().await?;
    let voided_hold = voided_hold
        .get("transaction_id")
        .and_then(serde_json::Value::as_str)
        .ok_or("no transaction_id")?
        .to_owned();
    let voided = book
        .post(&serde_json::json!({
            "tenant_id": "t1",
            "idempotency_key": "void-2",
            "reverses_id": voided_hold,
        }))
        .await?;
    assert_eq!(voided.status(), 201);

    // Void the resolved hold; resolve the voided one.
    let void_after_resolve = book
        .post(&serde_json::json!({
            "tenant_id": "t1",
            "idempotency_key": "void-the-resolved",
            "reverses_id": resolved_hold,
        }))
        .await?;
    let resolve_after_void = book
        .post(&serde_json::json!({
            "tenant_id": "t1",
            "idempotency_key": "capture-the-voided",
            "effective_at": "2026-08-29T00:00:00Z",
            "resolves_id": voided_hold,
            "postings": [{
                "source": revenue, "destination": receivable,
                "amount_minor": 700, "currency": "USD"
            }],
        }))
        .await?;

    for (case, refused) in [
        ("voiding a resolved hold", void_after_resolve),
        ("resolving a voided hold", resolve_after_void),
    ] {
        assert_eq!(refused.status(), 422, "{case} must be refused");
        let error: serde_json::Value = refused.json().await?;
        assert_eq!(
            error.get("type"),
            Some(&"target_already_superseded".into()),
            "for {case}"
        );
    }
    // hold-1 + capture, hold-2 + void marker; the refusals wrote nothing.
    assert_eq!(book.write_counts().await?, (4, 4, 6));
    book.assert_reconciled().await
}

/// The resolve-vs-reverse race twin, direction one: an API VOID racing a
/// genuinely UNCOMMITTED rival RESOLUTION of the same pending. The gate
/// reads committed state and passes; the void's marker blocks on the
/// rival's uncommitted `uq_txn__one_supersession` tuple; when the rival
/// commits, the unique violation fires INSIDE the single call and the
/// constraint-name mapping must answer 422 `target_already_superseded`, never a
/// 500 — the window the two per-pointer indexes could never referee.
#[tokio::test]
async fn a_void_racing_an_uncommitted_resolution_is_refused_not_a_500() -> TestResult {
    let book = TestBook::new("reverse_rival_resolve").await?;
    let (receivable, revenue) = book.fixture_accounts().await?;
    let pending = post_a_pending_hold(&book, revenue, receivable).await?;
    // The rival: a full, balanced resolution, begun and HELD uncommitted
    // (the shared staging in support/book.rs).
    let held_open = book
        .begin_a_rival_resolution(pending, receivable, revenue)
        .await?;

    let racer = book.spawn_post(&serde_json::json!({
        "tenant_id": "t1",
        "idempotency_key": "void-api",
        "reverses_id": pending,
    }));
    let blocked = book.wait_until_a_backend_blocks_on_a_lock().await?;
    assert!(
        blocked,
        "the API void never blocked on the rival's uncommitted claim within 15s"
    );
    held_open.commit().await?;

    let (status, _replayed, body) = racer.await??;

    assert_eq!(
        status, 422,
        "the blocked void must be refused by name, never a 500; body was {body}"
    );
    assert_eq!(body.get("type"), Some(&"target_already_superseded".into()));
    // The rival's resolution stands; the void attempt wrote nothing.
    assert_eq!(book.write_counts().await?, (2, 2, 4));
    assert_eq!(book.balance(receivable).await?, (500, 0, 2));
    book.assert_reconciled().await
}

/// ...and direction two: an API RESOLUTION racing an uncommitted rival
/// VOID — the rival is the zero-entry marker itself, so what blocks the
/// resolution is nothing but the supersession index tuple. Same named 422.
#[tokio::test]
async fn a_resolution_racing_an_uncommitted_void_is_refused_not_a_500() -> TestResult {
    let book = TestBook::new("reverse_rival_void").await?;
    let (receivable, revenue) = book.fixture_accounts().await?;
    let pending = post_a_pending_hold(&book, revenue, receivable).await?;
    // The rival: the void marker alone — one event, one zero-entry posted
    // transaction naming the target — begun on a pooled connection and HELD
    // uncommitted. Inline rather than shared: the zero-entry marker is this
    // test's whole point, and no other test stages one.
    let mut held_open = book.pool.begin().await?;
    sqlx::raw_sql(AssertSqlSafe(format!(
        "INSERT INTO ledger_events (tenant_id, id, kind, source, idempotency_key,
                                    idempotency_hash, payload, effective_at)
         VALUES ('t1', '0e2e0000-0000-7000-8000-0000000000a0', 'posting', 'internal',
                 'rival-void', decode('00', 'hex'), '{{}}'::jsonb, '2026-08-28T00:00:00Z');
         INSERT INTO ledger_transactions (tenant_id, id, event_id, kind, status,
                                          effective_at, reverses_id)
         VALUES ('t1', '0e2e0000-0000-7000-8000-0000000000a1',
                 '0e2e0000-0000-7000-8000-0000000000a0', 'posting', 'posted',
                 '2026-08-28T00:00:00Z', '{pending}')"
    )))
    .execute(&mut *held_open)
    .await?;

    let racer = book.spawn_post(&serde_json::json!({
        "tenant_id": "t1",
        "idempotency_key": "capture-api",
        "effective_at": "2026-08-29T00:00:00Z",
        "resolves_id": pending,
        "postings": [{
            "source": revenue, "destination": receivable,
            "amount_minor": 500, "currency": "USD"
        }],
    }));
    let blocked = book.wait_until_a_backend_blocks_on_a_lock().await?;
    assert!(
        blocked,
        "the API resolution never blocked on the rival's uncommitted void within 15s"
    );
    held_open.commit().await?;

    let (status, _replayed, body) = racer.await??;

    assert_eq!(
        status, 422,
        "the blocked resolution must be refused by name, never a 500; body was {body}"
    );
    assert_eq!(body.get("type"), Some(&"target_already_superseded".into()));
    // The rival's void stands — a legitimately voided hold, ten zeros via
    // the carve-out — and the resolution attempt wrote nothing.
    assert_eq!(book.write_counts().await?, (2, 2, 2));
    assert_eq!(book.balance(receivable).await?, (0, 0, 1));
    book.assert_reconciled().await
}

/// The hash covers `reverses_id` and the reversal's optional date: a key
/// reused with a DIFFERENT target — or with the omitted date now spelled
/// out — is a different request wearing an old key, refused as
/// `idempotency_key_reused`, never replayed and never a second reversal.
#[tokio::test]
async fn a_reused_key_differing_only_in_reverses_id_or_its_date_is_refused() -> TestResult {
    let book = TestBook::new("reverse_key_reuse").await?;
    let (receivable, revenue) = book.fixture_accounts().await?;
    let charge = post_one_charge(&book, revenue, receivable).await?;
    let other = book
        .post(&serde_json::json!({
            "tenant_id": "t1",
            "idempotency_key": "charge-2",
            "effective_at": "2026-08-27T12:00:00Z",
            "postings": [{
                "source": revenue, "destination": receivable,
                "amount_minor": 900, "currency": "USD"
            }],
        }))
        .await?;
    assert_eq!(other.status(), 201);
    let other: serde_json::Value = other.json().await?;
    let reversed = book
        .post(&serde_json::json!({
            "tenant_id": "t1",
            "idempotency_key": "undo-1",
            "reverses_id": charge,
        }))
        .await?;
    assert_eq!(reversed.status(), 201);

    // undo-1 pointed at the OTHER charge, and undo-1 with the date the
    // default chose now spelled out: both different bodies.
    let moved_target = book
        .post(&serde_json::json!({
            "tenant_id": "t1",
            "idempotency_key": "undo-1",
            "reverses_id": other.get("transaction_id"),
        }))
        .await?;
    let spelled_out = book
        .post(&serde_json::json!({
            "tenant_id": "t1",
            "idempotency_key": "undo-1",
            "effective_at": "2026-08-27T12:00:00Z",
            "reverses_id": charge,
        }))
        .await?;

    for (case, refused) in [
        ("a different reverses_id", moved_target),
        ("the defaulted date spelled out", spelled_out),
    ] {
        assert_eq!(refused.status(), 422, "for {case}");
        let error: serde_json::Value = refused.json().await?;
        assert_eq!(
            error.get("type"),
            Some(&"idempotency_key_reused".into()),
            "for {case}"
        );
    }
    // Two charges and one mirror; the reuses wrote nothing.
    assert_eq!(book.write_counts().await?, (3, 3, 6));
    book.assert_reconciled().await
}
