//! The port, and the errors it can answer with. The api crate consumes this
//! and never the adapter (the composition root in crates/openledger is where
//! the two meet).
//!
//! **Four methods, and each carries its OWN error type.** Posting, opening an
//! account, defining a period and closing one are all writes — each can
//! honour the promise every variant below except `Storage` makes, that
//! *nothing was written* — which is what earns them their place here rather
//! than a port apiece (ADR-0021, ADR-0024). What none of them earns is a
//! share of [`WriteError`]: those ten variants are about postings, and
//! widening the enum with `account_exists` or `period_overlaps` would make
//! every handler match on refusals its endpoint cannot receive — exactly the
//! shared-error-enum shape ADR-0014 refused for the wire.

use uuid::Uuid;

use crate::accounts::{AccountOpened, OpenAccount};
use crate::domain::{PostTransaction, Posted};
use crate::periods::{ClosePeriod, DefinePeriod, PeriodClosed, PeriodDefined};

/// The port. Four consumer-facing capabilities, all writes: post a
/// transaction, open an account, define a period and close one. A read is not
/// here and cannot be — a read cannot say "nothing was written" — which is why
/// `Reports` is a port of its own (ADR-0019); anything else the API grows must
/// earn its place here the way opening and the close did.
///
/// Every method is a native async fn stated as RPITIT with an explicit
/// `+ Send` bound (an axum handler's future must be `Send`, and bare
/// `async fn` in a trait cannot promise that to a generic caller). The cost of
/// writing it this way is dyn-compatibility: `dyn Ledger` does not exist, so
/// consumers take the port as a generic parameter. With exactly one adapter
/// that trade is free — see the router's comment in the api crate for the
/// consuming side.
pub trait Ledger: Send + Sync {
    /// Post atomically, or return the stored result of having done so —
    /// ADR-0013's replay contract, restated on the port so every adapter
    /// carries it.
    fn post(
        &self,
        command: &PostTransaction,
    ) -> impl Future<Output = Result<Posted, WriteError>> + Send;

    /// Open one account, or return the stored result of having done so.
    ///
    /// The SAME replay contract, deliberately: opening an account is an
    /// accepted operation that writes no ledger transaction, which is the
    /// case ADR-0005 justified `ledger_events` by — so the claim and the
    /// account insert share one database transaction and the key behaves
    /// exactly as it does on the posting path (ADR-0021).
    fn open_account(
        &self,
        command: &OpenAccount,
    ) -> impl Future<Output = Result<AccountOpened, OpenAccountError>> + Send;

    /// Define one period, or return the stored result of having done so.
    ///
    /// The SAME replay contract again, for the same reason opening carries it
    /// (ADR-0024): defining a period is an accepted operation that writes no
    /// ledger transaction, so the claim and the `ledger_periods` insert share
    /// one database transaction and the caller's key behaves exactly as it
    /// does on the posting path.
    fn define_period(
        &self,
        command: &DefinePeriod,
    ) -> impl Future<Output = Result<PeriodDefined, DefinePeriodError>> + Send;

    /// Close one period, for one currency — the sweep, the close record and
    /// the checkpoint, in one database transaction and in that order
    /// (ADR-0024).
    ///
    /// **This is the one write on the port with NO replay**, and the
    /// difference is ADR-0011 §2's rather than this port's: the idempotency
    /// key is DERIVED (`tenant:close:period:currency`), so a second attempt
    /// meets `uq_events__idempotency` and is answered
    /// [`ClosePeriodError::PeriodAlreadyClosed`] — a close happens once, and
    /// there is no stored result to re-render.
    fn close_period(
        &self,
        command: &ClosePeriod,
    ) -> impl Future<Output = Result<PeriodClosed, ClosePeriodError>> + Send;
}

/// What an adapter can answer instead of `Posted`. Every variant except
/// `Storage` promises "nothing was written", and the writer keeps that
/// promise with a rollback, not a hope.
pub enum WriteError {
    /// Same idempotency key, different body. ADR-0013: a distinct error the
    /// caller must change the request to escape — and no row was written.
    KeyReused,
    /// A posting names an account that does not exist, or a currency its
    /// account does not hold. Nothing was written.
    AccountUnknown { account_id: Uuid, currency: String },
    /// Coalescing the legs overflowed 64-bit minor units — exactly
    /// arithmetic overflow, nothing else wears this name. Nothing was
    /// written.
    Overflow,
    /// `resolves_id` names a transaction that does not exist on this
    /// tenant's book. Nothing was written.
    ResolveTargetUnknown { resolves_id: Uuid },
    /// `resolves_id` names a transaction that is not pending — resolving
    /// posted history is the −49,223 counterexample ADR-0004 recorded, and
    /// the writer is the layer that refuses it. Nothing was written.
    ResolveTargetNotPending { resolves_id: Uuid },
    /// `reverses_id` names a transaction that does not exist on this
    /// tenant's book. Nothing was written.
    ReverseTargetUnknown { reverses_id: Uuid },
    /// `reverses_id` names a transaction that cannot be reversed: a
    /// `period_close` (un-closing would contradict its standing
    /// checkpoint), or a transaction that is itself a resolution or a
    /// reversal — reversing a resolution strands its pending forever
    /// (ADR-0016's worked failure). Nothing was written.
    ReverseTargetNotReversible { reverses_id: Uuid },
    /// The named target already has its one supersession — it was resolved
    /// or reversed, and either fate is final: pending → posted happens
    /// once, and so does the void. Nothing was written.
    TargetAlreadySuperseded { transaction_id: Uuid },
    /// The writer reached a state its own derivations promise cannot happen
    /// — a leg without a counter in maps derived from those same legs, a
    /// rendering that failed after `PostTransaction::new` validated it.
    /// Nothing the bracket wrote survives it. The caller gets a 500 with no
    /// internals; the string is for the operator's log, which is the only
    /// place it goes.
    Internal(String),
    /// The storage failed. This carried `sqlx::Error` while the adapter lived
    /// in this crate — "opaque wrapper deferred until a second adapter needs
    /// one", the old comment said. The second consumer arrived, but as an
    /// enforcement requirement rather than an adapter: deny.toml's capability
    /// map holds only if THIS crate names no sqlx type anywhere, so the
    /// variant is the opaque boxed error now, and the Postgres error type
    /// stays inside the adapter crate (crates/ledger/postgres).
    Storage(Box<dyn std::error::Error + Send + Sync>),
}

/// What an adapter can answer instead of [`AccountOpened`] — its own enum, not
/// [`WriteError`]'s, for the reason this module's doc gives. Every variant
/// except `Storage` promises "nothing was written", and the writer keeps that
/// promise with a rollback rather than a hope.
///
/// Each refusal is a constraint the schema already holds (ADR-0021's table),
/// and the two that are RACES — the unique indexes — are the reason
/// `AccountExists` exists as a variant rather than as a pre-flight check
/// alone: two concurrent creates of one account are real, and the loser must
/// be told by name.
pub enum OpenAccountError {
    /// Same idempotency key, different body. ADR-0013's poisoned replay, on
    /// the same spine and under the same name the posting endpoint uses —
    /// deliberately, because it is the same contract. Nothing was written.
    KeyReused,
    /// `purpose` names no row in `account_types`. The chart is what says what
    /// an account MEANS, and a purpose it does not carry has no category, no
    /// normal balance and no scope for the writer to derive
    /// (`fk_accounts__type` would refuse the insert; this refuses the request
    /// first, by name). Nothing was written.
    AccountTypeUnknown { purpose: String },
    /// `uq_accounts__owned` (one account per owner, purpose and currency) or
    /// `uq_accounts__house` (one house account per purpose and currency, per
    /// tenant) already holds this account.
    ///
    /// **It does not say whose** (ADR-0021's cost list): `uq_accounts__owned`
    /// is keyed per `(tenant, owner_type, owner_id, purpose, currency)`, so
    /// within one tenant a collision is always the caller's own account, and
    /// the refusal says the account exists and says no more. That is the same
    /// fail-closed silence ADR-0019 records for tenants. Nothing was written.
    AccountExists { purpose: String, currency: String },
    /// `ck_accounts__house_has_no_owner`: a house account has no owner and an
    /// owned account must have one. Refused before the insert, so the caller
    /// gets the API's own sentence rather than a check-constraint message.
    /// Nothing was written.
    AccountOwnerMismatched {
        owner_type: &'static str,
        owner_id_given: bool,
    },
    /// `ck_accounts__per_shard_is_owned`: this type's split key IS the
    /// counterparty, and a house account is one row per purpose and currency
    /// — so it nets every counterparty's position at write time and **no
    /// report can recover it** (ADR-0012). Nothing was written.
    AccountTypeRequiresAnOwner { purpose: String },
    /// The writer reached a state its own construction promises cannot happen
    /// — an accepted claim whose account the replay lookup cannot find. The
    /// caller gets a 500 with no internals; the string is for the operator's
    /// log, which is the only place it goes.
    Internal(String),
    /// The storage failed. Opaque for the reason [`WriteError::Storage`] is:
    /// this crate names no sqlx type, and deny.toml's capability map only
    /// holds because it does not.
    Storage(Box<dyn std::error::Error + Send + Sync>),
}

/// What an adapter can answer instead of [`PeriodDefined`] — its own enum, for
/// the reason this module's doc gives. Every variant except `Storage` promises
/// "nothing was written", and the writer keeps that promise with a rollback
/// rather than a hope.
///
/// Each refusal is a constraint `ledger_periods` already holds (ADR-0024's
/// table), and both of the named ones are refusals only the DATABASE can make:
/// an overlap is a statement about other rows, and a zone's existence is the
/// server's tzdata. Surfacing them by name is what keeps the caller from being
/// handed a constraint message.
pub enum DefinePeriodError {
    /// Same idempotency key, different body. ADR-0013's poisoned replay, on
    /// the same spine and under the same name every other write uses.
    /// Nothing was written.
    KeyReused,
    /// `pk_periods` — this tenant already has a period under this code.
    ///
    /// **ADR-0024's refusal table does not carry this one, and it has to
    /// exist**: `pk_periods` is `(tenant_id, code)` and it is checked BEFORE
    /// `ex_periods__no_overlap`, so re-defining a code — the same one with a
    /// corrected boundary, or the same request under a fresh key — reached the
    /// caller as a `23505` with no name at all, which is the shape ADR-0021
    /// gave `account_exists` for one table over. Measured on the running
    /// binary: `pk_periods` fires first even when the two ranges are
    /// identical, so the overlap refusal is reachable only for a DIFFERENT
    /// code. Nothing was written.
    PeriodExists { code: String },
    /// `ex_periods__no_overlap` — a GiST exclusion over
    /// `tstzrange(starts_at, ends_at, '[)')`: this tenant already has a period
    /// covering part of this one. The API surfaces the constraint rather than
    /// re-checking it, because a read-then-insert cannot see an uncommitted
    /// rival and the exclusion index can. Nothing was written.
    PeriodOverlaps { code: String },
    /// `ck_periods__tz_known` — the server does not recognise this zone name.
    /// It arrives as `22023` (`invalid_parameter_value`) from `timezone()`
    /// rather than as a check violation, because an unrecognised zone RAISES
    /// where it would have to return NULL for the CHECK to fail. Nothing was
    /// written.
    PeriodZoneUnknown { tz: String },
    /// The writer reached a state its own construction promises cannot happen
    /// — an accepted claim whose period the replay lookup cannot find. The
    /// caller gets a 500 with no internals; the string is for the operator's
    /// log, which is the only place it goes.
    Internal(String),
    /// The storage failed. Opaque for the reason [`WriteError::Storage`] is.
    Storage(Box<dyn std::error::Error + Send + Sync>),
}

/// What an adapter can answer instead of [`PeriodClosed`] — its own enum
/// again. Every variant except `Storage` promises "nothing was written", and
/// on this operation that promise is worth more than on any other: a close
/// writes a transaction, its entries, every swept account's balance row, the
/// close record and one checkpoint row per account, and a refusal must undo
/// all of it.
pub enum ClosePeriodError {
    /// `{code}` names no period on this tenant. Refused BEFORE the key is
    /// claimed, which matters more here than elsewhere: the key is derived,
    /// so a burnt one could never be retried under a different name.
    /// Nothing was written.
    PeriodUnknown { code: String },
    /// This period and currency are already closed — `pk_closes`, reached
    /// through `uq_events__idempotency` because the key is deterministic. A
    /// close happens once, and correcting one is a later posting like
    /// everything else here (ADR-0016: reversing a close is refused).
    /// Nothing was written.
    PeriodAlreadyClosed { code: String, currency: String },
    /// This tenant holds no `retained_earnings` house account in this
    /// currency, so the sweep has no destination. Refused before the claim,
    /// for the reason `PeriodUnknown` is. Nothing was written.
    RetainedEarningsUnknown { currency: String },
    /// The derived key is held by an event this close did not write — the
    /// same key with a DIFFERENT body, which on this operation can only mean
    /// another operation claimed the string. Told apart from
    /// `PeriodAlreadyClosed` by the stored hash, which is why the close has a
    /// canonical byte form at all. Nothing was written.
    KeyReused,
    /// The writer reached a state its own construction promises cannot happen
    /// — a period whose `ends_at` has no representable microsecond before it,
    /// a claim that wrote no transaction. The caller gets a 500 with no
    /// internals; the string is for the operator's log.
    Internal(String),
    /// The storage failed. Opaque for the reason [`WriteError::Storage`] is.
    Storage(Box<dyn std::error::Error + Send + Sync>),
}
