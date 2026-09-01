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
//! map to an exit code — and, beside it, the composition root in
//! `serve_the_api`, the one place the Postgres adapters are wired into their
//! services, and the services into the api router as its `Ledger` and — since
//! ADR-0019's read path — its `Reports`.
//!
//! Beside it, since ADR-0018, is `batching` — the accumulator's machinery:
//! the queue, the dispatcher pool and the permit each dispatcher's turn is.
//! It is here because it needs a runtime and nothing in the core does, and
//! the ADR states the cost plainly: this crate is no longer ONLY a
//! composition root. The branching business logic it would otherwise have
//! brought stayed in `ledger::LedgerService::post_batch`, where the
//! fake-repository tests are; if the machinery grows past a few hundred
//! lines, a `ledger-batch` crate is the right move rather than more of this.

mod batching;
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
        Some(Command::Serve {
            database_url,
            read_database_url,
            bind,
            dashboard,
        }) => {
            let database_url = require_database_url(database_url)?;
            // The flag is a bool at the command line and a named choice
            // everywhere below it: the api crate decides what serving the
            // dashboard means, and this is the one place the two spellings
            // meet.
            let dashboard = if dashboard {
                api::Dashboard::Served
            } else {
                api::Dashboard::NotServed
            };
            block_on(serve_the_api(
                &database_url,
                read_database_url,
                bind,
                dashboard,
            ))
        }
    }
}

/// The composition root: this is the one place the Postgres adapters are
/// chosen as the two services' storage, and the services as the api router's
/// `Ledger` and `Reports`. The api crate never sees a pool — it takes the
/// ports; the pools' sizing lives in db — and this crate never names an sqlx
/// type: the adapters take `db::Database` and `db::ReadDatabase`, which is
/// what lets deny.toml refuse sqlx here. The startup gate runs before anything
/// binds; after that this returns only when serving stops.
async fn serve_the_api(
    database_url: &str,
    read_database_url: Option<String>,
    bind: std::net::SocketAddr,
    dashboard: api::Dashboard,
) -> Result<(), Failure> {
    // Lazy, so nothing has connected yet: a malformed URL is the only failure
    // here, and it is a usage error.
    let database = db::Database::connect_lazy(database_url)
        .map_err(|e| Failure::Usage(format!("could not parse the database URL: {e}")))?;
    let read_database =
        db::ReadDatabase::connect_lazy(read_database_url.as_deref().unwrap_or(database_url))
            .map_err(|e| Failure::Usage(format!("could not parse the read database URL: {e}")))?;
    // The startup gate, before anything binds or listens: an unmigrated or
    // behind database is exit 1 with the remedy (`openledger migrate`) in the
    // message — not a server that fails its first query at runtime. Lock-free;
    // ADR-0003's "the ledger process never migrates" is why it can be. It runs
    // on the WRITER's pool: the read pool is lazy and a deployment that has
    // not created its read login yet should fail on its first read with the
    // backend's own message, not refuse to serve the write path.
    db::verify_schema_is_current(&database)
        .await
        .map_err(Failure::Failed)?;
    let writers = one_writer_per_dispatcher(&database);
    api::run(
        batching::BatchingLedger::dispatching_over(writers),
        the_reader(&read_database),
        bind,
        dashboard,
    )
    .await
    .map_err(Failure::from)
}

/// The reader: one report service over one Postgres report store over the read
/// pool.
///
/// **There is no pool of readers to match the writers', and the asymmetry is
/// the design.** A writer holds a stripe affinity for its lifetime, so the
/// writers are N distinct services (ADR-0018 §1); a read holds nothing, takes
/// a connection for the length of its transaction and gives it back, so one
/// service over one pool is the whole of it. What limits concurrent reports is
/// `db::READ_POOL_CONNECTIONS`, in the crate that owns pool sizing.
fn the_reader(
    read_database: &db::ReadDatabase,
) -> ledger::ReportService<ledger_postgres::PgReportStore> {
    ledger::ReportService::new(ledger_postgres::PgReportStore::over_the_read_pool(
        read_database,
    ))
}

/// The writer pool: one writer per dispatcher, each striping on the index it
/// will hold for its lifetime. The index is the writer's for good because
/// worker affinity is the property of being CONSTANT for one writer and
/// different between concurrent ones (ADR-0018 §1) — a single writer holding a
/// single affinity would put every write for one account on one stripe, and
/// striping would then buy nothing.
fn one_writer_per_dispatcher(
    database: &db::Database,
) -> Vec<ledger::LedgerService<ledger_postgres::PgRepository>> {
    (0..batching::DISPATCHERS)
        .map(|index| {
            ledger::LedgerService::new(ledger_postgres::PgRepository::for_writer(
                database,
                index as u32,
            ))
        })
        .collect()
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
