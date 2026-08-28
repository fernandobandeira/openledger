//! `serve`'s startup behavior — suite-wide rather than any endpoint's, so it
//! lives at the top level: the binary must refuse to serve a database the
//! pre-deploy migrate job never reached, and its refusal must name the
//! remedy (ADR-0003 splits deploys into migrate-then-serve; this is the half
//! the serving process enforces). All three of the gate's refusal branches
//! are here: never migrated, behind this binary, and checksum mismatch.
//!
//! The last two branches are staged by SURGICAL edits to `_sqlx_migrations`
//! — sqlx's own bookkeeping table, not this project's journal and not a file
//! under `migrations/`: while the migration set is one frozen baseline, a
//! version the database honestly lacks cannot exist without slipping a
//! test-only migration into `migrations/`, which is itself the edit
//! `check-migrations-immutable.sh` refuses. Deleting the version row (or
//! doctoring its checksum) on a scratch database produces exactly the state
//! the gate's SELECTs would read mid-upgrade, with nothing else touched.

use sqlx::{Connection, PgConnection};

use crate::support::{TestResult, postgres};

#[tokio::test]
async fn serve_refuses_a_database_that_was_never_migrated() -> TestResult {
    // A scratch database with NO migrate — the state a serve rolled out
    // before its migration job would find.
    let db_url = postgres::create_scratch_db("unmigrated_serve").await?;

    let output = postgres::openledger()?
        .args(["serve", "--bind", "127.0.0.1:0"])
        .env("DATABASE_URL", &db_url)
        .output()?;

    assert_eq!(
        output.status.code(),
        Some(1),
        "serve against an unmigrated database must exit 1 (stderr: {})",
        String::from_utf8_lossy(&output.stderr)
    );
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("openledger migrate"),
        "the refusal must name the remedy `openledger migrate`; stderr was: {stderr}"
    );
    Ok(())
}

#[tokio::test]
async fn serve_refuses_a_database_behind_this_binary_naming_the_missing_version() -> TestResult {
    // A migrated database whose version row is then deleted — the state the
    // gate's "behind" branch reads when this binary embeds a migration the
    // database has not applied (the module comment says why the fixture is
    // this edit and not a real second migration).
    let db_url = postgres::create_scratch_db("behind_serve").await?;
    postgres::migrate(&db_url)?;
    let mut admin = PgConnection::connect(&db_url).await?;
    sqlx::raw_sql("DELETE FROM _sqlx_migrations WHERE version = 1")
        .execute(&mut admin)
        .await?;
    admin.close().await?;

    let output = postgres::openledger()?
        .args(["serve", "--bind", "127.0.0.1:0"])
        .env("DATABASE_URL", &db_url)
        .output()?;

    assert_eq!(
        output.status.code(),
        Some(1),
        "serve against a behind database must exit 1 (stderr: {})",
        String::from_utf8_lossy(&output.stderr)
    );
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("behind") && stderr.contains('1'),
        "the refusal must say the schema is behind and name the missing version; \
         stderr was: {stderr}"
    );
    assert!(
        stderr.contains("openledger migrate"),
        "the refusal must name the remedy `openledger migrate`; stderr was: {stderr}"
    );
    Ok(())
}

#[tokio::test]
async fn serve_refuses_a_database_whose_applied_checksum_differs() -> TestResult {
    // A migrated database whose stored checksum is then doctored — the state
    // the gate's most dangerous branch reads: "migration applied", but a
    // DIFFERENT file was. Same surgical-fixture reasoning as above; the
    // schema itself is untouched and correct, which is exactly what makes
    // this branch dangerous enough to gate on.
    let db_url = postgres::create_scratch_db("checksum_serve").await?;
    postgres::migrate(&db_url)?;
    let mut admin = PgConnection::connect(&db_url).await?;
    sqlx::raw_sql(r"UPDATE _sqlx_migrations SET checksum = '\x00' WHERE version = 1")
        .execute(&mut admin)
        .await?;
    admin.close().await?;

    let output = postgres::openledger()?
        .args(["serve", "--bind", "127.0.0.1:0"])
        .env("DATABASE_URL", &db_url)
        .output()?;

    assert_eq!(
        output.status.code(),
        Some(1),
        "serve against a checksum-mismatched database must exit 1 (stderr: {})",
        String::from_utf8_lossy(&output.stderr)
    );
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("checksum"),
        "the refusal must say the mismatch is a checksum's; stderr was: {stderr}"
    );
    Ok(())
}
