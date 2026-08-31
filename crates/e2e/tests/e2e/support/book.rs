//! `TestBook` — one test's own database, migrated by `openledger migrate`,
//! seeded with the published chart, and served by the compiled binary over
//! real HTTP — plus the assertion helpers every endpoint test shares.

use std::io::{BufRead, BufReader};
use std::process::{Child, Stdio};

use sqlx::PgPool;
use sqlx::postgres::PgPoolOptions;
use uuid::Uuid;

use super::postgres;

pub type TestResult = Result<(), Box<dyn std::error::Error>>;

/// What one [`TestBook::spawn_post`] task resolves to: status, the
/// `Idempotency-Replayed` header if the response carried one, and the body.
pub type PostOutcome =
    Result<(reqwest::StatusCode, Option<String>, serde_json::Value), reqwest::Error>;

/// Kills the served process when the test ends, pass or fail.
struct Server(Child);

impl Drop for Server {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

/// One test's book: the scratch database `e2e_<name>`, a pool into it, and the
/// compiled binary serving it.
pub struct TestBook {
    pub pool: PgPool,
    /// The scratch database's ADMIN URL — for tests that need a second
    /// connection under different credentials (`swap_credentials`).
    pub db_url: String,
    base: String,
    client: reqwest::Client,
    _server: Server,
}

impl TestBook {
    pub async fn new(name: &str) -> Result<Self, Box<dyn std::error::Error>> {
        Self::build(name, false).await
    }

    /// Like [`new`](Self::new), but the spawned `serve` connects as the
    /// LOGIN role `e2e_app_login`, which inherits `openledger_app` — the
    /// policy role, NOT the schema owner. Everything the server then does on
    /// the wire runs under the baseline's GRANT lists and RLS writer
    /// policies, which is what the role-separation test needs; the `pool`
    /// stays the ADMIN's, because fixtures and oracle reads (the recon views
    /// are deliberately not granted to the app role) are the test's, not the
    /// server's.
    pub async fn new_as_app_role(name: &str) -> Result<Self, Box<dyn std::error::Error>> {
        Self::build(name, true).await
    }

    async fn build(
        name: &str,
        serve_as_app_role: bool,
    ) -> Result<Self, Box<dyn std::error::Error>> {
        // The adopter's own path: a fresh database, `openledger migrate`, the
        // published chart.
        let db_url = postgres::create_scratch_db(name).await?;
        postgres::migrate(&db_url)?;
        let pool = PgPoolOptions::new()
            .max_connections(4)
            .connect(&db_url)
            .await?;
        sqlx::raw_sql(include_str!("../../../../../schema/chart.sql"))
            .execute(&pool)
            .await?;

        let serve_url = if serve_as_app_role {
            // Roles are cluster-wide; the fixture is existence-guarded and
            // never dropped (postgres.rs says why). Created through the
            // scratch pool because CREATE ROLE lands on the cluster no
            // matter which database runs it.
            postgres::ensure_login_role(&pool, postgres::APP_LOGIN, "openledger_app").await?;
            // One grant the baseline cannot carry: `_sqlx_migrations` is
            // sqlx's own bookkeeping table, created by the migrator and
            // owned by whoever ran it — the frozen baseline's GRANT lists
            // predate it by construction. serve's startup gate reads it
            // (crates/db/src/verify.rs), so a deployment that serves as a
            // non-owner role makes exactly this grant, and so does this
            // fixture.
            sqlx::raw_sql("GRANT SELECT ON _sqlx_migrations TO openledger_app")
                .execute(&pool)
                .await?;
            postgres::swap_credentials(&db_url, postgres::APP_LOGIN, postgres::LOGIN_PASSWORD)?
        } else {
            db_url.clone()
        };

        // The server, bound to port 0; the announced address is the contract.
        let mut server = Server(
            postgres::openledger()?
                .args(["serve", "--bind", "127.0.0.1:0"])
                .env("DATABASE_URL", &serve_url)
                .stdout(Stdio::piped())
                .spawn()?,
        );
        let stdout = server.0.stdout.take().ok_or("server stdout not captured")?;
        let mut announced = String::new();
        BufReader::new(stdout).read_line(&mut announced)?;
        let base = announced
            .trim()
            .strip_prefix("listening on ")
            .ok_or_else(|| format!("unexpected first line: {announced:?}"))?
            .to_owned();

        Ok(Self {
            pool,
            db_url,
            base,
            client: reqwest::Client::new(),
            _server: server,
        })
    }

    pub async fn account(
        &self,
        tenant: &str,
        owner: Option<&str>,
        purpose: &str,
        category: &str,
        normal_balance: &str,
        scope: &str,
    ) -> Result<Uuid, sqlx::Error> {
        let (id,): (Uuid,) = sqlx::query_as(
            "INSERT INTO ledger_accounts
                    (tenant_id, owner_type, owner_id, purpose, category, normal_balance,
                     counterparty_scope, currency)
             VALUES ($6, CASE WHEN $1::text IS NULL THEN 'house' ELSE 'company' END::account_owner_type,
                     $1, $2, $3::ledger_category, $4::ledger_normal_balance, $5, 'USD')
             RETURNING id",
        )
        .bind(owner)
        .bind(purpose)
        .bind(category)
        .bind(normal_balance)
        .bind(scope)
        .bind(tenant)
        .fetch_one(&self.pool)
        .await?;
        Ok(id)
    }

    /// The fixture posts between `customer_receivable` and `fee_revenue`
    /// deliberately: neither is a perimeter type, so `chart_lint`'s
    /// perimeter_unattested error — correct, and fired for every perimeter
    /// account until the attestation feed exists — stays out of the oracle.
    pub async fn fixture_accounts(&self) -> Result<(Uuid, Uuid), Box<dyn std::error::Error>> {
        self.fixture_accounts_for("t1").await
    }

    /// The same pair under any tenant — for the tests where a second book
    /// must exist (cross-tenant key reuse, RLS scoping).
    pub async fn fixture_accounts_for(
        &self,
        tenant: &str,
    ) -> Result<(Uuid, Uuid), Box<dyn std::error::Error>> {
        let receivable = self
            .account(
                tenant,
                Some("co_1"),
                "customer_receivable",
                "asset",
                "debit",
                "per_shard",
            )
            .await?;
        let revenue = self
            .account(tenant, None, "fee_revenue", "revenue", "credit", "none")
            .await?;
        Ok((receivable, revenue))
    }

    pub async fn post(
        &self,
        body: &serde_json::Value,
    ) -> Result<reqwest::Response, reqwest::Error> {
        self.client
            .post(format!("{}/v1/transactions", self.base))
            .json(body)
            .send()
            .await
    }

    /// One POST as a spawned task, for the concurrent-duplicate test: the
    /// task owns a clone of the SHARED client (reqwest's `Client` is an Arc
    /// over one pool, so every caller draws from the same connections) and
    /// returns the response pre-read — status, the `Idempotency-Replayed`
    /// header if any, body — because a `reqwest::Response` cannot cross the
    /// `JoinHandle` usefully once the assertions need the body consumed.
    pub fn spawn_post(&self, body: &serde_json::Value) -> tokio::task::JoinHandle<PostOutcome> {
        let client = self.client.clone();
        let url = format!("{}/v1/transactions", self.base);
        let body = body.clone();
        tokio::task::spawn(async move {
            let response = client.post(url).json(&body).send().await?;
            let status = response.status();
            let replayed = response
                .headers()
                .get("idempotency-replayed")
                .and_then(|value| value.to_str().ok())
                .map(str::to_owned);
            let body: serde_json::Value = response.json().await?;
            Ok((status, replayed, body))
        })
    }

    /// A bodiless request with an arbitrary method and path, for the
    /// conformance test — which walks paths out of the committed spec rather
    /// than knowing them, so `post` above is too specific for it.
    pub async fn request(
        &self,
        method: reqwest::Method,
        path: &str,
    ) -> Result<reqwest::Response, reqwest::Error> {
        self.client
            .request(method, format!("{}{}", self.base, path))
            .send()
            .await
    }

    /// The (input, output, last_seq) balance row of one account.
    pub async fn balance(&self, account: Uuid) -> Result<(i64, i64, i64), sqlx::Error> {
        sqlx::query_as(
            "SELECT input, output, last_seq FROM ledger_account_balances
             WHERE tenant_id = 't1' AND account_id = $1",
        )
        .bind(account)
        .fetch_one(&self.pool)
        .await
    }

    /// Row counts of (events, transactions, entries) — the three tables a
    /// posting writes atomically. A refused write must move none of them.
    pub async fn write_counts(&self) -> Result<(i64, i64, i64), sqlx::Error> {
        sqlx::query_as(
            "SELECT (SELECT count(*) FROM ledger_events),
                    (SELECT count(*) FROM ledger_transactions),
                    (SELECT count(*) FROM ledger_entries)",
        )
        .fetch_one(&self.pool)
        .await
    }

    /// The sweep's quiescence assumption, made explicit and waitable-for.
    /// recon_cursor_breaks reads the snapshot horizon, and report_cursor()'s
    /// comment names the honest cost: the horizon is the CLUSTER's, so one
    /// in-flight transaction anywhere on the server — another database
    /// included — holds it back. The operator sweep runs on a quiet book;
    /// this binary runs sibling tests concurrently on one cluster, so an
    /// entry this book has committed can sit above a horizon a sibling still
    /// pins — 'above_horizon', transiently, on a healthy book. Wait,
    /// bounded, for the horizon to retire this book's newest entry; once
    /// retired it STAYS retired (xids only grow), so anything read or
    /// spawned after this cannot trip over a neighbor. A forged far-future
    /// xact_id outlives the bound and still fails in the oracle.
    ///
    /// The bound is 15s because the longest honest pin measured here is
    /// not a query: it is a sibling's setup `DROP DATABASE ... WITH
    /// (FORCE)`, which holds its xid through a forced checkpoint and the
    /// file unlinking — over five seconds on a loaded Docker volume, and
    /// every run OPENS with a wave of them (each test's create_scratch_db
    /// drops the previous run's database). 200 polls flaked exactly there
    /// when the suite grew past seventeen tests.
    pub async fn wait_for_the_horizon_to_retire_this_book(&self) -> TestResult {
        for _ in 0..600 {
            let (now_retired,): (bool,) = sqlx::query_as(
                "SELECT coalesce(max(xact_id) <= pg_snapshot_xmin(pg_current_snapshot()), true)
                 FROM ledger_entries",
            )
            .fetch_one(&self.pool)
            .await?;
            if now_retired {
                return Ok(());
            }
            tokio::time::sleep(std::time::Duration::from_millis(25)).await;
        }
        // A timeout fails HERE, as itself — not by falling through to the
        // oracle, where a held-back horizon reads as `cursor_forgery` and
        // sends whoever is debugging into the forgery check instead of at
        // the neighbor holding the horizon.
        Err(
            "the cluster's xmin horizon never retired this book's entries after 15s — \
             another database on this cluster likely has an open transaction holding it \
             back; see ADR-0010's cluster-horizon note. This is a stalled horizon, not a \
             cursor forgery."
                .into(),
        )
    }

    /// The oracle. Ten checks, and every one must report zero breaks.
    pub async fn assert_reconciled(&self) -> TestResult {
        self.wait_for_the_horizon_to_retire_this_book().await?;
        let checks: Vec<(String, i64)> =
            sqlx::query_as("SELECT check_name, breaks FROM reconciliation")
                .fetch_all(&self.pool)
                .await?;
        assert_eq!(checks.len(), 10, "the reconciliation view lost a check");
        for (check, breaks) in checks {
            // cursor_forgery carries a `reason` per row ('above_horizon' or
            // 'predates_txn' — recon_cursor_breaks in the baseline), and the
            // two point at different culprits; a failure message without it
            // is a number where a diagnosis could be.
            if check == "cursor_forgery" && breaks != 0 {
                let reasons: Vec<(String,)> =
                    sqlx::query_as("SELECT coalesce(reason, '?') FROM recon_cursor_breaks")
                        .fetch_all(&self.pool)
                        .await?;
                assert_eq!(
                    breaks,
                    0,
                    "reconciliation check cursor_forgery reports {breaks} break(s); reasons: {:?}",
                    reasons
                        .iter()
                        .map(|(reason,)| reason.as_str())
                        .collect::<Vec<_>>()
                );
            }
            assert_eq!(
                breaks, 0,
                "reconciliation check {check} reports {breaks} break(s)"
            );
        }
        Ok(())
    }
}

pub fn header(
    response: &reqwest::Response,
    name: &str,
) -> Result<String, Box<dyn std::error::Error>> {
    Ok(response
        .headers()
        .get(name)
        .ok_or_else(|| format!("no {name} header"))?
        .to_str()?
        .to_owned())
}
