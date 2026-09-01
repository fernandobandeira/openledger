//! The core: the posting types, their validation, the canonical idempotency
//! hash, the pure posting math, the [`Ledger`] port, and the writer service
//! that stands behind it — and deliberately not one line of SQL.
//!
//! This crate and its Postgres writer used to be one crate, co-located under
//! ADR-0004's reasoning that PostgreSQL is half the product. The co-location
//! is superseded: deny.toml's bans ratchet is the hexagonal boundary made
//! machine-checked, and it only means something if the crate that holds the
//! domain can be FORBIDDEN sqlx outright — so the adapter lives in
//! `postgres/`, and this crate compiles with no database in the room. That
//! directory is a SEPARATE crate (`ledger-postgres`), a nested workspace
//! member with its own manifest and its own deny.toml allowance — never a
//! module of this one, because a module cannot be forbidden a dependency.
//! What ADR-0004 still decides is what the adapter looks like on the inside:
//! the SQL there is the product's reasoning about PostgreSQL, not an
//! interchangeable backend behind a storage-agnostic interface, and no such
//! interface is pretended here — both ports below are the ledger's contract,
//! not a generic store's.
//!
//! Inside the crate the layout is: `domain` is the pure core's types —
//! entities, value objects, their validation, the canonical hash and the
//! versioned payload rendering; `postings` is the posting math the writer
//! runs before its SQL does; `port` is the one trait a consumer sees;
//! `repository` is the outbound port the adapter implements; and `service`
//! is the writer — the claim-or-replay use-case, orchestrated over the
//! repository.
//!
//! The read path is the same layout again, one ring over (ADR-0019): `reports`
//! is the second INBOUND port — a port of its own rather than a method on
//! [`Ledger`], because every variant of [`WriteError`] except `Storage`
//! promises *"nothing was written"* and a read cannot say that; `report_store`
//! is its outbound port; and `report_service` is the reader, whose one piece of
//! judgement is the cursor rule.
//!
//! ADR-0021 added a second WRITE to the first ring rather than a third ring:
//! `accounts` is the account-opening command — its validation, its canonical
//! hash and its stored payload, the same four things `domain` owns for a
//! posting — and the port, the repository and the service each grew for it
//! where they already were. It is a module of its own because a posting and
//! an opening share nothing but the idempotency spine, and the spine is
//! `ledger_events`, not a Rust type.

mod accounts;
mod domain;
mod port;
mod postings;
mod report_service;
mod report_store;
mod reports;
mod repository;
mod service;

// Consumers write `ledger::Posting`; the module layout is this crate's own
// business. Of the posting math only the TYPES are exported — the adapter
// needs `Append` (and the `Leg`, `Delta`, `Direction` inside it) because the
// `Repository` port's signatures name them; the functions are `pub(crate)`,
// called by the writer service alone, so the math's order of operations
// cannot be re-orchestrated outside this crate.
pub use accounts::{
    Account, AccountOpened, AccountOwner, AccountOwnerType, ChartTriple, OpenAccount,
};
pub use domain::{Invalid, PostTransaction, Posted, Posting, TransactionStatus};
pub use port::{Ledger, OpenAccountError, WriteError};
pub use postings::{Append, Delta, Direction, Leg};
pub use report_service::ReportService;
pub use report_store::{
    AccountListingRead, AccountStatementRead, BalanceSheetRead, IncomeStatementRead, ReadBounds,
    ReportRefusal, ReportStore, Scoped, TrialBalanceRead,
};
pub use reports::{
    AccountBalance, AccountBalanceQuery, AccountListing, AccountListingQuery, AccountStatement,
    AccountStatementEntry, AccountStatementQuery, BalanceSheetQuery, Cursor, CursorQuery,
    CursorUnparseable, IncomeStatementQuery, ReadError, Reports, Statement, StatementAxis,
    StatementKey, StatementLine, Transaction, TransactionEntry, TransactionQuery, TrialBalance,
    TrialBalanceQuery, TrialBalanceRow,
};
pub use repository::{
    Appended, BalanceUpsert, BatchMember, Claimed, MemberOutcome, OpenedAccount, Repository,
    StorageError, StoredAccount, StoredResult, SupersedeRefusal,
};
pub use service::LedgerService;
