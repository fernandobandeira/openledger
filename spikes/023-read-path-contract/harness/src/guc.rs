//! Q1 — tenant scoping on a pooled connection.
//!
//! Everything here runs on a **real `sqlx::PgPool` sized to exactly one
//! connection**, which is the whole point: `max_connections(1)` makes "the
//! connection the next request gets" deterministic, so a leak is a fact rather
//! than a race. The pool is otherwise configured the way `crates/db`
//! configures the serving process's — same `after_connect` session timeouts,
//! same sqlx 0.9 line — because the question is what THAT pool does with
//! session state, and a different pool answers a different question.
//!
//! The login behind DATABASE_URL is the migration/owner role, and the owner is
//! not bound by RLS (`FORCE ROW LEVEL SECURITY` is deliberately not set —
//! ADR-0013). So every read below runs after `SET LOCAL ROLE openledger_read`,
//! which is exactly how `reconcile.rs` reaches `openledger_recon` and exactly
//! what Q2 then interrogates on its own terms.

use std::time::Duration;

use sqlx::postgres::{PgConnectOptions, PgPoolOptions};
use sqlx::{Executor, PgPool, Row};

const SESSION_TIMEOUTS: &str = "\
    SET statement_timeout = '30s'; \
    SET lock_timeout = '10s'; \
    SET idle_in_transaction_session_timeout = '60s'";

/// One row per (check, observation). Printed as a table so the transcript is
/// the evidence.
fn say(case: &str, detail: &str) {
    println!("{case:<58} {detail}");
}

async fn pool(url: &str) -> Result<PgPool, sqlx::Error> {
    let options: PgConnectOptions = url.parse()?;
    Ok(PgPoolOptions::new()
        .max_connections(1)
        .min_connections(0)
        .idle_timeout(Duration::from_secs(5))
        .acquire_timeout(Duration::from_secs(15))
        .after_connect(|conn, _meta| {
            Box::pin(async move {
                sqlx::raw_sql(SESSION_TIMEOUTS).execute(conn).await?;
                Ok(())
            })
        })
        .connect_lazy_with(options))
}

/// The three reads the whole spike is about, run under `openledger_read` with
/// whatever `app.tenant_id` the session currently carries. Returns
/// (entries visible, the GUC as `current_setting` sees it, tenants visible).
async fn what_the_reader_sees(
    conn: &mut sqlx::PgConnection,
) -> Result<(i64, String, String), sqlx::Error> {
    // Its own transaction, so the SET LOCAL ROLE below is scoped to this read
    // and this read only. Whether the CALLER's scoping survives is what the
    // cases vary.
    conn.execute("BEGIN ISOLATION LEVEL READ COMMITTED READ ONLY")
        .await?;
    conn.execute("SET LOCAL ROLE openledger_read").await?;
    let row = sqlx::query(
        "SELECT (SELECT count(*) FROM ledger_entries)                              AS entries,
                coalesce(current_setting('app.tenant_id', true), '<NULL>')          AS guc,
                coalesce((SELECT string_agg(DISTINCT tenant_id, ',' ORDER BY tenant_id)
                          FROM ledger_entries), '<none>')                           AS tenants",
    )
    .fetch_one(&mut *conn)
    .await?;
    let out = (
        row.get::<i64, _>("entries"),
        row.get::<String, _>("guc"),
        row.get::<String, _>("tenants"),
    );
    conn.execute("COMMIT").await?;
    Ok(out)
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let url = std::env::var("DATABASE_URL")?;
    let pool = pool(&url).await?;

    println!("== Q1 · tenant scoping on a pooled connection ==");
    println!("pool: max_connections=1, sqlx 0.9, crates/db's after_connect");
    println!();

    // ---------------------------------------------------------------- A
    // The claim under test: an unset GUC reads zero rows. The baseline's own
    // comment asserts it; nothing had executed it.
    println!("-- A · fail closed when unset --------------------------------");
    {
        let mut c = pool.acquire().await?;
        let (n, guc, tenants) = what_the_reader_sees(&mut c).await?;
        say(
            "unset app.tenant_id, reader role",
            &format!("entries={n} guc={guc} tenants={tenants}"),
        );
    }

    // ...and through the report surfaces, which is where it actually matters:
    // trial_balance carries security_invoker, and the two statement functions
    // are SECURITY INVOKER plpgsql.
    {
        let mut c = pool.acquire().await?;
        c.execute("BEGIN ISOLATION LEVEL READ COMMITTED READ ONLY")
            .await?;
        c.execute("SET LOCAL ROLE openledger_read").await?;
        let tb: i64 = sqlx::query_scalar("SELECT count(*) FROM trial_balance")
            .fetch_one(&mut *c)
            .await?;
        let tba: i64 = sqlx::query_scalar(
            "SELECT count(*) FROM trial_balance_at('t1','-infinity','infinity', report_cursor())",
        )
        .fetch_one(&mut *c)
        .await?;
        let bs: i64 = sqlx::query_scalar(
            "SELECT count(*) FROM balance_sheet_at('t1','infinity', report_cursor())",
        )
        .fetch_one(&mut *c)
        .await?;
        let is: i64 = sqlx::query_scalar(
            "SELECT count(*) FROM income_statement_for('t1','-infinity','infinity', report_cursor())",
        )
        .fetch_one(&mut *c)
        .await?;
        c.execute("COMMIT").await?;
        say(
            "unset GUC, through the report surfaces",
            &format!("trial_balance={tb} trial_balance_at={tba} balance_sheet_at={bs} income_statement_for={is}"),
        );
    }

    // ---------------------------------------------------------------- B
    // Session SET, then hand the connection back. This is the leak.
    println!();
    println!("-- B · session SET, returned to the pool ---------------------");
    {
        let mut c = pool.acquire().await?;
        c.execute("SET app.tenant_id = 't1'").await?;
        let (n, guc, tenants) = what_the_reader_sees(&mut c).await?;
        say(
            "checkout 1: SET app.tenant_id = 't1', then read",
            &format!("entries={n} guc={guc} tenants={tenants}"),
        );
        // drop(c) returns it to the pool. No DISCARD ALL, no reset — sqlx
        // does not promise one, which is the fact this case establishes.
    }
    {
        let mut c = pool.acquire().await?;
        let (n, guc, tenants) = what_the_reader_sees(&mut c).await?;
        say(
            "checkout 2: sets NOTHING, reads as if for t2",
            &format!("entries={n} guc={guc} tenants={tenants}"),
        );
    }

    // ---------------------------------------------------------------- C
    // SET LOCAL inside a transaction. Scoped to the transaction, so the
    // connection goes back clean.
    println!();
    println!("-- C · SET LOCAL inside an explicit transaction --------------");
    {
        let mut c = pool.acquire().await?;
        // Reset the leak B left behind, so C measures C.
        c.execute("RESET app.tenant_id").await?;
        c.execute("BEGIN ISOLATION LEVEL READ COMMITTED READ ONLY")
            .await?;
        c.execute("SET LOCAL ROLE openledger_read").await?;
        c.execute("SET LOCAL app.tenant_id = 't1'").await?;
        let row = sqlx::query(
            "SELECT count(*) AS n,
                    coalesce(string_agg(DISTINCT tenant_id, ','), '<none>') AS tenants
             FROM ledger_entries",
        )
        .fetch_one(&mut *c)
        .await?;
        say(
            "inside the transaction, SET LOCAL 't1'",
            &format!(
                "entries={} tenants={}",
                row.get::<i64, _>("n"),
                row.get::<String, _>("tenants")
            ),
        );
        c.execute("COMMIT").await?;
        let (n, guc, tenants) = what_the_reader_sees(&mut c).await?;
        say(
            "same connection, after COMMIT",
            &format!("entries={n} guc={guc} tenants={tenants}"),
        );
    }
    {
        let mut c = pool.acquire().await?;
        let (n, guc, tenants) = what_the_reader_sees(&mut c).await?;
        say(
            "next checkout after a SET LOCAL request",
            &format!("entries={n} guc={guc} tenants={tenants}"),
        );
    }

    // ---------------------------------------------------------------- D
    // set_config(..., is_local => true) — the only form that takes a BIND
    // PARAMETER. `SET app.tenant_id = $1` is a syntax error, and tenant_id is
    // caller-supplied text from a request body (ADR-0017).
    println!();
    println!("-- D · set_config(..., is_local => true), parameterised ------");
    {
        let mut c = pool.acquire().await?;
        match c.execute("SET app.tenant_id = $1").await {
            Ok(_) => say("SET app.tenant_id = $1", "ACCEPTED (unexpected)"),
            Err(e) => say("SET app.tenant_id = $1", &format!("REFUSED: {e}")),
        }
    }
    {
        let mut c = pool.acquire().await?;
        c.execute("BEGIN ISOLATION LEVEL READ COMMITTED READ ONLY")
            .await?;
        c.execute("SET LOCAL ROLE openledger_read").await?;
        // The bind is what makes this the form a handler can actually use.
        // A hostile tenant_id is data, never syntax.
        let applied: String = sqlx::query_scalar("SELECT set_config('app.tenant_id', $1, true)")
            .bind("t2")
            .fetch_one(&mut *c)
            .await?;
        let row = sqlx::query(
            "SELECT count(*) AS n,
                    coalesce(string_agg(DISTINCT tenant_id, ','), '<none>') AS tenants
             FROM ledger_entries",
        )
        .fetch_one(&mut *c)
        .await?;
        say(
            "set_config($1, is_local => true) in a transaction",
            &format!(
                "applied={applied} entries={} tenants={}",
                row.get::<i64, _>("n"),
                row.get::<String, _>("tenants")
            ),
        );
        // The injection attempt that the bind makes inert.
        let hostile: String = sqlx::query_scalar("SELECT set_config('app.tenant_id', $1, true)")
            .bind("t2'; SET ROLE openledger_app; --")
            .fetch_one(&mut *c)
            .await?;
        let n: i64 = sqlx::query_scalar("SELECT count(*) FROM ledger_entries")
            .fetch_one(&mut *c)
            .await?;
        let who: String = sqlx::query_scalar("SELECT current_user::text")
            .fetch_one(&mut *c)
            .await?;
        say(
            "…and with a hostile tenant_id as the bind",
            &format!("applied={hostile:?} entries={n} current_user={who}"),
        );
        c.execute("COMMIT").await?;
    }

    // ---------------------------------------------------------------- E
    // The trap: is_local => true with NO explicit transaction. LOCAL scope is
    // the current transaction, and in autocommit each statement IS one.
    println!();
    println!("-- E · set_config(local) with NO explicit transaction --------");
    {
        let mut c = pool.acquire().await?;
        c.execute("RESET ALL").await?;
        let applied: String = sqlx::query_scalar("SELECT set_config('app.tenant_id', $1, true)")
            .bind("t1")
            .fetch_one(&mut *c)
            .await?;
        // A SEPARATE statement, therefore a separate implicit transaction.
        let row = sqlx::query(
            "SELECT coalesce(current_setting('app.tenant_id', true), '<NULL>') AS guc",
        )
        .fetch_one(&mut *c)
        .await?;
        say(
            "set_config(local) then a separate statement",
            &format!("applied={applied} next statement sees guc={}", row.get::<String, _>("guc")),
        );
        // ...and the read that would have been scoped by it.
        c.execute("BEGIN ISOLATION LEVEL READ COMMITTED READ ONLY")
            .await?;
        c.execute("SET LOCAL ROLE openledger_read").await?;
        let n: i64 = sqlx::query_scalar("SELECT count(*) FROM ledger_entries")
            .fetch_one(&mut *c)
            .await?;
        c.execute("COMMIT").await?;
        say(
            "…and the read it was supposed to scope",
            &format!("entries={n}"),
        );
        // The same two calls in ONE statement DO work, which is the form that
        // makes a one-round-trip read legal.
        let row = sqlx::query(
            "WITH s AS (SELECT set_config('app.tenant_id', $1, true))
             SELECT (SELECT count(*) FROM ledger_entries) AS n FROM s",
        )
        .bind("t1")
        .fetch_one(&mut *c)
        .await;
        match row {
            Ok(r) => say(
                "one statement: WITH set_config(...) SELECT …",
                &format!("entries={} (as OWNER, unscoped by RLS)", r.get::<i64, _>("n")),
            ),
            Err(e) => say("one statement: WITH set_config(...) SELECT …", &format!("{e}")),
        }
    }

    println!();
    println!("done.");
    Ok(())
}
