//! `POST /v1/accounts` — the write ADR-0021 added, and the one operation in
//! this system that had no API at all until it did. Its whole contract in one
//! file: what an opening writes, what the server DERIVES rather than accepts,
//! every refusal by name, and the replay.
//!
//! **The test that carries the endpoint's argument** is
//! `an_account_opened_over_http_is_a_posting_target_immediately`: an account
//! seeded by SQL and an account opened over HTTP have to be the same account,
//! or the endpoint is a second way to make a nearly-right row. It posts
//! through the new account and then asks the oracle.
//!
//! The refusals are one test per GUARD, never one per wire name — and the two
//! halves of `account_owner_mismatched` are two guards under one name, so they
//! are held as two cases of one test rather than assumed to be symmetric.
//!
//! **Every fixture here is a NON-PERIMETER type**, for the reason
//! `support/book.rs` states about the posting fixtures: `chart_lint`'s
//! `perimeter_unattested` is an error-severity row for any perimeter account
//! that carries posted entries, the attestation feed does not exist
//! (ADR-0012), and the oracle at the end of every test counts error rows.
//! `customer_receivable` and `fee_revenue` are the pair the suite already
//! posts between.

use crate::support::{TestBook, TestResult, header, refusal_detail, refusal_type};

/// One opening, ready to be varied. `customer_receivable` is `per_shard`, so
/// it must be OWNED — which is what makes it the right fixture for the
/// house-account refusal as well as for the happy path.
fn an_opening(key: &str, owner: &str) -> serde_json::Value {
    serde_json::json!({
        "tenant_id": "t1",
        "idempotency_key": key,
        "purpose": "customer_receivable",
        "owner_type": "company",
        "owner_id": owner,
        "currency": "USD",
    })
}

/// One opening with one field replaced. A named helper rather than
/// `body["field"] = …`: `serde_json::Value`'s indexing panics on a
/// non-object, and this workspace denies `indexing_slicing` — so the
/// replacement is an insert into the map, which cannot.
fn with(
    field: &str,
    value: serde_json::Value,
    mut opening: serde_json::Value,
) -> serde_json::Value {
    if let Some(object) = opening.as_object_mut() {
        object.insert(field.to_owned(), value);
    }
    opening
}

/// The account an accepted opening answered with — the whole
/// representation, which is what the 201 carries since the `account_id` it
/// used to answer with left the DERIVED triple reachable only by a second
/// call and a client-side scan (ADR-0021's cost list).
fn account_in(body: &serde_json::Value) -> Option<&serde_json::Value> {
    body.get("account")
}

/// The account id off an accepted opening.
fn account_of(body: &serde_json::Value) -> Option<&str> {
    account_in(body)?
        .get("account_id")
        .and_then(serde_json::Value::as_str)
}

/// One field of the account an opening answered with, as text.
fn field_of(body: &serde_json::Value, field: &str) -> Option<String> {
    account_in(body)?
        .get(field)
        .and_then(serde_json::Value::as_str)
        .map(str::to_owned)
}

/// The chart triple the server derived, as the ANSWER states it — the three
/// values a caller never sent and could not previously read back.
fn derived_triple(body: &serde_json::Value) -> Option<(String, String, String)> {
    Some((
        field_of(body, "category")?,
        field_of(body, "normal_balance")?,
        field_of(body, "counterparty_scope")?,
    ))
}

/// What the published chart holds for `customer_receivable` — an asset with a
/// debit normal balance, split by counterparty.
const RECEIVABLE_TRIPLE: (&str, &str, &str) = ("asset", "debit", "per_shard");

/// How many accounts this book holds — a refused opening must not move it.
async fn accounts_on(book: &TestBook) -> Result<i64, sqlx::Error> {
    let (count,): (i64,) = sqlx::query_as("SELECT count(*) FROM ledger_accounts")
        .fetch_one(&book.pool)
        .await?;
    Ok(count)
}

#[tokio::test]
async fn an_opening_creates_the_account_and_claims_its_key() -> TestResult {
    let book = TestBook::new("open_account").await?;

    let created = book.open_account(&an_opening("open-1", "co_1")).await?;

    assert_eq!(created.status(), 201);
    assert_eq!(header(&created, "idempotency-replayed")?, "false");
    let body: serde_json::Value = created.json().await?;
    assert!(account_of(&body).is_some(), "no account_id in {body}");
    // An EVENT and no ledger transaction — the case ADR-0005 justified the
    // event log by, and the reason opening an account could reuse the
    // idempotency spine instead of inventing one.
    let (events, transactions, entries) = book.write_counts().await?;
    assert_eq!((events, transactions, entries), (1, 0, 0), "{body}");

    book.assert_reconciled().await
}

#[tokio::test]
async fn the_server_derives_the_chart_triple_the_caller_never_sends() -> TestResult {
    // The three columns `ledger_accounts` copies from the chart —
    // `fk_accounts__type` and `fk_accounts__scope` hold them honest, and a
    // body that could state them would earn a foreign-key error in place of
    // an answer (ADR-0021). The request below names a purpose and nothing
    // else about what the account MEANS.
    let book = TestBook::new("open_account_derives").await?;

    let created = book.open_account(&an_opening("open-1", "co_1")).await?;

    assert_eq!(created.status(), 201);
    let body: serde_json::Value = created.json().await?;
    let account: uuid::Uuid = account_of(&body).ok_or("no account_id")?.parse()?;
    let derived: (String, String, String) = sqlx::query_as(
        "SELECT a.category::text, a.normal_balance::text, a.counterparty_scope
           FROM ledger_accounts a WHERE a.id = $1",
    )
    .bind(account)
    .fetch_one(&book.pool)
    .await?;
    // Exactly what `account_types` holds for `customer_receivable` in the
    // published chart — read off the account, so a writer that bound the
    // wrong row fails here rather than at the next reclassification.
    let (category, normal_balance, counterparty_scope) = RECEIVABLE_TRIPLE;
    assert_eq!(
        derived,
        (
            category.to_owned(),
            normal_balance.to_owned(),
            counterparty_scope.to_owned()
        )
    );

    book.assert_reconciled().await
}

#[tokio::test]
async fn the_opening_answers_with_the_triple_it_derived_and_not_only_an_id() -> TestResult {
    // ADR-0021's cost list, closed: the derived triple is the REASON the
    // server derives it, and a 201 of two UUIDs meant seeing it took a second
    // call to `GET /v1/accounts` plus a client-side scan for the id — there is
    // no `GET /v1/accounts/{id}` and the listing filters on `purpose` and
    // `owner_id` but not on the account. "Show me the account I just opened"
    // was a paged search.
    let book = TestBook::new("open_account_answers_the_triple").await?;

    let created = book.open_account(&an_opening("open-1", "co_1")).await?;

    assert_eq!(created.status(), 201);
    let body: serde_json::Value = created.json().await?;
    let (category, normal_balance, counterparty_scope) = RECEIVABLE_TRIPLE;
    assert_eq!(
        derived_triple(&body),
        Some((
            category.to_owned(),
            normal_balance.to_owned(),
            counterparty_scope.to_owned()
        )),
        "{body}"
    );
    // And the spine is still visible beside it: opening an account writes an
    // EVENT and no ledger transaction, which is the case ADR-0005 justified
    // the event log by.
    assert!(
        body.get("event_id")
            .and_then(serde_json::Value::as_str)
            .is_some(),
        "the answer dropped its event_id: {body}"
    );

    book.assert_reconciled().await
}

#[tokio::test]
async fn a_replay_answers_the_same_account_the_first_call_did_field_for_field() -> TestResult {
    // A replay re-renders the STORED result (ADR-0013 §2), and now that the
    // result is the whole account the replay has to carry the whole account:
    // a 200 that answered less than its 201 would make the header the only
    // honest part of it.
    let book = TestBook::new("open_account_replay_answers_the_same").await?;
    let first = book.open_account(&an_opening("open-1", "co_1")).await?;
    assert_eq!(first.status(), 201, "the first opening");
    let first: serde_json::Value = first.json().await?;

    let replayed = book.open_account(&an_opening("open-1", "co_1")).await?;

    assert_eq!(replayed.status(), 200);
    assert_eq!(header(&replayed, "idempotency-replayed")?, "true");
    let replayed: serde_json::Value = replayed.json().await?;
    // The whole representation, not only the id — and the same one, read back
    // from the register rather than rebuilt from the request.
    assert_eq!(account_in(&replayed), account_in(&first), "{replayed}");
    let (category, normal_balance, counterparty_scope) = RECEIVABLE_TRIPLE;
    assert_eq!(
        derived_triple(&replayed),
        Some((
            category.to_owned(),
            normal_balance.to_owned(),
            counterparty_scope.to_owned()
        )),
        "{replayed}"
    );

    book.assert_reconciled().await
}

#[tokio::test]
async fn the_metadata_an_opening_set_is_readable_back_on_both_of_this_resources_verbs() -> TestResult
{
    // A caller could WRITE metadata and had no route that read it back, which
    // is a hole rather than a missing feature: the opening's answer and the
    // listing both carry it now, and an opening that named none reads back the
    // column's own `{}` rather than a null.
    let book = TestBook::new("open_account_metadata").await?;
    let annotated = with(
        "metadata",
        serde_json::json!({"ledger": "receivables", "region": "eu"}),
        an_opening("open-1", "co_1"),
    );

    let created = book.open_account(&annotated).await?;

    assert_eq!(created.status(), 201);
    let body: serde_json::Value = created.json().await?;
    assert_eq!(
        account_in(&body).and_then(|account| account.get("metadata")),
        Some(&serde_json::json!({"ledger": "receivables", "region": "eu"})),
        "{body}"
    );
    // And the same object off the listing, which is the only other route that
    // speaks it.
    let (status, page) = book.read(&crate::support::accounts_path("t1", &[])).await?;
    assert_eq!(status.as_u16(), 200, "{page}");
    let listed = page
        .get("accounts")
        .and_then(|accounts| accounts.get(0))
        .and_then(|account| account.get("metadata"));
    assert_eq!(
        listed,
        Some(&serde_json::json!({"ledger": "receivables", "region": "eu"})),
        "{page}"
    );

    book.assert_reconciled().await
}

#[tokio::test]
async fn an_opening_that_named_no_metadata_reads_back_the_columns_empty_object() -> TestResult {
    // `NOT NULL DEFAULT '{}'`: an absent metadata and an empty one are the
    // same row, so the answer says `{}` and never `null` — a reader never has
    // to defend against a distinction the schema does not make.
    let book = TestBook::new("open_account_no_metadata").await?;

    let created = book.open_account(&an_opening("open-1", "co_1")).await?;

    assert_eq!(created.status(), 201);
    let body: serde_json::Value = created.json().await?;
    assert_eq!(
        account_in(&body).and_then(|account| account.get("metadata")),
        Some(&serde_json::json!({})),
        "{body}"
    );

    book.assert_reconciled().await
}

#[tokio::test]
async fn an_account_opened_over_http_is_a_posting_target_immediately() -> TestResult {
    // The endpoint's whole argument: an account opened over HTTP and one
    // seeded by SQL must be the SAME account. If the derived triple, the
    // owner columns or the stripe count were nearly right, the posting below
    // would still succeed and the ten-check oracle at the end would not.
    let book = TestBook::new("open_account_then_post").await?;
    let (_receivable, revenue) = book.fixture_accounts().await?;
    let created = book.open_account(&an_opening("open-1", "co_2")).await?;
    assert_eq!(created.status(), 201, "opening the posting target");
    let body: serde_json::Value = created.json().await?;
    let opened: uuid::Uuid = account_of(&body).ok_or("no account_id")?.parse()?;

    let posted = book
        .post(&serde_json::json!({
            "tenant_id": "t1",
            "idempotency_key": "charge-1",
            "effective_at": "2026-08-27T12:00:00Z",
            "postings": [{
                "source": revenue, "destination": opened,
                "amount_minor": "2500", "currency": "USD"
            }],
        }))
        .await?;

    assert_eq!(posted.status(), 201, "{:?}", posted.text().await);
    assert_eq!(book.balance(opened).await?, (2500, 0, 1));

    book.assert_reconciled().await
}

#[tokio::test]
async fn a_replayed_opening_returns_the_stored_account_and_opens_no_second_one() -> TestResult {
    // ADR-0013 §2's replay contract, inherited whole: the same key with the
    // same body re-renders the stored result under 200 and the header, and
    // the account it names is the FIRST one — there is no second row.
    let book = TestBook::new("open_account_replay").await?;
    let first = book.open_account(&an_opening("open-1", "co_1")).await?;
    assert_eq!(first.status(), 201, "the first opening");
    let first: serde_json::Value = first.json().await?;

    let replayed = book.open_account(&an_opening("open-1", "co_1")).await?;

    assert_eq!(replayed.status(), 200);
    assert_eq!(header(&replayed, "idempotency-replayed")?, "true");
    let replayed: serde_json::Value = replayed.json().await?;
    assert_eq!(account_of(&replayed), account_of(&first), "{replayed}");
    assert_eq!(accounts_on(&book).await?, 1);

    book.assert_reconciled().await
}

#[tokio::test]
async fn a_key_reused_with_a_different_body_is_refused_and_opens_nothing() -> TestResult {
    let book = TestBook::new("open_account_key_reused").await?;
    let first = book.open_account(&an_opening("open-1", "co_1")).await?;
    assert_eq!(first.status(), 201, "the first opening");

    let refused = book.open_account(&an_opening("open-1", "co_2")).await?;

    assert_eq!(refused.status(), 422);
    let body: serde_json::Value = refused.json().await?;
    assert_eq!(
        refusal_type(&body),
        Some("idempotency_key_reused"),
        "{body}"
    );
    assert_eq!(accounts_on(&book).await?, 1);

    book.assert_reconciled().await
}

#[tokio::test]
async fn an_opening_cannot_reuse_a_key_a_posting_already_claimed() -> TestResult {
    // The spine is SHARED — one `uq_events__key` per tenant — and this is
    // what that costs and buys: a key a posting holds is not available to an
    // opening, and the caller is told so by name rather than handed someone
    // else's stored result. The two canonical byte forms carry different
    // version tags, so the hashes differ and the replay lookup finds nothing.
    let book = TestBook::new("open_account_shares_the_spine").await?;
    let (receivable, revenue) = book.fixture_accounts().await?;
    let posted = book
        .post(&crate::support::charge("shared-key", revenue, receivable))
        .await?;
    assert_eq!(posted.status(), 201, "seeding the posting");

    let refused = book.open_account(&an_opening("shared-key", "co_2")).await?;

    assert_eq!(refused.status(), 422);
    let body: serde_json::Value = refused.json().await?;
    assert_eq!(
        refusal_type(&body),
        Some("idempotency_key_reused"),
        "{body}"
    );

    book.assert_reconciled().await
}

#[tokio::test]
async fn a_purpose_the_chart_does_not_carry_is_refused_by_name() -> TestResult {
    let book = TestBook::new("open_account_unknown_type").await?;
    let opening = with(
        "purpose",
        serde_json::json!("not_a_type_any_chart_has"),
        an_opening("open-1", "co_1"),
    );

    let refused = book.open_account(&opening).await?;

    assert_eq!(refused.status(), 422);
    let body: serde_json::Value = refused.json().await?;
    assert_eq!(refusal_type(&body), Some("account_type_unknown"), "{body}");
    // The API's own sentence, naming what to change — never the foreign key's.
    assert!(
        refusal_detail(&body).contains("not_a_type_any_chart_has"),
        "the refusal must name the purpose; detail was {:?}",
        refusal_detail(&body)
    );
    assert_eq!(accounts_on(&book).await?, 0);

    book.assert_reconciled().await
}

#[tokio::test]
async fn a_second_account_for_one_owner_purpose_and_currency_is_refused_by_name() -> TestResult {
    // `uq_accounts__owned`. A fresh key, so this is not a replay: it is the
    // same account asked for twice, and the second answer is a refusal rather
    // than a duplicate row.
    let book = TestBook::new("open_account_exists").await?;
    let first = book.open_account(&an_opening("open-1", "co_1")).await?;
    assert_eq!(first.status(), 201, "the first opening");

    let refused = book.open_account(&an_opening("open-2", "co_1")).await?;

    assert_eq!(refused.status(), 422);
    let body: serde_json::Value = refused.json().await?;
    assert_eq!(refusal_type(&body), Some("account_exists"), "{body}");
    assert_eq!(accounts_on(&book).await?, 1);

    book.assert_reconciled().await
}

#[tokio::test]
async fn a_second_house_account_for_one_purpose_and_currency_is_refused_by_name() -> TestResult {
    // `uq_accounts__house` — the other index behind the same name, and a
    // different guard: house accounts are keyed per tenant, purpose and
    // currency with no owner in the key at all.
    let book = TestBook::new("open_house_account_exists").await?;
    let house = serde_json::json!({
        "tenant_id": "t1",
        "idempotency_key": "open-1",
        "purpose": "fee_revenue",
        "owner_type": "house",
        "currency": "USD",
    });
    let first = book.open_account(&house).await?;
    assert_eq!(first.status(), 201, "the first house account");
    let again = with("idempotency_key", serde_json::json!("open-2"), house);

    let refused = book.open_account(&again).await?;

    assert_eq!(refused.status(), 422);
    let body: serde_json::Value = refused.json().await?;
    assert_eq!(refusal_type(&body), Some("account_exists"), "{body}");
    assert_eq!(accounts_on(&book).await?, 1);

    book.assert_reconciled().await
}

#[tokio::test]
async fn an_owner_that_disagrees_with_its_owner_type_is_refused_by_name() -> TestResult {
    // Both halves of `ck_accounts__house_has_no_owner` under one name, and
    // they are two guards rather than one symmetry: a house account carrying
    // an owner, and an owned account carrying none. `fee_revenue` is used for
    // the house half because its scope is `none` — a `per_shard` type in a
    // house account is a DIFFERENT refusal, held next door.
    let book = TestBook::new("open_account_owner_mismatch").await?;
    let cases = [
        serde_json::json!({
            "tenant_id": "t1", "idempotency_key": "open-1",
            "purpose": "fee_revenue", "owner_type": "house",
            "owner_id": "co_1", "currency": "USD",
        }),
        serde_json::json!({
            "tenant_id": "t1", "idempotency_key": "open-2",
            "purpose": "customer_receivable", "owner_type": "company",
            "currency": "USD",
        }),
    ];

    for opening in &cases {
        let refused = book.open_account(opening).await?;

        assert_eq!(refused.status(), 422, "opening {opening}");
        let body: serde_json::Value = refused.json().await?;
        assert_eq!(
            refusal_type(&body),
            Some("account_owner_mismatched"),
            "opening {opening} answered {body}"
        );
    }
    assert_eq!(accounts_on(&book).await?, 0);

    book.assert_reconciled().await
}

#[tokio::test]
async fn a_type_split_by_counterparty_is_refused_a_house_account_by_name() -> TestResult {
    // `ck_accounts__per_shard_is_owned`: `uq_accounts__house` is one row per
    // purpose and currency, so a house `customer_receivable` would net every
    // counterparty's position at write time and no report could recover it
    // (ADR-0012). It is the one refusal that needs the CHART to be judged,
    // which is why it cannot be refused at the door.
    let book = TestBook::new("open_account_per_shard_house").await?;

    let refused = book
        .open_account(&serde_json::json!({
            "tenant_id": "t1",
            "idempotency_key": "open-1",
            "purpose": "customer_receivable",
            "owner_type": "house",
            "currency": "USD",
        }))
        .await?;

    assert_eq!(refused.status(), 422);
    let body: serde_json::Value = refused.json().await?;
    assert_eq!(
        refusal_type(&body),
        Some("account_type_requires_an_owner"),
        "{body}"
    );
    assert_eq!(accounts_on(&book).await?, 0);

    book.assert_reconciled().await
}

#[tokio::test]
async fn a_body_outside_what_the_columns_hold_is_refused_as_an_invalid_request() -> TestResult {
    // The three the schema states as CHECKs on the account row —
    // `ck_accounts__stripe_count`, `ck_accounts__currency_iso` and
    // `ck_accounts__tenant_non_empty` — refused at the door instead, where
    // the answer names the field rather than the constraint. Metadata rides
    // with them: `jsonb` would store a bare number as happily as an object,
    // and an array or a string as happily as either. All three are refused,
    // which is what lets the spec declare the field an `object` rather than
    // leave it untyped — a client generated from an untyped `metadata` can
    // only `JSON.stringify` the one field this API exists to let it put its
    // own structure in.
    let book = TestBook::new("open_account_invalid").await?;
    let cases = [
        ("stripe_count", serde_json::json!(1025)),
        ("currency", serde_json::json!("usd")),
        ("tenant_id", serde_json::json!("   ")),
        ("metadata", serde_json::json!(3)),
        ("metadata", serde_json::json!([{"region": "eu"}])),
        ("metadata", serde_json::json!("region=eu")),
    ];

    for (n, (field, value)) in cases.iter().enumerate() {
        let opening = with(
            field,
            value.clone(),
            an_opening(&format!("open-{n}"), "co_1"),
        );

        let refused = book.open_account(&opening).await?;

        assert_eq!(refused.status(), 422, "opening {opening}");
        let body: serde_json::Value = refused.json().await?;
        assert_eq!(
            refusal_type(&body),
            Some("invalid_request"),
            "opening {opening} answered {body}"
        );
    }
    assert_eq!(accounts_on(&book).await?, 0);

    book.assert_reconciled().await
}

#[tokio::test]
async fn a_stripe_count_the_caller_asked_for_is_the_one_the_account_carries() -> TestResult {
    // The one operational number this API speaks (ADR-0013 §4): no stripe
    // VALUE ever reaches a response, but the COUNT is a hint the caller
    // chooses and the register keeps.
    let book = TestBook::new("open_account_striped").await?;
    let opening = with(
        "stripe_count",
        serde_json::json!(64),
        an_opening("open-1", "co_1"),
    );

    let created = book.open_account(&opening).await?;

    assert_eq!(created.status(), 201);
    let body: serde_json::Value = created.json().await?;
    let account: uuid::Uuid = account_of(&body).ok_or("no account_id")?.parse()?;
    let (stripe_count,): (i16,) =
        sqlx::query_as("SELECT stripe_count FROM ledger_accounts WHERE id = $1")
            .bind(account)
            .fetch_one(&book.pool)
            .await?;
    assert_eq!(stripe_count, 64);

    book.assert_reconciled().await
}
