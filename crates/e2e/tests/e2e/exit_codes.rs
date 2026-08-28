//! The binary's exit-code contract, held against the compiled binary —
//! suite-wide rather than any endpoint's, so it lives at the top level.
//! `failure.rs` defines the numbers: 1 is "read the error first" (held by
//! `startup.rs`'s serve refusals), 2 is "the invocation is wrong", 3 is
//! "another migrator held the lock — safe to re-run". This file holds 2 and
//! 3, the two a deploy pipeline branches on without a human in the loop.

use sqlx::{Connection, PgConnection};

use crate::support::{TestResult, postgres};

#[tokio::test]
async fn a_malformed_bind_address_is_a_usage_error_and_exit_2() -> TestResult {
    // No database anywhere near this: clap's typed SocketAddr parser refuses
    // the flag before dispatch, and main maps every usage error — clap's or
    // ours — to the same 2.
    let output = postgres::openledger()?
        .args(["serve", "--bind", "not-an-address"])
        .output()?;

    assert_eq!(
        output.status.code(),
        Some(2),
        "a malformed --bind must exit 2 (stderr: {})",
        String::from_utf8_lossy(&output.stderr)
    );
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("--bind"),
        "the usage error must name the flag; stderr was: {stderr}"
    );
    Ok(())
}

#[tokio::test]
async fn a_migrator_that_never_gets_the_lock_exits_3_and_says_rerun() -> TestResult {
    // Hold the migrator's advisory lock from an admin session. The literal
    // is migrate.rs's LOCK_KEY — the ASCII bytes of `openledg` as a
    // big-endian i64, written down there so it can never shift under a
    // library upgrade. Advisory locks are namespaced PER DATABASE (the lock
    // tag carries the database OID), so holding it on this scratch database
    // blocks only this database's migrator — sibling tests migrating their
    // own scratch databases never see it, which is also why this test needs
    // no migrate-mutex: the contender below never reaches any DDL.
    let db_url = postgres::create_scratch_db("locked_migrate").await?;
    let mut holder = PgConnection::connect(&db_url).await?;
    sqlx::raw_sql("SELECT pg_advisory_lock(x'6F70656E6C656467'::bigint)")
        .execute(&mut holder)
        .await?;

    // A one-second budget: long enough to prove the poll loop polls, short
    // enough to keep the suite honest.
    let output = postgres::openledger()?
        .args(["migrate", "--lock-secs", "1"])
        .env("DATABASE_URL", &db_url)
        .output()?;

    assert_eq!(
        output.status.code(),
        Some(3),
        "a migrator that never gets the lock must exit 3 (stderr: {})",
        String::from_utf8_lossy(&output.stderr)
    );
    // Exit 3's whole point is the operator instruction: giving up is safe to
    // re-run, and the message must say so.
    let stderr = String::from_utf8_lossy(&output.stderr).to_lowercase();
    assert!(
        stderr.contains("giving up") && stderr.contains("re-run"),
        "the lock failure must say it gave up and is safe to re-run; stderr was: {stderr}"
    );

    holder.close().await?;
    Ok(())
}
