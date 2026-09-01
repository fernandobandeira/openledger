//! `TestBook` — one test's own database, migrated by `openledger migrate`,
//! seeded with the published chart, and served by the compiled binary over
//! real HTTP — plus the assertion helpers every endpoint test shares.

use std::io::{BufRead, BufReader};
use std::process::{Child, Stdio};

use sqlx::postgres::PgPoolOptions;
use sqlx::{AssertSqlSafe, PgPool, Postgres, Transaction};
use uuid::Uuid;

use super::postgres;

pub type TestResult = Result<(), Box<dyn std::error::Error>>;

/// One POST, read to the end: status, the `Idempotency-Replayed` header if
/// the response carried one, and the body.
pub type PostAnswer = (reqwest::StatusCode, Option<String>, serde_json::Value);

/// What one [`TestBook::spawn_post`] task resolves to.
pub type PostOutcome = Result<PostAnswer, reqwest::Error>;

/// One charge of 100 between a pair, under `t1` — the body every concurrent
/// burst in the suite sends. It lives here rather than in one endpoint file
/// because three of them send it: a burst must be tenant-homogeneous or the
/// drain steps over its members and nothing shares a statement, so "the same
/// tenant, the same shape, only the key differing" is a property of the
/// FIXTURE and not of any one test.
pub fn charge(key: &str, source: Uuid, destination: Uuid) -> serde_json::Value {
    serde_json::json!({
        "tenant_id": "t1",
        "idempotency_key": key,
        "effective_at": "2026-08-27T12:00:00Z",
        "postings": [{
            "source": source, "destination": destination,
            "amount_minor": 100, "currency": "USD"
        }],
    })
}

/// Every member of a burst accepted. Called from a test's assert phase, never
/// from the helper that posts: a burst helper that asserted on the way past
/// would run this silently at the call site — and in more than one test here
/// these statuses ARE the second half of the test's name.
pub fn assert_every_member_was_accepted(answers: &[PostAnswer]) {
    for (n, (status, _, body)) in answers.iter().enumerate() {
        assert_eq!(
            status.as_u16(),
            201,
            "member {n} of the burst was not accepted — a 500 here is what a deadlock victim \
             looks like: {body}"
        );
    }
}

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
    /// Held so the served process outlives the test. Never read: the served
    /// process is no longer a writer identity — it runs a POOL of dispatchers,
    /// each owning its own index — so nothing about the book can be predicted
    /// from it (ADR-0018 §1).
    #[expect(dead_code, reason = "the field's value is the process staying alive")]
    server: Server,
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
            server,
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
        tokio::task::spawn(async move { post_one(&client, &url, &body).await })
    }

    /// Every body posted AT ONCE, answered in the order given. The one shape
    /// three files needed and each had written for itself; nothing is
    /// asserted on the way past, because a helper that asserts hides the
    /// test's own assert phase inside its arrange phase.
    pub async fn post_all_at_once(
        &self,
        bodies: &[serde_json::Value],
    ) -> Result<Vec<PostAnswer>, Box<dyn std::error::Error>> {
        let handles: Vec<_> = bodies.iter().map(|body| self.spawn_post(body)).collect();
        let mut answers = Vec::with_capacity(handles.len());
        for handle in handles {
            answers.push(handle.await??);
        }
        Ok(answers)
    }

    /// ONE CLIENT as a spawned task: the given bodies posted one after
    /// another, each answered before the next is sent. N of these are N
    /// SUSTAINED writers, which is a different workload from N callers
    /// arriving at once and the one a concurrency proof needs — a single
    /// burst is drained by a couple of dispatchers into a couple of very
    /// large batches, while sustained arrivals keep many dispatchers holding
    /// small batches at the same time, which is what puts differing account
    /// subsets in flight together.
    pub fn spawn_client(
        &self,
        bodies: Vec<serde_json::Value>,
    ) -> tokio::task::JoinHandle<Vec<PostOutcome>> {
        let client = self.client.clone();
        let url = format!("{}/v1/transactions", self.base);
        tokio::task::spawn(async move {
            let mut answers = Vec::with_capacity(bodies.len());
            for body in &bodies {
                answers.push(post_one(&client, &url, body).await);
            }
            answers
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

    /// How many database transactions on this book wrote MORE THAN ONE ledger
    /// transaction — which is exactly how many batched statements carried
    /// company (ADR-0018 §2). `ledger_entries.xact_id` defaults to
    /// `pg_current_xact_id()`, so entries written by one statement share one
    /// value and entries written by two share none.
    ///
    /// **This is the only witness a batch leaves.** A batched post is
    /// indistinguishable on the wire from an unbatched one — same endpoint,
    /// same response, same error grammar, deliberately — so a test that means
    /// to exercise the batched statement has no way to ask for it and must
    /// read afterwards whether it got it. Without this, a concurrency test
    /// that happened to dispatch every member alone would pass while proving
    /// nothing about the path it named.
    pub async fn statements_that_carried_more_than_one_transaction(
        &self,
    ) -> Result<i64, sqlx::Error> {
        let (shared,): (i64,) = sqlx::query_as(
            "SELECT count(*) FROM (
                 SELECT xact_id FROM ledger_entries
                 GROUP BY xact_id
                 HAVING count(DISTINCT transaction_id) > 1
             ) AS shared",
        )
        .fetch_one(&self.pool)
        .await?;
        Ok(shared)
    }

    /// Every counter on this book, asserted gapless from 1 within its own
    /// `(account, currency, stripe)`. That grain is the contract, not the
    /// account's: a stripe is a separate lock issuing a separate run
    /// (ADR-0013 §4), so two stripes of one account both issue 1 and an
    /// account-wide run would be unfalsifiable.
    pub async fn assert_every_counter_is_gapless_from_one(&self) -> TestResult {
        let counters: Vec<(Uuid, String, i16, Vec<i64>)> = sqlx::query_as(
            "SELECT account_id, currency, stripe,
                    array_agg(account_seq ORDER BY account_seq)
             FROM ledger_entries
             GROUP BY account_id, currency, stripe
             ORDER BY account_id, currency, stripe",
        )
        .fetch_all(&self.pool)
        .await?;
        assert!(
            !counters.is_empty(),
            "no entries to check a counter against"
        );
        for (account, currency, stripe, seqs) in counters {
            let expected: Vec<i64> = (1..=seqs.len() as i64).collect();
            assert_eq!(
                seqs, expected,
                "account_seq of ({account}, {currency}, stripe {stripe}) is not a gapless run from 1"
            );
        }
        Ok(())
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

    /// The blocked-loser wait every uncommitted-rival race shares: poll —
    /// bounded exactly like the horizon wait above, never a bare sleep —
    /// until a backend on THIS database is waiting on a lock, which is the
    /// spawned API call blocked on a rival's uncommitted claim. Scoped by
    /// `datname` so a sibling test's lock cannot satisfy the poll. `false`
    /// means the bound expired with nothing blocked; the caller asserts,
    /// with its own message naming which call never blocked.
    pub async fn wait_until_a_backend_blocks_on_a_lock(&self) -> Result<bool, sqlx::Error> {
        for _ in 0..600 {
            let (waiting,): (i64,) = sqlx::query_as(
                "SELECT count(*) FROM pg_stat_activity
                 WHERE datname = current_database() AND wait_event_type = 'Lock'",
            )
            .fetch_one(&self.pool)
            .await?;
            if waiting > 0 {
                return Ok(true);
            }
            tokio::time::sleep(std::time::Duration::from_millis(25)).await;
        }
        Ok(false)
    }

    /// A rival resolution of `pending`, begun and HELD uncommitted — the
    /// staging both directions of the supersession race share (the
    /// adversary's original setup). Full, balanced and correctly cached —
    /// event, transaction naming the target, both legs, cache advanced —
    /// so the book it leaves behind once the caller commits the returned
    /// transaction is an ordinarily resolved hold, and the oracle's ten
    /// zeros still bind. Dropping the transaction instead abandons the
    /// rival, releasing whatever blocked on it.
    pub async fn begin_a_rival_resolution(
        &self,
        pending: Uuid,
        receivable: Uuid,
        revenue: Uuid,
    ) -> Result<Transaction<'static, Postgres>, sqlx::Error> {
        let mut held_open = self.pool.begin().await?;
        sqlx::raw_sql(AssertSqlSafe(format!(
            "INSERT INTO ledger_events (tenant_id, id, kind, source, idempotency_key,
                                        idempotency_hash, payload, effective_at)
             VALUES ('t1', '0e2e0000-0000-7000-8000-000000000070', 'posting', 'internal',
                     'rival-capture', decode('00', 'hex'), '{{}}'::jsonb,
                     '2026-08-29T00:00:00Z');
             INSERT INTO ledger_transactions (tenant_id, id, event_id, kind, status,
                                              effective_at, resolves_id)
             VALUES ('t1', '0e2e0000-0000-7000-8000-000000000071',
                     '0e2e0000-0000-7000-8000-000000000070', 'posting', 'posted',
                     '2026-08-29T00:00:00Z', '{pending}');
             INSERT INTO ledger_entries (tenant_id, transaction_id, account_id, direction,
                                         amount_minor, currency, account_seq, effective_at)
             VALUES ('t1', '0e2e0000-0000-7000-8000-000000000071', '{receivable}',
                     'debit', 500, 'USD', 2, '2026-08-29T00:00:00Z'),
                    ('t1', '0e2e0000-0000-7000-8000-000000000071', '{revenue}',
                     'credit', 500, 'USD', 2, '2026-08-29T00:00:00Z');
             UPDATE ledger_account_balances SET input = input + 500, last_seq = 2
             WHERE tenant_id = 't1' AND account_id = '{receivable}';
             UPDATE ledger_account_balances SET output = output + 500, last_seq = 2
             WHERE tenant_id = 't1' AND account_id = '{revenue}'"
        )))
        .execute(&mut *held_open)
        .await?;
        Ok(held_open)
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

/// One POST, read to the end — status, the `Idempotency-Replayed` header if
/// the response carried one, body — because a `reqwest::Response` cannot
/// cross a `JoinHandle` usefully once the assertions need the body consumed.
async fn post_one(client: &reqwest::Client, url: &str, body: &serde_json::Value) -> PostOutcome {
    let response = client.post(url).json(body).send().await?;
    let status = response.status();
    let replayed = response
        .headers()
        .get("idempotency-replayed")
        .and_then(|value| value.to_str().ok())
        .map(str::to_owned);
    let body: serde_json::Value = response.json().await?;
    Ok((status, replayed, body))
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
