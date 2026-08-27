//! `openledger migrate` — take a lock, apply what is pending, exit.
//!
//! This is ADR-0003 (`site/content/decisions/0003-migrations.md`) in code. Two things
//! here are not the library's defaults; the ADR carries the reasoning and the
//! measurements, and this file does not restate them.
//!
//! **1. `sqlx`'s own locking is off, and ours replaces it.** `sqlx` takes
//! `pg_advisory_lock`, which *blocks* — and a blocked migrator is a live
//! transaction that `CREATE INDEX CONCURRENTLY` waits for, so two migrators and
//! one concurrent index build deadlock. A try-lock in a poll never joins that
//! cycle: it asks, fails, and sleeps outside any transaction.
//!
//! **2. Nothing here migrates downwards.** `sqlx::migrate!` would compile a
//! `.down.sql` into the binary without comment, so that rule is a test at the
//! bottom of this file rather than a sentence in a document.
//!
//! **Everything else is deliberately still `sqlx`'s** — the version table, the
//! checksum comparison, the dirty-version check, and the transaction per
//! migration. In particular this file does **not** work out what is pending
//! before running. An earlier version did, to log it, and returned early when
//! that list came back empty. That skipped `Migrator::run`'s dirty-version,
//! checksum and missing-version checks on precisely the run a re-deploy
//! performs, and it resolved the version table through `search_path` where
//! `sqlx` resolves it through the creation namespace — so against two schemas it
//! reported success on a database it had never migrated. `run()` is cheap on an
//! already-migrated database, and those three checks are the reason to call it
//! anyway.

use std::time::{Duration, Instant};

use sqlx::postgres::PgConnectOptions;
use sqlx::{Connection, Executor, PgConnection};

use crate::{Failure, say};

/// The advisory-lock key every `openledger migrate` competes for. It is the
/// ASCII bytes of `openledg` read as a big-endian i64 — arbitrary, but a
/// literal rather than a hash, so it can never shift under a library upgrade.
/// Advisory locks share one namespace per database: a key collision with
/// another application means the two block each other, which is why this is
/// written down rather than derived.
///
/// NOTE that `sqlx-cli` does not take this lock. `sqlx migrate run` computes its
/// own key from the database name, so a developer reaching for the obvious tool
/// runs DDL beside us with nothing in the way. Use this binary.
const LOCK_KEY: i64 = 0x6F70_656E_6C65_6467;

/// How often to re-ask for the lock. Short enough that a normal handover is not
/// noticeable, long enough that a fifteen-minute wait is 900 queries.
const POLL_INTERVAL: Duration = Duration::from_secs(1);

/// DDL takes `ACCESS EXCLUSIVE`, and PostgreSQL queues lock requests **in
/// order** — so a migrator waiting behind one long-running reader puts every
/// later query on that table behind *it* as well. That is a full ledger stall
/// caused by a migration that has not started yet, and it lasts as long as the
/// reader does. Failing fast is the better trade for a job that can be re-run.
/// `CREATE INDEX CONCURRENTLY` is unaffected: its lock acquisitions are brief,
/// and one that cannot be taken in five seconds should fail rather than queue.
const LOCK_TIMEOUT_TEXT: &str = "5s";
const SET_LOCK_TIMEOUT: &str = "SET lock_timeout = '5s'";

pub async fn run(database_url: &str, lock_wait: Duration) -> Result<(), Failure> {
    let options: PgConnectOptions = database_url
        .parse()
        .map_err(|e| Failure::Usage(format!("could not parse the database URL: {e}")))?;

    // Named, so that the failure path below can say who is holding the lock.
    let mut conn = PgConnection::connect_with(&options.application_name("openledger-migrate"))
        .await
        .map_err(|e| Failure::Failed(format!("could not connect: {e}")))?;

    conn.execute(SET_LOCK_TIMEOUT)
        .await
        .map_err(|e| Failure::Failed(format!("could not set lock_timeout: {e}")))?;

    if !acquire_lock(&mut conn, lock_wait).await? {
        return Err(Failure::Locked(format!(
            "another migrator has held the lock for {}s — giving up.{}",
            lock_wait.as_secs(),
            lock_holder(&mut conn).await
        )));
    }

    // The lock is held from here, so both exit paths below release it. An
    // unwind would not, which is why nothing between here and there panics:
    // output goes through `say`, and there is no indexing or arithmetic.
    let outcome = apply(&mut conn).await;
    release_lock(&mut conn).await;
    outcome
}

async fn apply(conn: &mut PgConnection) -> Result<(), Failure> {
    // The migrations, compiled into the binary by this macro. The deploy image
    // therefore carries no migration files, which is what lets the same image
    // run as both the ledger and its pre-deploy job.
    let mut migrator = sqlx::migrate!("./migrations");
    migrator.set_locking(false); // see the module comment — ours is the try-lock above

    let started = Instant::now();
    migrator.run(conn).await.map_err(classify)?;

    // Every migration the binary carries is applied by the time `run` returns,
    // so this needs no second look at the database to be true.
    say(&format!(
        "schema up to date — {} applied or already present, {} ms",
        plural(migrator.iter().count()),
        started.elapsed().as_millis()
    ));
    Ok(())
}

/// A migration that timed out taking its table lock is the one failure here that
/// is *safe to re-run*, and it is the failure `SET lock_timeout` exists to
/// produce — so it must not exit 1, which this binary defines as "do not retry
/// blindly". PostgreSQL raises `55P03 lock_not_available` for it.
fn classify(error: sqlx::migrate::MigrateError) -> Failure {
    let blocked = match &error {
        sqlx::migrate::MigrateError::Execute(sqlx::Error::Database(db))
        | sqlx::migrate::MigrateError::ExecuteMigration(sqlx::Error::Database(db), _) => {
            db.code().as_deref() == Some("55P03")
        }
        _ => false,
    };

    if blocked {
        Failure::Locked(format!(
            "a migration could not take its table lock within {LOCK_TIMEOUT_TEXT}. Something \
             long-running is holding it; nothing was half-applied. Re-run this job. ({error})"
        ))
    } else {
        Failure::Failed(format!("migration failed: {error}"))
    }
}

/// Ask for the lock; if someone else holds it, sleep and ask again until the
/// budget runs out. Returns `false` when it ran out — a *visible, re-runnable*
/// failure, which under a pre-deploy job is the failure we want.
async fn acquire_lock(conn: &mut PgConnection, budget: Duration) -> Result<bool, Failure> {
    let deadline = Instant::now()
        .checked_add(budget)
        .ok_or_else(|| Failure::Usage("the lock budget is too large".to_owned()))?;
    let mut announced = false;

    loop {
        let (acquired,): (bool,) = sqlx::query_as("SELECT pg_try_advisory_lock($1)")
            .bind(LOCK_KEY)
            .fetch_one(&mut *conn)
            .await
            .map_err(|e| Failure::Failed(format!("could not take the migration lock: {e}")))?;

        if acquired {
            if announced {
                say("lock acquired");
            }
            return Ok(true);
        }
        if Instant::now() >= deadline {
            return Ok(false);
        }
        if !announced {
            say(&format!(
                "another migrator holds the lock — waiting up to {}s",
                budget.as_secs()
            ));
            announced = true;
        }
        tokio::time::sleep(POLL_INTERVAL).await;
    }
}

/// Who is holding it, for the message an operator actually reads. Best effort:
/// this runs on a path that has already failed, so a failure here is silence
/// rather than a second error. Without it the operator is told only that
/// *someone* holds the lock, and finding out means knowing to query `pg_locks`
/// for a magic integer.
async fn lock_holder(conn: &mut PgConnection) -> String {
    let found: Result<Option<(i32, String, String)>, _> = sqlx::query_as(
        "SELECT a.pid, coalesce(a.application_name, '(unnamed)'), a.state
           FROM pg_locks l
           JOIN pg_stat_activity a ON a.pid = l.pid
          WHERE l.locktype = 'advisory' AND l.objsubid = 1
            AND ((l.classid::bigint << 32) | l.objid::bigint) = $1
          LIMIT 1",
    )
    .bind(LOCK_KEY)
    .fetch_optional(conn)
    .await;

    match found {
        Ok(Some((pid, name, state))) => {
            format!(
                " Held by pid {pid} ({name}), {state}. If that process is gone, its backend may still be finishing; re-run this job."
            )
        }
        // No holder visible: the lock was released between the last poll and
        // now, or the holder's backend is on another database's view.
        Ok(None) => " No holder is visible now — re-run this job.".to_owned(),
        Err(_) => " Re-run this job.".to_owned(),
    }
}

/// Closing the connection releases it too, but only once the socket teardown
/// completes. Releasing it explicitly means a job that retries immediately does
/// not race the previous process's `close()`.
async fn release_lock(conn: &mut PgConnection) {
    if let Err(e) = sqlx::query("SELECT pg_advisory_unlock($1)")
        .bind(LOCK_KEY)
        .execute(conn)
        .await
    {
        eprintln!("openledger: could not release the migration lock: {e}");
    }
}

fn plural(count: usize) -> String {
    match count {
        1 => "1 migration".to_owned(),
        n => format!("{n} migrations"),
    }
}

#[cfg(test)]
mod tests {
    /// ADR-0003: **no down migrations.** A down migration on a ledger is a lie
    /// or data loss — `DROP COLUMN` destroys real state, `DROP INDEX` restores
    /// an index the data may no longer satisfy, and neither brings rows back.
    /// `sqlx::migrate!` compiles a `.down.sql` in without comment, so the rule
    /// needs a test rather than a sentence.
    #[test]
    fn there_are_no_down_migrations() {
        for migration in sqlx::migrate!("./migrations").iter() {
            assert!(
                !migration.migration_type.is_down_migration(),
                "migration {} is a down migration; ADR-0003 forbids them",
                migration.version
            );
        }
    }

    /// ADR-0003's most expensive finding, and one this project has now learned
    /// twice across two tool changes: `sqlx` sends a migration file as a single
    /// *simple query*, and PostgreSQL runs a multi-statement simple query inside
    /// an implicit transaction block. So `-- no-transaction` parses correctly
    /// and `CREATE INDEX CONCURRENTLY` still fails with *cannot run inside a
    /// transaction block*. A no-transaction migration must hold exactly one
    /// statement, which means the idempotent drop/create pair is two files.
    ///
    /// The counter is a heuristic — it does not understand semicolons inside
    /// string literals or dollar-quoted bodies — and it errs toward failing,
    /// which for a rule this cheap to satisfy is the right direction.
    #[test]
    fn no_transaction_migrations_hold_exactly_one_statement() {
        for migration in sqlx::migrate!("./migrations").iter() {
            if !migration.no_tx {
                continue;
            }
            let statements = statement_count(migration.sql.as_str());
            assert_eq!(
                statements, 1,
                "migration {} is marked `-- no-transaction` and holds {statements} statements; \
                 PostgreSQL would run them in an implicit transaction block. Split it.",
                migration.version
            );
        }
    }

    fn statement_count(sql: &str) -> usize {
        sql.lines()
            .map(|line| line.split_once("--").map_or(line, |(code, _)| code))
            .collect::<Vec<_>>()
            .join("\n")
            .split(';')
            .filter(|statement| !statement.trim().is_empty())
            .count()
    }
}
