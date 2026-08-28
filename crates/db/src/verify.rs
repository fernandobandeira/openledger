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
    // With a lazy pool this SELECT is also the first real connection, so an
    // unreachable database surfaces here, once, with its own message —
    // instead of at pool construction.
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

    let applied: Vec<(i64, Vec<u8>)> = sqlx::query_as(
        "SELECT version, checksum FROM _sqlx_migrations WHERE success ORDER BY version",
    )
    .fetch_all(pool)
    .await
    .map_err(|e| format!("could not read the applied migrations: {e}"))?;

    // The versions and checksums this binary carries, from the same macro
    // `migrate` runs.
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
