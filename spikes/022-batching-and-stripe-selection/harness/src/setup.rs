//! A fresh scratch database, migrated by the compiled `openledger migrate`,
//! seeded with `schema/chart.sql`, and given the accounts the workload
//! posts against — the same path `crates/e2e/tests/e2e/support/postgres.rs`
//! and `support/book.rs` take, minus the served process (this harness talks
//! to the database directly, because the statement is what is under
//! measurement, not the HTTP surface).

use std::error::Error;
use std::process::Command;

use sqlx::postgres::PgPoolOptions;
use sqlx::{AssertSqlSafe, Connection, PgConnection, PgPool};
use uuid::Uuid;

pub type Fallible<T> = Result<T, Box<dyn Error>>;

const CHART: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../../schema/chart.sql"
));

const DEFAULT_ADMIN: &str = "postgres://openledger:openledger@localhost:5433/openledger?sslmode=disable";

pub fn admin_url() -> String {
    std::env::var("DATABASE_URL").unwrap_or_else(|_| DEFAULT_ADMIN.to_owned())
}

/// The compiled binary. `cargo build -p openledger` from the repo root puts
/// it here; RUN.sh does that first and this error names the remedy.
fn openledger_binary() -> Fallible<String> {
    if let Ok(path) = std::env::var("OPENLEDGER_BIN") {
        return Ok(path);
    }
    let path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../../target/debug/openledger"
    );
    if !std::path::Path::new(path).is_file() {
        return Err(format!(
            "{path} does not exist — run `cargo build -p openledger` from the repo root first"
        )
        .into());
    }
    Ok(path.to_owned())
}

fn swap_database(url: &str, name: &str) -> Fallible<String> {
    let (base, query) = match url.split_once('?') {
        Some((base, query)) => (base, Some(query)),
        None => (url, None),
    };
    let (root, _db) = base
        .rsplit_once('/')
        .ok_or("the admin URL carries no database name")?;
    Ok(match query {
        Some(query) => format!("{root}/{name}?{query}"),
        None => format!("{root}/{name}"),
    })
}

/// Drop and recreate `spike022_<label>`, migrate it, seed the chart.
pub async fn fresh_book(label: &str) -> Fallible<(String, PgPool)> {
    if label.is_empty()
        || !label
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_')
    {
        return Err(format!("label {label:?} is not a bare identifier").into());
    }
    let admin_url = admin_url();
    let db = format!("spike022_{label}");
    let mut admin = PgConnection::connect(&admin_url).await?;
    sqlx::raw_sql(AssertSqlSafe(format!(
        "DROP DATABASE IF EXISTS {db} WITH (FORCE)"
    )))
    .execute(&mut admin)
    .await?;
    sqlx::raw_sql(AssertSqlSafe(format!("CREATE DATABASE {db}")))
        .execute(&mut admin)
        .await?;
    admin.close().await?;

    let db_url = swap_database(&admin_url, &db)?;
    let migrated = Command::new(openledger_binary()?)
        .arg("migrate")
        .env("DATABASE_URL", &db_url)
        .status()?;
    if !migrated.success() {
        return Err("openledger migrate failed".into());
    }
    let pool = PgPoolOptions::new()
        .max_connections(4)
        .connect(&db_url)
        .await?;
    sqlx::raw_sql(AssertSqlSafe(CHART.to_owned()))
        .execute(&pool)
        .await?;
    Ok((db_url, pool))
}

/// Drop the scratch book. Called at the END of every run, in the success and
/// the failure path alike: the full matrix is ~370 configurations, and ~370
/// abandoned databases on the cluster is not tidiness, it is background load
/// — autovacuum workers, a longer `pg_database` scan, and a shared buffer
/// pool split across books nobody is reading — contaminating every later
/// measurement. `--keep-database` keeps one for a post-mortem.
pub async fn drop_book(label: &str) -> Fallible<()> {
    let db = format!("spike022_{label}");
    let mut admin = PgConnection::connect(&admin_url()).await?;
    sqlx::raw_sql(AssertSqlSafe(format!(
        "DROP DATABASE IF EXISTS {db} WITH (FORCE)"
    )))
    .execute(&mut admin)
    .await?;
    admin.close().await?;
    Ok(())
}

/// One tenant's accounts: N per-company receivables that spread, and the two
/// house accounts every clearing touches.
///
/// `network_settlement_payable` is deliberately NOT used — SPEC.md's
/// substitution note: it is `is_perimeter = true`, so `chart_lint`'s
/// `perimeter_unattested` would hold one of the ten checks permanently
/// non-zero and destroy the correctness gate. `interchange_revenue` and
/// `fee_revenue` are non-perimeter house types with the same write shape.
pub struct TenantAccounts {
    pub tenant: String,
    pub receivables: Vec<Uuid>,
    pub interchange: Uuid,
    pub fee: Uuid,
}

async fn account(
    pool: &PgPool,
    tenant: &str,
    owner: Option<&str>,
    purpose: &str,
    category: &str,
    normal_balance: &str,
    scope: &str,
    stripe_count: i16,
) -> Result<Uuid, sqlx::Error> {
    let (id,): (Uuid,) = sqlx::query_as(
        "INSERT INTO ledger_accounts
                (tenant_id, owner_type, owner_id, purpose, category, normal_balance,
                 counterparty_scope, currency, stripe_count)
         VALUES ($6, CASE WHEN $1::text IS NULL THEN 'house' ELSE 'company' END::account_owner_type,
                 $1, $2, $3::ledger_category, $4::ledger_normal_balance, $5, 'USD', $7)
         RETURNING id",
    )
    .bind(owner)
    .bind(purpose)
    .bind(category)
    .bind(normal_balance)
    .bind(scope)
    .bind(tenant)
    .bind(stripe_count)
    .fetch_one(pool)
    .await?;
    Ok(id)
}

/// `--stripes N` is the stripe_count set on the HOUSE accounts (SPEC.md):
/// they are the contended rows. The per-company receivables spread on their
/// own and stay at one stripe.
pub async fn open_accounts(
    pool: &PgPool,
    tenants: usize,
    companies: usize,
    stripes: i16,
) -> Fallible<Vec<TenantAccounts>> {
    let mut out = Vec::with_capacity(tenants);
    for t in 0..tenants {
        let tenant = format!("t{t}");
        let mut receivables = Vec::with_capacity(companies);
        for c in 0..companies {
            receivables.push(
                account(
                    pool,
                    &tenant,
                    Some(&format!("co_{c}")),
                    "customer_receivable",
                    "asset",
                    "debit",
                    "per_shard",
                    1,
                )
                .await?,
            );
        }
        let interchange = account(
            pool,
            &tenant,
            None,
            "interchange_revenue",
            "revenue",
            "credit",
            "none",
            stripes,
        )
        .await?;
        let fee = account(
            pool,
            &tenant,
            None,
            "fee_revenue",
            "revenue",
            "credit",
            "none",
            stripes,
        )
        .await?;
        // Section E's B = 1 arm is adversarial only because the presented
        // leg order and the canonical account-id order DISAGREE, and that
        // disagreement rests on a fact nothing else states: `ledger_accounts.id`
        // defaults to `uuidv7()`, which is time-ordered, so accounts opened
        // in this order carry ids in this order. The clearing presents
        // interchange before the receivable and the fee last; the canonical
        // order is receivable, interchange, fee. Reverse a writer's legs and
        // the two house rows are taken in opposite orders — the AB-BA the
        // `ORDER BY` exists to prevent.
        //
        // If uuidv7 were ever swapped for uuidv4 the ids would be random,
        // the presented order would agree with the canonical one by accident
        // as often as not, and section E would measure a diluted hazard
        // while reporting a clean one. Load-bearing, therefore asserted.
        let highest_receivable = receivables.iter().max().copied();
        if let Some(highest) = highest_receivable {
            if !(highest < interchange && interchange < fee) {
                return Err(format!(
                    "tenant {tenant}: the account ids are not in creation order \
                     (receivables max {highest}, interchange {interchange}, fee {fee}). \
                     Section E's presented-vs-canonical disagreement depends on \
                     uuidv7 being time-ordered; it is not, here, so the deadlock \
                     arms would measure a hazard they had not actually built."
                )
                .into());
            }
        }
        out.push(TenantAccounts {
            tenant,
            receivables,
            interchange,
            fee,
        });
    }
    Ok(out)
}

/// The number of transactions the book actually holds. The result line
/// reports `clearings` from an in-process counter; this is the database's
/// own answer, and the two disagreeing means the counter is fiction.
pub async fn transactions_in_the_book(pool: &PgPool) -> Fallible<i64> {
    let (count,): (i64,) = sqlx::query_as("SELECT count(*) FROM ledger_transactions")
        .fetch_one(pool)
        .await?;
    Ok(count)
}

/// Perturb one cached balance by one minor unit. The reconciliation oracle's
/// `balance_cache` check recomputes every balance from the entries; a
/// one-unit lie in one row must make it break. Used only by `--corrupt`,
/// after the workload and before the verdict, to prove the gate can go red.
/// An assertion that has never failed is a decoration, and this repo does not
/// ship decorations.
pub async fn corrupt_one_cached_balance(pool: &PgPool) -> Fallible<String> {
    let corrupted: Option<(Uuid, i16)> = sqlx::query_as(
        "UPDATE ledger_account_balances SET input = input + 1
         WHERE (account_id, stripe) = (
             SELECT account_id, stripe FROM ledger_account_balances
             ORDER BY account_id, stripe LIMIT 1)
         RETURNING account_id, stripe",
    )
    .fetch_optional(pool)
    .await?;
    match corrupted {
        Some((account_id, stripe)) => Ok(format!("{account_id}/stripe {stripe}")),
        None => Err("--corrupt found no balance row to perturb: the workload \
                     wrote nothing, so the gate was never given anything to \
                     catch"
            .into()),
    }
}

/// The oracle's precondition, lifted verbatim in intent from
/// `TestBook::wait_for_the_horizon_to_retire_this_book`: `recon_cursor_breaks`
/// reads the CLUSTER's snapshot horizon, so an entry this book has committed
/// can sit above a horizon another database still pins — 'above_horizon',
/// transiently, on a healthy book. Wait, bounded, for the horizon to retire
/// this book's newest entry, and fail HERE rather than in the oracle.
pub async fn wait_for_the_horizon_to_retire_this_book(pool: &PgPool) -> Fallible<()> {
    for _ in 0..600 {
        let (now_retired,): (bool,) = sqlx::query_as(
            "SELECT coalesce(max(xact_id) <= pg_snapshot_xmin(pg_current_snapshot()), true)
             FROM ledger_entries",
        )
        .fetch_one(pool)
        .await?;
        if now_retired {
            return Ok(());
        }
        tokio::time::sleep(std::time::Duration::from_millis(25)).await;
    }
    Err("the cluster's xmin horizon never retired this book's entries after 15s — \
         a stalled horizon, not a cursor forgery"
        .into())
}

/// Ten checks, every one at zero breaks, or the verdict names what broke.
/// A configuration that does not reconcile is not a throughput number.
pub async fn reconciliation_verdict(pool: &PgPool) -> Fallible<(bool, String)> {
    wait_for_the_horizon_to_retire_this_book(pool).await?;
    let checks: Vec<(String, i64)> = sqlx::query_as("SELECT check_name, breaks FROM reconciliation")
        .fetch_all(pool)
        .await?;
    if checks.len() != 10 {
        return Ok((
            false,
            format!("the reconciliation view reports {} checks, not 10", checks.len()),
        ));
    }
    let broken: Vec<String> = checks
        .iter()
        .filter(|(_, breaks)| *breaks != 0)
        .map(|(name, breaks)| format!("{name}={breaks}"))
        .collect();
    if broken.is_empty() {
        Ok((true, "ten_zeros".to_owned()))
    } else {
        Ok((false, format!("BREAKS {}", broken.join(","))))
    }
}
