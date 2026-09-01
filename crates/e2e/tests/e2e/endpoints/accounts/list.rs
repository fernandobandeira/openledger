//! `GET /v1/accounts` — the account register of one book, keyset-paginated.
//!
//! **The listing ADR-0019 refused.** Its ground was that one *"needs an
//! ordering and a page key this spike did not design"*, which is a *not yet*
//! rather than a *never*: `pk_accounts` is `(tenant_id, id)` and `id` is
//! `uuidv7()`, so the ordering exists and is total. ADR-0021 withdraws the
//! refusal for accounts and KEEPS it for transactions, which have two time
//! axes and no way to pick one without being confidently wrong.
//!
//! What this file holds: the page and its order, the boundary a keyset walk
//! crosses, the tenant the answer is fenced to, the two equality filters, and
//! the page size refused rather than clamped. And one absence, asserted:
//! **no balance reaches this answer** — that question is per currency and per
//! stripe, and the balance route answers it one account at a time.

use crate::support::{TestBook, TestResult, accounts_path, refusal_detail, refusal_type};

/// One opening under `t1`. Every fixture here is `customer_receivable` owned
/// by a company, or the house `fee_revenue` the suite already uses — both
/// non-perimeter, so `chart_lint`'s `perimeter_unattested` stays out of the
/// oracle.
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

/// Three receivables opened through the endpoint, in this order — so the
/// register's `uuidv7` order is the order they were asked for, and a page
/// boundary can be asserted against a known sequence.
async fn three_accounts_opened(book: &TestBook) -> TestResult {
    for (n, owner) in ["co_1", "co_2", "co_3"].iter().enumerate() {
        let created = book
            .open_account(&an_opening(&format!("open-{n}"), owner))
            .await?;
        assert_eq!(created.status(), 201, "opening the account for {owner}");
    }
    Ok(())
}

/// The `account_id`s of a page, in the order the page listed them.
fn accounts_of(page: &serde_json::Value) -> Vec<String> {
    page.get("accounts")
        .and_then(serde_json::Value::as_array)
        .map(|accounts| {
            accounts
                .iter()
                .filter_map(|account| {
                    account
                        .get("account_id")
                        .and_then(serde_json::Value::as_str)
                        .map(str::to_owned)
                })
                .collect()
        })
        .unwrap_or_default()
}

/// The key a page hands back for the next one, if it handed one back.
fn next_after_of(page: &serde_json::Value) -> Option<&str> {
    page.get("next_after").and_then(serde_json::Value::as_str)
}

#[tokio::test]
async fn the_listing_answers_the_register_in_creation_order() -> TestResult {
    let book = TestBook::new("list_accounts").await?;
    three_accounts_opened(&book).await?;

    let (status, page) = book.read(&accounts_path("t1", &[])).await?;

    assert_eq!(status.as_u16(), 200, "{page}");
    // The database's own order, read over the admin connection: the endpoint
    // must not have its own opinion about which account comes first.
    let register: Vec<String> = book
        .accounts_on_the_register("t1")
        .await?
        .into_iter()
        .map(|(id, _purpose, _owner)| id.to_string())
        .collect();
    assert_eq!(accounts_of(&page), register, "{page}");
    // A short page is the end of the register, and a key here would send the
    // caller after a page that cannot exist.
    assert_eq!(next_after_of(&page), None, "{page}");

    book.assert_reconciled().await
}

#[tokio::test]
async fn the_listing_carries_identity_and_a_stripe_count_and_no_balance() -> TestResult {
    // ADR-0021's shape ruling, both halves: the identity a caller needs to
    // find an account it already knows about, and NOT its balance — per
    // currency and per stripe, so a balance per row would be N+1 and
    // `GET /v1/accounts/{id}/balance` answers it exactly.
    let book = TestBook::new("list_accounts_shape").await?;
    let created = book.open_account(&an_opening("open-1", "co_1")).await?;
    assert_eq!(created.status(), 201, "opening the account");

    let (status, page) = book.read(&accounts_path("t1", &[])).await?;

    assert_eq!(status.as_u16(), 200, "{page}");
    let listed = page
        .get("accounts")
        .and_then(|accounts| accounts.get(0))
        .ok_or("the page listed no accounts")?;
    let fields: Vec<&str> = listed
        .as_object()
        .into_iter()
        .flatten()
        .map(|(field, _)| field.as_str())
        .collect();
    // The WHOLE field set, not a presence check per field — which is what
    // makes this the absence test too: no `posted_minor`, no `input`, no
    // `output`, no `last_seq`, and no stripe VALUE beside the count
    // (ADR-0013 §4). `serde_json`'s map is ordered, so this list is the
    // rendering's own order.
    assert_eq!(
        fields,
        [
            "account_id",
            "category",
            "counterparty_scope",
            "created_at",
            "currency",
            "normal_balance",
            "owner_id",
            "owner_type",
            "purpose",
            "stripe_count",
        ],
        "{listed}"
    );

    book.assert_reconciled().await
}

#[tokio::test]
async fn a_keyset_walk_crosses_a_page_boundary_without_repeating_or_skipping() -> TestResult {
    // The property an offset does not have: the second page starts strictly
    // above the last id of the first, so a concurrent insert can shift
    // nothing (ADR-0021). Three accounts and a page size of two, so the
    // boundary falls inside the register rather than at its end.
    let book = TestBook::new("list_accounts_paged").await?;
    three_accounts_opened(&book).await?;
    let (status, first) = book.read(&accounts_path("t1", &[("limit", "2")])).await?;
    assert_eq!(status.as_u16(), 200, "{first}");
    let after = next_after_of(&first)
        .ok_or("a full page must hand back the key of the next one")?
        .to_owned();

    let (status, second) = book
        .read(&accounts_path("t1", &[("limit", "2"), ("after", &after)]))
        .await?;

    assert_eq!(status.as_u16(), 200, "{second}");
    let walked: Vec<String> = accounts_of(&first)
        .into_iter()
        .chain(accounts_of(&second))
        .collect();
    let register: Vec<String> = book
        .accounts_on_the_register("t1")
        .await?
        .into_iter()
        .map(|(id, _purpose, _owner)| id.to_string())
        .collect();
    // Every account exactly once, in order: two pages of two and three, so
    // the second page is short and closes the walk.
    assert_eq!(walked, register, "first {first}, second {second}");
    assert_eq!(next_after_of(&second), None, "{second}");

    book.assert_reconciled().await
}

#[tokio::test]
async fn the_listing_answers_one_tenants_book_and_never_a_neighbours() -> TestResult {
    // The read path's fence, on the route that could leak a whole register
    // rather than one row: the reader's session is scoped to the tenant the
    // query names, and `rls_accounts__tenant` is what holds it (ADR-0019).
    let book = TestBook::new("list_accounts_tenant").await?;
    book.fixture_accounts_for("t1").await?;
    book.fixture_accounts_for("t2").await?;

    let (status, page) = book.read(&accounts_path("t1", &[])).await?;

    assert_eq!(status.as_u16(), 200, "{page}");
    let mine: Vec<String> = book
        .accounts_on_the_register("t1")
        .await?
        .into_iter()
        .map(|(id, _purpose, _owner)| id.to_string())
        .collect();
    assert_eq!(accounts_of(&page), mine, "{page}");
    // And nothing of t2's, named rather than inferred from the count.
    for (id, _purpose, _owner) in book.accounts_on_the_register("t2").await? {
        assert!(
            !page.to_string().contains(&id.to_string()),
            "t2's account {id} reached t1's listing: {page}"
        );
    }

    book.assert_reconciled().await
}

#[tokio::test]
async fn the_filters_are_equality_on_purpose_and_on_owner() -> TestResult {
    // Equality and nothing else (ADR-0021): what a caller needs to find an
    // account it already knows about, with no index this schema does not
    // have behind it. The house `fee_revenue` is what makes the `purpose`
    // filter selective, and it has no owner — so the `owner_id` filter must
    // not return it.
    let book = TestBook::new("list_accounts_filtered").await?;
    let (_receivable, _revenue) = book.fixture_accounts().await?;
    let created = book.open_account(&an_opening("open-1", "co_2")).await?;
    assert_eq!(created.status(), 201, "opening the second receivable");

    let (status, by_purpose) = book
        .read(&accounts_path("t1", &[("purpose", "fee_revenue")]))
        .await?;
    let (_status, by_owner) = book
        .read(&accounts_path("t1", &[("owner_id", "co_2")]))
        .await?;

    assert_eq!(status.as_u16(), 200, "{by_purpose}");
    // One house revenue account, and it is the only `fee_revenue` on the book.
    let listed_purposes: Vec<&str> = by_purpose
        .get("accounts")
        .and_then(serde_json::Value::as_array)
        .map(|accounts| {
            accounts
                .iter()
                .filter_map(|account| account.get("purpose").and_then(serde_json::Value::as_str))
                .collect()
        })
        .unwrap_or_default();
    assert_eq!(listed_purposes, ["fee_revenue"], "{by_purpose}");
    // One account for co_2 — the one just opened, and not the house account
    // that has no owner at all.
    assert_eq!(accounts_of(&by_owner).len(), 1, "{by_owner}");

    book.assert_reconciled().await
}

#[tokio::test]
async fn a_page_size_outside_the_window_is_refused_rather_than_clamped() -> TestResult {
    // A clamped page is an answer to a question the caller did not ask, and
    // nothing on the wire would say so — so zero, a negative and a value
    // above the ceiling are each a refusal naming the window.
    let book = TestBook::new("list_accounts_limit").await?;
    book.fixture_accounts().await?;

    for limit in ["0", "-1", "1001"] {
        let (status, body) = book.read(&accounts_path("t1", &[("limit", limit)])).await?;

        assert_eq!(status.as_u16(), 422, "limit {limit} answered {body}");
        assert_eq!(
            refusal_type(&body),
            Some("invalid_request"),
            "limit {limit} answered {body}"
        );
        assert!(
            refusal_detail(&body).contains("1000"),
            "the refusal must name the window; detail was {:?}",
            refusal_detail(&body)
        );
    }

    book.assert_reconciled().await
}

#[tokio::test]
async fn a_book_with_no_accounts_answers_an_empty_page_and_never_a_404() -> TestResult {
    // The same fail-closed silence every read route keeps (ADR-0019): an
    // unknown tenant, a typo'd one and a book with no accounts are one
    // answer, because nothing in this schema declares a tenant and inventing
    // the status would mean inventing the registry.
    let book = TestBook::new("list_accounts_empty").await?;
    book.fixture_accounts_for("t1").await?;

    let (status, page) = book.read(&accounts_path("nobody", &[])).await?;

    assert_eq!(status.as_u16(), 200, "{page}");
    assert!(accounts_of(&page).is_empty(), "{page}");
    assert_eq!(next_after_of(&page), None, "{page}");

    book.assert_reconciled().await
}
