//! openledger — an open-source double-entry ledger.
//!
//! The ledger service is not built yet (see the roadmap in `site/content/roadmap.md`). The one thing
//! this binary does today is apply migrations, and that is deliberate rather
//! than incidental: ADR-0003 makes `migrate` a *subcommand of the same binary*,
//! so a deployment runs the same image with a different command, and the ledger
//! process never migrates.

mod migrate;

use std::io::Write;
use std::process::ExitCode;
use std::time::Duration;

/// How long a migrator waits for another one to finish before giving up.
///
/// **This is a number someone has to choose.** A migration slower than the
/// budget makes a *second* migrator give up rather than wait. Under a pre-deploy
/// job that is the right failure — a job that gives up is visible and
/// re-runnable, where a job that hangs forever holds up the deploy silently.
/// Fifteen minutes is long enough for a large `CREATE INDEX CONCURRENTLY` and
/// short enough that a stuck one is noticed.
const DEFAULT_LOCK_WAIT: Duration = Duration::from_secs(900);

/// A day. Not decoration: `Instant + Duration` panics on overflow, and a `u64`
/// of seconds reaches it. Anything near this is a typo either way.
const MAX_LOCK_WAIT_SECS: u64 = 86_400;

const USAGE: &str = "\
openledger — an open-source double-entry ledger

USAGE
    openledger migrate [--database-url <url>]

COMMANDS
    migrate     Apply every pending migration, then exit.

                Run it as a pre-deploy job — a Kubernetes Job, a Helm
                pre-upgrade hook, an ECS one-off task — that must succeed
                before the new pods roll. A bad migration should stop a
                deploy, not crash-loop a ledger (ADR-0003).

ENVIRONMENT
    DATABASE_URL                    PostgreSQL connection string. Prefer this
                                    over --database-url, which is visible to
                                    anyone who can read the process table.
    OPENLEDGER_MIGRATE_LOCK_SECS    Seconds to wait for another migrator to
                                    finish before giving up. Default 900,
                                    maximum 86400.

EXIT CODES
    0   nothing left to apply
    1   the migration failed, or the database could not be reached
        — do not retry blindly; look at the error
    2   the command line or the environment is wrong
    3   another migrator held the lock for the whole budget
        — safe to re-run

CONNECTING
    Use sslmode=verify-full against a managed database. sqlx defaults to
    `prefer`, which will fall back to cleartext, and `require` encrypts
    without verifying anything. TLS roots are compiled in, so the image
    needs no certificate bundle of its own.
";

/// What went wrong, and what an operator should do about it. The distinction is
/// the whole point: a job that gives up on the lock should be retried, and a job
/// that failed a migration must not be.
pub enum Failure {
    /// The invocation is wrong. Retrying changes nothing.
    Usage(String),
    /// Someone else held the lock for the whole budget. Safe to re-run.
    Locked(String),
    /// The migration or the connection failed. Read the error first.
    Failed(String),
}

impl Failure {
    fn message(&self) -> &str {
        match self {
            Self::Usage(m) | Self::Locked(m) | Self::Failed(m) => m,
        }
    }

    fn code(&self) -> u8 {
        match self {
            Self::Failed(_) => 1,
            Self::Usage(_) => 2,
            Self::Locked(_) => 3,
        }
    }
}

/// `println!` panics on a broken pipe, and this crate denies `panic`. A closed
/// stdout after a committed migration must not turn a success into exit 101.
pub fn say(message: &str) {
    let _ = writeln!(std::io::stdout(), "{message}");
}

fn main() -> ExitCode {
    match dispatch() {
        Ok(()) => ExitCode::SUCCESS,
        Err(failure) => {
            eprintln!("openledger: {}", failure.message());
            ExitCode::from(failure.code())
        }
    }
}

fn dispatch() -> Result<(), Failure> {
    let args: Vec<String> = std::env::args().skip(1).collect();

    match args.first().map(String::as_str) {
        Some("migrate") => match migrate_args(args.get(1..).unwrap_or_default())? {
            None => {
                say(USAGE);
                Ok(())
            }
            Some(database_url) => block_on(migrate::run(&database_url, lock_wait()?)),
        },
        Some("help" | "--help" | "-h") | None => {
            say(USAGE);
            Ok(())
        }
        Some(other) => Err(Failure::Usage(format!(
            "unknown command `{other}`\n\n{USAGE}"
        ))),
    }
}

/// The connection string, from the flag or the environment, in that order.
/// `Ok(None)` means the caller asked for help instead.
fn migrate_args(args: &[String]) -> Result<Option<String>, Failure> {
    let mut from_flag = None;
    let mut rest = args.iter();

    while let Some(arg) = rest.next() {
        match arg.as_str() {
            "--help" | "-h" => return Ok(None),
            "--database-url" => match rest.next() {
                Some(url) => from_flag = Some(url.clone()),
                None => return Err(Failure::Usage("--database-url needs a value".to_owned())),
            },
            other => match other.strip_prefix("--database-url=") {
                Some(url) => from_flag = Some(url.to_owned()),
                None => {
                    return Err(Failure::Usage(format!(
                        "unknown argument `{other}`\n\n{USAGE}"
                    )));
                }
            },
        }
    }

    from_flag
        .or_else(|| std::env::var("DATABASE_URL").ok())
        .map(Some)
        .ok_or_else(|| {
            Failure::Usage("no database URL — set DATABASE_URL or pass --database-url".to_owned())
        })
}

/// A malformed or absurd budget is an error, never a silent fall back to the
/// default: the whole point of the setting is that someone chose the number.
fn lock_wait() -> Result<Duration, Failure> {
    let raw = match std::env::var("OPENLEDGER_MIGRATE_LOCK_SECS") {
        Err(_) => return Ok(DEFAULT_LOCK_WAIT),
        Ok(raw) => raw,
    };

    match raw.parse::<u64>() {
        Ok(secs) if (1..=MAX_LOCK_WAIT_SECS).contains(&secs) => Ok(Duration::from_secs(secs)),
        _ => Err(Failure::Usage(format!(
            "OPENLEDGER_MIGRATE_LOCK_SECS must be a whole number of seconds \
             between 1 and {MAX_LOCK_WAIT_SECS}, not `{raw}`"
        ))),
    }
}

/// One current-thread runtime, built by hand rather than by `#[tokio::main]`,
/// so that its failure is a message instead of a panic — ADR-0001 denies
/// `unwrap`, `expect` and `panic` across this crate.
fn block_on(future: impl Future<Output = Result<(), Failure>>) -> Result<(), Failure> {
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|e| Failure::Failed(format!("could not start the async runtime: {e}")))?
        .block_on(future)
}
