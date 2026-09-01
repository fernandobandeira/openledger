//! Where the databases come from: the admin URL (environment or fallback
//! container), scratch databases, and `openledger migrate` under the one-at-
//! a-time mutex. No `#[test]` lives under `support/` — that is the layout
//! rule stated in main.rs.

use std::collections::BTreeSet;
use std::process::Command;
use std::sync::{Mutex, OnceLock, PoisonError};

use sqlx::{AssertSqlSafe, Connection, PgConnection};
use testcontainers_modules::postgres::Postgres;
use testcontainers_modules::testcontainers::runners::SyncRunner;
use testcontainers_modules::testcontainers::{Container, ImageExt, ReuseDirective};

/// The URL scratch databases are created through. DATABASE_URL wins when set —
/// CI's schema job and `make test` point it at a PostgreSQL they already run.
/// Without it, ONE `postgres:18-alpine` container serves the whole test
/// binary: 18 is a floor, not a preference — `uuidv7()` is a PostgreSQL 18
/// built-in and the baseline defaults primary keys to it.
pub fn admin_url() -> Result<String, Box<dyn std::error::Error>> {
    if let Ok(url) = std::env::var("DATABASE_URL") {
        return Ok(url);
    }
    // A Result in the static, not a panic: a failed start is an error every
    // test reports, not a poisoned lock the second test trips over.
    static FALLBACK: OnceLock<Result<Fallback, String>> = OnceLock::new();
    let fallback = FALLBACK.get_or_init(|| {
        // The blocking start on its own thread: the sync runner blocks on a
        // runtime of its own, which panics when called from inside a tokio
        // runtime — and every caller here is a #[tokio::test].
        std::thread::spawn(start_container)
            .join()
            .map_err(|_| "the container-start thread panicked".to_owned())?
    });
    match fallback {
        Ok(container) => Ok(container.url.clone()),
        Err(err) => Err(err.clone().into()),
    }
}

/// The fixed name of the one fallback container every no-DATABASE_URL run
/// shares. Reclaim it with `docker rm -f openledger-e2e-pg`; the next run
/// recreates it on demand. Never touch `openledger-db-1` — that one is
/// `make up`'s, holds a real local book, and is not this suite's to manage.
const REUSED_CONTAINER: &str = "openledger-e2e-pg";

struct Fallback {
    url: String,
    // Held so the container outlives every test in this run. It outlives the
    // RUN too, on purpose: testcontainers 0.27 ships no ryuk reaper (grep its
    // source for one), its only cleanup is Drop, and a static is never
    // dropped — so an anonymous container here leaked one per run. Instead
    // the container is NAMED and marked `ReuseDirective::Always` (the
    // `reusable-containers` feature, enabled in the workspace Cargo.toml):
    // the runner finds `openledger-e2e-pg` by name, restarts it if stopped,
    // and creates it only when absent — at most ONE container ever exists,
    // and later runs skip the image start. Scratch state cannot carry over:
    // every scratch database opens with DROP DATABASE IF EXISTS. Two
    // first-runs racing the same name is the one case this trades away — the
    // loser fails on the name conflict and a re-run reuses; the per-run leak
    // was worse.
    _container: Container<Postgres>,
}

fn start_container() -> Result<Fallback, String> {
    let container = Postgres::default()
        .with_tag("18-alpine")
        .with_container_name(REUSED_CONTAINER)
        .with_reuse(ReuseDirective::Always)
        // 400, not the image's 100, and for the same reason
        // `docker-compose.yml` says it there: this suite runs one serving
        // process per test in parallel, each holding a writer pool of one
        // connection per dispatcher (`db`'s POOL_CONNECTIONS, 38). The
        // measured peak across four 16-thread `make test` runs is 187-227
        // backends; 100 fails the run with `sorry, too many clients already`.
        // Reuse means an ALREADY-RUNNING container
        // from before this line keeps whatever it was started with —
        // `docker rm -f openledger-e2e-pg` is what picks the new setting up.
        .with_cmd(["postgres", "-c", "max_connections=400"])
        .start()
        .map_err(|e| format!("starting the fallback postgres container: {e}"))?;
    // Host and mapped port resolved here, on this thread, for the same reason
    // the start is: on the sync container they block too.
    let host = container
        .get_host()
        .map_err(|e| format!("fallback container host: {e}"))?;
    let port = container
        .get_host_port_ipv4(5432)
        .map_err(|e| format!("fallback container port: {e}"))?;
    Ok(Fallback {
        url: format!("postgres://postgres:postgres@{host}:{port}/postgres"),
        _container: container,
    })
}

/// Same URL, different database name: `postgres://u:p@host:port/db?x` keeps
/// everything but `db`.
fn swap_database(url: &str, name: &str) -> Result<String, Box<dyn std::error::Error>> {
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

/// The compiled binary — the thing under test. `CARGO_BIN_EXE_openledger`
/// is only set by cargo for the package that DEFINES the binary, and this
/// suite deliberately lives in its own crate (crates/e2e owns the test-only
/// capability allowances in deny.toml) — so resolve the binary from this
/// test executable's own location instead: test binaries run from
/// `target/<profile>/deps/`, and the bin sits one directory up (the same
/// resolution assert_cmd uses). A path lookup guarantees no build: `make
/// test` and CI run `cargo build -p openledger` before the suite, and the
/// error below names that remedy for anyone running `cargo test -p e2e`
/// bare after a clean.
pub fn openledger() -> Result<Command, Box<dyn std::error::Error>> {
    let mut path = std::env::current_exe()?;
    path.pop(); // this test binary's file name
    if path.ends_with("deps") {
        path.pop();
    }
    path.push(format!("openledger{}", std::env::consts::EXE_SUFFIX));
    if !path.is_file() {
        return Err(format!(
            "{} does not exist — run `cargo build -p openledger` first              (make test and CI do; a bare `cargo test -p e2e` builds only the suite)",
            path.display()
        )
        .into());
    }
    Ok(Command::new(path))
}

/// Drop and recreate the scratch database `e2e_<name>`, and return a URL into
/// it. Deliberately does NOT migrate — `startup.rs` needs the unmigrated
/// database as its fixture; `TestBook` calls [`migrate`] next.
///
/// Each name may be claimed ONCE per test binary. The open with `DROP
/// DATABASE ... WITH (FORCE)` is what makes a collision dangerous rather
/// than merely untidy: FORCE terminates every backend on the database, so
/// two tests sharing a name means the second's setup kills the first's
/// running server and pool mid-test, and the failure surfaces as an
/// unrelated connection error in whichever test loses. The registry turns
/// that race into an immediate, named error at the point of the mistake.
pub async fn create_scratch_db(name: &str) -> Result<String, Box<dyn std::error::Error>> {
    static CLAIMED: Mutex<BTreeSet<String>> = Mutex::new(BTreeSet::new());
    if !CLAIMED
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .insert(name.to_owned())
    {
        return Err(format!(
            "scratch database name {name:?} is already claimed by another test in this binary — \
             pick a unique name, or its DROP DATABASE WITH (FORCE) kills that test's server"
        )
        .into());
    }
    // The database name is spliced into DDL below (CREATE DATABASE takes
    // no bind parameters), so refuse anything that is not the bare
    // lowercase identifier a test writes as a literal. That check is what
    // makes the AssertSqlSafe claims below true.
    if name.is_empty() || !name.bytes().all(|b| b.is_ascii_lowercase() || b == b'_') {
        return Err(format!("test database name {name:?} is not a bare identifier").into());
    }
    let admin_url = admin_url()?;
    let db = format!("e2e_{name}");

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
    swap_database(&admin_url, &db)
}

/// The LOGIN roles the role-separation tests connect as, and the password
/// they share. Roles are CLUSTER-wide, not per-database: they outlive every
/// scratch database, they are visible to every test at once, and a `DROP
/// ROLE` here would race a sibling test that is connected as the role — so
/// the names are FIXED, creation is existence-guarded, and nothing ever
/// drops them. Reclaim by hand with `DROP ROLE e2e_app_login, e2e_read_login`
/// on a quiet cluster if they bother you; the next run recreates them.
pub const APP_LOGIN: &str = "e2e_app_login";
pub const READ_LOGIN: &str = "e2e_read_login";
pub const LOGIN_PASSWORD: &str = "e2e-only";

/// Create the LOGIN role `login`, inheriting `policy_role`'s grants and RLS
/// policies (`IN ROLE`, and INHERIT is the default) — or CONVERGE an
/// existing one. Two reasons the block below is not a plain guarded CREATE:
/// the guard alone is not race-proof (two tests can both see the role
/// absent and race `CREATE ROLE` into `pg_authid_rolname_index`, so the
/// loser's duplicate error is swallowed), and a fixed cluster-wide name can
/// pre-exist with someone else's password or membership — so the ALTER and
/// GRANT run unconditionally, healing the role to this fixture's contract
/// instead of failing every later run with an authentication error.
pub async fn ensure_login_role(
    pool: &sqlx::PgPool,
    login: &str,
    policy_role: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    // Spliced into DDL (CREATE ROLE takes no bind parameters); the same
    // bare-identifier reasoning as create_scratch_db, with digits allowed
    // after the first byte (`e2e_app_login` carries one).
    for name in [login, policy_role] {
        if !name.bytes().next().is_some_and(|b| b.is_ascii_lowercase())
            || !name
                .bytes()
                .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_')
        {
            return Err(format!("role name {name:?} is not a bare identifier").into());
        }
    }
    sqlx::raw_sql(AssertSqlSafe(format!(
        "DO $$ BEGIN
             BEGIN
                 CREATE ROLE {login};
             EXCEPTION WHEN duplicate_object OR unique_violation THEN NULL;
             END;
             ALTER ROLE {login} LOGIN PASSWORD '{LOGIN_PASSWORD}';
             GRANT {policy_role} TO {login};
         END $$"
    )))
    .execute(pool)
    .await?;
    Ok(())
}

/// Same URL, different credentials: `postgres://u:p@host:port/db?x` keeps
/// everything from the host on. How a test connects as one of the LOGIN
/// roles above without re-deriving host, port or database name.
pub fn swap_credentials(
    url: &str,
    user: &str,
    password: &str,
) -> Result<String, Box<dyn std::error::Error>> {
    let rest = url
        .strip_prefix("postgres://")
        .ok_or("the admin URL is not postgres://")?;
    let host_onward = match rest.split_once('@') {
        Some((_credentials, host_onward)) => host_onward,
        None => rest,
    };
    Ok(format!("postgres://{user}:{password}@{host_onward}"))
}

/// `openledger migrate` into one scratch database. Serialized across tests:
/// the migrator's advisory lock keys on the database (the database OID is
/// part of the lock tag), but the baseline's role guard reads the
/// CLUSTER-wide pg_roles — two migrates into sibling scratch databases on a
/// fresh cluster both see the roles absent and race CREATE ROLE into
/// pg_authid_rolname_index. No adopter runs two first-migrates on one
/// cluster at once; this suite does.
pub fn migrate(db_url: &str) -> Result<(), Box<dyn std::error::Error>> {
    static MIGRATE: Mutex<()> = Mutex::new(());
    let _one_at_a_time = MIGRATE
        .lock()
        .map_err(|_| "a test panicked while migrating")?;
    let migrated = openledger()?
        .arg("migrate")
        .env("DATABASE_URL", db_url)
        .status()?;
    if migrated.success() {
        Ok(())
    } else {
        Err("openledger migrate failed".into())
    }
}
