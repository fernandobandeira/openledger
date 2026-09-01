//! The outbound repository port: what the writer service asks of storage —
//! one method per statement the adapter runs, plus the transaction bracket
//! around them. Since single-call posting (roadmap M3, spike 003) the
//! first-writer path IS one statement, so the port carries two: the claim
//! with the whole append riding on it, and the replay lookup — each in a
//! single-command form and an N-command form, because a batch is ONE
//! statement for N callers rather than N calls (ADR-0018 §5), and a method
//! per statement is what that costs. Since ADR-0021 there are three more,
//! all for opening an account: the chart read the derived triple comes from,
//! the claim that carries the account insert, and that operation's own replay
//! lookup — one method per statement, again.
//!
//! This seam is NOT storage-agnosticism. There is one adapter
//! (`crates/ledger/postgres`, a nested workspace member) and no swappability
//! promise; ADR-0004 still owns why the SQL is abstracted no further than
//! this — it is the product's reasoning about PostgreSQL, not an
//! interchangeable backend. The seam exists to place the COMMAND in the
//! core: the claim-or-replay use-case is orchestration, not SQL, so it lives
//! in `service` behind these methods — and deny.toml's ratchet holds because
//! every signature here names only domain types, `serde_json::Value` (the
//! payload the event log stores), and the opaque storage error. No sqlx.

use uuid::Uuid;

use crate::accounts::{ChartTriple, OpenAccount};
use crate::domain::PostTransaction;
use crate::postings::Append;

/// What the single call answered for one coalesced delta, in account order:
/// the counter the balance upsert returned, or `None` when the upsert's
/// existence check found no such account holding this currency — the
/// service turns the first `None` into the refusal that names it.
pub struct BalanceUpsert {
    pub account_id: Uuid,
    pub currency: String,
    pub last_seq: Option<i64>,
}

/// The first writer's appended posting, as the single call reports it: the
/// claimed event, the transaction it caused, and each delta's balance
/// upsert. Everything it names is still uncommitted — the service closes
/// the bracket.
pub struct Appended {
    pub event_id: Uuid,
    pub transaction_id: Uuid,
    pub balance_upserts: Vec<BalanceUpsert>,
}

/// Why the single call refused to write a SUPERSEDING transaction — a
/// resolution or a reversal — over its named target: the semantic linkage
/// the schema deliberately does not hold (ADR-0004's counterexample: a
/// posted transaction "resolved" by another posted one took revenue to
/// −49,223 with every declarative check green; ADR-0016's reversal twin: a
/// reversed resolution strands its pending forever). The statement
/// diagnoses; the service names the refusal; nothing is written.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SupersedeRefusal {
    /// `resolves_id` names no transaction on this tenant's book.
    ResolveTargetUnknown,
    /// The resolve target exists and is not pending — nothing to resolve.
    ResolveTargetNotPending,
    /// `reverses_id` names no transaction on this tenant's book.
    ReverseTargetUnknown,
    /// The reverse target is not an ordinary posting: it is a `period_close`
    /// (un-closing would contradict the standing checkpoint), or it is
    /// itself a resolution or reversal (reversing a resolution strands its
    /// pending forever — ADR-0016's worked failure).
    ReverseTargetNotReversible,
    /// The target already has its one supersession — a resolution or a
    /// reversal, whichever won (`uq_txn__one_supersession` is the backstop
    /// for the race; the sequential case is diagnosed before the index has
    /// to speak).
    TargetAlreadySuperseded,
}

/// What the single call answered after claiming the key: the append, or —
/// for a superseding transaction whose target failed the gate — the
/// diagnosis. Either way the key WAS claimed in the open transaction; a
/// refusal is made true by the service's rollback.
pub enum Claimed {
    Appended(Appended),
    SupersessionRefused(SupersedeRefusal),
}

/// One member of a batch: the same four values a single post hands
/// [`Repository::claim_and_append`], gathered so that N independent commands
/// travel to storage as one slice. Borrowed throughout — a batch is
/// assembled from callers still waiting on their own answers, and copying
/// their commands to post them would be a copy per member per statement.
///
/// The planned `append` rides along for its LEGS, in posting order. The
/// batched statement re-coalesces and re-numbers ACROSS members — one
/// balance upsert for an account every member touched, not one per member —
/// so `deltas` and `seq_offsets` are the single path's shape and the batched
/// statement recomputes both (ADR-0018's recorded cost: the walk-back moves
/// from unit-tested Rust into a SQL window function). The plan is still what
/// refuses a member whose own legs overflow 64 bits, before any of this runs.
///
/// `Copy`, because the service selects SUBSETS of a batch — the members whose
/// key an earlier caller already held go on to the replay lookup — and a
/// member is four shared references: copying one copies no command, no hash
/// and no plan.
#[derive(Clone, Copy)]
pub struct BatchMember<'a> {
    pub command: &'a PostTransaction,
    pub hash: &'a [u8],
    pub payload: &'a serde_json::Value,
    pub append: &'a Append,
}

/// What the batched statement answered for ONE member. Every variant except
/// `Appended` means nothing was written FOR THIS MEMBER while its batch-mates
/// committed — the per-member form of the port's standing promise
/// (ADR-0018 §3).
pub enum MemberOutcome {
    /// This member claimed its key and its transaction is written,
    /// uncommitted, in the shared bracket.
    ///
    /// It carries the claim and the transaction and NOTHING ELSE — not the
    /// [`Appended`] the single path answers with — because the balance
    /// upserts that value's third field would name do not exist at member
    /// grain: the batched statement coalesces every member's deltas into one
    /// upsert per `(tenant, account, currency, stripe)`, which is the whole
    /// reason a batch beats N statements, so no row of that upsert belongs to
    /// one member. Carrying an `Appended` whose `balance_upserts` is ALWAYS
    /// empty would be a trap rather than a shape: anything reading it the way
    /// `commit_or_refuse_unknown_account` reads the single path's — one
    /// upsert per delta, and a `NULL` counter is an unknown account — would
    /// refuse its own success. The wrong state is unrepresentable instead.
    ///
    /// Nothing is lost: the existence check the single path reads off a
    /// `NULL` counter is answered ABOVE the claim here, and comes back as
    /// [`AccountUnknown`](MemberOutcome::AccountUnknown).
    Appended {
        event_id: Uuid,
        transaction_id: Uuid,
    },
    /// This member named an account that does not exist, or one that does
    /// not hold the currency it posted. The gate withheld the member's
    /// CLAIM, so its idempotency key is untouched and its retry is a fresh
    /// request — which is the point: gate below the claim instead and the
    /// refused member's event row commits with its innocent neighbours, its
    /// key is burned forever, and every retry is answered
    /// `transaction_id: null, replayed: true` — a success the caller cannot
    /// tell from a real one (ADR-0018 §3).
    ///
    /// The account named is the first in account order, as the single path's
    /// refusal names it.
    AccountUnknown { account_id: Uuid, currency: String },
    /// An earlier caller holds this member's key. It appended nothing, and
    /// its answer is [`stored_result`](Repository::stored_result)'s — the
    /// replay half stays a separate statement here for the same reason it
    /// does on the single path (ADR-0013 §2: folded into the claim it
    /// returns zero rows under the very race it exists to handle). So a
    /// batch carrying any replay costs a fourth round trip.
    KeyAlreadyClaimed,
}

/// What an already-claimed key stored, as the replay lookup answers it: the
/// event, and the transaction it caused — `None` for an operation that wrote
/// no transaction at all, which ADR-0013 records as the legitimate shape for
/// the majority of accepted operations. The lookup answering `None` for the
/// whole pair is a different fact: the key was reused with a different body.
pub type StoredResult = (Uuid, Option<Uuid>);

/// What the account-opening statement answered after claiming the key: the
/// account it wrote, or the unique index's refusal.
///
/// `AlreadyExists` arrives as an ERROR from the backend rather than as rows —
/// `23505` on `uq_accounts__owned` or `uq_accounts__house` — and the adapter
/// classifies it by constraint name, the same shape
/// [`SupersedeRefusal::TargetAlreadySuperseded`] is classified in on the
/// posting path. The service names the refusal and rolls back; nothing is
/// written.
pub enum OpenedAccount {
    Opened {
        event_id: Uuid,
        account_id: Uuid,
    },
    /// `uq_accounts__owned` or `uq_accounts__house` already holds this
    /// account. Which of the two is not carried: the refusal says the account
    /// exists and deliberately says no more (ADR-0021), so the caller gets
    /// one sentence and the index that produced it stays the adapter's
    /// business.
    AlreadyExists,
}

/// What an already-claimed OPENING stored, as its replay lookup answers it:
/// the event, and the account it caused.
///
/// `None` in the inner position is a can't-happen state and not a legitimate
/// shape — an accepted opening always wrote an account, and the lookup finds
/// it by the natural key the replayed body itself names
/// (`uq_accounts__owned` / `uq_accounts__house`, the same two indexes that
/// refuse a second one). The service answers it as `Internal`. `None` for the
/// whole pair is the different fact [`StoredResult`]'s is: the key was reused
/// with a different body.
pub type StoredAccount = (Uuid, Option<Uuid>);

/// The opaque storage failure. The port names no backend error type — the
/// Postgres error stays inside the adapter crate, boxed at exactly one
/// function — and the service forwards it unread into
/// [`WriteError::Storage`](crate::WriteError::Storage).
pub type StorageError = Box<dyn std::error::Error + Send + Sync>;

/// The repository. Each method is a native async fn stated as RPITIT with an
/// explicit `+ Send` bound, for the same reason the [`Ledger`](crate::Ledger)
/// port states it that way: the service's future must be `Send` for an axum
/// handler, and a bare `async fn` in a trait cannot promise that to a
/// generic caller.
pub trait Repository: Send + Sync {
    /// The open database transaction the statement methods operate on and
    /// [`commit`](Repository::commit) / [`rollback`](Repository::rollback)
    /// consume. Opaque to the service: it threads the value through and
    /// decides when the bracket closes, nothing more.
    type Tx: Send;

    /// Open the one database transaction a post runs in. ADR-0013 §1 is this
    /// method's contract: the transaction it yields runs at READ COMMITTED
    /// because the adapter SETS it, never because a deployment default
    /// happened to agree — under inherited REPEATABLE READ or stricter,
    /// 64–90% of contended writes fail and no retry loop rescues them. The
    /// invariant is stated here; the SQL that honors it lives in the adapter.
    fn begin(&self) -> impl Future<Output = Result<Self::Tx, StorageError>> + Send;

    /// Statement A, carrying the whole append with it — single-call posting
    /// (roadmap M3, measured by spike 003): claim the idempotency key,
    /// storing the command's hash and `payload` (its JSON rendering) beside
    /// it, and — only when the claim returns a row — insert the transaction,
    /// upsert every delta's balance row in account order, and append the
    /// entries numbered `last_seq - offset`, all in this ONE statement.
    /// `append` is the planned append: legs in posting order, one offset per
    /// leg, deltas iterating in account-id order — and the statement must
    /// preserve that order when it takes the balance row locks.
    ///
    /// For a REVERSING command (`reverses_id` set, no postings), the
    /// statement derives the append from the target itself: a posted target
    /// yields the full mirror — same legs, directions flipped, cache moved
    /// back — and a pending target yields the zero-posting void marker,
    /// with no entries, no deltas and no balance movement (ADR-0016,
    /// Reversals and the void). The returned [`Appended`] then carries the
    /// upserts the STATEMENT ran, not upserts the plan predicted — empty
    /// for a void.
    ///
    /// `Some` means this caller is the first writer: either the append
    /// already happened (uncommitted), or — for a superseding transaction —
    /// the statement's gate found the target unsupersedable and diagnosed
    /// it ([`Claimed::SupersessionRefused`]). On that refused path the gate
    /// withholds only the transaction row and the entries hanging off it:
    /// the key claim and the balance upserts DID run, uncommitted, because
    /// they depend on the claim and not the transaction — which is exactly
    /// why the service answers the refusal only after rolling the bracket
    /// back. `None` means an earlier caller claimed the key and NOTHING
    /// here ran — the claim's replay half stays the separate
    /// [`stored_result`](Repository::stored_result), because folding the
    /// two is the one-statement hole ADR-0013 §2 reproduced. A void answers
    /// `Some` with zero upserts, never `None`: the statement's final SELECT
    /// anchors on the claimed row, so zero rows means exactly "the key was
    /// already held" and nothing else (ADR-0016's return-shape requirement).
    fn claim_and_append(
        &self,
        tx: &mut Self::Tx,
        command: &PostTransaction,
        hash: &[u8],
        payload: &serde_json::Value,
        append: &Append,
    ) -> impl Future<Output = Result<Option<Claimed>, StorageError>> + Send;

    /// Statement A, batched — the SAME append for N independent commands in
    /// ONE statement (ADR-0018 §3). Nothing here waits for company: the
    /// caller assembles whatever arrived while the previous statement was in
    /// flight and hands it over, so a one-member batch is the common case
    /// and takes [`claim_and_append`](Repository::claim_and_append) instead.
    ///
    /// **The batch carries plain POSTED postings only** (ADR-0018 §4).
    /// Pending transactions, resolutions and reversals keep the single
    /// statement, which already holds the supersede gate, the server-derived
    /// mirror and the pending rule; reapplying those per member inside SQL
    /// would move ADR-0010's "the cache means posted" ruling out of the pure
    /// math that unit-tests it. The caller routes; a member the batch cannot
    /// carry is a disagreement between caller and adapter, not a caller
    /// error, and is answered as [`StorageError`].
    ///
    /// **One outcome per member, in the order given.** A shorter or longer
    /// answer means the adapter and the caller disagree about the statement:
    /// that is an internal fault, exactly as a delta/upsert count mismatch
    /// is on the single path, and never a refusal wearing a caller error's
    /// name.
    ///
    /// **A refused member is refused alone, and the others commit.** Every
    /// refusal outside `Storage` promises "nothing was written"; a batch
    /// cannot roll back for one member without destroying the rest, so the
    /// promise is kept by WITHHOLDING — a member that cannot proceed
    /// contributes nothing to the shared statement, its idempotency key
    /// included. Three failures still take the whole batch down, and they
    /// are accepted rather than fixed (ADR-0018 §3); each is documented at
    /// the line of SQL that produces it.
    fn claim_and_append_batch(
        &self,
        tx: &mut Self::Tx,
        members: &[BatchMember<'_>],
    ) -> impl Future<Output = Result<Vec<MemberOutcome>, StorageError>> + Send;

    /// Statement B: the [`StoredResult`] of the already claimed key — with
    /// the hash in the lookup's WHERE, never compared by the caller: a
    /// same-key/different-body replay finds NO row, so a caller that forgets
    /// to compare gets nothing instead of the wrong stored result
    /// (ADR-0013 §2).
    fn stored_result(
        &self,
        tx: &mut Self::Tx,
        command: &PostTransaction,
        hash: &[u8],
    ) -> impl Future<Output = Result<Option<StoredResult>, StorageError>> + Send;

    /// Statement B, batched — the stored results of N already-claimed keys in
    /// ONE lookup. A batch carrying any replay costs a fourth round trip, and
    /// this is what keeps it FOUR: one lookup for the whole unclaimed subset,
    /// never one per member. A batch carrying no replay runs it not at all.
    ///
    /// The members are the ones [`claim_and_append_batch`](Repository::claim_and_append_batch)
    /// answered [`MemberOutcome::KeyAlreadyClaimed`] for, handed back whole
    /// because they are the same members; only `command` and `hash` are read.
    ///
    /// **One answer per member, in the order given**, and the hash is in the
    /// lookup's WHERE exactly as it is on the single path: a member whose key
    /// was reused with a DIFFERENT body comes back `None` — never another
    /// member's stored result, and never the right member's wrong one. A
    /// shorter or longer answer is the same disagreement about the statement
    /// that a mismatched outcome count is, and is internal, never a caller
    /// error.
    fn stored_result_batch(
        &self,
        tx: &mut Self::Tx,
        members: &[BatchMember<'_>],
    ) -> impl Future<Output = Result<Vec<Option<StoredResult>>, StorageError>> + Send;

    /// The chart's own row for a purpose — the three columns
    /// `ledger_accounts` copies and `fk_accounts__type` /
    /// `fk_accounts__scope` hold honest (ADR-0021). `None` means
    /// `account_types` has no such code, which the service answers as
    /// `account_type_unknown`.
    ///
    /// It runs INSIDE the opening's own database transaction, and that is not
    /// incidental: the triple this read answers with is the triple the insert
    /// binds, so a chart edit between the two would be a foreign-key error
    /// where a named refusal belongs. One statement, one method, like every
    /// other on this port.
    fn chart_triple_for_purpose(
        &self,
        tx: &mut Self::Tx,
        purpose: &str,
    ) -> impl Future<Output = Result<Option<ChartTriple>, StorageError>> + Send;

    /// Statement A for an opening: claim the idempotency key, storing the
    /// command's hash and `payload` beside it, and — only when the claim
    /// returns a row — insert the account, in this ONE statement (ADR-0021's
    /// *"in the same database transaction"*, held as one statement rather
    /// than two for the same reason posting is).
    ///
    /// `triple` is what [`chart_triple_for_purpose`](Repository::chart_triple_for_purpose)
    /// answered. The statement binds it rather than joining `account_types`
    /// again: the derivation is the writer's decision and the composite
    /// foreign keys are what verify it, so the join would be a second opinion
    /// on a question already asked.
    ///
    /// `Some` means this caller is the first writer — either the account is
    /// written, uncommitted, or the unique index refused it
    /// ([`OpenedAccount::AlreadyExists`]). `None` means an earlier caller
    /// claimed the key and NOTHING here ran; the replay half stays the
    /// separate [`stored_account`](Repository::stored_account), because
    /// folding the two is the one-statement hole ADR-0013 §2 reproduced.
    fn claim_and_open_account(
        &self,
        tx: &mut Self::Tx,
        command: &OpenAccount,
        hash: &[u8],
        payload: &serde_json::Value,
        triple: &ChartTriple,
    ) -> impl Future<Output = Result<Option<OpenedAccount>, StorageError>> + Send;

    /// Statement B for an opening: the [`StoredAccount`] of the already
    /// claimed key — with the hash in the lookup's WHERE, never compared by
    /// the caller, exactly as [`stored_result`](Repository::stored_result)
    /// does it (ADR-0013 §2: a same-key/different-body replay must find NO
    /// row, so a caller that forgets to compare gets nothing rather than the
    /// wrong stored result).
    ///
    /// The account is found by the natural key the REPLAYED BODY names, since
    /// `ledger_accounts` carries no `event_id` column — the same
    /// `uq_accounts__owned` / `uq_accounts__house` keys that refuse a second
    /// one, read from the other side. The body is the one whose hash matched,
    /// so the key it names is the key the first writer used.
    fn stored_account(
        &self,
        tx: &mut Self::Tx,
        command: &OpenAccount,
        hash: &[u8],
    ) -> impl Future<Output = Result<Option<StoredAccount>, StorageError>> + Send;

    /// Commit the bracket: the event claim and everything it caused become
    /// durable together.
    fn commit(&self, tx: Self::Tx) -> impl Future<Output = Result<(), StorageError>> + Send;

    /// Abandon the bracket. Every refusal the service answers promises
    /// "nothing was written", and this is how it keeps the promise.
    fn rollback(&self, tx: Self::Tx) -> impl Future<Output = Result<(), StorageError>> + Send;
}
