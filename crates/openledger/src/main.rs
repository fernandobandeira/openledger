//! openledger — an open-source double-entry ledger.
//!
//! Three subcommands: `migrate` applies the schema, `serve` is the ledger
//! API, `reconcile` is the daily sweep. One binary on purpose: ADR-0003 makes
//! `migrate` a *subcommand of the same binary*, so a deployment runs the same
//! image with a different command, and the ledger process never migrates —
//! and ADR-0010 gives the sweep the same shape, a command an operator runs
//! and schedules rather than a step that happens invisibly.
//!
//! The command line is `clap`'s derive, so the *shape* of the interface — flag
//! forms, environment fallbacks, the range on the lock budget, the help text —
//! is declared on the fields in `cli.rs` rather than parsed by hand. What is
//! not `clap`'s is the **exit code**, which for this binary is an
//! operator-facing contract rather than a detail: `Failure` in `failure.rs`
//! defines 1, 2 and 3, and the only reason `main` handles `clap`'s errors
//! separately is to keep a usage error at 2 whether it came from `clap` or
//! from us. What is left in this file is exactly the seam: parse, dispatch,
//! map to an exit code — and the composition root in `dispatch`, the one
//! place the Postgres repository is wired into the writer service, and the
//! service into the api router as its `Ledger`.

mod cli;
mod failure;

use std::process::ExitCode;
use std::time::Duration;

use clap::CommandFactory;
use clap::Parser as _;
use clap::error::ErrorKind;

use cli::{Cli, Command};
use failure::Failure;

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

/// The database URL both commands require, from the flag or DATABASE_URL.
/// clap leaves it optional so its absence can be refused HERE, as a usage
/// error naming both spellings — with our exit code, not clap's error.
fn require_database_url(database_url: Option<String>) -> Result<String, Failure> {
    database_url.ok_or_else(|| {
        Failure::Usage("no database URL — set DATABASE_URL or pass --database-url".to_owned())
    })
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
            let database_url = require_database_url(database_url)?;
            block_on(async {
                db::migrate::run(&database_url, Duration::from_secs(lock_secs))
                    .await
                    .map_err(Failure::from)
            })
        }
        Some(Command::Reconcile { database_url }) => {
            let database_url = require_database_url(database_url)?;
            block_on(async {
                db::reconcile::run(&database_url)
                    .await
                    .map_err(Failure::from)
            })
        }
        Some(Command::Serve { database_url, bind }) => {
            let database_url = require_database_url(database_url)?;
            // The composition root: this is the one place the Postgres
            // repository is chosen as the writer service's storage, and the
            // service as the api router's `Ledger`. The api crate never sees
            // the pool — it takes the port; the pool's sizing lives in db —
            // and this crate never names an sqlx type: the repository takes
            // `db::Database`, which is what lets deny.toml refuse sqlx here.
            block_on(async {
                // Lazy, so nothing has connected yet: a malformed URL is the
                // only failure here, and it is a usage error.
                let database = db::Database::connect_lazy(&database_url).map_err(|e| {
                    Failure::Usage(format!("could not parse the database URL: {e}"))
                })?;
                // The startup gate, before anything binds or listens: an
                // unmigrated or behind database is exit 1 with the remedy
                // (`openledger migrate`) in the message — not a server that
                // fails its first query at runtime. Lock-free; ADR-0003's
                // "the ledger process never migrates" is why it can be.
                db::verify_schema_is_current(&database)
                    .await
                    .map_err(Failure::Failed)?;
                let repository = ledger_postgres::PgRepository::new(&database);
                api::run(ledger::LedgerService::new(repository), bind)
                    .await
                    .map_err(Failure::from)
            })
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
