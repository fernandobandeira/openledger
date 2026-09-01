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

/// One GET, read to the end: status and body. No header travels with it — the
/// read routes carry `Idempotency-Replayed` on none of them, because nothing
/// they do is a write.
pub type ReadAnswer = (reqwest::StatusCode, serde_json::Value);

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
            "amount_minor": "100", "currency": "USD"
        }],
    })
}

/// One pending 5.00 between the fixture pair, posted through the front door
/// — the injection the reconcile suite used to fake over an admin connection,
/// now the endpoint's own. Returns the pending transaction id.
///
/// It lives here rather than in one endpoint file because two of them stage
/// it identically: `pending.rs` needs a hold to resolve and `reverse.rs` needs
/// one to void, and "a hold of 5.00 under `hold-1`, dated 2026-08-28" is a
/// property of the FIXTURE, not of either file. It asserts its own 201 — see
/// [`TestBook::post_all_at_once`] on where that line runs.
pub async fn post_a_pending_hold(
    book: &TestBook,
    revenue: Uuid,
    receivable: Uuid,
) -> Result<Uuid, Box<dyn std::error::Error>> {
    let created = book
        .post(&serde_json::json!({
            "tenant_id": "t1",
            "idempotency_key": "hold-1",
            "effective_at": "2026-08-28T00:00:00Z",
            "status": "pending",
            "postings": [{
                "source": revenue, "destination": receivable,
                "amount_minor": "500", "currency": "USD"
            }],
        }))
        .await?;
    assert_eq!(created.status(), 201, "seeding the pending hold");
    let body: serde_json::Value = created.json().await?;
    Ok(body
        .get("transaction_id")
        .and_then(serde_json::Value::as_str)
        .ok_or("no transaction_id on the pending 201")?
        .parse()?)
}

/// One posted charge of `minor` between a pair, dated `effective_at` — the
/// shape every READ test's book is built from, because what a read test varies
/// is WHEN a posting is dated rather than what it contains, and
/// [`charge`] fixes that date at one day. Returns the transaction id, and
/// asserts its own 201 exactly as [`post_a_pending_hold`] does: a fixture that
/// failed to land silently surfaces as an incomprehensible report.
pub async fn post_a_charge_dated(
    book: &TestBook,
    key: &str,
    effective_at: &str,
    minor: i64,
    source: Uuid,
    destination: Uuid,
) -> Result<Uuid, Box<dyn std::error::Error>> {
    let created = book
        .post(&serde_json::json!({
            "tenant_id": "t1",
            "idempotency_key": key,
            "effective_at": effective_at,
            "postings": [{
                "source": source, "destination": destination,
                "amount_minor": minor.to_string(), "currency": "USD"
            }],
        }))
        .await?;
    assert_eq!(created.status(), 201, "seeding the charge {key}");
    let body: serde_json::Value = created.json().await?;
    Ok(body
        .get("transaction_id")
        .and_then(serde_json::Value::as_str)
        .ok_or("no transaction_id on the charge's 201")?
        .parse()?)
}

/// The period resource's two paths (ADR-0024) — the collection a definition
/// posts to, and one period's close.
pub const PERIODS_PATH: &str = "/v1/periods";

/// `POST /v1/periods/{code}/close` as a path.
pub fn close_path(code: &str) -> String {
    format!("{PERIODS_PATH}/{code}/close")
}

/// One period defined through the front door, asserting its own 201 — an
/// ARRANGE helper, for the tests whose subject is what happens to a period
/// that exists. A test whose subject is the DEFINITION itself posts the body
/// itself and states the status in its own assert phase.
pub async fn define_a_period(
    book: &TestBook,
    key: &str,
    code: &str,
    starts_at: &str,
    ends_at: &str,
) -> TestResult {
    let created = book
        .post_to(
            PERIODS_PATH,
            &serde_json::json!({
                "tenant_id": "t1",
                "idempotency_key": key,
                "code": code,
                "starts_at": starts_at,
                "ends_at": ends_at,
                "tz": "UTC",
            }),
        )
        .await?;
    assert_eq!(created.status(), 201, "defining the period {code}");
    Ok(())
}

/// One period closed through the front door, asserting its own 201 and
/// answering with the body — the ARRANGE half for tests that read the book
/// afterwards, and the ACT half for the ones that read the answer. It is one
/// helper for both because a close has exactly one accepted shape: there is no
/// replay to tell apart (the key is derived, so a repeat is a refusal).
pub async fn close_a_period(
    book: &TestBook,
    code: &str,
    currency: &str,
) -> Result<serde_json::Value, Box<dyn std::error::Error>> {
    let closed = book
        .post_to(
            &close_path(code),
            &serde_json::json!({"tenant_id": "t1", "currency": currency}),
        )
        .await?;
    let status = closed.status();
    let body: serde_json::Value = closed.json().await?;
    assert_eq!(status, 201, "closing {code} in {currency}: {body}");
    Ok(body)
}

/// One account opened through `POST /v1/accounts`, answering with its id.
///
/// The suite's other fixtures write accounts in SQL (`TestBook::account`),
/// which fixes the currency at USD; this goes through the endpoint, so a test
/// that needs a book in two currencies can have one — and gets the register's
/// own id back rather than one it chose.
pub async fn open_an_account(
    book: &TestBook,
    key: &str,
    purpose: &str,
    owner: Option<&str>,
    currency: &str,
) -> Result<Uuid, Box<dyn std::error::Error>> {
    let opened = book
        .open_account(&serde_json::json!({
            "tenant_id": "t1",
            "idempotency_key": key,
            "purpose": purpose,
            "owner_type": if owner.is_some() { "company" } else { "house" },
            "owner_id": owner,
            "currency": currency,
        }))
        .await?;
    assert_eq!(
        opened.status(),
        201,
        "opening the {purpose} account in {currency}"
    );
    let body: serde_json::Value = opened.json().await?;
    Ok(body
        .get("account")
        .and_then(|account| account.get("account_id"))
        .and_then(serde_json::Value::as_str)
        .ok_or("no account_id on the opening's 201")?
        .parse()?)
}

/// `GET /v1/reports/balance-sheet` as a path: the two parameters every call
/// needs, plus whatever this call is varying — `cursor`, `chart_version`, or a
/// deliberately malformed one of either.
///
/// The builders live here rather than in one test file because four files
/// assemble the same routes, and a query string written out four times is four
/// places for a parameter name to drift from the one the router reads.
pub fn balance_sheet_path(tenant: &str, as_of: &str, and: &[(&str, &str)]) -> String {
    with_parameters(
        &format!("/v1/reports/balance-sheet?tenant_id={tenant}&as_of={as_of}"),
        and,
    )
}

/// `GET /v1/reports/trial-balance` as a path. The range is HALF-OPEN on both
/// report routes that take one (ADR-0011 §A3), so `effective_to` is the first
/// instant NOT reported.
pub fn trial_balance_path(tenant: &str, from: &str, to: &str, and: &[(&str, &str)]) -> String {
    with_parameters(
        &format!(
            "/v1/reports/trial-balance?tenant_id={tenant}&effective_from={from}\
             &effective_to={to}"
        ),
        and,
    )
}

/// The account resource's collection path — the one both of ADR-0021's verbs
/// hang off.
pub const ACCOUNTS_PATH: &str = "/v1/accounts";

/// `GET /v1/accounts` with its book, and whatever page or filter this call is
/// varying.
pub fn accounts_path(tenant: &str, and: &[(&str, &str)]) -> String {
    with_parameters(&format!("{ACCOUNTS_PATH}?tenant_id={tenant}"), and)
}

/// `GET /v1/accounts/{account_id}/balance` as a path. `currency` is required:
/// the balance row's key includes it.
pub fn account_balance_path(tenant: &str, account: Uuid, currency: &str) -> String {
    format!("/v1/accounts/{account}/balance?tenant_id={tenant}&currency={currency}")
}

/// `GET /v1/accounts/{account_id}/entries` as a path (ADR-0023).
///
/// `axis` is an argument rather than one of the varying pairs because it is
/// REQUIRED — there is no default and the endpoint refuses to pick one — so a
/// builder that let it be forgotten would let a test forget the decision this
/// route exists to make. The test that asks what a MISSING axis answers builds
/// its path itself, which is the honest way to ask for something the shape
/// here will not produce.
pub fn account_entries_path(
    tenant: &str,
    account: Uuid,
    axis: &str,
    and: &[(&str, &str)],
) -> String {
    with_parameters(
        &format!("/v1/accounts/{account}/entries?tenant_id={tenant}&axis={axis}"),
        and,
    )
}

/// `GET /v1/transactions/{transaction_id}` as a path.
pub fn transaction_path(tenant: &str, transaction: Uuid) -> String {
    format!("/v1/transactions/{transaction}?tenant_id={tenant}")
}

/// `GET /v1/cursor` as a path. It takes a `tenant_id` like every other read,
/// for the scoping rather than because the answer depends on it: the horizon
/// is `pg_snapshot_xmin`, which is the cluster's.
pub fn cursor_path(tenant: &str) -> String {
    format!("/v1/cursor?tenant_id={tenant}")
}

fn with_parameters(path: &str, and: &[(&str, &str)]) -> String {
    let mut path = path.to_owned();
    for (name, value) in and {
        path.push_str(&format!("&{name}={value}"));
    }
    path
}

/// One report issued and its body taken, asserting its own 200 — an ARRANGE
/// helper, for the report a test then re-issues or compares against. A test
/// whose subject is the status reads [`TestBook::read`] instead and states the
/// status itself, in its own assert phase.
pub async fn a_report_issued(
    book: &TestBook,
    path: &str,
) -> Result<serde_json::Value, Box<dyn std::error::Error>> {
    let (status, body) = book.read(path).await?;
    assert_eq!(status.as_u16(), 200, "issuing {path}: {body}");
    Ok(body)
}

/// The cursor a report says it ran at — the value a caller stores to re-run
/// exactly this report. Every report route answers with one, whether or not
/// the caller supplied it (ADR-0019).
pub fn pinned_cursor_of(report: &serde_json::Value) -> Result<String, Box<dyn std::error::Error>> {
    Ok(report
        .get("pinned_cursor")
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| format!("the report carried no pinned_cursor: {report}"))?
        .to_owned())
}

/// The amount of one line of a statement face, as it came off the wire: a
/// decimal STRING holding an exact integer, never a JSON number (ADR-0019), so
/// nothing here parses it and no comparison in this suite goes through a
/// float.
pub fn amount_of_the_line(
    face: &serde_json::Value,
    fs_line: &str,
) -> Result<String, Box<dyn std::error::Error>> {
    let lines = face
        .get("lines")
        .and_then(serde_json::Value::as_array)
        .ok_or_else(|| format!("the answer carried no lines array: {face}"))?;
    let line = lines
        .iter()
        .find(|line| line.get("fs_line").and_then(serde_json::Value::as_str) == Some(fs_line))
        .ok_or_else(|| format!("the face carries no {fs_line} line: {face}"))?;
    Ok(line
        .get("amount_minor")
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| format!("the {fs_line} line carried no amount_minor: {line}"))?
        .to_owned())
}

/// One account's `(debits, credits, balance_debit_positive)` of a trial
/// balance — three decimal strings, in the order the answer carries them.
pub type TrialBalanceAmounts = (String, String, String);

/// One account's row of a trial balance, as `(debits, credits,
/// balance_debit_positive)` — all three decimal strings, for the same reason
/// [`amount_of_the_line`] returns one. `None` is the account having no
/// activity in the window at all, which is a different answer from a zero row
/// and must not be flattened into one.
pub fn row_of_the_account(
    report: &serde_json::Value,
    account: Uuid,
) -> Result<Option<TrialBalanceAmounts>, Box<dyn std::error::Error>> {
    let rows = report
        .get("rows")
        .and_then(serde_json::Value::as_array)
        .ok_or_else(|| format!("the answer carried no rows array: {report}"))?;
    let Some(row) = rows.iter().find(|row| {
        row.get("account_id").and_then(serde_json::Value::as_str) == Some(&account.to_string())
    }) else {
        return Ok(None);
    };
    let mut amounts = Vec::with_capacity(3);
    for column in ["debits", "credits", "balance_debit_positive"] {
        amounts.push(
            row.get(column)
                .and_then(serde_json::Value::as_str)
                .ok_or_else(|| format!("the row carried no {column}: {row}"))?
                .to_owned(),
        );
    }
    let [debits, credits, balance] = <[String; 3]>::try_from(amounts)
        .map_err(|amounts| format!("a trial-balance row read {} amounts", amounts.len()))?;
    Ok(Some((debits, credits, balance)))
}

/// Which accounts a trial balance reported at all, in the order it answered
/// them. The witness a tenant fence needs: a leak shows up as an account id
/// that is not this tenant's, whatever the amounts beside it say.
pub fn accounts_reported_by(
    report: &serde_json::Value,
) -> Result<Vec<String>, Box<dyn std::error::Error>> {
    let rows = report
        .get("rows")
        .and_then(serde_json::Value::as_array)
        .ok_or_else(|| format!("the answer carried no rows array: {report}"))?;
    let mut reported = Vec::with_capacity(rows.len());
    for row in rows {
        reported.push(
            row.get("account_id")
                .and_then(serde_json::Value::as_str)
                .ok_or_else(|| format!("a trial-balance row carried no account_id: {row}"))?
                .to_owned(),
        );
    }
    Ok(reported)
}

/// The `type` a refusal came back under — ADR-0014's subject-then-condition
/// name, which is the half of an error a caller branches on.
pub fn refusal_type(body: &serde_json::Value) -> Option<&str> {
    body.get("type").and_then(serde_json::Value::as_str)
}

/// The `detail` a refusal came back with — the half a human reads.
pub fn refusal_detail(body: &serde_json::Value) -> &str {
    body.get("detail")
        .and_then(serde_json::Value::as_str)
        .unwrap_or_default()
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

/// How one test's book is SERVED — the two credentials a deployment chooses
/// between, as a fixture. Which login the server itself connects under, and
/// which login (if any) the READ path is given of its own.
struct Serving<'a> {
    /// The server connects as `e2e_app_login`, inheriting `openledger_app`,
    /// rather than as the schema owner.
    as_the_app_role: bool,
    /// `READ_DATABASE_URL`: a login of this name, made a member of every
    /// policy role beside it. **`None` is the SHIPPED DEFAULT** — the flag is
    /// optional and falls back to `DATABASE_URL` (`cli.rs`), so a deployment
    /// that has not created a read login yet reads on the WRITER's credential
    /// and the tenant fence rests entirely on the `SET LOCAL ROLE` inside
    /// every read transaction (ADR-0019).
    read_login: Option<(&'a str, &'a [&'a str])>,
}

/// The default shape: the owner's URL for both paths, no `READ_DATABASE_URL`.
const AS_SHIPPED: Serving<'static> = Serving {
    as_the_app_role: false,
    read_login: None,
};

impl TestBook {
    pub async fn new(name: &str) -> Result<Self, Box<dyn std::error::Error>> {
        Self::build(name, &AS_SHIPPED).await
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
        Self::build(
            name,
            &Serving {
                as_the_app_role: true,
                read_login: None,
            },
        )
        .await
    }

    /// The deployment ADR-0019 asks for: `READ_DATABASE_URL` set, under a
    /// login whose ONLY membership is `openledger_read`. The fence is then a
    /// property of the credential — the connection cannot write and cannot
    /// match the writer's permissive `USING (true)` — rather than of a
    /// statement the adapter has to remember to send.
    pub async fn new_with_a_read_login_of_its_own(
        name: &str,
    ) -> Result<Self, Box<dyn std::error::Error>> {
        Self::build(
            name,
            &Serving {
                as_the_app_role: false,
                read_login: Some((postgres::READ_LOGIN, &["openledger_read"])),
            },
        )
        .await
    }

    /// The deployment ADR-0019 measured and refuses: `READ_DATABASE_URL` under
    /// a login that is a member of BOTH `openledger_app` and
    /// `openledger_read`. RLS policies are permissive and OR'd, so this
    /// credential's own qual is the writer's `USING (true)` unioned with the
    /// reader's tenant predicate — it reads every tenant, and the only thing
    /// standing between it and a cross-tenant answer is the
    /// `SET LOCAL ROLE openledger_read` the adapter issues inside every read
    /// transaction.
    pub async fn new_with_a_read_login_that_can_write_too(
        name: &str,
    ) -> Result<Self, Box<dyn std::error::Error>> {
        Self::build(
            name,
            &Serving {
                as_the_app_role: false,
                read_login: Some((postgres::DUAL_LOGIN, &["openledger_app", "openledger_read"])),
            },
        )
        .await
    }

    /// Seven named steps, and nothing else: a fresh database, the migrator, a
    /// pool, the published chart, the URL the server will connect under, the
    /// URL its READ path will connect under, and the server itself.
    async fn build(name: &str, serving: &Serving<'_>) -> Result<Self, Box<dyn std::error::Error>> {
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
        let serve_url = if serving.as_the_app_role {
            serve_url_under_the_app_role(&pool, &db_url).await?
        } else {
            db_url.clone()
        };
        let read_url = match serving.read_login {
            Some((login, policy_roles)) => {
                Some(read_url_under_its_own_login(&pool, &db_url, login, policy_roles).await?)
            }
            None => None,
        };
        let (server, base) =
            spawn_the_server_and_read_its_address(&serve_url, read_url.as_deref())?;

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
        self.post_to("/v1/transactions", body).await
    }

    /// One POST at any path this book serves. There are two write routes
    /// since ADR-0021 — the posting endpoint and the account one — and they
    /// are the same call with a different path, so `post` above is this at
    /// `/v1/transactions` and [`open_account`](Self::open_account) is this at
    /// `/v1/accounts`.
    pub async fn post_to(
        &self,
        path: &str,
        body: &serde_json::Value,
    ) -> Result<reqwest::Response, reqwest::Error> {
        self.client
            .post(format!("{}{path}", self.base))
            .json(body)
            .send()
            .await
    }

    /// One POST to `/v1/accounts` — the write ADR-0021 added, and the reason
    /// the suite's own fixtures no longer have to be the only way an account
    /// comes to exist.
    pub async fn open_account(
        &self,
        body: &serde_json::Value,
    ) -> Result<reqwest::Response, reqwest::Error> {
        self.post_to(ACCOUNTS_PATH, body).await
    }

    /// The account register as the DATABASE holds it, for one tenant, in the
    /// listing's own order — the oracle a listing test holds its page
    /// against, read over the admin connection rather than through the
    /// endpoint under test.
    pub async fn accounts_on_the_register(
        &self,
        tenant: &str,
    ) -> Result<Vec<(Uuid, String, Option<String>)>, sqlx::Error> {
        sqlx::query_as(
            "SELECT id, purpose, owner_id FROM ledger_accounts
              WHERE tenant_id = $1 ORDER BY id",
        )
        .bind(tenant)
        .fetch_all(&self.pool)
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
    /// asserted on the way past, because these statuses ARE the property
    /// under test in most of the tests that call it.
    ///
    /// **The line the suite holds, stated exactly:** no helper ever asserts on
    /// the property under test — that assertion belongs in the test's own
    /// assert phase, under the test's own name. Arrange helpers DO assert that
    /// their fixture landed (`post_a_pending_hold` in this file,
    /// `post_one_charge` in three files), and that is not the same thing: a silently failed fixture
    /// surfaces as an incomprehensible downstream failure, so the fixture says
    /// so where it happened.
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

    /// One GET at a path this book serves, read to the end — status and body,
    /// both the caller's to assert on. Every read route is a GET with its
    /// parameters in the query string (ADR-0019), so this is the whole of what
    /// a read caller does.
    pub async fn read(&self, path: &str) -> Result<ReadAnswer, Box<dyn std::error::Error>> {
        let response = self
            .client
            .get(format!("{}{path}", self.base))
            .send()
            .await?;
        let status = response.status();
        Ok((status, response.json().await?))
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

    /// A spawned burst has REACHED the book, waited for the same bounded way
    /// as the two polls above rather than with a bare sleep. The e2e suite
    /// runs on a current-thread runtime, so a burst of `spawn_post` tasks has
    /// not necessarily sent a byte until something in the test yields; a
    /// blocking subprocess started before that has nothing to race. Polling
    /// for an event count above `were` yields, and the condition is
    /// MONOTONIC — once a member of the burst has committed it stays
    /// committed, so this cannot pass by luck of a timing window the way a
    /// 5ms sleep did — and it says exactly what the caller needs: the burst
    /// is landing, and the rest of it is still in flight.
    pub async fn wait_until_a_post_of_the_burst_has_landed(&self, were: i64) -> TestResult {
        for _ in 0..600 {
            let (events, _, _) = self.write_counts().await?;
            if events > were {
                return Ok(());
            }
            tokio::time::sleep(std::time::Duration::from_millis(5)).await;
        }
        Err(format!(
            "no member of the spawned burst committed within 3s — the book still holds \
             {were} event(s), so nothing was in flight to race"
        )
        .into())
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
            // ONE assertion per check, with the diagnosis built into its
            // message: cursor_forgery carries a `reason` per row
            // ('above_horizon' or 'predates_txn' — recon_cursor_breaks in the
            // baseline), and the two point at different culprits, so a bare
            // number here is a number where a diagnosis could be. Read only
            // when the check has actually broken, because the reasons query
            // costs a round trip and every other check's rows are empty.
            let diagnosis = if check == "cursor_forgery" && breaks != 0 {
                let reasons: Vec<(String,)> =
                    sqlx::query_as("SELECT coalesce(reason, '?') FROM recon_cursor_breaks")
                        .fetch_all(&self.pool)
                        .await?;
                format!(
                    "; reasons: {:?}",
                    reasons
                        .iter()
                        .map(|(reason,)| reason.as_str())
                        .collect::<Vec<_>>()
                )
            } else {
                String::new()
            };
            assert_eq!(
                breaks, 0,
                "reconciliation check {check} reports {breaks} break(s){diagnosis}"
            );
        }
        Ok(())
    }
}

/// The sweep a close performs (ADR-0011 §2): `minor` debited out of
/// `from_revenue` and credited into `into_retained_earnings`, which is what
/// makes the period's temporary positions net to zero at the close. A close
/// with no sweep is a period that had nothing to sweep, and it writes no legs
/// at all — ADR-0020's empty-close carve-out.
pub struct ASweep {
    pub minor: i64,
    pub from_revenue: Uuid,
    pub into_retained_earnings: Uuid,
}

/// The axes a close can be wrong on, one field each — because a close is not
/// one thing, and since ADR-0020 the sweep names five separate ways for it to
/// be a `close_typing` break. ADR-0011 §2 says what the closing transaction
/// CONTAINS, ADR-0020 says what its checkpoint holds and how its cursor
/// relates to its own transaction, and each of those fails on its own. Spelled
/// out so every forgery in `reconcile.rs` is ONE field away from the honest
/// shape it forges, which is what stops a forgery drifting into an unrelated
/// book.
///
/// It lives here rather than in `reconcile.rs` because `reverse.rs` stages a
/// close too — the kind arm of the reversal gate needs a COMPLETE one, and a
/// second hand-rolled copy of these five INSERTs is a copy that rots.
pub struct AClose<'a> {
    /// the period code and the half-open instants it resolved to
    pub period: &'a str,
    pub starts_at: &'a str,
    pub ends_at: &'a str,
    /// the closing transaction's own effective date, inside the period
    /// (`ck_closes__txn_in_period`)
    pub closes_at: &'a str,
    /// the last two hex digits of every id this close writes, so two closes on
    /// one book cannot collide
    pub ids: &'a str,
    /// the SQL expression stored as `computed_at_xid`
    pub computed_at_xid: &'a str,
    /// the sweep, or `None` for the ENTRYLESS close a period with nothing to
    /// sweep produces (ADR-0020's carve-out).
    pub sweeps: Option<ASweep>,
    /// whether `ledger_period_closes` names the transaction at all. `false` is
    /// spike 025 F2(a): an honest close whose one INSERT was forgotten.
    pub recorded: bool,
    /// whether the checkpoint lands. Computed at the STORED cursor with the
    /// close's own transaction admitted by identity — migration 00004 part 1's
    /// `INSERT … SELECT`, verbatim, because a fixture that computes the
    /// checkpoint some other way is testing the fixture.
    pub checkpointed: bool,
}

/// Write one close of `t1`'s book, and return the closing transaction's id.
/// Every column here is one the app role may INSERT, and the cache is advanced
/// the way the writer advances it (the entry carries the `last_seq` the cache
/// row just took), so a close written by this helper leaves `balance_cache`
/// and `unbalanced_transactions` green and only the axis under test red.
pub async fn close_the_period(
    book: &TestBook,
    close: &AClose<'_>,
) -> Result<Uuid, Box<dyn std::error::Error>> {
    let AClose {
        period,
        starts_at,
        ends_at,
        closes_at,
        ids,
        computed_at_xid,
        sweeps,
        recorded,
        checkpointed,
    } = close;
    let event = format!("0e2e0000-0000-7000-8000-0000000000{ids}");
    let txn = format!("0e2e0000-0000-7000-8000-0000000001{ids}");
    let mut sql = format!(
        "INSERT INTO ledger_periods (tenant_id, code, starts_at, ends_at, tz)
         VALUES ('t1', '{period}', '{starts_at}', '{ends_at}', 'UTC');
         INSERT INTO ledger_events (tenant_id, id, kind, source, idempotency_key,
                                    idempotency_hash, payload, effective_at)
         VALUES ('t1', '{event}', 'period_close', 'internal',
                 'close-{period}', decode('00', 'hex'), '{{}}'::jsonb, '{closes_at}');
         INSERT INTO ledger_transactions (tenant_id, id, event_id, kind, status, effective_at)
         VALUES ('t1', '{txn}', '{event}', 'period_close', 'posted', '{closes_at}');"
    );
    if let Some(ASweep {
        minor,
        from_revenue,
        into_retained_earnings,
    }) = sweeps
    {
        sql.push_str(&format!(
            "INSERT INTO ledger_account_balances AS b
                 (tenant_id, account_id, currency, input, output, last_seq,
                  owner_type, owner_id_key, purpose, category, normal_balance)
             SELECT 't1', a.id, 'USD',
                    CASE WHEN a.id = '{from_revenue}' THEN {minor} ELSE 0 END,
                    CASE WHEN a.id = '{from_revenue}' THEN 0 ELSE {minor} END,
                    1, a.owner_type, a.owner_id_key, a.purpose, a.category, a.normal_balance
             FROM ledger_accounts a
             WHERE a.tenant_id = 't1' AND a.id IN ('{from_revenue}', '{into_retained_earnings}')
             ON CONFLICT (tenant_id, account_id, currency, stripe) DO UPDATE
                SET input = b.input + EXCLUDED.input, output = b.output + EXCLUDED.output,
                    last_seq = b.last_seq + 1;
             INSERT INTO ledger_entries (tenant_id, transaction_id, account_id, direction,
                                         amount_minor, currency, account_seq, effective_at)
             SELECT 't1', '{txn}', b.account_id,
                    CASE WHEN b.account_id = '{from_revenue}' THEN 'debit'
                         ELSE 'credit' END::ledger_direction,
                    {minor}, 'USD', b.last_seq, '{closes_at}'
             FROM ledger_account_balances b
             WHERE b.tenant_id = 't1'
               AND b.account_id IN ('{from_revenue}', '{into_retained_earnings}');"
        ));
    }
    if *recorded {
        sql.push_str(&format!(
            "INSERT INTO ledger_period_closes (tenant_id, period_code, currency, starts_at,
                                               ends_at, transaction_id, txn_effective_at,
                                               computed_at_xid)
             VALUES ('t1', '{period}', 'USD', '{starts_at}', '{ends_at}', '{txn}',
                     '{closes_at}', {computed_at_xid});"
        ));
    }
    if *checkpointed {
        sql.push_str(&format!(
            "INSERT INTO ledger_period_balances (tenant_id, period_code, currency, account_id,
                                                 input, output)
             SELECT 't1', '{period}', 'USD', e.account_id,
                    COALESCE(SUM(e.amount_minor) FILTER (WHERE e.direction = 'debit'), 0),
                    COALESCE(SUM(e.amount_minor) FILTER (WHERE e.direction = 'credit'), 0)
             FROM ledger_entries e
             JOIN ledger_transactions x ON x.tenant_id = e.tenant_id AND x.id = e.transaction_id
                                       AND x.status = 'posted'
             WHERE e.tenant_id = 't1' AND e.currency = 'USD'
               AND e.effective_at < '{ends_at}'
               AND (e.xact_id < (SELECT c.computed_at_xid FROM ledger_period_closes c
                                 WHERE c.tenant_id = 't1' AND c.period_code = '{period}'
                                   AND c.currency = 'USD')
                    OR e.transaction_id = '{txn}')
             GROUP BY e.account_id;"
        ));
    }
    sqlx::raw_sql(AssertSqlSafe(sql))
        .execute(&book.pool)
        .await?;
    Ok(txn.parse()?)
}

/// The URL a server SERVING AS THE APP ROLE connects under: the login role
/// exists, it can read the migrator's own bookkeeping table, and the
/// credentials in the URL are swapped for its own.
///
/// Roles are cluster-wide; the fixture is existence-guarded and never dropped
/// (postgres.rs says why). Created through the scratch pool because CREATE
/// ROLE lands on the cluster no matter which database runs it.
async fn serve_url_under_the_app_role(
    pool: &PgPool,
    db_url: &str,
) -> Result<String, Box<dyn std::error::Error>> {
    postgres::ensure_login_role(pool, postgres::APP_LOGIN, "openledger_app").await?;
    // One grant the baseline cannot carry: `_sqlx_migrations` is sqlx's own
    // bookkeeping table, created by the migrator and owned by whoever ran it
    // — the frozen baseline's GRANT lists predate it by construction. serve's
    // startup gate reads it (crates/db/src/verify.rs), so a deployment that
    // serves as a non-owner role makes exactly this grant, and so does this
    // fixture.
    sqlx::raw_sql("GRANT SELECT ON _sqlx_migrations TO openledger_app")
        .execute(pool)
        .await?;
    postgres::swap_credentials(db_url, postgres::APP_LOGIN, postgres::LOGIN_PASSWORD)
}

/// The URL the READ path connects under: a login of its own, a member of
/// every policy role named, and the scratch database's credentials swapped for
/// its. Cluster-wide and existence-guarded, exactly as the app login above is
/// (postgres.rs says why they are never dropped).
///
/// Nothing is granted here beyond the memberships: `openledger_read` carries
/// its own SELECT list in the baseline, and a read login that needed a grant
/// the baseline does not make would be a finding about the baseline rather
/// than something for a fixture to paper over.
async fn read_url_under_its_own_login(
    pool: &PgPool,
    db_url: &str,
    login: &str,
    policy_roles: &[&str],
) -> Result<String, Box<dyn std::error::Error>> {
    for policy_role in policy_roles {
        postgres::ensure_login_role(pool, login, policy_role).await?;
    }
    postgres::swap_credentials(db_url, login, postgres::LOGIN_PASSWORD)
}

/// The compiled binary, serving the given URL on a port the OS chose, and the
/// base URL it announced on its first line of stdout — bound to port 0, so
/// the announcement is the contract rather than a number this file guessed.
///
/// `READ_DATABASE_URL` is set only when a test asked for a read login of its
/// own: unset is the shipped default, and the fallback to `DATABASE_URL` is a
/// configuration the fence has to hold under (ADR-0019).
fn spawn_the_server_and_read_its_address(
    serve_url: &str,
    read_url: Option<&str>,
) -> Result<(Server, String), Box<dyn std::error::Error>> {
    let mut command = postgres::openledger()?;
    command
        .args(["serve", "--bind", "127.0.0.1:0"])
        .env("DATABASE_URL", serve_url)
        .stdout(Stdio::piped());
    if let Some(read_url) = read_url {
        command.env("READ_DATABASE_URL", read_url);
    }
    let mut server = Server(command.spawn()?);
    let stdout = server.0.stdout.take().ok_or("server stdout not captured")?;
    let mut announced = String::new();
    BufReader::new(stdout).read_line(&mut announced)?;
    let base = announced
        .trim()
        .strip_prefix("listening on ")
        .ok_or_else(|| format!("unexpected first line: {announced:?}"))?
        .to_owned();
    Ok((server, base))
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
