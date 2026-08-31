//! The shape of the command line — `clap`'s derive, and the prose it prints.
//!
//! The command line is `clap`'s derive, so the *shape* of the interface — flag
//! forms, environment fallbacks, the range on the lock budget, the help text —
//! is declared on the fields below rather than parsed by hand. What is not
//! `clap`'s is the **exit code**, which lives in `failure.rs`.

use clap::{Parser, Subcommand};

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

const SERVE_ABOUT: &str = "\
Serve the ledger API until stopped.

One endpoint today: POST /v1/transactions, the posting engine
behind it (M3). Run `openledger migrate` first: serve checks
that the schema is current before it listens, and an unmigrated
or behind database is exit 1 naming that command. The check
takes no locks — the serving process never migrates (ADR-0003).";

const RECONCILE_ABOUT: &str = "\
Run the ten reconciliation checks, then exit.

One REPEATABLE READ READ ONLY transaction as openledger_recon —
the role the views grant to, assumed with SET ROLE, so the login
behind DATABASE_URL needs membership in it. Every check clean is
exit 0; breaks are exit 1 with each breaking check named on
stderr. The sweep takes ACCESS SHARE only and cannot block a
posting. Schedule it once a day at a cut-off (ADR-0010).";

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
    0   nothing left to apply, or every reconciliation check is clean
    1   the migration failed, the database could not be reached, or
        the sweep found breaks — do not retry blindly; look at the error
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
pub struct Cli {
    #[command(subcommand)]
    pub command: Option<Command>,
}

#[derive(Subcommand)]
pub enum Command {
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

    /// Run the reconciliation sweep, then exit
    #[command(long_about = RECONCILE_ABOUT)]
    Reconcile {
        /// PostgreSQL connection string
        ///
        // `Option` for the same message-quality reason as `migrate`'s:
        // `dispatch` refuses its absence naming both spellings.
        #[arg(
            long,
            env = "DATABASE_URL",
            hide_env_values = true,
            value_name = "URL",
            long_help = DATABASE_URL_HELP
        )]
        database_url: Option<String>,
    },

    /// Serve the ledger API
    #[command(long_about = SERVE_ABOUT)]
    Serve {
        /// PostgreSQL connection string
        #[arg(
            long,
            env = "DATABASE_URL",
            hide_env_values = true,
            value_name = "URL",
            long_help = DATABASE_URL_HELP
        )]
        database_url: Option<String>,

        /// Address to listen on
        ///
        // A typed `SocketAddr`, so a malformed address is CLAP's usage error
        // (exit 2, the flag named) — the api crate receives an address, never
        // a string to re-refuse.
        #[arg(
            long,
            env = "OPENLEDGER_BIND",
            hide_env_values = true,
            value_name = "ADDR",
            default_value = "127.0.0.1:8080",
            value_parser = clap::value_parser!(std::net::SocketAddr)
        )]
        bind: std::net::SocketAddr,
    },
}

#[cfg(test)]
mod tests {
    //! `clap` builds the parser at runtime from the derive, and an
    //! inconsistent one — a duplicate long flag, a default that its own
    //! `value_parser` rejects — panics on first use rather than failing to
    //! compile. This module is that check, and it is why the assertion is
    //! worth a test at all. What the flags MEAN (the exit codes, the
    //! migrate-then-serve split) is held by the e2e suite against the
    //! compiled binary: `startup.rs` holds exit 1's serve refusals,
    //! `exit_codes.rs` holds 2 (a malformed flag) and 3 (the lock budget
    //! spent, safe to re-run), and `reconcile.rs` holds the sweep's 0 and
    //! its breaks-on-stderr exit 1.

    use clap::CommandFactory;

    use super::*;

    #[test]
    fn the_command_line_is_well_formed() {
        Cli::command().debug_assert();
    }
}
