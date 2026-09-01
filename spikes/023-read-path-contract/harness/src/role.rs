//! Q2 — assuming the read role, and where its connections come from.
//!
//! Two candidate shapes, both measured on real `sqlx::PgPool`s:
//!
//!   * **shared pool** — the serving process's one pool
//!     (`crates/db`, `POOL_CONNECTIONS = 38`), with the read path issuing
//!     `SET LOCAL ROLE openledger_read` inside its transaction and the writer
//!     using the same connections;
//!   * **its own pool** — a second pool whose `after_connect` issues
//!     `SET ROLE openledger_read` **once per connection**, so the role is a
//!     property of the connection rather than of the request.
//!
//! Every pool here is `max_connections(1)`, which makes "the connection the
//! next request gets" deterministic: a leak becomes a fact instead of a race.
//!
//! Also here, because it is the same mechanism: the RLS plan-cache question
//! ADR-0013's cost list raises and does not resolve — *"both recent RLS
//! plan-cache CVEs came from role switching"* — tested against sqlx's
//! per-connection prepared-statement cache, which is keyed by SQL text and so
//! is exactly the shape those CVEs describe.

use std::time::Duration;

use sqlx::postgres::{PgConnectOptions, PgPoolOptions};
use sqlx::{Executor, PgPool, Row};

const SESSION_TIMEOUTS: &str = "\
    SET statement_timeout = '30s'; \
    SET lock_timeout = '10s'; \
    SET idle_in_transaction_session_timeout = '60s'";

fn say(case: &str, detail: &str) {
    println!("{case:<58} {detail}");
}

/// The serving process's pool shape: nothing assumed about the role.
async fn writer_shaped_pool(url: &str) -> Result<PgPool, sqlx::Error> {
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

/// The candidate read pool: the role is assumed once, on connect, and never
/// again. Nothing per request can forget it and nothing per request can undo
/// it for the next caller, because there is no per-request role statement at
/// all.
async fn reader_shaped_pool(url: &str, timeout: &'static str) -> Result<PgPool, sqlx::Error> {
    // The timeout is a &'static str from this file, never caller input; sqlx's
    // raw_sql lint wants the string built where it can see it, so the two
    // variants are spelled out rather than formatted.
    let setup: &'static str = match timeout {
        "90s" => "SET statement_timeout = '90s'; SET lock_timeout = '10s'; \
                  SET idle_in_transaction_session_timeout = '60s'; SET ROLE openledger_read",
        _ => "SET statement_timeout = '30s'; SET lock_timeout = '10s'; \
              SET idle_in_transaction_session_timeout = '60s'; SET ROLE openledger_read",
    };
    let options: PgConnectOptions = url.parse()?;
    Ok(PgPoolOptions::new()
        .max_connections(1)
        .min_connections(0)
        .idle_timeout(Duration::from_secs(5))
        .acquire_timeout(Duration::from_secs(15))
        .after_connect(move |conn, _meta| {
            Box::pin(async move {
                sqlx::raw_sql(setup).execute(conn).await?;
                Ok(())
            })
        })
        .connect_lazy_with(options))
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let url = std::env::var("DATABASE_URL")?;

    println!("== Q2 · assuming the read role ==");
    println!();

    // ---------------------------------------------------------------- A
    // The hazard in the direction that costs money: a session SET ROLE
    // survives the checkout and the next caller is the WRITER.
    println!("-- A · session SET ROLE, returned to the pool, next caller writes --");
    {
        let pool = writer_shaped_pool(&url).await?;
        {
            let mut c = pool.acquire().await?;
            c.execute("SET ROLE openledger_read").await?;
            let who: String = sqlx::query_scalar("SELECT current_user::text")
                .fetch_one(&mut *c)
                .await?;
            say("checkout 1: SET ROLE openledger_read", &format!("current_user={who}"));
        }
        {
            let mut c = pool.acquire().await?;
            let who: String = sqlx::query_scalar("SELECT current_user::text")
                .fetch_one(&mut *c)
                .await?;
            // A write shaped like the writer's: the account row the write path
            // touches on every posting. INSERT is the grant openledger_read
            // does not hold.
            let attempt = sqlx::query(
                "INSERT INTO ledger_accounts
                        (tenant_id, owner_type, owner_id, purpose, category,
                         normal_balance, counterparty_scope, currency)
                 VALUES ('t1','house',NULL,'interchange_revenue','revenue','credit','none','USD')",
            )
            .execute(&mut *c)
            .await;
            say(
                "checkout 2: the WRITER's next posting",
                &match attempt {
                    Ok(_) => format!("current_user={who} INSERT SUCCEEDED (unexpected)"),
                    Err(e) => format!("current_user={who} INSERT REFUSED: {e}"),
                },
            );
        }
        pool.close().await;
    }

    // ---------------------------------------------------------------- B
    // SET LOCAL ROLE: scoped to the transaction, so the connection goes back
    // as the login it was.
    println!();
    println!("-- B · SET LOCAL ROLE inside the read's own transaction ------");
    {
        let pool = writer_shaped_pool(&url).await?;
        {
            let mut c = pool.acquire().await?;
            c.execute("BEGIN ISOLATION LEVEL READ COMMITTED READ ONLY").await?;
            c.execute("SET LOCAL ROLE openledger_read").await?;
            // Order matters: the GUC is set AFTER the role change, so it is
            // set under the read role's privileges. `app.` is a placeholder
            // namespace, so it is USERSET — but that is a claim, so test it.
            let applied: Result<String, _> =
                sqlx::query_scalar("SELECT set_config('app.tenant_id', $1, true)")
                    .bind("t1")
                    .fetch_one(&mut *c)
                    .await;
            let inside: String = sqlx::query_scalar("SELECT current_user::text")
                .fetch_one(&mut *c)
                .await?;
            let n: i64 = sqlx::query_scalar("SELECT count(*) FROM ledger_entries")
                .fetch_one(&mut *c)
                .await?;
            say(
                "inside: SET LOCAL ROLE then set_config as that role",
                &format!(
                    "current_user={inside} set_config={:?} entries={n}",
                    applied.as_ref().map(String::as_str).map_err(|e| e.to_string())
                ),
            );
            c.execute("COMMIT").await?;
            let after: String = sqlx::query_scalar("SELECT current_user::text")
                .fetch_one(&mut *c)
                .await?;
            say("same connection, after COMMIT", &format!("current_user={after}"));
        }
        {
            let mut c = pool.acquire().await?;
            let who: String = sqlx::query_scalar("SELECT current_user::text")
                .fetch_one(&mut *c)
                .await?;
            say("next checkout", &format!("current_user={who}"));
        }
        pool.close().await;
    }

    // ---------------------------------------------------------------- C
    // Does it survive an error and a ROLLBACK? A failed read must not leave
    // the connection wearing the read role.
    println!();
    println!("-- C · an error inside the read transaction, then ROLLBACK ---");
    {
        let pool = writer_shaped_pool(&url).await?;
        {
            let mut c = pool.acquire().await?;
            c.execute("BEGIN ISOLATION LEVEL READ COMMITTED READ ONLY").await?;
            c.execute("SET LOCAL ROLE openledger_read").await?;
            let boom = sqlx::query("SELECT 1/0").fetch_one(&mut *c).await;
            say(
                "the read raises",
                &format!("{}", boom.err().map(|e| e.to_string()).unwrap_or_else(|| "no error".into())),
            );
            c.execute("ROLLBACK").await?;
            let after: String = sqlx::query_scalar("SELECT current_user::text")
                .fetch_one(&mut *c)
                .await?;
            let guc: String =
                sqlx::query_scalar("SELECT coalesce(current_setting('app.tenant_id', true), '<NULL>')")
                    .fetch_one(&mut *c)
                    .await?;
            say("after ROLLBACK", &format!("current_user={after} guc={guc:?}"));
        }
        pool.close().await;
    }

    // ---------------------------------------------------------------- D
    // The candidate: the role assumed in after_connect, and only the GUC per
    // request. Nothing per request can forget the role, because there is no
    // per-request role statement.
    println!();
    println!("-- D · a dedicated read pool, SET ROLE in after_connect ------");
    {
        let pool = reader_shaped_pool(&url, "30s").await?;
        {
            let mut c = pool.acquire().await?;
            let who: String = sqlx::query_scalar("SELECT current_user::text")
                .fetch_one(&mut *c)
                .await?;
            let n: i64 = sqlx::query_scalar("SELECT count(*) FROM ledger_entries")
                .fetch_one(&mut *c)
                .await?;
            say(
                "fresh connection, nothing set per request",
                &format!("current_user={who} entries={n}"),
            );
        }
        {
            let mut c = pool.acquire().await?;
            c.execute("BEGIN ISOLATION LEVEL READ COMMITTED READ ONLY").await?;
            let _: String = sqlx::query_scalar("SELECT set_config('app.tenant_id', $1, true)")
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
            c.execute("COMMIT").await?;
            say(
                "one request: transaction + set_config, no role statement",
                &format!(
                    "entries={} tenants={}",
                    row.get::<i64, _>("n"),
                    row.get::<String, _>("tenants")
                ),
            );
        }
        {
            // …and can a caller on this pool climb back out to the login?
            // RESET ROLE is what a hostile or buggy read would reach for.
            let mut c = pool.acquire().await?;
            let reset = c.execute("RESET ROLE").await;
            let who: String = sqlx::query_scalar("SELECT current_user::text")
                .fetch_one(&mut *c)
                .await?;
            say(
                "RESET ROLE on a read-pool connection",
                &format!("{:?} current_user={who}", reset.map(|_| "ok").map_err(|e| e.to_string())),
            );
        }
        pool.close().await;
    }

    // ---------------------------------------------------------------- E
    // The plan-cache question. sqlx caches prepared statements per connection,
    // keyed by SQL text. Prepare under one (role, GUC) pair and execute under
    // another: if the cached plan carried the first pair's RLS qual, the second
    // execution reads the wrong tenant. Same text, three times, on ONE
    // connection.
    println!();
    println!("-- E · sqlx's prepared-statement cache across a role/GUC change --");
    {
        let pool = writer_shaped_pool(&url).await?;
        let mut c = pool.acquire().await?;
        const Q: &str = "SELECT count(*)::int8 AS n,
                                coalesce(string_agg(DISTINCT tenant_id, ','), '<none>') AS tenants
                         FROM ledger_entries";
        // 1. as the OWNER, unscoped — RLS does not apply to the owner at all
        //    (FORCE ROW LEVEL SECURITY deliberately not set, ADR-0013), so the
        //    first plan is prepared with no RLS qual whatsoever. This is the
        //    worst case for a cache that fails to replan.
        let r = sqlx::query(Q).fetch_one(&mut *c).await?;
        say(
            "1st execution: OWNER, no GUC",
            &format!("entries={} tenants={}", r.get::<i64, _>("n"), r.get::<String, _>("tenants")),
        );
        // 2. same text, same connection, now as the reader scoped to t1
        c.execute("BEGIN ISOLATION LEVEL READ COMMITTED READ ONLY").await?;
        c.execute("SET LOCAL ROLE openledger_read").await?;
        let _: String = sqlx::query_scalar("SELECT set_config('app.tenant_id', $1, true)")
            .bind("t1")
            .fetch_one(&mut *c)
            .await?;
        let r = sqlx::query(Q).fetch_one(&mut *c).await?;
        say(
            "2nd execution: same text, reader scoped to t1",
            &format!("entries={} tenants={}", r.get::<i64, _>("n"), r.get::<String, _>("tenants")),
        );
        // 3. same text, same connection, same transaction, GUC moved to t2
        let _: String = sqlx::query_scalar("SELECT set_config('app.tenant_id', $1, true)")
            .bind("t2")
            .fetch_one(&mut *c)
            .await?;
        let r = sqlx::query(Q).fetch_one(&mut *c).await?;
        say(
            "3rd execution: same text, GUC moved to t2",
            &format!("entries={} tenants={}", r.get::<i64, _>("n"), r.get::<String, _>("tenants")),
        );
        c.execute("COMMIT").await?;
        // 4. and back out to the owner on the same connection
        let r = sqlx::query(Q).fetch_one(&mut *c).await?;
        say(
            "4th execution: same text, back to the OWNER",
            &format!("entries={} tenants={}", r.get::<i64, _>("n"), r.get::<String, _>("tenants")),
        );
        drop(c);
        pool.close().await;
    }

    // ---------------------------------------------------------------- F
    // The empty-string GUC. `RESET app.tenant_id` on a placeholder GUC does
    // NOT restore NULL — it restores '' — so the fail-closed property after a
    // RESET rests on something other than NULL semantics, and the baseline's
    // comment only names NULL.
    println!();
    println!("-- F · what RESET leaves behind, and what then fails closed --");
    {
        let pool = writer_shaped_pool(&url).await?;
        let mut c = pool.acquire().await?;
        let fresh: Option<String> =
            sqlx::query_scalar("SELECT current_setting('app.tenant_id', true)")
                .fetch_one(&mut *c)
                .await?;
        say("fresh connection, never SET", &format!("current_setting => {fresh:?}"));
        c.execute("SET app.tenant_id = 't1'").await?;
        c.execute("RESET app.tenant_id").await?;
        let after: Option<String> =
            sqlx::query_scalar("SELECT current_setting('app.tenant_id', true)")
                .fetch_one(&mut *c)
                .await?;
        say("after SET then RESET", &format!("current_setting => {after:?}"));
        // Does an empty-string GUC read anything? Only if a tenant could be
        // named ''. Every tenant-keyed table carries
        // ck_*__tenant_non_empty CHECK (btrim(tenant_id) <> ''), so try it.
        c.execute("BEGIN").await?;
        let forge = sqlx::query(
            "INSERT INTO ledger_accounts
                    (tenant_id, owner_type, owner_id, purpose, category,
                     normal_balance, counterparty_scope, currency)
             VALUES ('', 'house', NULL, 'fee_revenue','revenue','credit','none','USD')",
        )
        .execute(&mut *c)
        .await;
        say(
            "can a tenant be named ''? (as the OWNER, no less)",
            &match forge {
                Ok(_) => "ACCEPTED — the empty-string GUC is then a HOLE".to_string(),
                Err(e) => format!("REFUSED: {e}"),
            },
        );
        c.execute("ROLLBACK").await?;
        drop(c);
        pool.close().await;
    }

    // ---------------------------------------------------------------- G
    // Does the read pool's own statement_timeout stick? The candidate answer
    // to Q5 is a longer timeout for reads than the writer's 30s, and it is
    // only available if it is a property of the pool.
    println!();
    println!("-- G · a read pool with its own statement_timeout ------------");
    {
        let pool = reader_shaped_pool(&url, "90s").await?;
        let mut c = pool.acquire().await?;
        let st: String = sqlx::query_scalar("SHOW statement_timeout")
            .fetch_one(&mut *c)
            .await?;
        let who: String = sqlx::query_scalar("SELECT current_user::text")
            .fetch_one(&mut *c)
            .await?;
        say(
            "read pool after_connect: 90s",
            &format!("statement_timeout={st} current_user={who}"),
        );
        // ...and can the read role raise it itself? statement_timeout is
        // USERSET, so a per-request override is available without a second
        // pool at all — which is a real alternative and has to be stated.
        c.execute("BEGIN ISOLATION LEVEL READ COMMITTED READ ONLY").await?;
        let bump = c.execute("SET LOCAL statement_timeout = '120s'").await;
        let st: String = sqlx::query_scalar("SHOW statement_timeout")
            .fetch_one(&mut *c)
            .await?;
        c.execute("COMMIT").await?;
        say(
            "SET LOCAL statement_timeout as openledger_read",
            &format!("{:?} => {st}", bump.map(|_| "ok").map_err(|e| e.to_string())),
        );
        drop(c);
        pool.close().await;
    }

    println!();
    println!("done.");
    Ok(())
}
