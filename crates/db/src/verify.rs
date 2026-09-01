//! `serve`'s startup gate: is the schema this binary was compiled against
//! actually in the database? ADR-0003 splits the deployment in two — migrate
//! is a pre-deploy job, and **the ledger process never migrates** — which
//! leaves a gap this check closes: a serve rolled out against a database the
//! job never reached would otherwise fail request by request, at runtime, in
//! whatever query first touched a missing table.

use crate::Database;

/// Refuse to serve a database whose schema is not the one this binary was
/// compiled against. A database AHEAD of the binary — applied versions this
/// binary does not embed — passes: that is the tolerance a rolling restart
/// needs, where the old binary keeps serving while the new one migrates.
/// Three failures, each with the remedy in the message,
/// all exit 1 in the binary: no `_sqlx_migrations` table (never migrated),
/// applied-and-successful versions missing some of the embedded migrator's
/// (behind this binary), or an applied version whose **checksum** differs
/// from the embedded copy — a database that answers "migration applied" but
/// applied a *different file* is the most dangerous of the three, because
/// every query would run and some would be quietly wrong.
///
/// Lock-FREE, and that is the point, not an optimization: this runs on the
/// serving path, and ADR-0003's split only holds if serving never contends
/// with a migrator. Plain SELECTs take no advisory lock and no DDL lock, so
/// a migrator mid-run is never blocked by — and never blocks — a starting
/// server. (A migrator committing concurrently can at worst make this read
/// see one version fewer; the operator re-runs serve after the job, which
/// is the documented order anyway.)
///
/// `_sqlx_migrations` is resolved through `search_path`, unqualified —
/// exactly how sqlx's own migrator reads it on this same URL.
///
/// Coverage note: all three branches are held end to end
/// (`crates/e2e/tests/e2e/startup.rs`). The never-migrated branch runs on a
/// database migrate never touched; the behind and checksum-mismatch branches
/// are staged by surgical edits to `_sqlx_migrations` — sqlx's bookkeeping
/// table, not this project's journal and not `migrations/` — because while
/// the migration set is one frozen baseline, no honest mid-upgrade fixture
/// exists (startup.rs and ADR-0015 both say so). This crate's own tests stay
/// deliberately database-free (migrate.rs's test module states why).
pub async fn verify_schema_is_current(database: &Database) -> Result<(), String> {
    let pool = database.pool();
    refuse_an_unmigrated_database(pool).await?;
    let applied = applied_migration_checksums(pool).await?;
    let (missing, mismatched) = drift_from_the_embedded_migrations(&applied);

    if !missing.is_empty() {
        return Err(format!(
            "the schema is behind this binary: migration(s) {} not applied. \
             Run `openledger migrate` first (ADR-0003).",
            missing.join(", ")
        ));
    }
    if !mismatched.is_empty() {
        return Err(format!(
            "applied migration(s) {} do not match the copies this binary embeds \
             (checksum mismatch): either this database was migrated from files that \
             predate the ADR-0003 baseline freeze, or this binary is stale for it. \
             `openledger migrate` will refuse the same mismatch (VersionMismatch) — \
             work out which side is wrong before serving; do not edit \
             _sqlx_migrations into agreement.",
            mismatched.join(", ")
        ));
    }
    Ok(())
}

/// The first of the three failures: a database the migration job never
/// reached at all. With a lazy pool this SELECT is also the first real
/// connection, so an unreachable database surfaces here, once, with its own
/// message — instead of at pool construction.
async fn refuse_an_unmigrated_database(pool: &sqlx::PgPool) -> Result<(), String> {
    let (migrated,): (bool,) = sqlx::query_as("SELECT to_regclass('_sqlx_migrations') IS NOT NULL")
        .fetch_one(pool)
        .await
        .map_err(|e| format!("could not read the schema state: {e}"))?;
    if !migrated {
        return Err(
            "this database has never been migrated (no _sqlx_migrations table). \
             Run `openledger migrate` first — the serving process never migrates \
             (ADR-0003)."
                .to_owned(),
        );
    }
    Ok(())
}

/// One `_sqlx_migrations` row as this check reads it: the version, and the
/// checksum of the file that was actually applied.
type AppliedRow = (i64, Vec<u8>);

/// What the database says it applied: version and checksum for every
/// SUCCESSFUL row, in version order. `success` is sqlx's own flag — a row for
/// a migration that failed mid-run is not something this binary may serve on.
async fn applied_migration_checksums(pool: &sqlx::PgPool) -> Result<Vec<AppliedRow>, String> {
    sqlx::query_as("SELECT version, checksum FROM _sqlx_migrations WHERE success ORDER BY version")
        .fetch_all(pool)
        .await
        .map_err(|e| format!("could not read the applied migrations: {e}"))
}

/// The comparison, and the only part of this check with a rule in it: what the
/// binary embeds, against what the database applied. Two lists back — versions
/// the database is MISSING, and versions whose applied checksum DIFFERS from
/// the embedded copy. Applied versions this binary does not embed are ignored,
/// which is the rolling-restart tolerance the doc above promises.
///
/// Pure, and deliberately: the embedded set comes from the same
/// `sqlx::migrate!` macro `migrate` runs, so this is testable with no database
/// in the room.
fn drift_from_the_embedded_migrations(applied: &[AppliedRow]) -> (Vec<String>, Vec<String>) {
    let mut missing: Vec<String> = Vec::new();
    let mut mismatched: Vec<String> = Vec::new();
    for migration in sqlx::migrate!("../../migrations")
        .iter()
        .filter(|m| !m.migration_type.is_down_migration())
    {
        match applied
            .iter()
            .find(|(version, _)| *version == migration.version)
        {
            None => missing.push(migration.version.to_string()),
            Some((_, checksum)) if checksum.as_slice() != migration.checksum.as_ref() => {
                mismatched.push(migration.version.to_string());
            }
            Some(_) => {}
        }
    }
    (missing, mismatched)
}

#[cfg(test)]
mod tests {
    //! The comparison walk, held against the migration set `sqlx::migrate!`
    //! compiles into this binary — no database in the room, the same way
    //! migrate.rs's tests state it. What the two SELECTs above see is held end
    //! to end instead (`crates/e2e/tests/e2e/startup.rs`); what the walk MEANS
    //! is held here, because it is the half with the rule in it.

    use super::{AppliedRow, drift_from_the_embedded_migrations};

    /// Every migration this binary embeds, rendered as the rows a database
    /// that applied all of them would return.
    fn a_database_that_applied_all_of_them() -> Vec<AppliedRow> {
        sqlx::migrate!("../../migrations")
            .iter()
            .filter(|m| !m.migration_type.is_down_migration())
            .map(|m| (m.version, m.checksum.to_vec()))
            .collect()
    }

    /// The same checksum, no longer the same file: one byte longer is enough
    /// to be a different sum, and it is what a database migrated from a file
    /// that predates the baseline freeze looks like from here.
    fn a_different_checksum(mut checksum: Vec<u8>) -> Vec<u8> {
        checksum.push(0);
        checksum
    }

    #[test]
    fn a_database_holding_every_embedded_migration_has_drifted_in_neither_direction() {
        let applied = a_database_that_applied_all_of_them();

        let (missing, mismatched) = drift_from_the_embedded_migrations(&applied);

        assert!(
            missing.is_empty() && mismatched.is_empty(),
            "an up-to-date database reported missing {missing:?} and mismatched {mismatched:?}"
        );
    }

    #[test]
    fn an_applied_migration_whose_checksum_differs_is_mismatched_and_never_missing() {
        let tampered: Vec<AppliedRow> = a_database_that_applied_all_of_them()
            .into_iter()
            .map(|(version, checksum)| (version, a_different_checksum(checksum)))
            .collect();
        let every_version: Vec<String> = tampered
            .iter()
            .map(|(version, _)| version.to_string())
            .collect();

        let (missing, mismatched) = drift_from_the_embedded_migrations(&tampered);

        // The dangerous branch: the row IS there, so nothing is missing —
        // reporting it as missing would send the operator to `migrate` for a
        // disagreement `migrate` will refuse.
        assert!(missing.is_empty(), "a present row reported as missing");
        assert_eq!(mismatched, every_version);
    }

    #[test]
    fn an_embedded_migration_the_database_never_applied_is_missing_and_never_mismatched() {
        let mut applied = a_database_that_applied_all_of_them();
        let never_applied = applied.pop().map(|(version, _)| version.to_string());

        let (missing, mismatched) = drift_from_the_embedded_migrations(&applied);

        assert_eq!(missing, Vec::from_iter(never_applied));
        assert!(
            mismatched.is_empty(),
            "an absent row reported as a checksum mismatch"
        );
    }
}
