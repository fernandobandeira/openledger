//! POST /v1/transactions, its whole contract in one file: what a posting
//! writes — and, for a refused one, what it must not — and what a replayed
//! idempotency key returns and a reused one refuses. Idempotency sits here
//! rather than in a file of its own because it is this endpoint's contract
//! (ADR-0013), not a concern beside it.

use uuid::Uuid;

use crate::support::{TestBook, TestResult, header};

#[tokio::test]
async fn a_single_posting_lands_on_both_accounts() -> TestResult {
    let book = TestBook::new("single_posting").await?;
    let (receivable, revenue) = book.fixture_accounts().await?;

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

    assert_eq!(created.status(), 201);
    assert_eq!(header(&created, "idempotency-replayed")?, "false");
    let body: serde_json::Value = created.json().await?;
    assert!(
        body.get("event_id")
            .is_some_and(serde_json::Value::is_string),
        "no event_id in {body}"
    );
    assert!(
        body.get("transaction_id")
            .is_some_and(serde_json::Value::is_string),
        "no transaction_id in {body}"
    );

    // One leg per account: `input` on the debit side, `output` on the credit.
    assert_eq!(book.balance(receivable).await?, (2500, 0, 1));
    assert_eq!(book.balance(revenue).await?, (0, 2500, 1));

    book.assert_reconciled().await
}

#[tokio::test]
async fn two_postings_over_one_pair_coalesce_into_one_balance_row() -> TestResult {
    let book = TestBook::new("coalesce").await?;
    let (receivable, revenue) = book.fixture_accounts().await?;

    // Two postings over the same pair in one call: the legs coalesce into one
    // balance upsert per account, and the seqs stay gapless.
    let created = book
        .post(&serde_json::json!({
            "tenant_id": "t1",
            "idempotency_key": "charge-1",
            "effective_at": "2026-08-27T12:00:00Z",
            "postings": [
                { "source": revenue, "destination": receivable, "amount_minor": 1000, "currency": "USD" },
                { "source": revenue, "destination": receivable, "amount_minor": 500,  "currency": "USD" },
            ],
        }))
        .await?;

    assert_eq!(created.status(), 201);
    for (account, input, output) in [(receivable, 1500_i64, 0_i64), (revenue, 0, 1500)] {
        let (rows,): (i64,) = sqlx::query_as(
            "SELECT count(*) FROM ledger_account_balances
             WHERE tenant_id = 't1' AND account_id = $1",
        )
        .bind(account)
        .fetch_one(&book.pool)
        .await?;
        assert_eq!(
            rows, 1,
            "coalescing must leave ONE balance row for {account}"
        );
        assert_eq!(
            book.balance(account).await?,
            (input, output, 2),
            "balance row of {account}"
        );
        let (seqs,): (Vec<i64>,) = sqlx::query_as(
            "SELECT array_agg(account_seq ORDER BY account_seq) FROM ledger_entries
             WHERE tenant_id = 't1' AND account_id = $1",
        )
        .bind(account)
        .fetch_one(&book.pool)
        .await?;
        assert_eq!(seqs, vec![1, 2], "account_seq of {account} has a gap");
    }

    book.assert_reconciled().await
}

#[tokio::test]
async fn an_unknown_account_is_refused_and_nothing_is_written() -> TestResult {
    let book = TestBook::new("unknown_account").await?;
    let (receivable, revenue) = book.fixture_accounts().await?;

    // An account that does not exist: 422, and the whole write — the event row
    // included — rolled back.
    let refused = book
        .post(&serde_json::json!({
            "tenant_id": "t1",
            "idempotency_key": "charge-ghost",
            "effective_at": "2026-08-27T12:00:00Z",
            "postings": [{
                "source": Uuid::from_u128(0xDEAD_BEEF_DEAD_BEEF_DEAD_BEEF_DEAD_BEEF),
                "destination": receivable,
                "amount_minor": 100, "currency": "USD"
            }],
        }))
        .await?;

    assert_eq!(refused.status(), 422);
    let error: serde_json::Value = refused.json().await?;
    assert_eq!(error.get("type"), Some(&"unknown_account".into()));

    // A currency the account does not hold, on accounts that DO exist: the
    // same refusal, because the balance upsert's WHERE matches on (account,
    // currency) together — existence and currency are one check in the SQL.
    // This case lives here and not in the service's unit tests on purpose:
    // the unit fake answers "accounts exist" as a boolean and cannot hold a
    // WHERE clause's behavior; the real statement can.
    let mismatched = book
        .post(&serde_json::json!({
            "tenant_id": "t1",
            "idempotency_key": "charge-eur",
            "effective_at": "2026-08-27T12:00:00Z",
            "postings": [{
                "source": revenue, "destination": receivable,
                "amount_minor": 100, "currency": "EUR"
            }],
        }))
        .await?;

    assert_eq!(mismatched.status(), 422);
    let error: serde_json::Value = mismatched.json().await?;
    assert_eq!(error.get("type"), Some(&"unknown_account".into()));
    let detail = error.get("detail").and_then(serde_json::Value::as_str);
    assert!(
        detail.is_some_and(|detail| detail.contains("EUR")),
        "the refusal must name the currency the account does not hold; detail was {detail:?}"
    );

    assert_eq!(
        book.write_counts().await?,
        (0, 0, 0),
        "a refused write left rows behind"
    );
    book.assert_reconciled().await
}

#[tokio::test]
async fn an_invalid_request_never_reaches_the_database() -> TestResult {
    let book = TestBook::new("invalid_request").await?;
    let (receivable, revenue) = book.fixture_accounts().await?;

    // Each body breaks one precondition the writer refuses before touching the
    // database: a self-posting, a zero amount, a currency that is not three
    // uppercase ASCII letters (the same rule as ck_entries__currency_iso).
    let invalid = [
        serde_json::json!({
            "tenant_id": "t1",
            "idempotency_key": "self-posting",
            "effective_at": "2026-08-27T12:00:00Z",
            "postings": [{
                "source": receivable, "destination": receivable,
                "amount_minor": 100, "currency": "USD"
            }],
        }),
        serde_json::json!({
            "tenant_id": "t1",
            "idempotency_key": "zero-amount",
            "effective_at": "2026-08-27T12:00:00Z",
            "postings": [{
                "source": revenue, "destination": receivable,
                "amount_minor": 0, "currency": "USD"
            }],
        }),
        serde_json::json!({
            "tenant_id": "t1",
            "idempotency_key": "lowercase-currency",
            "effective_at": "2026-08-27T12:00:00Z",
            "postings": [{
                "source": revenue, "destination": receivable,
                "amount_minor": 100, "currency": "usd"
            }],
        }),
    ];
    for body in &invalid {
        let refused = book.post(body).await?;

        assert_eq!(refused.status(), 422, "for {body}");
        let error: serde_json::Value = refused.json().await?;
        assert_eq!(
            error.get("type"),
            Some(&"invalid_request".into()),
            "for {body}"
        );
    }

    assert_eq!(
        book.write_counts().await?,
        (0, 0, 0),
        "an invalid request reached the database"
    );
    book.assert_reconciled().await
}

#[tokio::test]
async fn a_replay_returns_the_stored_result() -> TestResult {
    let book = TestBook::new("replay").await?;
    let (receivable, revenue) = book.fixture_accounts().await?;

    let charge = serde_json::json!({
        "tenant_id": "t1",
        "idempotency_key": "charge-1",
        "effective_at": "2026-08-27T12:00:00Z",
        "postings": [{
            "source": revenue, "destination": receivable,
            "amount_minor": 2500, "currency": "USD"
        }],
    });

    let created = book.post(&charge).await?;
    assert_eq!(created.status(), 201);
    assert_eq!(header(&created, "idempotency-replayed")?, "false");
    let first: serde_json::Value = created.json().await?;

    // Same key, same body: the stored result, marked as a replay.
    let replayed = book.post(&charge).await?;
    assert_eq!(replayed.status(), 200);
    assert_eq!(header(&replayed, "idempotency-replayed")?, "true");
    let second: serde_json::Value = replayed.json().await?;
    assert_eq!(first, second, "a replay must return the stored result");

    // The same instant rendered in a different offset. The writer hashes a
    // canonical byte form it owns (ADR-0013), normalized to UTC before
    // formatting, so this body is the SAME request — a 201 here would mean the
    // hash covers a language-level rendering, not the instant.
    let shifted = serde_json::json!({
        "tenant_id": "t1",
        "idempotency_key": "charge-1",
        "effective_at": "2026-08-27T14:00:00+02:00",
        "postings": [{
            "source": revenue, "destination": receivable,
            "amount_minor": 2500, "currency": "USD"
        }],
    });
    let canonicalized = book.post(&shifted).await?;
    assert_eq!(canonicalized.status(), 200);
    assert_eq!(header(&canonicalized, "idempotency-replayed")?, "true");
    let third: serde_json::Value = canonicalized.json().await?;
    assert_eq!(
        first, third,
        "a re-rendered timestamp must replay, not repost"
    );

    // Three requests, one write: one event, one transaction, the one
    // posting's two legs — the full triple, so a replay that slipped extra
    // ENTRIES past unchanged event and transaction counts would fail too.
    assert_eq!(
        book.write_counts().await?,
        (1, 1, 2),
        "a replay wrote new rows"
    );

    book.assert_reconciled().await
}

#[tokio::test]
async fn a_reused_key_with_a_different_body_is_refused() -> TestResult {
    let book = TestBook::new("poisoned_replay").await?;
    let (receivable, revenue) = book.fixture_accounts().await?;

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
    assert_eq!(created.status(), 201);

    // Same key, different amount: 422, a named error, and nothing written.
    let refused = book
        .post(&serde_json::json!({
            "tenant_id": "t1",
            "idempotency_key": "charge-1",
            "effective_at": "2026-08-27T12:00:00Z",
            "postings": [{
                "source": revenue, "destination": receivable,
                "amount_minor": 9999, "currency": "USD"
            }],
        }))
        .await?;
    assert_eq!(refused.status(), 422);
    // The header appears only on the two ACCEPTED responses (the spec
    // documents it on 201 and 200, nowhere else) — a refusal carries no
    // replay claim at all, not a false one.
    assert!(
        refused.headers().get("idempotency-replayed").is_none(),
        "a refusal must not carry the Idempotency-Replayed header"
    );
    let error: serde_json::Value = refused.json().await?;
    assert_eq!(error.get("type"), Some(&"idempotency_key_reused".into()));

    // Still the one write — the full (events, transactions, entries) triple,
    // and the book unmoved.
    assert_eq!(
        book.write_counts().await?,
        (1, 1, 2),
        "a refused reuse left rows behind"
    );
    assert_eq!(book.balance(receivable).await?, (2500, 0, 1));
    assert_eq!(book.balance(revenue).await?, (0, 2500, 1));

    book.assert_reconciled().await
}

#[tokio::test]
async fn concurrent_identical_posts_produce_one_write_and_replays_never_conflicts() -> TestResult {
    // ADR-0013 §2's race semantics, pinned: N callers race one fresh key,
    // statement A blocks the losers on the winner's in-flight claim, and
    // statement B — a SEPARATE statement, so its snapshot is taken after the
    // winner commits — finds the durable result. The one-statement CTE
    // refactor the ADR forbids returns ZERO rows under exactly this race
    // (the CTE's snapshot predates the winner's commit), which this test
    // would report as a 422 or a 500 among the responses below. No 409
    // exists on this surface, invented or otherwise (ADR-0014).
    const CALLERS: usize = 12;

    let book = TestBook::new("concurrent_duplicate").await?;
    let (receivable, revenue) = book.fixture_accounts().await?;
    let charge = serde_json::json!({
        "tenant_id": "t1",
        "idempotency_key": "charge-race",
        "effective_at": "2026-08-27T12:00:00Z",
        "postings": [{
            "source": revenue, "destination": receivable,
            "amount_minor": 2500, "currency": "USD"
        }],
    });

    // All CALLERS posts in flight together, over one shared client.
    let handles: Vec<_> = (0..CALLERS).map(|_| book.spawn_post(&charge)).collect();
    let mut responses = Vec::new();
    for handle in handles {
        responses.push(handle.await??);
    }

    // Exactly one 201 (the claim), everything else a 200 replay — and zero
    // 409s, zero 500s, zero anything else.
    let created = responses
        .iter()
        .filter(|(status, _, _)| *status == 201)
        .count();
    let replayed = responses
        .iter()
        .filter(|(status, _, _)| *status == 200)
        .count();
    assert_eq!(
        (created, replayed),
        (1, CALLERS - 1),
        "statuses were {:?}",
        responses
            .iter()
            .map(|(status, _, _)| status.as_u16())
            .collect::<Vec<_>>()
    );
    for (status, header, _) in &responses {
        let expected = if *status == 201 { "false" } else { "true" };
        assert_eq!(
            header.as_deref(),
            Some(expected),
            "Idempotency-Replayed on the {status}"
        );
    }
    // Identical bodies: every caller gets the SAME stored result re-rendered,
    // never a second write's ids.
    let mut bodies = responses.iter().map(|(_, _, body)| body);
    let first = bodies.next().ok_or("no responses")?;
    assert!(
        bodies.all(|body| body == first),
        "concurrent duplicates disagreed about the stored result"
    );
    // One write on the book: one event row, one transaction, two legs.
    assert_eq!(
        book.write_counts().await?,
        (1, 1, 2),
        "a concurrent duplicate wrote more than once"
    );

    book.assert_reconciled().await
}

#[tokio::test]
async fn a_storage_failure_is_a_500_that_commits_nothing_and_names_no_internals() -> TestResult {
    let book = TestBook::new("storage_failure").await?;
    let (receivable, revenue) = book.fixture_accounts().await?;
    // Break the schema out from under the RUNNING server: rename the events
    // table over an admin connection. A rename is neither a drop nor a
    // rewrite, so the journal's event triggers rightly allow it — and the
    // server's next claim statement fails as a real storage error would.
    sqlx::raw_sql("ALTER TABLE ledger_events RENAME TO ledger_events_hidden")
        .execute(&book.pool)
        .await?;

    let failed = book
        .post(&serde_json::json!({
            "tenant_id": "t1",
            "idempotency_key": "charge-500",
            "effective_at": "2026-08-27T12:00:00Z",
            "postings": [{
                "source": revenue, "destination": receivable,
                "amount_minor": 100, "currency": "USD"
            }],
        }))
        .await?;

    assert_eq!(failed.status(), 500);
    // The header appears only on the two accepted responses (per the spec);
    // a failure carries no replay claim.
    assert!(
        failed.headers().get("idempotency-replayed").is_none(),
        "a 500 must not carry the Idempotency-Replayed header"
    );
    let error: serde_json::Value = failed.json().await?;
    assert_eq!(error.get("type"), Some(&"internal".into()));
    // The exact documented sentence — the caller gets no internals; the
    // operator's log has the error (the spec's 500 description).
    assert_eq!(
        error.get("detail"),
        Some(&"the write failed; nothing was committed".into())
    );
    // Belt and braces on the no-internals-leak promise: nothing of the
    // backend's error may reach the wire, byte for byte.
    let detail = error
        .get("detail")
        .and_then(serde_json::Value::as_str)
        .unwrap_or_default()
        .to_lowercase();
    for fragment in [
        "sql",
        "postgres",
        "relation",
        "ledger_events",
        "127.0.0.1",
        "localhost",
    ] {
        assert!(
            !detail.contains(fragment),
            "the 500 detail leaks an internal fragment: {fragment:?}"
        );
    }

    // Nothing was committed — and the oracle runs on the healed schema.
    sqlx::raw_sql("ALTER TABLE ledger_events_hidden RENAME TO ledger_events")
        .execute(&book.pool)
        .await?;
    assert_eq!(
        book.write_counts().await?,
        (0, 0, 0),
        "a failed write left rows behind"
    );
    book.assert_reconciled().await
}

#[tokio::test]
async fn a_tenant_reusing_another_tenants_key_gets_its_own_fresh_write() -> TestResult {
    // The idempotency key is unique PER TENANT, and this one test holds
    // three separate one-line-deletion guards at once: drop tenant_id from
    // the claim's conflict target and t2's insert conflicts with t1's row
    // (no 201 here); drop it from statement B's WHERE and t2 replays t1's
    // stored result (a cross-tenant read); drop it from the canonical hash
    // bytes and two tenants' identical bodies collide as "the same request".
    let book = TestBook::new("cross_tenant_key").await?;
    let (t1_receivable, t1_revenue) = book.fixture_accounts().await?;
    let (t2_receivable, t2_revenue) = book.fixture_accounts_for("t2").await?;

    let t1_created = book
        .post(&serde_json::json!({
            "tenant_id": "t1",
            "idempotency_key": "charge-shared",
            "effective_at": "2026-08-27T12:00:00Z",
            "postings": [{
                "source": t1_revenue, "destination": t1_receivable,
                "amount_minor": 2500, "currency": "USD"
            }],
        }))
        .await?;
    assert_eq!(t1_created.status(), 201);
    let first: serde_json::Value = t1_created.json().await?;

    // t2, the SAME key, its own accounts: a fresh claim, never a replay.
    let t2_created = book
        .post(&serde_json::json!({
            "tenant_id": "t2",
            "idempotency_key": "charge-shared",
            "effective_at": "2026-08-27T12:00:00Z",
            "postings": [{
                "source": t2_revenue, "destination": t2_receivable,
                "amount_minor": 2500, "currency": "USD"
            }],
        }))
        .await?;

    assert_eq!(t2_created.status(), 201);
    assert_eq!(header(&t2_created, "idempotency-replayed")?, "false");
    let second: serde_json::Value = t2_created.json().await?;
    assert_ne!(
        first.get("event_id"),
        second.get("event_id"),
        "t2 was handed t1's stored event"
    );
    // Two writes on the book: two events, two transactions, four legs.
    assert_eq!(
        book.write_counts().await?,
        (2, 2, 4),
        "cross-tenant key reuse did not produce two independent writes"
    );

    book.assert_reconciled().await
}
