//! The tenant fence, held through the binary on every credential a deployment
//! can be wearing — ADR-0019's central finding, and the one thing in the read
//! path whose failure is silent, plausible and other people's money.
//!
//! **The finding, restated.** RLS policies are permissive and OR'd, and
//! `pg_has_role` — not equality — decides which apply. A login that is a member
//! of both `openledger_app` and `openledger_read` therefore matches the
//! writer's `USING (true)` as well as the reader's tenant qual, the union is
//! `true`, and `app.tenant_id` becomes decoration: it reads EVERY tenant, with
//! every policy in the schema exactly as written. The shipped binary's
//! `READ_DATABASE_URL` **falls back to `DATABASE_URL`** when it is not set, so
//! the DEFAULT configuration is that shape — and it is safe only because the
//! adapter issues `SET LOCAL ROLE openledger_read` inside every read
//! transaction, which makes `current_user` the read role and leaves the
//! writer's policy no role to attach to.
//!
//! So the fence is asserted on three credentials, not one:
//!
//! 1. **the fallback** — no `READ_DATABASE_URL` at all, reads on the writer's
//!    own URL, which here is the schema owner's and is not subject to RLS in
//!    the first place;
//! 2. **a read login of its own**, whose only membership is `openledger_read`
//!    — the deployment ADR-0019 asks for;
//! 3. **a read login that can also write**, a member of both policy roles —
//!    the deployment ADR-0019 measured reading six entries across two tenants.
//!
//! And a fourth test, which is a CONTROL rather than a claim about the binary:
//! the same dual-membership login, connected directly and scoped only by the
//! GUC, really does read both tenants. Without it the three tests above are
//! satisfied by a database on which no credential could ever have leaked, and
//! the fence they assert would be a fence around nothing.
//!
//! **What these tests hold, and what they cannot — measured by injection,
//! recorded here rather than assumed.** What they hold is the OBSERVABLE: a
//! caller reading as t1 is never handed t2's money, on any of the three
//! credentials. What they cannot isolate is WHICH mechanism keeps that true,
//! and the measurement is unambiguous:
//!
//! - **Replace the adapter's `SET LOCAL ROLE openledger_read` with a no-op**
//!   and all five tests here stay GREEN. Expected: `db`'s read pool already
//!   assumes the role in `after_connect`, and ADR-0019 calls the per-
//!   transaction statement the belt to that braces.
//! - **Remove BOTH** — the adapter's `SET LOCAL ROLE` and the pool's
//!   `SET ROLE` — and all five STILL stay green. That one is worth stating
//!   plainly: every read this endpoint layer issues carries its own
//!   `tenant_id` predicate (`trial_balance_at(p_tenant, …)`,
//!   `balance_sheet_at(p_tenant, …)`, and the `WHERE a.tenant_id = $1` in the
//!   balance, transaction and bounds statements), so RLS is the SECOND line of
//!   defence on all five routes and never the only one. No request this API
//!   accepts can distinguish a scoped session from an unscoped one.
//!
//! So the role assumption is not falsifiable over HTTP today, and a test here
//! that claimed to prove it would be claiming something it cannot see. What
//! falsifies it is the credential-level control below and `roles.rs`'s
//! scoped-then-reset pair — both of which measure the database rather than the
//! binary. This file's value is the other half: that the shipped answer is one
//! tenant's book on every credential a deployment can be wearing, which is the
//! property a caller has.

use sqlx::{Connection, PgConnection};
use uuid::Uuid;

use crate::support::{
    TestBook, TestResult, accounts_reported_by, amount_of_the_line, balance_sheet_path,
    post_a_charge_dated, postgres, row_of_the_account, trial_balance_path,
};

/// What each tenant's book holds. Different amounts, deliberately: a leak that
/// summed the two tenants would answer 102.77 and a leak that reported the
/// wrong one would answer 77.77, and neither can be mistaken for 25.00.
const T1_MINOR: i64 = 2500;
const T2_MINOR: i64 = 7777;
const CHARGE_DATE: &str = "2026-08-27T12:00:00Z";
const AS_OF: &str = "2026-09-01T00:00:00Z";
const EFFECTIVE_FROM: &str = "2026-08-01T00:00:00Z";
const EFFECTIVE_TO: &str = "2026-09-01T00:00:00Z";

/// Two tenants' books on one database, both written through the front door.
struct TwoTenants {
    t1_receivable: Uuid,
    t1_revenue: Uuid,
    t2_receivable: Uuid,
    t2_revenue: Uuid,
}

/// Seed both books, and assert the premise every test here rests on: BOTH
/// tenants really are on this database. Read through the admin pool, which RLS
/// does not bind — a one-tenant book would make every assertion below
/// vacuously green, exactly as `roles.rs` says of its own fixture.
async fn two_tenants_on_one_book(
    book: &TestBook,
) -> Result<TwoTenants, Box<dyn std::error::Error>> {
    let (t1_receivable, t1_revenue) = book.fixture_accounts_for("t1").await?;
    let (t2_receivable, t2_revenue) = book.fixture_accounts_for("t2").await?;
    post_a_charge_dated(
        book,
        "t1-charge",
        CHARGE_DATE,
        T1_MINOR,
        t1_revenue,
        t1_receivable,
    )
    .await?;
    // t2's charge cannot go through `post_a_charge_dated`, which posts as t1:
    // the tenant is the point here, so this one is spelled out.
    let created = book
        .post(&serde_json::json!({
            "tenant_id": "t2",
            "idempotency_key": "t2-charge",
            "effective_at": CHARGE_DATE,
            "postings": [{
                "source": t2_revenue, "destination": t2_receivable,
                "amount_minor": T2_MINOR, "currency": "USD"
            }],
        }))
        .await?;
    assert_eq!(created.status(), 201, "seeding t2's book");

    let tenants: Vec<(String,)> =
        sqlx::query_as("SELECT DISTINCT tenant_id FROM trial_balance ORDER BY tenant_id")
            .fetch_all(&book.pool)
            .await?;
    assert_eq!(
        tenants,
        [("t1".to_owned(),), ("t2".to_owned(),)],
        "the fixture must put two tenants on the book"
    );
    book.wait_for_the_horizon_to_retire_this_book().await?;

    Ok(TwoTenants {
        t1_receivable,
        t1_revenue,
        t2_receivable,
        t2_revenue,
    })
}

/// A trial balance read as t1 holds t1's book and nothing else — the whole
/// assertion, stated once because three tests make it against three
/// credentials and a fourth copy of it is a copy that rots.
///
/// It asserts the PROPERTY under test, so it is called from each test's assert
/// phase and never from an arrangement.
fn assert_the_answer_is_one_tenants_book(
    report: &serde_json::Value,
    tenants: &TwoTenants,
    credential: &str,
) -> TestResult {
    // Which accounts were reported at all: a leak is an account id that is not
    // this tenant's, whatever the amounts beside it say.
    assert_eq!(
        accounts_reported_by(report)?,
        [
            tenants.t1_receivable.to_string(),
            tenants.t1_revenue.to_string()
        ],
        "reading as t1 over {credential} reported accounts that are not t1's: {report}"
    );
    assert_eq!(
        row_of_the_account(report, tenants.t2_receivable)?,
        None,
        "t2's receivable appeared in t1's trial balance over {credential}"
    );
    assert_eq!(
        row_of_the_account(report, tenants.t2_revenue)?,
        None,
        "t2's revenue appeared in t1's trial balance over {credential}"
    );
    // ...and t1's own position is exact: a fence that answered nothing at all
    // would satisfy every line above and be a different bug.
    assert_eq!(
        row_of_the_account(report, tenants.t1_receivable)?,
        Some((T1_MINOR.to_string(), "0".to_owned(), T1_MINOR.to_string())),
        "t1's own position is wrong over {credential}"
    );
    Ok(())
}

/// Which login the read path actually connected under — the premise a test
/// that NAMES a credential needs, because a `READ_DATABASE_URL` the binary
/// ignored would fall back to the writer's URL and the fence assertion would
/// pass under a credential the test never exercised. Read right after the
/// report, while the pooled read connection is still open: `db`'s IDLE_TIMEOUT
/// is seconds, not milliseconds.
async fn assert_the_read_ran_under(book: &TestBook, login: &str) -> TestResult {
    let (connections,): (i64,) = sqlx::query_as(
        "SELECT count(*) FROM pg_stat_activity
          WHERE datname = current_database() AND usename = $1",
    )
    .bind(login)
    .fetch_one(&book.pool)
    .await?;
    assert!(
        connections > 0,
        "no backend on this book is connected as {login}, so READ_DATABASE_URL was not honoured          and this report was read on the writer's credential instead"
    );
    Ok(())
}

#[tokio::test]
async fn a_report_holds_one_tenants_book_when_the_read_path_falls_back_to_the_writers_url()
-> TestResult {
    // The SHIPPED DEFAULT: no READ_DATABASE_URL, so the read pool connects on
    // the writer's own credential — here the schema owner, which RLS does not
    // bind at all. What fences this read is the `SET LOCAL ROLE
    // openledger_read` in the adapter's bracket and nothing else.
    let book = TestBook::new("fence_fallback_url").await?;
    let tenants = two_tenants_on_one_book(&book).await?;

    let (status, as_t1) = book
        .read(&trial_balance_path("t1", EFFECTIVE_FROM, EFFECTIVE_TO, &[]))
        .await?;

    assert_eq!(status.as_u16(), 200, "{as_t1}");
    assert_the_answer_is_one_tenants_book(&as_t1, &tenants, "the fallback read URL")?;

    book.assert_reconciled().await
}

#[tokio::test]
async fn a_report_holds_one_tenants_book_on_a_read_login_whose_only_membership_is_the_read_role()
-> TestResult {
    // The deployment ADR-0019 asks for: READ_DATABASE_URL under a login that
    // cannot write. The fence is a property of the credential here — and the
    // `SET LOCAL ROLE` still runs, so this test also proves the two are
    // compatible rather than one undoing the other.
    let book = TestBook::new_with_a_read_login_of_its_own("fence_read_login").await?;
    let tenants = two_tenants_on_one_book(&book).await?;

    let (status, as_t1) = book
        .read(&trial_balance_path("t1", EFFECTIVE_FROM, EFFECTIVE_TO, &[]))
        .await?;

    assert_eq!(status.as_u16(), 200, "{as_t1}");
    assert_the_answer_is_one_tenants_book(&as_t1, &tenants, "a dedicated read login")?;
    assert_the_read_ran_under(&book, postgres::READ_LOGIN).await?;

    book.assert_reconciled().await
}

#[tokio::test]
async fn a_report_holds_one_tenants_book_on_a_read_login_that_can_also_write() -> TestResult {
    // The measured hazard, served: READ_DATABASE_URL under a login that is a
    // member of BOTH policy roles — what a deployment gets by pointing the new
    // variable at the credential it already had. This login reads every tenant
    // on its own (the control below measures exactly that), so a green result
    // here is the `SET LOCAL ROLE openledger_read` doing the work.
    let book =
        TestBook::new_with_a_read_login_that_can_write_too("fence_dual_membership_login").await?;
    let tenants = two_tenants_on_one_book(&book).await?;

    let (status, as_t1) = book
        .read(&trial_balance_path("t1", EFFECTIVE_FROM, EFFECTIVE_TO, &[]))
        .await?;

    assert_eq!(status.as_u16(), 200, "{as_t1}");
    assert_the_answer_is_one_tenants_book(&as_t1, &tenants, "a dual-membership read login")?;
    assert_the_read_ran_under(&book, postgres::DUAL_LOGIN).await?;

    book.assert_reconciled().await
}

#[tokio::test]
async fn a_dual_membership_login_reads_every_tenant_when_nothing_assumes_the_read_role()
-> TestResult {
    // THE CONTROL, and the only test in this file that does not go over HTTP:
    // it measures the credential rather than the binary. The same login the
    // test above serves, connected directly, scoped by `app.tenant_id` and
    // nothing else — the configuration ADR-0019 measured at six entries across
    // two tenants where the read role saw four.
    //
    // If this ever goes green-by-scoping, the three tests above stop meaning
    // anything: they would be asserting a fence on a credential that never
    // needed one.
    let book = TestBook::new("fence_dual_membership_control").await?;
    let tenants = two_tenants_on_one_book(&book).await?;
    postgres::ensure_login_role(&book.pool, postgres::DUAL_LOGIN, "openledger_app").await?;
    postgres::ensure_login_role(&book.pool, postgres::DUAL_LOGIN, "openledger_read").await?;
    let dual_url =
        postgres::swap_credentials(&book.db_url, postgres::DUAL_LOGIN, postgres::LOGIN_PASSWORD)?;
    let mut dual = PgConnection::connect(&dual_url).await?;

    // One session, scoped to t1 and then asked two questions — which tenants
    // it can see at all, and whether t2's own receivable is among the accounts
    // it can read. The pair is one claim: neither half says much without the
    // other, exactly as `roles.rs`'s scoped-then-reset pair does.
    sqlx::raw_sql("SET app.tenant_id = 't1'")
        .execute(&mut dual)
        .await?;
    let tenants_seen: Vec<(String,)> =
        sqlx::query_as("SELECT DISTINCT tenant_id FROM ledger_entries ORDER BY tenant_id")
            .fetch_all(&mut dual)
            .await?;
    let (t2_entries_seen,): (i64,) =
        sqlx::query_as("SELECT count(*) FROM ledger_entries WHERE account_id = $1")
            .bind(tenants.t2_receivable)
            .fetch_one(&mut dual)
            .await?;
    dual.close().await?;

    assert_eq!(
        tenants_seen,
        [("t1".to_owned(),), ("t2".to_owned(),)],
        "a login holding both openledger_app and openledger_read no longer reads every tenant \
         — the permissive OR'd policies ADR-0019 measured have changed, and the SET LOCAL ROLE \
         the read path relies on may now be fencing nothing"
    );
    assert!(
        t2_entries_seen > 0,
        "the control saw no entry of t2's receivable, so the leak it exists to demonstrate is \
         not being demonstrated"
    );

    book.assert_reconciled().await
}

#[tokio::test]
async fn a_balance_sheet_face_carries_one_tenants_money_and_not_the_sum_of_two() -> TestResult {
    // The other route, and a different failure mode: a trial balance names its
    // accounts, so a leak there is visible as an id. A FACE names none — it is
    // one amount per line — so a cross-tenant leak arrives as a number that is
    // simply too large, and the only thing that catches it is knowing what the
    // number should be.
    let book = TestBook::new("fence_face_one_tenant").await?;
    two_tenants_on_one_book(&book).await?;

    let (status, as_t1) = book.read(&balance_sheet_path("t1", AS_OF, &[])).await?;

    assert_eq!(status.as_u16(), 200, "{as_t1}");
    assert_eq!(
        amount_of_the_line(&as_t1, "receivables")?,
        T1_MINOR.to_string(),
        "the face carries more than t1's own receivable — {} would be both tenants",
        T1_MINOR + T2_MINOR
    );
    assert_eq!(
        amount_of_the_line(&as_t1, "current_year_earnings")?,
        T1_MINOR.to_string(),
        "the earnings plug carries more than t1's own revenue"
    );

    book.assert_reconciled().await
}
