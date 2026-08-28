//! The baseline's role separation, held live — suite-wide rather than any
//! endpoint's, so it lives at the top level. Two halves: the WRITER runs as
//! a policy-admitted role rather than the schema owner (so the GRANT lists
//! in `migrations/00001_baseline.sql` are proven sufficient for every
//! statement the writer sends, not just believed), and the READER's RLS
//! scoping holds — one tenant per session via `app.tenant_id`, failing
//! CLOSED when the GUC is unset (ADR-0013 §5).
//!
//! Both tests connect as cluster-wide LOGIN roles with fixed, guarded names
//! (`support::postgres` says why they are never dropped).

use sqlx::{Connection, PgConnection};

use crate::support::{TestBook, TestResult, header, postgres};

#[tokio::test]
async fn the_full_happy_path_works_when_serve_runs_as_the_app_role() -> TestResult {
    // The server connects as `e2e_app_login IN ROLE openledger_app` — the
    // policy role, not the owner — so every statement below runs under the
    // baseline's grants and the writer RLS policies. `book.pool` stays the
    // admin's on purpose: the recon views are granted to openledger_recon,
    // not to the app role, so the oracle reads through the admin connection
    // exactly as the sweep would through its own.
    let book = TestBook::new_as_app_role("app_role_serve").await?;
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
    let replayed = book.post(&charge).await?;

    // The post: the claim, the transaction, the upserts, the entries — every
    // writer statement, under the app role's grants.
    assert_eq!(created.status(), 201);
    assert_eq!(header(&created, "idempotency-replayed")?, "false");
    // The replay: statement B's lookup, same grants.
    assert_eq!(replayed.status(), 200);
    assert_eq!(header(&replayed, "idempotency-replayed")?, "true");
    // The balances the writer maintained, read through the admin pool.
    assert_eq!(book.balance(receivable).await?, (2500, 0, 1));
    assert_eq!(book.balance(revenue).await?, (0, 2500, 1));
    // The oracle, via the ADMIN connection (see above).
    book.assert_reconciled().await
}

#[tokio::test]
async fn the_read_role_sees_one_tenant_when_scoped_and_none_when_not() -> TestResult {
    // Two tenants' books on one database, written the front door's way.
    let book = TestBook::new("read_role_rls").await?;
    let (t1_receivable, t1_revenue) = book.fixture_accounts().await?;
    let (t2_receivable, t2_revenue) = book.fixture_accounts_for("t2").await?;
    for (tenant, source, destination) in [
        ("t1", t1_revenue, t1_receivable),
        ("t2", t2_revenue, t2_receivable),
    ] {
        let created = book
            .post(&serde_json::json!({
                "tenant_id": tenant,
                "idempotency_key": "charge-1",
                "effective_at": "2026-08-27T12:00:00Z",
                "postings": [{
                    "source": source, "destination": destination,
                    "amount_minor": 2500, "currency": "USD"
                }],
            }))
            .await?;
        assert_eq!(created.status(), 201, "seeding {tenant}");
    }
    // The premise the isolation claim needs: BOTH tenants' rows exist, seen
    // through the admin connection RLS does not bind.
    let admin_tenants: Vec<(String,)> =
        sqlx::query_as("SELECT DISTINCT tenant_id FROM trial_balance ORDER BY tenant_id")
            .fetch_all(&book.pool)
            .await?;
    assert_eq!(
        admin_tenants,
        [("t1".to_owned(),), ("t2".to_owned(),)],
        "the fixture must put two tenants on the book"
    );
    // The reader: a LOGIN role inheriting openledger_read's SELECT grants
    // and its RLS policies (trial_balance is security_invoker, so the
    // policies scope the view too).
    postgres::ensure_login_role(&book.pool, postgres::READ_LOGIN, "openledger_read").await?;
    let read_url =
        postgres::swap_credentials(&book.db_url, postgres::READ_LOGIN, postgres::LOGIN_PASSWORD)?;
    let mut reader = PgConnection::connect(&read_url).await?;

    // Scoped to t1: only t1's rows, and some rows — a zero here would be the
    // green-because-it-never-ran shape, not isolation.
    sqlx::raw_sql("SET app.tenant_id = 't1'")
        .execute(&mut reader)
        .await?;
    let scoped: Vec<(String,)> = sqlx::query_as("SELECT DISTINCT tenant_id FROM trial_balance")
        .fetch_all(&mut reader)
        .await?;
    assert_eq!(
        scoped,
        [("t1".to_owned(),)],
        "a t1-scoped reader saw other tenants' rows"
    );

    // GUC unset: ZERO rows. `current_setting('app.tenant_id', true)` is NULL
    // and `tenant_id = NULL` matches nothing — an unscoped session fails
    // CLOSED rather than seeing every tenant (ADR-0013 §5).
    sqlx::raw_sql("RESET app.tenant_id")
        .execute(&mut reader)
        .await?;
    let (unscoped,): (i64,) = sqlx::query_as("SELECT count(*) FROM trial_balance")
        .fetch_one(&mut reader)
        .await?;
    assert_eq!(unscoped, 0, "an unscoped reader must see NO rows, not all");

    reader.close().await?;
    book.assert_reconciled().await
}
