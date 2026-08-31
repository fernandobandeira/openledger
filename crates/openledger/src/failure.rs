//! The exit codes — for this binary an operator-facing contract rather than a
//! detail: 1, 2 and 3 are defined here and nowhere else.

/// What went wrong, and what an operator should do about it. The distinction is
/// the whole point: a job that gives up on the lock should be retried, and a job
/// that failed a migration must not be.
///
/// The exit codes are THIS binary's contract; the library crates return their
/// own error types (`db::MigrateError` carries the same three-way
/// distinction; `db::ReconcileError` folds drift into 1 — ADR-0010 assigns
/// the sweep no code of its own, and a drifted book is exactly "read the
/// error first"; `api::ServeError` is only ever exit 1 — serve's usage errors
/// are clap's now, refused before the crate is reached), and the `From`
/// impls below are the one place the mapping to a number lives.
pub enum Failure {
    /// The invocation is wrong. Retrying changes nothing.
    Usage(String),
    /// Someone else held the lock for the whole budget. Safe to re-run.
    Locked(String),
    /// The migration or the connection failed. Read the error first.
    Failed(String),
}

impl Failure {
    pub fn message(&self) -> &str {
        match self {
            Self::Usage(m) | Self::Locked(m) | Self::Failed(m) => m,
        }
    }

    pub fn code(&self) -> u8 {
        match self {
            Self::Failed(_) => 1,
            Self::Usage(_) => 2,
            Self::Locked(_) => 3,
        }
    }
}

impl From<db::MigrateError> for Failure {
    fn from(error: db::MigrateError) -> Self {
        match error {
            db::MigrateError::Usage(m) => Self::Usage(m),
            db::MigrateError::Locked(m) => Self::Locked(m),
            db::MigrateError::Failed(m) => Self::Failed(m),
        }
    }
}

impl From<db::ReconcileError> for Failure {
    fn from(error: db::ReconcileError) -> Self {
        match error {
            db::ReconcileError::Usage(m) => Self::Usage(m),
            // Drift and a failed sweep are both exit 1: an operator reads the
            // message either way, and the message is where they differ — the
            // breaking checks are named, one per line.
            db::ReconcileError::Failed(m) | db::ReconcileError::Drift(m) => Self::Failed(m),
        }
    }
}

impl From<api::ServeError> for Failure {
    fn from(error: api::ServeError) -> Self {
        Self::Failed(error.0)
    }
}
