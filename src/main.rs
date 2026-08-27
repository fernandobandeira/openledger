//! openledger — an open-source double-entry ledger.
//!
//! The ledger service is not built yet (see the roadmap in `site/content/roadmap.md`). The one thing
//! this binary does today is apply migrations, and that is deliberate rather
//! than incidental: ADR-0003 makes `migrate` a *subcommand of the same binary*,
//! so a deployment runs the same image with a different command, and the ledger
//! process never migrates.
//!
//! The command line is `clap`'s derive, so the *shape* of the interface — flag
//! forms, environment fallbacks, the range on the lock budget, the help text —
//! is declared on the fields below rather than parsed by hand. What is not
//! `clap`'s is the **exit code**, which for this binary is an operator-facing
//! contract rather than a detail: `Failure` below defines 1, 2 and 3, and the
//! only reason `main` handles `clap`'s errors separately is to keep a usage
//! error at 2 whether it came from `clap` or from us.

mod migrate;

use std::io::Write;
use std::process::ExitCode;
use std::time::Duration;

use clap::error::ErrorKind;
use clap::{CommandFactory, Parser, Subcommand};

/// How long a migrator waits for another one to finish before giving up.
///
/// **This is a number someone has to choose.** A migration slower than the
/// budget makes a *second* migrator give up rather than wait. Under a pre-deploy
/// job that is the right failure — a job that gives up is visible and
/// re-runnable, where a job that hangs forever holds up the deploy silently.
/// Fifteen minutes is long enough for a large `CREATE INDEX CONCURRENTLY` and
/// short enough that a stuck one is noticed.
const DEFAULT_LOCK_WAIT_SECS: u64 = 900;

/// A day. Not decoration: `Instant + Duration` panics on overflow, and a `u64`
/// of seconds reaches it. Anything near this is a typo either way.
const MAX_LOCK_WAIT_SECS: u64 = 86_400;

/// The long help, laid out here rather than reflowed by `clap`.
///
/// `clap` wraps text to the terminal width only under its `wrap_help` feature,
/// which pulls in a terminal-size probe and the `rustix` tree beneath it — five
/// crates to re-wrap prose that is going into a deploy log at whatever width
/// the log viewer has. Without that feature `clap` prints these strings as
/// written, newlines and all, so the line breaks below are the ones an operator
/// sees. A doc comment would not do: `clap_derive` collapses those into
/// paragraphs before `clap` ever sees them.
const MIGRATE_ABOUT: &str = "\
Apply every pending migration, then exit.

Run it as a pre-deploy job — a Kubernetes Job, a Helm pre-upgrade
hook, an ECS one-off task — that must succeed before the new pods
roll. A bad migration should stop a deploy, not crash-loop a
ledger (ADR-0003).";

const DATABASE_URL_HELP: &str = "\
PostgreSQL connection string.

Prefer DATABASE_URL over this flag, which is visible to
anyone who can read the process table.";

const LOCK_SECS_HELP: &str = "\
Seconds to wait for another migrator to finish before
giving up.

A value outside the range is a usage error, never a silent
fall back to the default: the point of the setting is that
someone chose the number.";

/// The half of the help that is not a description of a flag: what the exit codes
/// mean, and how to connect. Shown under `--help`, not the shorter `-h`.
const OPERATING_NOTES: &str = "\
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

#[derive(Parser)]
#[command(
    name = "openledger",
    about = "openledger — an open-source double-entry ledger",
    after_long_help = OPERATING_NOTES,
    // No `--version`: the crate is 0.0.0 and nothing has been released, so the
    // flag would answer a question this binary cannot yet answer honestly.
    disable_version_flag = true
)]
struct Cli {
    #[command(subcommand)]
    command: Option<Command>,
}

#[derive(Subcommand)]
enum Command {
    /// Apply every pending migration, then exit
    #[command(long_about = MIGRATE_ABOUT)]
    Migrate {
        /// PostgreSQL connection string
        ///
        // `Option`, and not `clap`'s `required`, for the sake of the message:
        // "the following required arguments were not provided" names the flag
        // and not the environment variable an operator should reach for
        // instead. `dispatch` supplies the one that does.
        #[arg(
            long,
            env = "DATABASE_URL",
            hide_env_values = true,
            value_name = "URL",
            long_help = DATABASE_URL_HELP
        )]
        database_url: Option<String>,

        /// Seconds to wait for another migrator before giving up
        ///
        // `hide_env_values` here is cosmetic rather than a secret: `clap`
        // renders an unset variable as `[env: NAME=]`, and the trailing `=` in
        // the common case is worse than not showing the value at all.
        #[arg(
            long = "lock-secs",
            env = "OPENLEDGER_MIGRATE_LOCK_SECS",
            hide_env_values = true,
            value_name = "SECS",
            default_value_t = DEFAULT_LOCK_WAIT_SECS,
            value_parser = clap::value_parser!(u64).range(1..=MAX_LOCK_WAIT_SECS),
            long_help = LOCK_SECS_HELP
        )]
        lock_secs: u64,
    },
}

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
    let cli = match Cli::try_parse() {
        Ok(cli) => cli,
        Err(error) => return clap_exit(error),
    };

    match dispatch(cli) {
        Ok(()) => ExitCode::SUCCESS,
        Err(failure) => {
            eprintln!("openledger: {}", failure.message());
            ExitCode::from(failure.code())
        }
    }
}

/// `clap` formats its own errors, so they are printed as they come rather than
/// through `Failure`'s `openledger: ` prefix — a usage error is several lines
/// and a prefix on the first one reads as a truncated message.
///
/// The exit code, though, is ours. `clap`'s own convention already agrees on 2,
/// but that agreement is a coincidence this pins down: everything that is not a
/// request to *print something* is a usage error, which this binary defines as
/// exit 2. Asking for help is exit 0, on stdout, which is what `error.print()`
/// does for those two kinds.
fn clap_exit(error: clap::Error) -> ExitCode {
    let _ = error.print();
    match error.kind() {
        ErrorKind::DisplayHelp | ErrorKind::DisplayVersion => ExitCode::SUCCESS,
        _ => ExitCode::from(2),
    }
}

fn dispatch(cli: Cli) -> Result<(), Failure> {
    match cli.command {
        // Bare `openledger`, which a container started with no command gets.
        // Help on stdout and exit 0, the same as asking for it.
        None => {
            let _ = Cli::command().print_long_help();
            Ok(())
        }
        Some(Command::Migrate {
            database_url,
            lock_secs,
        }) => {
            let database_url = database_url.ok_or_else(|| {
                Failure::Usage(
                    "no database URL — set DATABASE_URL or pass --database-url".to_owned(),
                )
            })?;
            block_on(migrate::run(&database_url, Duration::from_secs(lock_secs)))
        }
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

#[cfg(test)]
mod tests {
    use super::*;

    /// `clap` builds the parser at runtime from the derive, and an inconsistent
    /// one — a duplicate long flag, a default that its own `value_parser`
    /// rejects — panics on first use rather than failing to compile. This is
    /// that check, and it is why the assertion is worth a test at all.
    #[test]
    fn the_command_line_is_well_formed() {
        Cli::command().debug_assert();
    }
}
