//! The `openledger reconcile` subcommand, held against the compiled binary —
//! suite-wide rather than any endpoint's, so it lives at the top level.
//! ADR-0010 decided the shape: the ten checks in one `REPEATABLE READ READ
//! ONLY` transaction as `openledger_recon`, turned into an exit code.
//!
//! EVERY ONE of the summary's ten checks has a red-path test in this file —
//! a book where that check breaks and the command must say so on stderr —
//! because a check that cannot fail this suite through the command is a
//! safety net nobody has ever load-tested. Five come from spike 013's DRIFT
//! files (M0's promise that "the same assertions come back as Rust tests");
//! the four that joined the family after the spike (ADR-0010's merged-
//! baseline note) get injections of their own here; the tenth,
//! `journal_to_reports`, breaks through its out-of-window bucket. Where a
//! spike file has sibling cases, one representative is ported — the
//! siblings share the same summary check and the same exit path, and each
//! skip is justified at the test it belongs to.
//!
//! THE ORDER OF THIS FILE, so a reader can predict placement: the two
//! controls that must sweep clean (the empty-book trap and the pending
//! population) → the drift injections, spike DRIFT order first (1–5), then
//! the post-spike checks in this order: journal-to-reports, equation,
//! close typing, checkpoint, cursor, chart lint → the
//! combined two-drift sweep → the command's contract edges (exit 2, the
//! membership refusal, the ten-rows guard, the read-only probe) → the
//! sweep racing live writers.

use sqlx::AssertSqlSafe;
use sqlx::postgres::PgPoolOptions;

use crate::support::{TestBook, TestResult, postgres};

/// Every check the summary names, for asserting what a drift report must
/// NOT contain. A free-floating copy of the view's names would rot silently
/// — book.rs pins only the COUNT of the summary, never the names — so the
/// clean test below holds this list name-for-name against the live view;
/// a renamed check fails there, loudly, instead of making the race test's
/// exclusion asserts vacuous.
const ALL_CHECKS: [&str; 10] = [
    "accounting_equation",
    "balance_cache",
    "chart_lint",
    "checkpoint_drift",
    "close_typing",
    "cross_scope_mirror",
    "cursor_forgery",
    "journal_to_reports",
    "orphan_entries",
    "unbalanced_transactions",
];

/// One posted transaction, so the clean book is NOT the empty book — spike
/// 013's negative control prints the trial balance for the same reason:
/// zero breaks over zero rows is silence, not assent.
async fn post_one_charge(
    book: &TestBook,
) -> Result<(uuid::Uuid, uuid::Uuid), Box<dyn std::error::Error>> {
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
    assert_eq!(created.status(), 201, "seeding the book");
    Ok((receivable, revenue))
}

/// The compiled binary's sweep against one database: (exit code, stdout,
/// stderr). Every test here reads the same three things.
fn sweep(db_url: &str) -> Result<(Option<i32>, String, String), Box<dyn std::error::Error>> {
    let output = postgres::openledger()?
        .arg("reconcile")
        .env("DATABASE_URL", db_url)
        .output()?;
    Ok((
        output.status.code(),
        String::from_utf8_lossy(&output.stdout).into_owned(),
        String::from_utf8_lossy(&output.stderr).into_owned(),
    ))
}

/// Spike 013 DRIFT 1's forgery, through the door the perimeter deliberately
/// leaves open: the cache is derived state and MEANT to be rewritten, so a
/// plain UPDATE moves the served number while the journal — the truth —
/// stands. The admin pool stands in for the granted `openledger_app` UPDATE
/// the spike used; the forgery is the same either way.
async fn forge_the_balance_cache(book: &TestBook) -> TestResult {
    sqlx::raw_sql("UPDATE ledger_account_balances SET output = output + 100000")
        .execute(&book.pool)
        .await?;
    Ok(())
}

/// Spike 013 DRIFT 4c's state: a posted transaction with no entries at all —
/// exactly what ADR-0004's `TRUNCATE` left behind, where "silence read as
/// assent". replica mode to skip the event FK: the forged row deliberately
/// names an event nothing wrote, because the state under test is the
/// transaction standing alone.
async fn insert_an_entryless_transaction(book: &TestBook) -> TestResult {
    sqlx::raw_sql(
        "SET session_replication_role = 'replica';
         INSERT INTO ledger_transactions (tenant_id, event_id, kind, status, effective_at)
         VALUES ('t1', '0e2e0000-0000-7000-8000-00000000feed', 'fee', 'posted',
                 '2026-08-28T00:00:00Z');
         SET session_replication_role = 'origin'",
    )
    .execute(&book.pool)
    .await?;
    Ok(())
}

/// One close of period 2026-08, correct in everything but the cursor
/// expression the caller passes — `'1'` for the close_typing forgery,
/// `pg_current_xact_id()` for the honest cursor the checkpoint test needs.
/// Shared because the two tests differ in EXACTLY that one value, and the
/// forgery must not drift away from the honest shape it forges.
async fn close_the_august_period(
    book: &TestBook,
    receivable: uuid::Uuid,
    revenue: uuid::Uuid,
    computed_at_xid: &str,
) -> TestResult {
    sqlx::raw_sql(AssertSqlSafe(format!(
        "INSERT INTO ledger_periods (tenant_id, code, starts_at, ends_at, tz)
         VALUES ('t1', '2026-08', '2026-08-01T00:00:00Z', '2026-09-01T00:00:00Z', 'UTC');
         INSERT INTO ledger_events (tenant_id, id, kind, source, idempotency_key,
                                    idempotency_hash, payload, effective_at)
         VALUES ('t1', '0e2e0000-0000-7000-8000-000000000040', 'period_close', 'internal',
                 'close-2026-08', decode('00', 'hex'), '{{}}'::jsonb, '2026-08-31T00:00:00Z');
         INSERT INTO ledger_transactions (tenant_id, id, event_id, kind, status, effective_at)
         VALUES ('t1', '0e2e0000-0000-7000-8000-000000000041',
                 '0e2e0000-0000-7000-8000-000000000040', 'period_close', 'posted',
                 '2026-08-31T00:00:00Z');
         INSERT INTO ledger_entries (tenant_id, transaction_id, account_id, direction,
                                     amount_minor, currency, account_seq, effective_at)
         VALUES ('t1', '0e2e0000-0000-7000-8000-000000000041', '{receivable}',
                 'debit', 100, 'USD', 2, '2026-08-31T00:00:00Z'),
                ('t1', '0e2e0000-0000-7000-8000-000000000041', '{revenue}',
                 'credit', 100, 'USD', 2, '2026-08-31T00:00:00Z');
         UPDATE ledger_account_balances SET input = input + 100, last_seq = 2
         WHERE tenant_id = 't1' AND account_id = '{receivable}';
         UPDATE ledger_account_balances SET output = output + 100, last_seq = 2
         WHERE tenant_id = 't1' AND account_id = '{revenue}';
         INSERT INTO ledger_period_closes (tenant_id, period_code, currency, starts_at,
                                           ends_at, transaction_id, txn_effective_at,
                                           computed_at_xid)
         VALUES ('t1', '2026-08', 'USD', '2026-08-01T00:00:00Z', '2026-09-01T00:00:00Z',
                 '0e2e0000-0000-7000-8000-000000000041', '2026-08-31T00:00:00Z',
                 {computed_at_xid})"
    )))
    .execute(&book.pool)
    .await?;
    Ok(())
}

// ---------------------------------------------------------------- controls

#[tokio::test]
async fn a_clean_book_reconciles_to_exit_0() -> TestResult {
    let book = TestBook::new("reconcile_clean").await?;
    post_one_charge(&book).await?;
    // The oracle first, for its bounded horizon wait (ADR-0010's
    // cluster-horizon note): once the horizon has retired this book's
    // newest entry it stays retired, so the sweep spawned below cannot trip
    // over a sibling test's transaction.
    book.assert_reconciled().await?;

    // ...and while the book is clean, pin ALL_CHECKS to the live view: this
    // is what keeps the exclusion asserts in the race test — and every
    // "named on stderr" assert in this file — honest against a rename.
    let live: Vec<(String,)> =
        sqlx::query_as("SELECT check_name FROM reconciliation ORDER BY check_name")
            .fetch_all(&book.pool)
            .await?;
    assert_eq!(
        live.iter().map(|(name,)| name.as_str()).collect::<Vec<_>>(),
        ALL_CHECKS,
        "ALL_CHECKS no longer matches the summary view's names"
    );

    let (code, stdout, stderr) = sweep(&book.db_url)?;
    assert_eq!(
        code,
        Some(0),
        "a clean book must reconcile to exit 0 (stderr: {stderr})"
    );
    // The summary line is the operator's evidence that all ten ran — not
    // merely that nothing was printed.
    assert!(
        stdout.contains("10 checks") && stdout.contains("0 breaks"),
        "the clean sweep must say all ten checks ran clean; stdout was: {stdout}"
    );
    Ok(())
}

/// Spike 013 DRIFT 6, the one that is NOT a drift: a pending transaction is
/// a named reconciling population, never a break. Injected the way the
/// schema means it (ADR-0010's ruling): entries carry the next account_seq
/// and advance `last_seq` — the counter numbers pending entries too — while
/// `input`/`output` stay put, because the cache means POSTED. The book must
/// sweep clean AND the bridge must derive available = posted + pending.
#[tokio::test]
async fn a_pending_transaction_is_a_named_population_not_a_break() -> TestResult {
    let book = TestBook::new("reconcile_pending").await?;
    let (receivable, revenue) = post_one_charge(&book).await?;

    // A real event and a real pending transaction, every FK enforced — this
    // injection is legitimate bookkeeping, not a perimeter bypass, which is
    // the point: the API has no pending endpoint yet (service.md), so the
    // admin connection stands in for the writer the roadmap still owes.
    sqlx::raw_sql(AssertSqlSafe(format!(
        "INSERT INTO ledger_events (tenant_id, id, kind, source, idempotency_key,
                                    idempotency_hash, payload, effective_at)
         VALUES ('t1', '0e2e0000-0000-7000-8000-000000000001', 'hold', 'internal',
                 'pending-hold-1', decode('00', 'hex'), '{{}}'::jsonb, '2026-08-28T00:00:00Z');
         INSERT INTO ledger_transactions (tenant_id, id, event_id, kind, status, effective_at)
         VALUES ('t1', '0e2e0000-0000-7000-8000-000000000002',
                 '0e2e0000-0000-7000-8000-000000000001', 'hold', 'pending', '2026-08-28T00:00:00Z');
         INSERT INTO ledger_entries (tenant_id, transaction_id, account_id, direction,
                                     amount_minor, currency, account_seq, effective_at)
         VALUES ('t1', '0e2e0000-0000-7000-8000-000000000002', '{receivable}',
                 'debit', 500, 'USD', 2, '2026-08-28T00:00:00Z'),
                ('t1', '0e2e0000-0000-7000-8000-000000000002', '{revenue}',
                 'credit', 500, 'USD', 2, '2026-08-28T00:00:00Z');
         UPDATE ledger_account_balances SET last_seq = last_seq + 1, updated_at = now()
         WHERE tenant_id = 't1' AND account_id IN ('{receivable}', '{revenue}')"
    )))
    .execute(&book.pool)
    .await?;

    // The oracle agrees the book is healthy...
    book.assert_reconciled().await?;
    // ...the command does too...
    let (code, stdout, stderr) = sweep(&book.db_url)?;
    assert_eq!(
        code,
        Some(0),
        "a pending transaction must not read as drift (stderr: {stderr})"
    );
    assert!(stdout.contains("0 breaks"), "stdout was: {stdout}");
    // ...and the population is NAMED, not merely tolerated: the bridge
    // derives available = posted + pending for the account holding the hold.
    let (posted, pending, available, txns): (i64, i64, i64, i64) = sqlx::query_as(
        // ::bigint on each: the bridge's sums come back NUMERIC, and the
        // amounts here are minor units a bigint holds exactly.
        "SELECT posted_balance_minor::bigint, pending_balance_minor::bigint,
                available_balance_minor::bigint, pending_txns::bigint
         FROM recon_pending_bridge WHERE tenant_id = 't1' AND account_id = $1",
    )
    .bind(receivable)
    .fetch_one(&book.pool)
    .await?;
    assert_eq!(
        (posted, pending, available, txns),
        (2500, 500, 3000, 1),
        "the bridge must foot: available = posted + pending, population counted"
    );
    Ok(())
}

// ------------------------------------ the drift classes, spike order first

/// Spike 013 DRIFT 1: the forged cache.
#[tokio::test]
async fn a_forged_cache_is_breaks_on_stderr_and_exit_1() -> TestResult {
    let book = TestBook::new("reconcile_drift").await?;
    post_one_charge(&book).await?;
    // The clean control before the forgery, spike 013's discipline: a red
    // sweep below means the injection was detected, not that the book was
    // already broken.
    book.assert_reconciled().await?;

    forge_the_balance_cache(&book).await?;

    let (code, stdout, stderr) = sweep(&book.db_url)?;
    assert_eq!(
        code,
        Some(1),
        "a drifted book must exit 1 (stdout: {stdout})"
    );
    // The breaks land on stderr with the breaking check NAMED — and ONLY
    // that check: the forgery touched no entry, so the horizon is quiet and
    // the other nine comparisons have nothing to say.
    assert!(
        stderr.contains("balance_cache") && stderr.contains("breaks in 1 of 10 checks"),
        "the drift report must name balance_cache and nothing else; stderr was: {stderr}"
    );
    // And no clean summary on stdout: one channel says one thing.
    assert!(
        !stdout.contains("0 breaks"),
        "a drifted sweep must not print the clean summary; stdout was: {stdout}"
    );
    Ok(())
}

/// Spike 013 DRIFT 2 (case 2a): `last_seq` pushed ahead of the journal with
/// the balance untouched. The cache row is three things at once — lock,
/// counter, cached number — and the spike's argument is that they need not
/// be DETECTED together: the command must go red on the counter alone, in
/// the same `balance_cache` check but a different class. (2b `seq_behind`
/// and 2c `seq_gap` share this check and this exit path; 2a is the
/// representative — 2b additionally fails closed on its own at the next
/// posting, which is the writer's test, not this command's.)
#[tokio::test]
async fn a_forged_sequence_counter_breaks_with_the_balance_exact() -> TestResult {
    let book = TestBook::new("reconcile_seq").await?;
    let (receivable, _) = post_one_charge(&book).await?;
    book.assert_reconciled().await?;

    // + 48 is not an arbitrary number: it is ADR-0004's "an INSERT left a
    // 48-wide gap", the hole this class was first reproduced with, carried
    // through spike 013's 05_drift_sequence.sql.
    sqlx::query("UPDATE ledger_account_balances SET last_seq = last_seq + 48 WHERE tenant_id = 't1' AND account_id = $1")
        .bind(receivable)
        .execute(&book.pool)
        .await?;

    let (code, _stdout, stderr) = sweep(&book.db_url)?;
    assert_eq!(code, Some(1), "a forged counter must exit 1");
    assert!(
        stderr.contains("balance_cache") && stderr.contains("breaks in 1 of 10 checks"),
        "the forged counter must break balance_cache alone; stderr was: {stderr}"
    );
    // The class, not just the check: the break list says the counter is
    // ahead and the balance is exact — the spike's whole point.
    let (reasons, balance_exact): (Vec<String>, bool) =
        sqlx::query_as("SELECT reasons, drift_minor = 0 FROM recon_balance_breaks")
            .fetch_one(&book.pool)
            .await?;
    assert_eq!(reasons, ["seq_ahead"], "the reason must be the counter");
    assert!(
        balance_exact,
        "the balance must be exact — only the counter drifted"
    );
    Ok(())
}

/// Spike 013 DRIFT 3 (case 3c): an entry whose transaction is not there —
/// injected the way it actually happens, `session_replication_role =
/// 'replica'` (the logical-replication apply path, what `pg_restore
/// --disable-triggers` sets), which skips the FK triggers that make this
/// population empty on the ordinary path. (3a no_account and 3b
/// no_account_type share the `orphan_entries` check and this exit path.)
#[tokio::test]
async fn an_entry_with_no_transaction_is_an_orphan_entries_break() -> TestResult {
    let book = TestBook::new("reconcile_orphan").await?;
    let (receivable, _) = post_one_charge(&book).await?;
    book.assert_reconciled().await?;

    sqlx::raw_sql(AssertSqlSafe(format!(
        "SET session_replication_role = 'replica';
         INSERT INTO ledger_entries (tenant_id, transaction_id, account_id, direction,
                                     amount_minor, currency, account_seq, effective_at)
         VALUES ('t1', '0e2e0000-0000-7000-8000-0000000000cc', '{receivable}',
                 'credit', 700, 'USD', 99, '2026-08-28T00:00:00Z');
         SET session_replication_role = 'origin'"
    )))
    .execute(&book.pool)
    .await?;

    // The injection committed an entry, so wait for the horizon to retire
    // it (assert_reconciled would do this and then fail on the break —
    // which is the point of the break).
    book.wait_for_the_horizon_to_retire_this_book().await?;
    let (code, _stdout, stderr) = sweep(&book.db_url)?;
    assert_eq!(code, Some(1), "an orphan entry must exit 1");
    assert!(
        stderr.contains("orphan_entries") && stderr.contains("breaks in 1 of 10 checks"),
        "the orphan must break orphan_entries alone; stderr was: {stderr}"
    );
    // ...alone because the statement NAMES the orphan as a reconciling item
    // rather than leaving it unexplained — the spike's finding that a
    // reconciliation is not a subtraction.
    let (explained,): (bool,) = sqlx::query_as(
        "SELECT coalesce(bool_and(unexplained_debits = 0 AND unexplained_credits = 0), true)
         FROM recon_journal_to_reports",
    )
    .fetch_one(&book.pool)
    .await?;
    assert!(
        explained,
        "the orphan must be a named reconciling item, not an unexplained gap"
    );
    Ok(())
}

/// Spike 013 DRIFT 4 (case 4c): the entryless transaction. (4a single_leg
/// carries the equation test below, 4b debits≠credits and 4d the
/// currency-blind pair share the `unbalanced_transactions` check and this
/// exit path; 4c is the one this project has already been burned by.)
#[tokio::test]
async fn an_entryless_transaction_is_an_unbalanced_transactions_break() -> TestResult {
    let book = TestBook::new("reconcile_entryless").await?;
    post_one_charge(&book).await?;
    book.assert_reconciled().await?;

    insert_an_entryless_transaction(&book).await?;

    let (code, _stdout, stderr) = sweep(&book.db_url)?;
    assert_eq!(code, Some(1), "an entryless transaction must exit 1");
    assert!(
        stderr.contains("unbalanced_transactions") && stderr.contains("breaks in 1 of 10 checks"),
        "the entryless transaction must break unbalanced_transactions alone; stderr was: {stderr}"
    );
    let (reason,): (String,) = sqlx::query_as("SELECT reason FROM recon_transaction_breaks")
        .fetch_one(&book.pool)
        .await?;
    assert_eq!(
        reason, "no_entries",
        "the class must be the TRUNCATE scar's"
    );
    Ok(())
}

/// Spike 013 DRIFT 5 (case 5a): one side of a cross-scope obligation booked
/// with no matching far side. Injected through the FRONT DOOR — an
/// ordinary, balanced, API-posted transaction on the tenant's own book —
/// because that is what makes this class invisible to every per-scope
/// check: nothing is forged, and somebody is still owed money. (5b, the
/// third-scope offset that silences the view, is the spike's documented
/// limitation of the CHECK, not a behaviour of this command — a test of it
/// would pin exit 0 on a book the ADR itself calls wrong.)
#[tokio::test]
async fn a_one_sided_cross_scope_booking_is_a_cross_scope_mirror_break() -> TestResult {
    let book = TestBook::new("reconcile_scope").await?;
    let (_, revenue) = post_one_charge(&book).await?;
    // The tenant-side claim on the operator: due_from_treasury declares
    // mirror_type = due_to_tenants in the published chart, and the operator
    // side never posts.
    let claim = book
        .account("t1", None, "due_from_treasury", "asset", "debit", "shared")
        .await?;
    let created = book
        .post(&serde_json::json!({
            "tenant_id": "t1",
            "idempotency_key": "treasury-draw-1",
            "effective_at": "2026-08-27T12:00:00Z",
            "postings": [{
                "source": revenue, "destination": claim,
                "amount_minor": 40000, "currency": "USD"
            }],
        }))
        .await?;
    assert_eq!(
        created.status(),
        201,
        "the one-sided booking is an ordinary posting"
    );

    book.wait_for_the_horizon_to_retire_this_book().await?;
    let (code, _stdout, stderr) = sweep(&book.db_url)?;
    assert_eq!(code, Some(1), "a one-sided obligation must exit 1");
    assert!(
        stderr.contains("cross_scope_mirror") && stderr.contains("breaks in 1 of 10 checks"),
        "the gap must break cross_scope_mirror alone; stderr was: {stderr}"
    );
    // The break carries the counterparty and the whole gap: 400.00 owed by
    // nobody, attributed to the pair between t1 and its operator.
    let (gap_is_whole, counterparty): (bool, String) =
        sqlx::query_as("SELECT gap_minor = 40000, counterparty FROM recon_scope_breaks")
            .fetch_one(&book.pool)
            .await?;
    assert!(gap_is_whole, "the gap must be the whole one-sided amount");
    assert_eq!(
        counterparty, "t1",
        "grouped per counterparty (A9), not deployment-wide"
    );
    Ok(())
}

// -------------------- the checks that joined the family after spike 013

/// `journal_to_reports`, red through its out-of-window bucket (A17): a
/// posted, balanced, correctly-cached transaction dated year 2226 —
/// finite, so `ck_txn__effective_finite` accepts it — is classified
/// `out_of_window` (not reported) while `trial_balance` still counts it,
/// so `unexplained` goes nonzero on a fat-fingered date rather than the
/// date being silently reported into every statement forever. Chosen over
/// the OTHER divergence (a presentation row missing under posted history)
/// deliberately: that one converges with the A14 RAISE — the statement
/// functions refuse to run at all, so through this command it surfaces as
/// a failed sweep naming chart_lint.type_unpresented, never as this
/// check's count. This bucket is the one that reaches the summary.
#[tokio::test]
async fn an_out_of_window_posting_is_a_journal_to_reports_break() -> TestResult {
    let book = TestBook::new("reconcile_out_of_window").await?;
    let (receivable, revenue) = post_one_charge(&book).await?;
    book.assert_reconciled().await?;

    sqlx::raw_sql(AssertSqlSafe(format!(
        "INSERT INTO ledger_events (tenant_id, id, kind, source, idempotency_key,
                                    idempotency_hash, payload, effective_at)
         VALUES ('t1', '0e2e0000-0000-7000-8000-000000000020', 'charge', 'internal',
                 'fat-finger-1', decode('00', 'hex'), '{{}}'::jsonb, '2226-08-27T12:00:00Z');
         INSERT INTO ledger_transactions (tenant_id, id, event_id, kind, status, effective_at)
         VALUES ('t1', '0e2e0000-0000-7000-8000-000000000021',
                 '0e2e0000-0000-7000-8000-000000000020', 'charge', 'posted', '2226-08-27T12:00:00Z');
         INSERT INTO ledger_entries (tenant_id, transaction_id, account_id, direction,
                                     amount_minor, currency, account_seq, effective_at)
         VALUES ('t1', '0e2e0000-0000-7000-8000-000000000021', '{receivable}',
                 'debit', 700, 'USD', 2, '2226-08-27T12:00:00Z'),
                ('t1', '0e2e0000-0000-7000-8000-000000000021', '{revenue}',
                 'credit', 700, 'USD', 2, '2226-08-27T12:00:00Z');
         UPDATE ledger_account_balances SET input = input + 700, last_seq = 2
         WHERE tenant_id = 't1' AND account_id = '{receivable}';
         UPDATE ledger_account_balances SET output = output + 700, last_seq = 2
         WHERE tenant_id = 't1' AND account_id = '{revenue}'"
    )))
    .execute(&book.pool)
    .await?;

    book.wait_for_the_horizon_to_retire_this_book().await?;
    let (code, _stdout, stderr) = sweep(&book.db_url)?;
    assert_eq!(code, Some(1), "a fat-fingered date must exit 1");
    assert!(
        stderr.contains("journal_to_reports") && stderr.contains("breaks in 1 of 10 checks"),
        "the out-of-window posting must break journal_to_reports alone; stderr was: {stderr}"
    );
    // The statement names WHERE the money went — the whole amount sits in
    // the out_of_window bucket, and unexplained carries its absence from
    // the reported population.
    let (bucketed,): (bool,) = sqlx::query_as(
        "SELECT out_of_window_debits = 700 AND unexplained_debits = -700
         FROM recon_journal_to_reports",
    )
    .fetch_one(&book.pool)
    .await?;
    assert!(
        bucketed,
        "the amount must sit in the out_of_window bucket, named"
    );
    Ok(())
}

/// `accounting_equation`, red through spike 013's DRIFT 4a shape: a single
/// posted leg with the cache advanced to match. It cannot break ALONE —
/// every journal shape that unbalances the balance sheet trips a second
/// check with it: here the cursor-bounded equation pairs with the
/// cursor-unbounded transaction check, and a leg forged ABOVE the cursor
/// would pair with `cursor_forgery` instead (the equation check exists for
/// PRESENTATION bugs, which live in the statement functions this suite
/// cannot honestly mutate) — so this is the one drift test that asserts
/// TWO named checks:
/// the transaction check catches the rows, the equation check catches the
/// face. That pairing is the point: a regression that silences either one
/// alone still fails here.
#[tokio::test]
async fn a_single_posted_leg_breaks_the_equation_and_the_transaction_check() -> TestResult {
    let book = TestBook::new("reconcile_equation").await?;
    let (_, revenue) = post_one_charge(&book).await?;
    book.assert_reconciled().await?;

    sqlx::raw_sql(AssertSqlSafe(format!(
        "INSERT INTO ledger_events (tenant_id, id, kind, source, idempotency_key,
                                    idempotency_hash, payload, effective_at)
         VALUES ('t1', '0e2e0000-0000-7000-8000-000000000030', 'fee', 'internal',
                 'single-leg-1', decode('00', 'hex'), '{{}}'::jsonb, '2026-08-27T13:00:00Z');
         INSERT INTO ledger_transactions (tenant_id, id, event_id, kind, status, effective_at)
         VALUES ('t1', '0e2e0000-0000-7000-8000-000000000031',
                 '0e2e0000-0000-7000-8000-000000000030', 'fee', 'posted', '2026-08-27T13:00:00Z');
         INSERT INTO ledger_entries (tenant_id, transaction_id, account_id, direction,
                                     amount_minor, currency, account_seq, effective_at)
         VALUES ('t1', '0e2e0000-0000-7000-8000-000000000031', '{revenue}',
                 'credit', 250, 'USD', 2, '2026-08-27T13:00:00Z');
         UPDATE ledger_account_balances SET output = output + 250, last_seq = 2
         WHERE tenant_id = 't1' AND account_id = '{revenue}'"
    )))
    .execute(&book.pool)
    .await?;

    // The equation check is pinned at report_cursor(), so the forged leg is
    // invisible to it until the horizon retires it — the same wait as ever.
    book.wait_for_the_horizon_to_retire_this_book().await?;
    let (code, _stdout, stderr) = sweep(&book.db_url)?;
    assert_eq!(code, Some(1), "a single posted leg must exit 1");
    assert!(
        stderr.contains("breaks in 2 of 10 checks")
            && stderr.contains("accounting_equation")
            && stderr.contains("unbalanced_transactions"),
        "the single leg must break the equation AND the transaction check; stderr was: {stderr}"
    );
    // The face is off by exactly the leg: 2.50 of earnings no asset carries.
    let (gap_is_the_leg,): (bool,) = sqlx::query_as(
        "SELECT gap_minor = -250 FROM recon_equation_breaks(report_cursor(), 'infinity')",
    )
    .fetch_one(&book.pool)
    .await?;
    assert!(
        gap_is_the_leg,
        "the equation gap must be the single leg's amount"
    );
    Ok(())
}

/// A full, honest close — period, event, `period_close` transaction,
/// balanced closing entries, cache advanced — whose stored close row names
/// a cursor BELOW its own closing transaction's commit position:
/// `computed_at_xid = 1`. The composite FKs type everything else about a
/// close declaratively; the cursor-to-commit relationship is the one
/// property only the sweep holds (`recon_close_breaks`' own comment), and
/// a cursor of 1 is exactly the forgery that makes the checkpoint check
/// vacuously green — which is why it must be a break of its own.
#[tokio::test]
async fn a_close_whose_cursor_precedes_it_is_a_close_typing_break() -> TestResult {
    let book = TestBook::new("reconcile_close_typing").await?;
    let (receivable, revenue) = post_one_charge(&book).await?;
    book.assert_reconciled().await?;

    close_the_august_period(&book, receivable, revenue, "'1'").await?;

    book.wait_for_the_horizon_to_retire_this_book().await?;
    let (code, _stdout, stderr) = sweep(&book.db_url)?;
    assert_eq!(code, Some(1), "a mis-cursored close must exit 1");
    assert!(
        stderr.contains("close_typing") && stderr.contains("breaks in 1 of 10 checks"),
        "the mis-cursored close must break close_typing alone; stderr was: {stderr}"
    );
    let (reason,): (String,) = sqlx::query_as("SELECT reason FROM recon_close_breaks")
        .fetch_one(&book.pool)
        .await?;
    assert_eq!(reason, "cursor_precedes_close");
    Ok(())
}

/// The same honest close with an honest cursor — and NO checkpoint rows:
/// "a checkpoint nothing reconciles is the balance_after column with
/// better manners" (ADR-0011), and a close whose `ledger_period_balances`
/// never landed is one the sweep must refuse to call closed. The recompute
/// finds the charge's entries below the cursor and the stored side empty:
/// one `missing_row` per account.
#[tokio::test]
async fn a_close_with_no_checkpoint_rows_is_a_checkpoint_drift_break() -> TestResult {
    let book = TestBook::new("reconcile_checkpoint").await?;
    let (receivable, revenue) = post_one_charge(&book).await?;
    book.assert_reconciled().await?;

    // pg_current_xact_id() inside the same batch as the closing transaction
    // is that transaction's own xact_id, so recon_close_breaks stays quiet
    // and only the missing checkpoint speaks.
    close_the_august_period(&book, receivable, revenue, "pg_current_xact_id()").await?;

    book.wait_for_the_horizon_to_retire_this_book().await?;
    let (code, _stdout, stderr) = sweep(&book.db_url)?;
    assert_eq!(code, Some(1), "a checkpoint-less close must exit 1");
    assert!(
        stderr.contains("checkpoint_drift") && stderr.contains("breaks in 1 of 10 checks"),
        "the missing checkpoint must break checkpoint_drift alone; stderr was: {stderr}"
    );
    let reasons: Vec<(String,)> =
        sqlx::query_as("SELECT DISTINCT reason FROM recon_checkpoint_breaks")
            .fetch_all(&book.pool)
            .await?;
    assert_eq!(
        reasons,
        [("missing_row".to_owned(),)],
        "every break must be a checkpoint row that never landed"
    );
    Ok(())
}

/// `cursor_forgery`, red through the persistent half of the check: a
/// balanced pair of legs appended to the posted charge with `xact_id`
/// SUPPLIED as 1 — below the transaction's own commit position, a leg
/// claiming to have committed before the transaction that carries it. The
/// baseline's own comment says who can do this: the column-level INSERT
/// grant stops the app role, and the OWNER can still write one. Unlike the
/// horizon transient the race test tolerates, `predates_txn` never clears
/// — no wait, however long, makes it honest — which is what makes it the
/// red path the race test cannot stand in for.
#[tokio::test]
async fn an_entry_with_a_forged_commit_key_is_a_cursor_forgery_break() -> TestResult {
    let book = TestBook::new("reconcile_cursor").await?;
    let (receivable, revenue) = post_one_charge(&book).await?;
    book.assert_reconciled().await?;

    let (charge,): (uuid::Uuid,) =
        sqlx::query_as("SELECT id FROM ledger_transactions WHERE tenant_id = 't1'")
            .fetch_one(&book.pool)
            .await?;
    // Balanced, cache-consistent, correctly dated — every OTHER check stays
    // quiet, so the forged commit key is the only thing wrong with this book.
    sqlx::raw_sql(AssertSqlSafe(format!(
        "INSERT INTO ledger_entries (tenant_id, transaction_id, account_id, direction,
                                     amount_minor, currency, account_seq, effective_at, xact_id)
         VALUES ('t1', '{charge}', '{receivable}', 'debit', 300, 'USD', 2,
                 '2026-08-27T12:00:00Z', '1'),
                ('t1', '{charge}', '{revenue}', 'credit', 300, 'USD', 2,
                 '2026-08-27T12:00:00Z', '1');
         UPDATE ledger_account_balances SET input = input + 300, last_seq = 2
         WHERE tenant_id = 't1' AND account_id = '{receivable}';
         UPDATE ledger_account_balances SET output = output + 300, last_seq = 2
         WHERE tenant_id = 't1' AND account_id = '{revenue}'"
    )))
    .execute(&book.pool)
    .await?;

    // No horizon wait needed, and none would help: xact_id 1 is below every
    // horizon there will ever be, and still a forgery.
    let (code, _stdout, stderr) = sweep(&book.db_url)?;
    assert_eq!(code, Some(1), "a forged commit key must exit 1");
    assert!(
        stderr.contains("cursor_forgery") && stderr.contains("breaks in 1 of 10 checks"),
        "the forged key must break cursor_forgery alone; stderr was: {stderr}"
    );
    let reasons: Vec<(String,)> = sqlx::query_as("SELECT DISTINCT reason FROM recon_cursor_breaks")
        .fetch_all(&book.pool)
        .await?;
    assert_eq!(
        reasons,
        [("predates_txn".to_owned(),)],
        "the class must be the persistent one, not the horizon transient"
    );
    Ok(())
}

/// `chart_lint`, red through its highest-stakes error: an `is_perimeter`
/// account — one whose type claims "mirrors exactly one external balance
/// and must reconcile against it" — carrying posted entries with no
/// attestation ever stored. Injected through the front door: the account
/// is opened and posted to exactly as the fixture accounts are, and the
/// fixture's own comment (book.rs) documents this firing as the reason it
/// avoids perimeter types.
#[tokio::test]
async fn an_unattested_perimeter_account_is_a_chart_lint_break() -> TestResult {
    let book = TestBook::new("reconcile_chart_lint").await?;
    let (_, revenue) = post_one_charge(&book).await?;
    book.assert_reconciled().await?;

    let cash = book
        .account("t1", None, "operating_cash", "asset", "debit", "shared")
        .await?;
    let created = book
        .post(&serde_json::json!({
            "tenant_id": "t1",
            "idempotency_key": "cash-in-1",
            "effective_at": "2026-08-27T14:00:00Z",
            "postings": [{
                "source": revenue, "destination": cash,
                "amount_minor": 300, "currency": "USD"
            }],
        }))
        .await?;
    assert_eq!(created.status(), 201, "posting to the perimeter account");

    book.wait_for_the_horizon_to_retire_this_book().await?;
    let (code, _stdout, stderr) = sweep(&book.db_url)?;
    assert_eq!(code, Some(1), "an unattested perimeter account must exit 1");
    assert!(
        stderr.contains("chart_lint") && stderr.contains("breaks in 1 of 10 checks"),
        "the unattested perimeter must break chart_lint alone; stderr was: {stderr}"
    );
    let rules: Vec<(String,)> =
        sqlx::query_as("SELECT DISTINCT rule FROM chart_lint WHERE severity = 'error'")
            .fetch_all(&book.pool)
            .await?;
    assert_eq!(rules, [("perimeter_unattested".to_owned(),)]);
    Ok(())
}

// -------------------------------------------------- two drifts, one sweep

/// Two independent drifts, one sweep, both named: an operator paged by this
/// command sees every breaking check at once, not the first one found.
/// DRIFT 1's cache forgery and DRIFT 4c's entryless transaction — the same
/// two injections the single-drift tests use, through the same helpers.
#[tokio::test]
async fn two_simultaneous_drifts_are_both_named_in_one_sweep() -> TestResult {
    let book = TestBook::new("reconcile_two_drifts").await?;
    post_one_charge(&book).await?;
    book.assert_reconciled().await?;

    forge_the_balance_cache(&book).await?;
    insert_an_entryless_transaction(&book).await?;

    let (code, _stdout, stderr) = sweep(&book.db_url)?;
    assert_eq!(code, Some(1), "two drifts must exit 1");
    assert!(
        stderr.contains("breaks in 2 of 10 checks")
            && stderr.contains("balance_cache")
            && stderr.contains("unbalanced_transactions"),
        "both breaking checks must be named in one report; stderr was: {stderr}"
    );
    Ok(())
}

// ------------------------------------------------------- contract edges

#[tokio::test]
async fn reconcile_without_a_database_url_is_a_usage_error_and_exit_2() -> TestResult {
    // No database anywhere near this: dispatch refuses the absence naming
    // both spellings, same as migrate's.
    let output = postgres::openledger()?
        .arg("reconcile")
        .env_remove("DATABASE_URL")
        .output()?;
    assert_eq!(output.status.code(), Some(2), "no URL must be exit 2");
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("DATABASE_URL") && stderr.contains("--database-url"),
        "the refusal must name both spellings; stderr was: {stderr}"
    );
    Ok(())
}

#[tokio::test]
async fn reconcile_with_a_garbage_database_url_is_a_usage_error_and_exit_2() -> TestResult {
    let output = postgres::openledger()?
        .arg("reconcile")
        .env("DATABASE_URL", "not-a-url")
        .output()?;
    assert_eq!(
        output.status.code(),
        Some(2),
        "an unparseable URL is a usage error — retrying changes nothing"
    );
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("could not parse"),
        "the refusal must say the URL did not parse; stderr was: {stderr}"
    );
    Ok(())
}

#[tokio::test]
async fn reconcile_against_an_unreachable_database_is_exit_1() -> TestResult {
    // Port 1 answers nothing; a refused connection is exit 1 — read the
    // error first — never a false clean 0 and never a retry-safe 3.
    let output = postgres::openledger()?
        .arg("reconcile")
        .env(
            "DATABASE_URL",
            "postgres://nobody:nothing@127.0.0.1:1/openledger",
        )
        .output()?;
    assert_eq!(
        output.status.code(),
        Some(1),
        "an unreachable database must exit 1"
    );
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("could not connect"),
        "the failure must name the connection; stderr was: {stderr}"
    );
    Ok(())
}

/// The sweep runs as the role the views grant to, and a login that was
/// never made a member is refused WITH THE REMEDY — the likeliest
/// deployment mistake, met with the GRANT to run rather than a bare
/// permission error.
#[tokio::test]
async fn a_login_outside_the_recon_role_is_refused_with_the_remedy() -> TestResult {
    let db_url = postgres::create_scratch_db("reconcile_norecon").await?;
    postgres::migrate(&db_url)?;
    let pool = PgPoolOptions::new()
        .max_connections(2)
        .connect(&db_url)
        .await?;
    // The reader login: a real, policy-admitted role — member of
    // openledger_read, NOT of openledger_recon. Exactly the wrong login an
    // operator would plausibly point the sweep at.
    postgres::ensure_login_role(&pool, postgres::READ_LOGIN, "openledger_read").await?;
    let read_url =
        postgres::swap_credentials(&db_url, postgres::READ_LOGIN, postgres::LOGIN_PASSWORD)?;

    let (code, _stdout, stderr) = sweep(&read_url)?;
    assert_eq!(code, Some(1), "a non-member login must exit 1");
    assert!(
        stderr.contains("openledger_recon") && stderr.contains("GRANT openledger_recon TO"),
        "the refusal must carry the remedy; stderr was: {stderr}"
    );
    Ok(())
}

/// ADR-0010's scar, held against the command itself: a summary that has
/// LOST a check must fail, never pass on nine zeros — a check that never
/// ran is indistinguishable from one that passed. Staged by surgery on the
/// summary view in a scratch database (the schema cannot honestly lose a
/// check any other way; the baseline is frozen).
#[tokio::test]
async fn a_summary_short_of_ten_checks_fails_rather_than_passing() -> TestResult {
    let db_url = postgres::create_scratch_db("reconcile_nine_checks").await?;
    postgres::migrate(&db_url)?;
    let pool = PgPoolOptions::new()
        .max_connections(2)
        .connect(&db_url)
        .await?;
    sqlx::raw_sql(include_str!("../../../../schema/chart.sql"))
        .execute(&pool)
        .await?;
    // Nine arms instead of ten: the real view, renamed, minus one check —
    // the shape a well-meaning migration could produce. The new view needs
    // its own grant; the rename carried the old one away with the old name.
    sqlx::raw_sql(
        "ALTER VIEW reconciliation RENAME TO reconciliation_all_ten;
         CREATE VIEW reconciliation AS
             SELECT check_name, breaks FROM reconciliation_all_ten
             WHERE check_name <> 'chart_lint';
         GRANT SELECT ON reconciliation TO openledger_recon",
    )
    .execute(&pool)
    .await?;

    let (code, stdout, stderr) = sweep(&db_url)?;
    assert_eq!(
        code,
        Some(1),
        "nine zeros must FAIL, not pass (stdout: {stdout})"
    );
    assert!(
        stderr.contains("returned 9 check(s)") && stderr.contains("silence read as assent"),
        "the failure must count the shortfall and name the scar; stderr was: {stderr}"
    );
    Ok(())
}

/// The READ ONLY half of the sweep transaction, made falsifiable: a write
/// smuggled into the summary's own read path — a SECURITY DEFINER function,
/// so the recon role's missing INSERT grant cannot be what stops it — must
/// be refused by the TRANSACTION, and nothing may land. A sweep regressed
/// to a plain writable BEGIN would execute this write and report ten clean
/// zeros, which is exactly what this test exists to fail. (The REPEATABLE
/// READ half has no red path at this surface yet: the sweep is one
/// statement, and one statement is one snapshot at every isolation level —
/// see the race test's comment.)
#[tokio::test]
async fn a_write_smuggled_into_the_sweep_is_refused_by_the_read_only_transaction() -> TestResult {
    let db_url = postgres::create_scratch_db("reconcile_probe").await?;
    postgres::migrate(&db_url)?;
    let pool = PgPoolOptions::new()
        .max_connections(2)
        .connect(&db_url)
        .await?;
    sqlx::raw_sql(include_str!("../../../../schema/chart.sql"))
        .execute(&pool)
        .await?;
    sqlx::raw_sql(
        "CREATE TABLE sweep_probe (hit_at timestamptz NOT NULL DEFAULT now());
         CREATE FUNCTION record_probe_hit() RETURNS bigint
             LANGUAGE plpgsql SECURITY DEFINER AS $$
             BEGIN INSERT INTO sweep_probe DEFAULT VALUES; RETURN 0; END $$;
         ALTER VIEW reconciliation RENAME TO reconciliation_all_ten;
         CREATE VIEW reconciliation AS
             SELECT check_name, breaks + record_probe_hit() AS breaks
             FROM reconciliation_all_ten;
         GRANT SELECT ON reconciliation TO openledger_recon",
    )
    .execute(&pool)
    .await?;

    let (code, stdout, stderr) = sweep(&db_url)?;
    assert_eq!(
        code,
        Some(1),
        "a sweep that reaches a write must fail, not report clean (stdout: {stdout})"
    );
    assert!(
        stderr.contains("read-only transaction"),
        "the refusal must be the transaction's, not a grant's; stderr was: {stderr}"
    );
    let (hits,): (i64,) = sqlx::query_as("SELECT count(*) FROM sweep_probe")
        .fetch_one(&pool)
        .await?;
    assert_eq!(hits, 0, "nothing may land from a sweep");
    Ok(())
}

// ------------------------------------------- the one-snapshot guarantee

/// Sweeps spawned while a wave of API posts is landing must never read a
/// mid-flight or freshly-committed posting as drift: a posting commits
/// atomically, and the sweep's one SELECT sees all of it or none. One
/// tolerance, and it is ADR-0010's own: a sweep whose snapshot catches
/// entries above the cluster horizon may transiently report
/// `cursor_forgery` (the quiescence assumption the clean tests wait out on
/// purpose) — but never any OTHER check. After the wave, the same book
/// sweeps clean.
///
/// WHAT THIS DOES NOT PIN, on purpose: the `REPEATABLE READ` half of the
/// sweep transaction. The sweep is one statement today, and one statement
/// is one snapshot at every isolation level, so no test at this surface
/// can fail on the isolation level alone — it is declared for the day the
/// sweep grows a second statement (ADR-0010's per-tenant bounding note),
/// and this comment exists so nobody reads this test as proving it. The
/// READ ONLY half IS pinned, by the smuggled-write test above.
#[tokio::test]
async fn a_sweep_racing_live_writers_never_reads_them_as_drift() -> TestResult {
    let book = TestBook::new("reconcile_race").await?;
    let (receivable, revenue) = book.fixture_accounts().await?;

    let mut posts = Vec::new();
    for round in 0..3 {
        for i in 0..8 {
            posts.push(book.spawn_post(&serde_json::json!({
                "tenant_id": "t1",
                "idempotency_key": format!("race-{round}-{i}"),
                "effective_at": "2026-08-27T12:00:00Z",
                "postings": [{
                    "source": revenue, "destination": receivable,
                    "amount_minor": 100 + i, "currency": "USD"
                }],
            })));
        }
        // Yield so the spawned posts actually send (this test runs on a
        // current-thread runtime); the server then processes them WHILE the
        // blocking sweep below runs — commits landing mid-snapshot is the
        // race under test.
        tokio::time::sleep(std::time::Duration::from_millis(5)).await;
        let (code, _stdout, stderr) = sweep(&book.db_url)?;
        if code == Some(1) {
            for check in ALL_CHECKS.iter().filter(|c| **c != "cursor_forgery") {
                assert!(
                    !stderr.contains(check),
                    "a sweep racing live writers reported {check} — a mid-flight \
                     posting read as drift; stderr was: {stderr}"
                );
            }
            assert!(
                stderr.contains("cursor_forgery"),
                "exit 1 mid-race can only be the horizon transient; stderr was: {stderr}"
            );
        } else {
            assert_eq!(
                code,
                Some(0),
                "mid-race sweep failed oddly; stderr: {stderr}"
            );
        }
    }

    // Every racer landed...
    for post in posts {
        let (status, _replayed, body) = post.await??;
        assert_eq!(status, 201, "a racing post failed: {body}");
    }
    // ...and the quiesced book is clean, oracle and command agreeing.
    book.assert_reconciled().await?;
    let (code, stdout, stderr) = sweep(&book.db_url)?;
    assert_eq!(
        code,
        Some(0),
        "the quiesced book must sweep clean (stderr: {stderr})"
    );
    assert!(stdout.contains("0 breaks"), "stdout was: {stdout}");
    Ok(())
}
