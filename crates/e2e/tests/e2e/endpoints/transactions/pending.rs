//! POST /v1/transactions, the pending → posted half of the contract
//! (roadmap M3, ADR-0016): a transaction posted as `status: pending` is
//! sequenced but moves no balance, and its resolution is a NEW posted
//! transaction carrying `resolves_id` — never an UPDATE to the original.
//! One file beside `post.rs` because it is the same endpoint's contract
//! grown by two optional fields, split so each file reads whole.
//!
//! THE ORDER OF THIS FILE: the two green paths (the pending post, the
//! resolution) → the amounts question (a partial capture resolves with
//! less) → the replay contract for both kinds of key, and its inverse (a
//! reused key differing ONLY in the new fields is a poisoned replay — the
//! hash must cover `status` and `resolves_id`) → the refusals, each a red
//! path against a specific guard: a target that does not exist (and one
//! that exists on ANOTHER tenant's book), a posted target (ADR-0004's
//! −49,223 counterexample — the semantic linkage the foreign key never
//! held), a second resolution, N resolutions racing one target (the gate
//! under concurrency), a resolution racing a genuinely UNCOMMITTED rival
//! (the `uq_txn__one_supersession` backstop, staged deterministically), and
//! a pending resolution (refused before any SQL).

use uuid::Uuid;

use crate::support::{TestBook, TestResult, header, post_a_pending_hold};

/// The (status, resolves_id) pair of one transaction row — what the
/// resolution tests must see mutate NEVER and reference exactly once.
async fn status_and_resolves(
    book: &TestBook,
    id: Uuid,
) -> Result<(String, Option<Uuid>), sqlx::Error> {
    sqlx::query_as(
        "SELECT status::text, resolves_id FROM ledger_transactions
         WHERE tenant_id = 't1' AND id = $1",
    )
    .bind(id)
    .fetch_one(&book.pool)
    .await
}

#[tokio::test]
async fn a_pending_posting_issues_seqs_and_never_moves_the_cache() -> TestResult {
    let book = TestBook::new("pending_post").await?;
    let (receivable, revenue) = book.fixture_accounts().await?;

    let pending = post_a_pending_hold(&book, revenue, receivable).await?;

    // The cache means POSTED (ADR-0010): input/output stand at zero while
    // last_seq advances, because the pending entries still drew their
    // account_seq under the balance row's lock.
    assert_eq!(book.balance(receivable).await?, (0, 0, 1));
    assert_eq!(book.balance(revenue).await?, (0, 0, 1));
    let (status, resolves): (String, Option<Uuid>) = status_and_resolves(&book, pending).await?;
    assert_eq!((status.as_str(), resolves), ("pending", None));
    let (seqs,): (Vec<i64>,) = sqlx::query_as(
        "SELECT array_agg(account_seq ORDER BY account_seq) FROM ledger_entries
         WHERE tenant_id = 't1' AND account_id = $1",
    )
    .bind(receivable)
    .fetch_one(&book.pool)
    .await?;
    assert_eq!(seqs, vec![1], "the pending entry must carry account_seq 1");
    // ...and the population is NAMED: the bridge derives available =
    // posted + pending for the account holding the hold.
    let (posted, pending_minor, available, txns): (i64, i64, i64, i64) = sqlx::query_as(
        "SELECT posted_balance_minor::bigint, pending_balance_minor::bigint,
                available_balance_minor::bigint, pending_txns::bigint
         FROM recon_pending_bridge WHERE tenant_id = 't1' AND account_id = $1",
    )
    .bind(receivable)
    .fetch_one(&book.pool)
    .await?;
    assert_eq!(
        (posted, pending_minor, available, txns),
        (0, 500, 500, 1),
        "the bridge must foot: available = posted + pending"
    );
    book.assert_reconciled().await
}

#[tokio::test]
async fn a_resolution_is_a_new_posted_transaction_and_only_then_the_cache_moves() -> TestResult {
    let book = TestBook::new("pending_resolve").await?;
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
    let body: serde_json::Value = resolved.json().await?;
    let resolution: Uuid = body
        .get("transaction_id")
        .and_then(serde_json::Value::as_str)
        .ok_or("no transaction_id on the resolution 201")?
        .parse()?;
    assert_ne!(resolution, pending, "a resolution is a NEW transaction");
    // The new row is posted and names its target; the original NEVER
    // mutated — still pending, exactly as written (the baseline's own
    // sentence on `ledger_transactions.status`).
    let (status, resolves) = status_and_resolves(&book, resolution).await?;
    assert_eq!((status.as_str(), resolves), ("posted", Some(pending)));
    let (status, resolves) = status_and_resolves(&book, pending).await?;
    assert_eq!(
        (status.as_str(), resolves),
        ("pending", None),
        "the pending original must stand unmutated"
    );
    // Only NOW the cache moves — by the resolution's own posted amounts —
    // and each account's counter has issued both entries' seqs.
    assert_eq!(book.balance(receivable).await?, (500, 0, 2));
    assert_eq!(book.balance(revenue).await?, (0, 500, 2));
    // The pending population is retired by reference: the bridge holds no
    // row for this book (`superseded` is recon_journal_to_reports' matching
    // item), so available = posted again.
    let (bridged,): (i64,) =
        sqlx::query_as("SELECT count(*) FROM recon_pending_bridge WHERE tenant_id = 't1'")
            .fetch_one(&book.pool)
            .await?;
    assert_eq!(bridged, 0, "a resolved hold must leave the bridge");
    assert_eq!(book.write_counts().await?, (2, 2, 4));
    book.assert_reconciled().await
}

/// The amounts question, pinned where the schema decides it: a pending
/// transaction is retired by REFERENCE (`resolves_id`), never by amount
/// matching, so a resolution may post less than it held — the partial
/// capture every card rail needs (card ADR-0001's clearings routinely
/// differ from the hold). The cache moves by what actually posted.
#[tokio::test]
async fn a_resolution_may_capture_less_than_the_pending_amounts() -> TestResult {
    let book = TestBook::new("pending_partial").await?;
    let (receivable, revenue) = book.fixture_accounts().await?;
    let pending = post_a_pending_hold(&book, revenue, receivable).await?;

    let resolved = book
        .post(&serde_json::json!({
            "tenant_id": "t1",
            "idempotency_key": "capture-partial",
            "effective_at": "2026-08-29T00:00:00Z",
            "resolves_id": pending,
            "postings": [{
                "source": revenue, "destination": receivable,
                "amount_minor": 300, "currency": "USD"
            }],
        }))
        .await?;

    assert_eq!(resolved.status(), 201);
    // Posted moved by the CAPTURED 3.00, and the unposted 2.00 remainder is
    // gone with the hold — not a balance anywhere.
    assert_eq!(book.balance(receivable).await?, (300, 0, 2));
    assert_eq!(book.balance(revenue).await?, (0, 300, 2));
    let (bridged,): (i64,) =
        sqlx::query_as("SELECT count(*) FROM recon_pending_bridge WHERE tenant_id = 't1'")
            .fetch_one(&book.pool)
            .await?;
    assert_eq!(bridged, 0, "a partially captured hold is still retired");
    book.assert_reconciled().await
}

/// ADR-0013 §2's replay contract is status-blind: the stored result is
/// `(event_id, transaction_id)` whatever the transaction's status, so a
/// pending key replays its stored pending answer and a resolving key its
/// stored resolution — never a re-post, never a second write.
#[tokio::test]
async fn a_pending_key_and_a_resolving_key_each_replay_their_own_stored_result() -> TestResult {
    let book = TestBook::new("pending_replay").await?;
    let (receivable, revenue) = book.fixture_accounts().await?;
    let hold = serde_json::json!({
        "tenant_id": "t1",
        "idempotency_key": "hold-1",
        "effective_at": "2026-08-28T00:00:00Z",
        "status": "pending",
        "postings": [{
            "source": revenue, "destination": receivable,
            "amount_minor": 500, "currency": "USD"
        }],
    });
    let held = book.post(&hold).await?;
    assert_eq!(held.status(), 201);
    let held: serde_json::Value = held.json().await?;
    let pending = held
        .get("transaction_id")
        .and_then(serde_json::Value::as_str)
        .ok_or("no transaction_id on the pending 201")?;
    let capture = serde_json::json!({
        "tenant_id": "t1",
        "idempotency_key": "capture-1",
        "effective_at": "2026-08-29T00:00:00Z",
        "resolves_id": pending,
        "postings": [{
            "source": revenue, "destination": receivable,
            "amount_minor": 500, "currency": "USD"
        }],
    });
    let captured = book.post(&capture).await?;
    assert_eq!(captured.status(), 201);
    let captured: serde_json::Value = captured.json().await?;

    let held_again = book.post(&hold).await?;
    let captured_again = book.post(&capture).await?;

    assert_eq!(held_again.status(), 200);
    assert_eq!(header(&held_again, "idempotency-replayed")?, "true");
    let held_replay: serde_json::Value = held_again.json().await?;
    assert_eq!(
        held_replay, held,
        "the pending key must replay its stored pending result"
    );
    assert_eq!(captured_again.status(), 200);
    assert_eq!(header(&captured_again, "idempotency-replayed")?, "true");
    let captured_replay: serde_json::Value = captured_again.json().await?;
    assert_eq!(
        captured_replay, captured,
        "the resolving key must replay its stored resolution"
    );
    // Two writes total, however many replays: the hold and its capture.
    assert_eq!(book.write_counts().await?, (2, 2, 4));
    book.assert_reconciled().await
}

/// The replay contract's inverse, for exactly the two NEW fields: same key,
/// identical postings and effective_at, and a body that differs ONLY in
/// `status` — or only in `resolves_id`, changed or omitted — is a DIFFERENT
/// request wearing an old key: 422 `idempotency_key_reused`, nothing
/// written, never a replay. This is the red path that pins the fields into
/// the canonical hash: strip `status`/`resolves_id` from `canonical_bytes`
/// (crates/ledger/src/domain.rs) and every retry below silently REPLAYS as
/// a 200 — a pending hold answered with its own claim's ids as though the
/// caller had posted it, which is how money moves twice.
#[tokio::test]
async fn a_reused_key_differing_only_in_status_or_resolves_id_is_refused() -> TestResult {
    let book = TestBook::new("pending_key_reuse").await?;
    let (receivable, revenue) = book.fixture_accounts().await?;
    let pending = post_a_pending_hold(&book, revenue, receivable).await?;
    let captured = book
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
    assert_eq!(captured.status(), 201);

    // hold-1's exact body with `status` omitted (posted), capture-1's exact
    // body with `resolves_id` omitted, and capture-1's with a different
    // target: three same-key/different-body calls.
    let differs_in_status = book
        .post(&serde_json::json!({
            "tenant_id": "t1",
            "idempotency_key": "hold-1",
            "effective_at": "2026-08-28T00:00:00Z",
            "postings": [{
                "source": revenue, "destination": receivable,
                "amount_minor": 500, "currency": "USD"
            }],
        }))
        .await?;
    let drops_the_target = book
        .post(&serde_json::json!({
            "tenant_id": "t1",
            "idempotency_key": "capture-1",
            "effective_at": "2026-08-29T00:00:00Z",
            "postings": [{
                "source": revenue, "destination": receivable,
                "amount_minor": 500, "currency": "USD"
            }],
        }))
        .await?;
    let moves_the_target = book
        .post(&serde_json::json!({
            "tenant_id": "t1",
            "idempotency_key": "capture-1",
            "effective_at": "2026-08-29T00:00:00Z",
            "resolves_id": uuid::Uuid::from_u128(0xBAD_1DEA),
            "postings": [{
                "source": revenue, "destination": receivable,
                "amount_minor": 500, "currency": "USD"
            }],
        }))
        .await?;

    for (case, refused) in [
        ("status pending → omitted", differs_in_status),
        ("resolves_id omitted", drops_the_target),
        ("resolves_id changed", moves_the_target),
    ] {
        assert_eq!(
            refused.status(),
            422,
            "a key reused with a different {case} must be refused, not replayed"
        );
        let error: serde_json::Value = refused.json().await?;
        assert_eq!(
            error.get("type"),
            Some(&"idempotency_key_reused".into()),
            "for {case}"
        );
    }
    // Still exactly the hold and its capture; the book unmoved.
    assert_eq!(book.write_counts().await?, (2, 2, 4));
    assert_eq!(book.balance(receivable).await?, (500, 0, 2));
    book.assert_reconciled().await
}

/// Two targets t1 cannot resolve, and the point is that they are the SAME
/// refusal: one that exists nowhere at all, and one that exists on ANOTHER
/// tenant's book. The gate reads only this tenant's transactions — drop the
/// tenant from its WHERE and the second of these posts across books.
#[tokio::test]
async fn resolving_a_transaction_that_does_not_exist_is_refused() -> TestResult {
    let book = TestBook::new("resolve_ghost").await?;
    let (receivable, revenue) = book.fixture_accounts().await?;
    let (t2_receivable, t2_revenue) = book.fixture_accounts_for("t2").await?;
    let t2_hold = book
        .post(&serde_json::json!({
            "tenant_id": "t2",
            "idempotency_key": "hold-t2",
            "effective_at": "2026-08-28T00:00:00Z",
            "status": "pending",
            "postings": [{
                "source": t2_revenue, "destination": t2_receivable,
                "amount_minor": 500, "currency": "USD"
            }],
        }))
        .await?;
    assert_eq!(t2_hold.status(), 201, "seeding t2's hold");
    let t2_hold: serde_json::Value = t2_hold.json().await?;

    let nowhere = book
        .post(&serde_json::json!({
            "tenant_id": "t1",
            "idempotency_key": "capture-ghost",
            "effective_at": "2026-08-29T00:00:00Z",
            "resolves_id": Uuid::from_u128(0xDEAD_BEEF),
            "postings": [{
                "source": revenue, "destination": receivable,
                "amount_minor": 500, "currency": "USD"
            }],
        }))
        .await?;
    let on_another_book = book
        .post(&serde_json::json!({
            "tenant_id": "t1",
            "idempotency_key": "capture-cross",
            "effective_at": "2026-08-29T00:00:00Z",
            "resolves_id": t2_hold.get("transaction_id"),
            "postings": [{
                "source": revenue, "destination": receivable,
                "amount_minor": 500, "currency": "USD"
            }],
        }))
        .await?;

    for (case, refused) in [
        ("a target that exists nowhere", nowhere),
        ("a target on another tenant's book", on_another_book),
    ] {
        assert_eq!(refused.status(), 422, "resolving {case} must be refused");
        let error: serde_json::Value = refused.json().await?;
        assert_eq!(
            error.get("type"),
            Some(&"resolve_target_unknown".into()),
            "for {case}"
        );
    }
    // Only t2's hold on the book — the whole write, the event claim included,
    // rolled back for BOTH of t1's attempts.
    assert_eq!(
        book.write_counts().await?,
        (1, 1, 2),
        "a refused resolution left rows behind"
    );
    book.assert_reconciled().await
}

/// ADR-0004's counterexample, red: a posted transaction "resolved" by
/// another posted one took revenue to −49,223 with every declarative check
/// green, because the foreign key held existence and the SEMANTIC linkage
/// was assumed. The writer is the layer that holds it — remove the gate and
/// this posts.
#[tokio::test]
async fn resolving_a_posted_transaction_is_refused() -> TestResult {
    let book = TestBook::new("resolve_posted").await?;
    let (receivable, revenue) = book.fixture_accounts().await?;
    let charge = book
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
    assert_eq!(charge.status(), 201);
    let charge: serde_json::Value = charge.json().await?;

    let refused = book
        .post(&serde_json::json!({
            "tenant_id": "t1",
            "idempotency_key": "capture-of-posted",
            "effective_at": "2026-08-29T00:00:00Z",
            "resolves_id": charge.get("transaction_id"),
            "postings": [{
                "source": revenue, "destination": receivable,
                "amount_minor": 2500, "currency": "USD"
            }],
        }))
        .await?;

    assert_eq!(refused.status(), 422);
    let error: serde_json::Value = refused.json().await?;
    assert_eq!(
        error.get("type"),
        Some(&"resolve_target_not_pending".into())
    );
    // The one posted charge, untouched — and nothing from the refusal.
    assert_eq!(book.write_counts().await?, (1, 1, 2));
    assert_eq!(book.balance(receivable).await?, (2500, 0, 1));
    book.assert_reconciled().await
}

#[tokio::test]
async fn a_second_resolution_of_one_pending_is_refused() -> TestResult {
    let book = TestBook::new("resolve_twice").await?;
    let (receivable, revenue) = book.fixture_accounts().await?;
    let pending = post_a_pending_hold(&book, revenue, receivable).await?;
    let first = book
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
    assert_eq!(first.status(), 201);

    // A NEW key, the same target: pending → posted happens once.
    let second = book
        .post(&serde_json::json!({
            "tenant_id": "t1",
            "idempotency_key": "capture-2",
            "effective_at": "2026-08-29T00:00:00Z",
            "resolves_id": pending,
            "postings": [{
                "source": revenue, "destination": receivable,
                "amount_minor": 500, "currency": "USD"
            }],
        }))
        .await?;

    assert_eq!(second.status(), 422);
    let error: serde_json::Value = second.json().await?;
    assert_eq!(error.get("type"), Some(&"target_already_superseded".into()));
    // The hold and its one capture; the cache moved once.
    assert_eq!(book.write_counts().await?, (2, 2, 4));
    assert_eq!(book.balance(receivable).await?, (500, 0, 2));
    book.assert_reconciled().await
}

/// N resolutions of one pending, each under its own fresh key, in flight
/// together: exactly one lands, whatever the interleave, and every loser is
/// the SAME named 422 the sequential case gets. Honestly stated: over one
/// shared client the racers typically arrive AFTER the winner commits, so
/// what this holds is the GATE under concurrency — losers diagnosed on
/// committed state — plus the invariant that no interleave yields a second
/// resolution or a 500. The genuinely-blocked window (a loser waiting on an
/// UNCOMMITTED winner's `uq_txn__one_supersession` tuple) is not reliably
/// reached here; the deterministic uncommitted-rival test below is what
/// pins that path and the adapter's constraint-name mapping.
#[tokio::test]
async fn concurrent_resolutions_of_one_pending_produce_exactly_one() -> TestResult {
    const CALLERS: usize = 8;

    let book = TestBook::new("resolve_race").await?;
    let (receivable, revenue) = book.fixture_accounts().await?;
    let pending = post_a_pending_hold(&book, revenue, receivable).await?;

    let racers: Vec<serde_json::Value> = (0..CALLERS)
        .map(|i| {
            serde_json::json!({
                "tenant_id": "t1",
                "idempotency_key": format!("capture-race-{i}"),
                "effective_at": "2026-08-29T00:00:00Z",
                "resolves_id": pending,
                "postings": [{
                    "source": revenue, "destination": receivable,
                    "amount_minor": 500, "currency": "USD"
                }],
            })
        })
        .collect();

    let responses = book.post_all_at_once(&racers).await?;

    let created = responses
        .iter()
        .filter(|(status, _, _)| *status == 201)
        .count();
    let refused = responses
        .iter()
        .filter(|(status, _, body)| {
            *status == 422 && body.get("type") == Some(&"target_already_superseded".into())
        })
        .count();
    assert_eq!(
        (created, refused),
        (1, CALLERS - 1),
        "statuses were {:?}",
        responses
            .iter()
            .map(|(status, _, body)| (status.as_u16(), body.get("type").cloned()))
            .collect::<Vec<_>>()
    );
    // One hold, one capture — the losers' claims all rolled back.
    assert_eq!(book.write_counts().await?, (2, 2, 4));
    assert_eq!(book.balance(receivable).await?, (500, 0, 2));
    book.assert_reconciled().await
}

/// The genuinely-blocked race, staged deterministically: a rival resolution
/// of the same target is begun on a second connection and HELD uncommitted
/// while the API resolves. The gate reads committed state, so the API call
/// passes it and then blocks on the rival's uncommitted claim; when the
/// rival commits, `uq_txn__one_supersession` fires INSIDE the single call —
/// the one window the gate cannot see — and the adapter's constraint-name
/// mapping must answer the same named 422 the sequential case gets, never
/// a 500. Rename the index, or the match string in
/// `refusal_from_supersession_race`, and THIS is the test that fails.
#[tokio::test]
async fn a_resolution_racing_an_uncommitted_rival_is_refused_not_a_500() -> TestResult {
    let book = TestBook::new("resolve_rival").await?;
    let (receivable, revenue) = book.fixture_accounts().await?;
    let pending = post_a_pending_hold(&book, revenue, receivable).await?;
    // The rival: a full, balanced, correctly-cached resolution, begun and
    // NOT committed (support/book.rs — the staging every supersession race
    // shares). The book it leaves behind after the commit below is an
    // ordinarily resolved hold, so the oracle's ten zeros still bind.
    let held_open = book
        .begin_a_rival_resolution(pending, receivable, revenue)
        .await?;

    // The API resolution, fired while the rival stands uncommitted...
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
    // ...and waited for AT THE LOCK, never with a bare sleep (the shared
    // db-scoped poll in support/book.rs).
    let blocked = book.wait_until_a_backend_blocks_on_a_lock().await?;
    assert!(
        blocked,
        "the API resolution never blocked on the rival's uncommitted claim within 15s"
    );
    held_open.commit().await?;

    let (status, _replayed, body) = racer.await??;

    assert_eq!(
        status, 422,
        "the blocked loser must be refused by name, never a 500; body was {body}"
    );
    assert_eq!(body.get("type"), Some(&"target_already_superseded".into()));
    // The rival's resolution stands alone; the API attempt wrote nothing.
    assert_eq!(book.write_counts().await?, (2, 2, 4));
    assert_eq!(book.balance(receivable).await?, (500, 0, 2));
    book.assert_reconciled().await
}

/// A resolution IS the posted half of pending → posted, so a pending
/// resolution is a shape with no meaning — refused by the command's own
/// constructor (ADR-0016), before any SQL: the schema accepts the column
/// pair, which is exactly why the writer must not.
#[tokio::test]
async fn a_pending_resolution_is_refused_before_the_database() -> TestResult {
    let book = TestBook::new("pending_resolution").await?;
    let (receivable, revenue) = book.fixture_accounts().await?;
    let pending = post_a_pending_hold(&book, revenue, receivable).await?;

    let refused = book
        .post(&serde_json::json!({
            "tenant_id": "t1",
            "idempotency_key": "pending-capture",
            "effective_at": "2026-08-29T00:00:00Z",
            "status": "pending",
            "resolves_id": pending,
            "postings": [{
                "source": revenue, "destination": receivable,
                "amount_minor": 500, "currency": "USD"
            }],
        }))
        .await?;

    assert_eq!(refused.status(), 422);
    let error: serde_json::Value = refused.json().await?;
    assert_eq!(error.get("type"), Some(&"invalid_request".into()));
    let detail = error.get("detail").and_then(serde_json::Value::as_str);
    assert!(
        detail.is_some_and(|detail| detail.contains("cannot itself be pending")),
        "the refusal must name the shape; detail was {detail:?}"
    );
    // Only the hold — the refusal never reached the database.
    assert_eq!(book.write_counts().await?, (1, 1, 2));
    book.assert_reconciled().await
}
