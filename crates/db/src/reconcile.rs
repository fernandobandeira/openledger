//! `openledger reconcile` — one snapshot, ten checks, an exit code.
//!
//! This is ADR-0010 (`site/content/decisions/0010-reconciliation.md`) in code:
//! the daily sweep an operator schedules, the same shape as `openledger
//! migrate` — a command, not a step that happens invisibly. The ADR carries
//! the reasoning and the measurements; three of its rulings shape this file.
//!
//! **1. One `REPEATABLE READ READ ONLY` transaction.** The family of views is
//! many statements, and under `READ COMMITTED` each takes its own snapshot —
//! the ADR demonstrates a repair committing mid-sweep leaving the summary
//! counting one break while the list enumerating it returns zero rows. One
//! snapshot makes the ten numbers one book. Safe here in a way it is not on
//! the write path: this transaction writes nothing, takes `ACCESS SHARE` and
//! nothing else, and so cannot block a posting.
//!
//! **2. As `openledger_recon`, the role that cannot write what it checks.**
//! The views grant to it and not to `openledger_app`, which holds `UPDATE` on
//! `ledger_account_balances` — the number `recon_balance_breaks` checks. The
//! role is `NOLOGIN` (the baseline names roles for what they may do, never
//! for who logs in), so the sweep assumes it with `SET ROLE` after
//! connecting; the login behind DATABASE_URL only needs membership.
//!
//! **3. The summary is the whole operator interface.** `SELECT * FROM
//! reconciliation` — ten rows, one per check, `breaks = 0` on each — becomes
//! the exit code. The row COUNT is asserted too, because this project has
//! already shipped a check that was empty for the wrong reason: ADR-0010
//! quotes the `TRUNCATE` where "silence read as assent". Ten zeros pass; a
//! missing row does not.

use sqlx::postgres::PgConnectOptions;
use sqlx::{Connection, Executor, PgConnection};

use crate::{ReconcileError, say};

/// How many checks the summary view returns — one row per check, always,
/// which is what makes the count assertable at all (ADR-0010: a check that
/// returns nothing because it was never run is indistinguishable from one
/// that passed). Ten at the merged baseline; a migration that adds a check
/// changes this number in the same change, and the e2e oracle pins the same
/// ten (`crates/e2e/tests/e2e/support/book.rs`).
const EXPECTED_CHECKS: usize = 10;

pub async fn run(database_url: &str) -> Result<(), ReconcileError> {
    let options: PgConnectOptions = database_url
        .parse()
        .map_err(|e| ReconcileError::Usage(format!("could not parse the database URL: {e}")))?;

    // Named, so an operator watching pg_stat_activity can tell the sweep
    // from the ledger it is checking.
    let mut conn = PgConnection::connect_with(&options.application_name("openledger-reconcile"))
        .await
        .map_err(|e| ReconcileError::Failed(format!("could not connect: {e}")))?;

    assume_recon_role(&mut conn).await?;

    // Elapsed-ms for the summary line below: operator-facing monotonic
    // timing in a scheduled job's log, not ledger time (clippy.toml
    // disallows ambient clocks workspace-wide). The number matters here —
    // the sweep is a linear scan of the journal, and ADR-0010 tells
    // deployments to budget it as linear and re-measure at their size.
    #[expect(
        clippy::disallowed_methods,
        reason = "operator-facing elapsed time in the sweep log, not ledger time"
    )]
    let started = std::time::Instant::now();
    let checks = sweep_in_one_snapshot(&mut conn).await;
    let _ = conn.close().await;
    let checks = checks?;

    if checks.len() != EXPECTED_CHECKS {
        return Err(ReconcileError::Failed(format!(
            "the reconciliation view returned {} check(s) where this binary expects \
             {EXPECTED_CHECKS} — a summary missing a check is silence read as assent \
             (ADR-0010). The schema and this binary disagree; run `openledger migrate` \
             with the binary that owns this database's schema before trusting a sweep.",
            checks.len()
        )));
    }

    refuse_drift(&checks)?;

    say(&format!(
        "book reconciled — {EXPECTED_CHECKS} checks, 0 breaks, {} ms",
        started.elapsed().as_millis()
    ));
    Ok(())
}

/// `SET ROLE openledger_recon`: from here every read runs under the sweep
/// role's grants, whatever the login behind DATABASE_URL may hold. The role
/// is what ADR-0010 grants the views to, and the refusal message carries the
/// remedy because the likeliest failure is a login that was never made a
/// member.
async fn assume_recon_role(conn: &mut PgConnection) -> Result<(), ReconcileError> {
    conn.execute("SET ROLE openledger_recon")
        .await
        .map_err(|e| {
            ReconcileError::Failed(format!(
                "could not assume the openledger_recon role: {e}. The sweep runs as the \
                 role the reconciliation views grant to (ADR-0010) — connect as a login \
                 that is a member of it (GRANT openledger_recon TO <login>), or as a \
                 role allowed to SET ROLE to it."
            ))
        })
        .map(|_| ())
}

/// The ten summary rows, read inside one `REPEATABLE READ READ ONLY`
/// transaction — opened and closed here, so the snapshot lives exactly as
/// long as the one statement that needs it. The transaction pins the
/// cluster's xmin horizon while it runs (ADR-0010 names that cost), which is
/// one more reason not to hold it around anything else.
///
/// Honesty about what each half buys TODAY: the sweep is a single statement,
/// and a single statement is one snapshot at every isolation level, so
/// `REPEATABLE READ` changes nothing observable until the sweep grows a
/// second statement — it is declared now because ADR-0010 specifies the
/// transaction shape and the multi-statement sweep (per-tenant bounding) is
/// the ADR's own growth path, and declaring it then would be a behaviour
/// change nobody reviews. `READ ONLY` binds immediately and is held red-path
/// by the e2e suite (a write smuggled into the summary's read path is
/// refused by the transaction, not by a grant).
async fn sweep_in_one_snapshot(
    conn: &mut PgConnection,
) -> Result<Vec<(String, i64)>, ReconcileError> {
    conn.execute("BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY")
        .await
        .map_err(|e| {
            ReconcileError::Failed(format!("could not open the sweep transaction: {e}"))
        })?;
    let checks: Vec<(String, i64)> =
        sqlx::query_as("SELECT check_name, breaks FROM reconciliation ORDER BY check_name")
            .fetch_all(&mut *conn)
            .await
            .map_err(|e| {
                ReconcileError::Failed(format!("could not read the reconciliation view: {e}"))
            })?;
    // Read-only, so COMMIT and ROLLBACK are the same ending; COMMIT states
    // that nothing failed.
    conn.execute("COMMIT").await.map_err(|e| {
        ReconcileError::Failed(format!("could not close the sweep transaction: {e}"))
    })?;
    Ok(checks)
}

/// Zero breaks on every check passes; anything else is `Drift`, with every
/// breaking check named in the message — the summary is the operator
/// interface, and the matching `recon_*` break list holds the rows. What to
/// do next is deliberately NOT decided here: ADR-0010's disposition table
/// says only the cache is ever repaired, and nothing that touches the
/// journal is repaired by this layer at all.
fn refuse_drift(checks: &[(String, i64)]) -> Result<(), ReconcileError> {
    let breaking: Vec<&(String, i64)> = checks.iter().filter(|(_, breaks)| *breaks != 0).collect();
    if breaking.is_empty() {
        return Ok(());
    }
    let mut message = format!(
        "reconciliation found breaks in {} of {EXPECTED_CHECKS} checks:",
        breaking.len()
    );
    for (check, breaks) in breaking {
        message.push_str(&format!("\n  {check}: {breaks} break(s)"));
    }
    message.push_str(
        "\nThe matching recon_* break list carries the rows. ADR-0010's disposition \
         table says what may be repaired (the cache, from the journal) and what must \
         never be (anything on the journal — there a repair is a new transaction).",
    );
    Err(ReconcileError::Drift(message))
}
