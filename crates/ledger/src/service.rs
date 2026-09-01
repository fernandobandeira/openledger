//! The writer service: ADR-0005's posting primitive under ADR-0013's
//! write-path contract. This is the use-case — hash, coalesce, number,
//! claim-and-append-or-replay, commit — orchestrated in the core over the
//! outbound [`Repository`] port, with no SQL in the room: the statements
//! live in the adapter (`crates/ledger/postgres`), the pure computation
//! before them in `domain` and `postings`.
//!
//! What is deliberately here already, because ADR-0013 calls them contract
//! and not optimization:
//! - idempotency is the two-statement replay (the claim, then a separate
//!   lookup with the hash in the `WHERE`) — single-call posting rides the
//!   whole append on the CLAIM, never on the lookup;
//! - legs are coalesced per account before the balance upsert, and accounts
//!   are locked in id order, batch-wide;
//! - `account_seq` is issued by the balance row's counter under its own lock
//!   and each entry's seq walks back from the returned total — the offsets
//!   are counted here in Rust, the one subtraction runs beside the counter;
//! - pending → posted (roadmap M3, ADR-0016) rides the same claim: a pending
//!   plan withholds the balance movement (the cache means POSTED, ADR-0010),
//!   and a superseding transaction — a resolution or a reversal — whose
//!   target the statement's gate found unsupersedable is refused by name
//!   after rollback;
//! - a reversal (ADR-0016, Reversals and the void) plans an EMPTY append —
//!   the caller sends no postings — and the statement derives the outcome
//!   from the target: the full mirror for a posted target, the zero-posting
//!   void marker for a pending one. The derived append is the statement's,
//!   so this service commits it without reconciling it against a plan it
//!   never made.
//!
//! The fourth clause of that contract — the transaction opens by SETTING
//! `READ COMMITTED` rather than inheriting it — is stated on
//! [`Repository::begin`] and honored by the adapter's SQL.
//!
//! And since ADR-0018 the same use-case exists for N independent commands at
//! once ([`LedgerService::post_batch`]): the same bracket, one statement for
//! the whole batch, one replay lookup for whichever members found their key
//! already held — and each caller answered on its own, because a batch cannot
//! roll back for one member without destroying the others. The queue and the
//! dispatcher permits that decide WHICH commands travel together are the
//! composition root's; nothing here has a runtime in it.

use std::collections::BTreeMap;

use uuid::Uuid;

use crate::domain::{PostTransaction, Posted};
use crate::port::{Ledger, WriteError};
use crate::postings::{self, Append, Delta};
use crate::repository::{
    Appended, BatchMember, Claimed, MemberOutcome, Repository, StorageError, StoredResult,
    SupersedeRefusal,
};

/// The writer behind the [`Ledger`] port, generic over the repository. One
/// adapter exists and no second is promised — the generic is the seam's
/// cost, not a plug-in system.
#[derive(Clone)]
pub struct LedgerService<R> {
    repository: R,
}

impl<R> LedgerService<R> {
    pub fn new(repository: R) -> Self {
        Self { repository }
    }
}

impl<R: Repository> LedgerService<R> {
    /// Post N independent commands, and answer each caller on its own
    /// (ADR-0018 §3). Not on the [`Ledger`] port and deliberately so: the
    /// port is what the HTTP surface consumes, one command at a time, and
    /// nothing about a batch reaches the wire. The accumulator that assembles
    /// the members lives in the composition root, where the queue and the
    /// permits have a runtime; this — planning each member, running the
    /// bracket, resolving each member's outcome — is the same orchestration
    /// over the same port that [`post`] already is for one command, and it
    /// stays here where the fake-repository tests are (ADR-0018 §5).
    ///
    /// One answer per command, in the order given.
    pub async fn post_batch(
        &self,
        commands: &[PostTransaction],
    ) -> Vec<Result<Posted, WriteError>> {
        post_batch(&self.repository, commands).await
    }
}

impl<R: Repository> Ledger for LedgerService<R> {
    async fn post(&self, command: &PostTransaction) -> Result<Posted, WriteError> {
        post(&self.repository, command).await
    }
}

/// The port's storage error arrives already opaque from the repository; this
/// is the one place it is folded into the port's answer.
fn storage(e: crate::repository::StorageError) -> WriteError {
    WriteError::Storage(e)
}

/// Post atomically, or return the stored result. One database transaction: the
/// event claim and everything it causes commit together, which is why there is
/// no in-flight state to report (ADR-0013 §2).
async fn post<R: Repository>(
    repository: &R,
    command: &PostTransaction,
) -> Result<Posted, WriteError> {
    let Planned {
        hash,
        payload,
        append,
        ..
    } = plan_for(command)?;

    let mut tx = repository.begin().await.map_err(storage)?;

    // Statement A, carrying the whole append with it — single-call posting
    // (roadmap M3): claim the idempotency key by inserting the event row,
    // and from the claimed row, in the SAME statement, the transaction, the
    // balance upserts in account order, the entries. Rows back mean the
    // insert happened — nobody held this key. Nothing back means an earlier
    // caller already claimed it, and the answer they stored is what this
    // caller gets (ADR-0013 §2); none of the append ran.
    match repository
        .claim_and_append(&mut tx, command, &hash, &payload, &append)
        .await
        .map_err(storage)?
    {
        // This caller is the first writer AND the command reverses: the
        // append the statement ran is the one IT derived from the target —
        // the mirror, or the void's nothing — so there is no plan to
        // reconcile it against; commit the derivation as it stands.
        Some(Claimed::Appended(appended)) if command.reverses_id().is_some() => {
            commit_derived_reversal(repository, tx, appended).await
        }
        // This caller is the first writer: the work is already done in this
        // open transaction — check it landed whole, then close the bracket.
        Some(Claimed::Appended(appended)) => {
            commit_or_refuse_unknown_account(repository, tx, appended, &append.deltas).await
        }
        // This caller is the first writer AND named a target the statement's
        // gate found unsupersedable — unresolvable, or unreversible: refuse
        // it by name, after the rollback that makes "nothing was written"
        // true.
        Some(Claimed::SupersessionRefused(refusal)) => {
            refuse_unsupersedable_target(repository, tx, command, refusal).await
        }
        // The key belongs to an earlier post: replay its stored result —
        // never redo the work — or refuse the key if the body differs.
        None => replay_or_refuse(repository, tx, command, &hash).await,
    }
}

/// Everything a command carries into its statement, computed before any SQL
/// runs: the canonical hash, the versioned payload, and the planned append.
/// One value because the four travel together — a batch hands the port
/// exactly this, per member ([`BatchMember`]), and a single post binds the
/// same three beside the same command.
struct Planned<'a> {
    command: &'a PostTransaction,
    hash: Vec<u8>,
    payload: serde_json::Value,
    append: Append,
}

impl<'a> Planned<'a> {
    /// The same plan, as the batched statement takes it. Borrowed
    /// throughout: a batch is assembled from callers still waiting on their
    /// own answers, and copying their commands to post them would be a copy
    /// per member per statement.
    fn as_member(&'a self) -> BatchMember<'a> {
        BatchMember {
            command: self.command,
            hash: &self.hash,
            payload: &self.payload,
            append: &self.append,
        }
    }
}

/// The pure work, all of it, before any SQL — and the one home for it, so a
/// batched member and a single post cannot come to carry different things.
/// A refusal here is this command's ALONE: in a batch it withholds one
/// member from the shared statement and touches nobody else, which is the
/// same isolation the statement's own gate performs for an unknown account.
fn plan_for(command: &PostTransaction) -> Result<Planned<'_>, WriteError> {
    // Both renderings were validated by `PostTransaction::new` (the
    // effective_at range check runs on the same UTC normalization the hash
    // formats), so a failure here is a can't-happen state and is answered as
    // one — a 500 with the detail in the operator's log, never a refusal
    // wearing a caller-error name.
    let hash: Vec<u8> = command.idempotency_hash().map_err(|invalid| {
        WriteError::Internal(format!(
            "the idempotency hash failed after validation: {}",
            invalid.detail()
        ))
    })?;
    let payload = command.payload().map_err(|invalid| {
        WriteError::Internal(format!(
            "the payload rendering failed after validation: {}",
            invalid.detail()
        ))
    })?;
    // The posting math: expand each posting into its two legs — the row is a
    // leg; the primitive you can call is a pair (ADR-0005) — coalesce per
    // (account, currency) so N legs cost one balance upsert, and count each
    // leg's offset back from its account's counter so the statement can
    // number the entries. ...and, for a pending transaction, the plan
    // withholds the balance movement while keeping every leg's seq: the
    // cache means POSTED (ADR-0010), and that ruling is applied here in the
    // pure math, never by a branch in the statement.
    let append = postings::plan_append(command.postings(), command.status())
        .map_err(|postings::Overflow| WriteError::Overflow)?;
    Ok(Planned {
        command,
        hash,
        payload,
        append,
    })
}

/// The first writer's second half: the append already ran inside the single
/// call, so what is left is reading its answer and closing the bracket —
/// commit on success, so the event claim and everything it caused become
/// durable together; on a refusal, rollback first, which is what makes the
/// refusal's "nothing was written" promise true. A balance upsert that
/// returned no counter is the existence check failing: the refusal names
/// that account — the first one in account order, as the per-statement
/// upserts used to.
async fn commit_or_refuse_unknown_account<R: Repository>(
    repository: &R,
    tx: R::Tx,
    appended: Appended,
    deltas: &BTreeMap<(Uuid, String), Delta>,
) -> Result<Posted, WriteError> {
    // One row per delta is the statement's own shape (it answers the deltas
    // it was handed, found or not); anything else means the adapter and this
    // service disagree about the statement — unreachable by construction,
    // answered as Internal rather than dressed up as a caller error.
    if appended.balance_upserts.len() != deltas.len() {
        let refusal = WriteError::Internal(format!(
            "the single call answered {} balance upserts for {} deltas",
            appended.balance_upserts.len(),
            deltas.len()
        ));
        repository.rollback(tx).await.map_err(storage)?;
        return Err(refusal);
    }
    if let Some(missing) = appended
        .balance_upserts
        .iter()
        .find(|upsert| upsert.last_seq.is_none())
    {
        let refusal = WriteError::AccountUnknown {
            account_id: missing.account_id,
            currency: missing.currency.clone(),
        };
        repository.rollback(tx).await.map_err(storage)?;
        return Err(refusal);
    }
    repository.commit(tx).await.map_err(storage)?;
    Ok(Posted {
        event_id: appended.event_id,
        transaction_id: Some(appended.transaction_id),
        replayed: false,
    })
}

/// The reversal's second half: the statement derived the whole outcome from
/// the target — the mirror's upserts, or none at all for the void — so
/// there is no planned delta set to reconcile against and no unknown-account
/// arm to keep: the mirror's accounts exist by construction (the target's
/// entries reference them under composite foreign keys, so the upsert's
/// existence join always matches), and the void upserts nothing. Commit the
/// bracket and answer with what the statement wrote.
async fn commit_derived_reversal<R: Repository>(
    repository: &R,
    tx: R::Tx,
    appended: Appended,
) -> Result<Posted, WriteError> {
    repository.commit(tx).await.map_err(storage)?;
    Ok(Posted {
        event_id: appended.event_id,
        transaction_id: Some(appended.transaction_id),
        replayed: false,
    })
}

/// The superseding transaction's target failed the statement's gate — it
/// does not exist, cannot be resolved or reversed, or already met its one
/// supersession (ADR-0004's list: the foreign key holds existence
/// eventually, but the SEMANTIC linkage is the writer's to hold, and this is
/// where it holds it). Roll back first, so the claimed key and the balance
/// locks the gated statement took are released and the refusal's "nothing
/// was written" is true, then name the target.
async fn refuse_unsupersedable_target<R: Repository>(
    repository: &R,
    tx: R::Tx,
    command: &PostTransaction,
    refusal: SupersedeRefusal,
) -> Result<Posted, WriteError> {
    repository.rollback(tx).await.map_err(storage)?;
    // The statement only diagnoses a supersession the command asked for, so
    // a refusal without the matching pointer means the adapter and this
    // service disagree about the statement — answered as the can't-happen
    // state it is, never dressed as a caller error.
    let disagreement = || {
        WriteError::Internal(
            "the single call refused a supersession the command never asked for".to_owned(),
        )
    };
    Err(match refusal {
        SupersedeRefusal::ResolveTargetUnknown => match command.resolves_id() {
            Some(resolves_id) => WriteError::ResolveTargetUnknown { resolves_id },
            None => disagreement(),
        },
        SupersedeRefusal::ResolveTargetNotPending => match command.resolves_id() {
            Some(resolves_id) => WriteError::ResolveTargetNotPending { resolves_id },
            None => disagreement(),
        },
        SupersedeRefusal::ReverseTargetUnknown => match command.reverses_id() {
            Some(reverses_id) => WriteError::ReverseTargetUnknown { reverses_id },
            None => disagreement(),
        },
        SupersedeRefusal::ReverseTargetNotReversible => match command.reverses_id() {
            Some(reverses_id) => WriteError::ReverseTargetNotReversible { reverses_id },
            None => disagreement(),
        },
        SupersedeRefusal::TargetAlreadySuperseded => {
            match command.resolves_id().or(command.reverses_id()) {
                Some(transaction_id) => WriteError::TargetAlreadySuperseded { transaction_id },
                None => disagreement(),
            }
        }
    })
}

/// The key was already claimed: answer the replay, or refuse the reuse.
/// Statement B is a SEPARATE statement, so it takes a new snapshot and can
/// see the row a concurrent writer committed while A blocked on it
/// (ADR-0013 §2). A row back is the stored result; no row back means the
/// key was reused with a different body. Either way this path only read,
/// so the bracket closes by rollback before the answer leaves.
async fn replay_or_refuse<R: Repository>(
    repository: &R,
    mut tx: R::Tx,
    command: &PostTransaction,
    hash: &[u8],
) -> Result<Posted, WriteError> {
    let stored = repository
        .stored_result(&mut tx, command, hash)
        .await
        .map_err(storage)?;
    repository.rollback(tx).await.map_err(storage)?;
    match stored {
        Some((event_id, transaction_id)) => Ok(Posted {
            event_id,
            transaction_id,
            replayed: true,
        }),
        None => Err(WriteError::KeyReused),
    }
}

/// Post N independent commands and answer each caller on its own. The
/// batch's shape decides which statement runs, and the common case is the
/// one that has been running since M3.
async fn post_batch<R: Repository>(
    repository: &R,
    commands: &[PostTransaction],
) -> Vec<Result<Posted, WriteError>> {
    match commands {
        // A dispatcher forms a batch from whatever is queued and never waits
        // for company that has not arrived; when nothing was queued there is
        // nothing to post (ADR-0018 §2).
        [] => Vec::new(),
        // ONE member takes the single statement — the path M3 shipped and
        // every post has taken since. Below the write ceiling every batch has
        // exactly one member, so the batched statement, with its per-member
        // gate, its window-function numbering and its three batch-wide abort
        // modes, is reachable only under genuine queueing pressure: that is
        // what makes batching safe to ship (ADR-0018 §2). It is also the
        // reason a pending, resolving or reversing command needs no special
        // case here — the accumulator never lets one share a batch, so a
        // batch of one is where it lands, and the statement it lands in is
        // the one with the supersede gate and the derived mirror.
        [only] => vec![post(repository, only).await],
        many => post_together(repository, many).await,
    }
}

/// Two or more independent commands, sharing one statement (ADR-0018 §3).
/// The batch's answer is per member throughout: a member the plan refuses
/// never reaches storage, a member the statement's gate withholds is refused
/// while its batch-mates commit, and only the two fates that belong to the
/// batch as a whole — a storage failure, or an answer this service cannot
/// read — reach every caller at once.
async fn post_together<R: Repository>(
    repository: &R,
    commands: &[PostTransaction],
) -> Vec<Result<Posted, WriteError>> {
    let planned: Vec<Result<Planned<'_>, WriteError>> = commands.iter().map(plan_for).collect();
    let members: Vec<BatchMember<'_>> = planned
        .iter()
        .filter_map(|planned| planned.as_ref().ok())
        .map(Planned::as_member)
        .collect();
    // Every member refused itself: there is nothing to ask storage, and no
    // transaction is opened to ask it in.
    if members.is_empty() {
        return answers_in_arrival_order(planned, std::iter::empty());
    }
    // One member left standing is a batch of ONE, and a batch of one takes
    // the single statement — the same rule `post_batch` applies to the batch
    // it was handed, applied again to the batch that survived planning.
    // Without this, refusals could hand the batched statement a single
    // member: harmless in what it writes, and a hole straight through
    // ADR-0018 §2's safety argument, which is that the batched statement is
    // reached only under genuine queueing pressure.
    if let [only] = members.as_slice() {
        let answered = post(repository, only.command).await;
        return answers_in_arrival_order(planned, std::iter::once(answered));
    }
    match append_the_batch(repository, &members).await {
        Ok(answered) => answers_in_arrival_order(planned, answered.into_iter()),
        // The batch failed as a whole. Every member that reached the
        // statement gets its own copy of that fate — and a member refused
        // before it keeps its own refusal, which is why this is not simply N
        // copies of the same answer.
        Err(refused) => answers_in_arrival_order(
            planned,
            std::iter::repeat_with(|| Err(refused.refusal_for_one_member())),
        ),
    }
}

/// What refuses a whole batch at once — the two fates that are nobody's own:
/// the storage failure whose blast radius batching widens from one caller to
/// N (ADR-0018 §3 — their keys were never claimed, so every one of them is
/// safe to retry), and the adapter disagreeing with this service about a
/// statement's shape. Rendered rather than carried, because each member needs
/// its OWN answer and neither a boxed storage error nor a [`WriteError`] is
/// `Clone`; what the operator's log prints is still the backend's own words.
enum WholeBatchRefusal {
    Storage(String),
    Internal(String),
}

impl WholeBatchRefusal {
    fn storage(failure: StorageError) -> Self {
        Self::Storage(failure.to_string())
    }

    /// One member's copy of the batch's fate, in the port's own grammar.
    fn refusal_for_one_member(&self) -> WriteError {
        match self {
            Self::Storage(rendered) => WriteError::Storage(rendered.clone().into()),
            Self::Internal(detail) => WriteError::Internal(detail.clone()),
        }
    }
}

/// The bracket, for N members: begin, ONE statement carrying every member's
/// claim and every member's append, the replay lookup for whichever members
/// came back already claimed, commit. This is `post`'s middle with the count
/// changed — and the round-trip count is the batch's, not the member's:
/// three calls for the whole batch, four when any member replays.
///
/// One answer per member, in the order given.
async fn append_the_batch<R: Repository>(
    repository: &R,
    members: &[BatchMember<'_>],
) -> Result<Vec<Result<Posted, WriteError>>, WholeBatchRefusal> {
    let mut tx = repository
        .begin()
        .await
        .map_err(WholeBatchRefusal::storage)?;
    // The one statement N members exist to share. A failure inside it fails
    // every member and commits nothing; the open database transaction dies
    // with the connection, which is what makes "nothing was committed" true
    // here exactly as it does on the single path — there is no rollback to
    // make.
    let outcomes = repository
        .claim_and_append_batch(&mut tx, members)
        .await
        .map_err(WholeBatchRefusal::storage)?;
    if let Some(refusal) = disagreement_over(outcomes.len(), members.len(), "batched claim") {
        return Err(refuse_the_batch_after_rollback(repository, tx, refusal).await);
    }
    let replaying = members_replaying_an_earlier_write(members, &outcomes);
    let replayed = replayed_results_for(repository, &mut tx, &replaying)
        .await
        .map_err(WholeBatchRefusal::storage)?;
    if let Some(refusal) =
        disagreement_over(replayed.len(), replaying.len(), "batched replay lookup")
    {
        return Err(refuse_the_batch_after_rollback(repository, tx, refusal).await);
    }
    repository
        .commit(tx)
        .await
        .map_err(WholeBatchRefusal::storage)?;
    Ok(answers_for_members(outcomes, replayed))
}

/// Roll the bracket back, THEN refuse — the ordering that makes "nothing was
/// written" true, and the reason the refusal travels as a value rather than
/// being returned where it is discovered. A rollback that itself fails is
/// what the caller hears about instead: the batch is refused either way, and
/// the backend's own words are the more useful of the two.
async fn refuse_the_batch_after_rollback<R: Repository>(
    repository: &R,
    tx: R::Tx,
    refusal: WholeBatchRefusal,
) -> WholeBatchRefusal {
    match repository.rollback(tx).await {
        Ok(()) => refusal,
        Err(failure) => WholeBatchRefusal::storage(failure),
    }
}

/// A count the adapter and this service must agree about: one outcome per
/// member the statement was handed, one stored result per member the lookup
/// was asked about. Anything else means the two disagree about the
/// statement — unreachable by construction (both anchor their final SELECT
/// on the members they were given), answered as `Internal` rather than
/// dressed up as a caller error, and never committed: an answer nobody can
/// read must not become a book. The same rule
/// [`commit_or_refuse_unknown_account`] follows for a delta count.
fn disagreement_over(answered: usize, asked: usize, statement: &str) -> Option<WholeBatchRefusal> {
    (answered != asked).then(|| {
        WholeBatchRefusal::Internal(format!(
            "the {statement} answered {answered} rows for {asked} members"
        ))
    })
}

/// The members an earlier caller beat to their key, in member order. They
/// appended nothing; what they get is what that first writer stored.
fn members_replaying_an_earlier_write<'a>(
    members: &[BatchMember<'a>],
    outcomes: &[MemberOutcome],
) -> Vec<BatchMember<'a>> {
    members
        .iter()
        .zip(outcomes)
        .filter(|(_, outcome)| matches!(outcome, MemberOutcome::KeyAlreadyClaimed))
        .map(|(member, _)| *member)
        .collect()
}

/// Statement B, ONCE for the whole batch — and not at all when no member
/// needs it. A batch carrying any replay costs a fourth round trip; running
/// the lookup per member would cost one per replayed member, which is the
/// round-trip count batching exists to remove. It stays a SEPARATE statement
/// for the same reason it is one on the single path: folded into the claim it
/// returns zero rows under the very race it exists to handle (ADR-0013 §2).
async fn replayed_results_for<R: Repository>(
    repository: &R,
    tx: &mut R::Tx,
    replaying: &[BatchMember<'_>],
) -> Result<Vec<Option<StoredResult>>, StorageError> {
    if replaying.is_empty() {
        return Ok(Vec::new());
    }
    repository.stored_result_batch(tx, replaying).await
}

/// Each member's answer, in the order the members were handed over: an
/// appended member is its caller's `Posted`, a member the gate withheld
/// carries the refusal naming the account it named — refused alone, while
/// its batch-mates commit — and a member whose key was already held takes
/// the next of the replay lookup's answers: the stored result, or the
/// key-reuse refusal, since the hash rides in the lookup's WHERE and a
/// different body finds no row (ADR-0013 §2).
fn answers_for_members(
    outcomes: Vec<MemberOutcome>,
    replayed: Vec<Option<StoredResult>>,
) -> Vec<Result<Posted, WriteError>> {
    let mut replayed = replayed.into_iter();
    outcomes
        .into_iter()
        .map(|outcome| match outcome {
            MemberOutcome::Appended {
                event_id,
                transaction_id,
            } => Ok(Posted {
                event_id,
                transaction_id: Some(transaction_id),
                replayed: false,
            }),
            MemberOutcome::AccountUnknown {
                account_id,
                currency,
            } => Err(WriteError::AccountUnknown {
                account_id,
                currency,
            }),
            MemberOutcome::KeyAlreadyClaimed => match replayed.next() {
                Some(Some((event_id, transaction_id))) => Ok(Posted {
                    event_id,
                    transaction_id,
                    replayed: true,
                }),
                Some(None) => Err(WriteError::KeyReused),
                // Counted against the lookup's answer before this runs, so
                // this arm is the count check's own can't-happen state —
                // never a caller error, and never a guess at which stored
                // result was meant.
                None => Err(WriteError::Internal(
                    "the batched replay lookup ran out of answers".to_owned(),
                )),
            },
        })
        .collect()
}

/// Each CALLER's answer, back in the order they handed their commands over.
/// A command its own plan refused keeps that refusal — it never reached the
/// statement — and every command that did reach it takes the next of the
/// statement's answers, which is what keeps the two orders one order.
fn answers_in_arrival_order(
    planned: Vec<Result<Planned<'_>, WriteError>>,
    mut answered: impl Iterator<Item = Result<Posted, WriteError>>,
) -> Vec<Result<Posted, WriteError>> {
    planned
        .into_iter()
        .map(|planned| match planned {
            Err(refusal) => Err(refusal),
            Ok(_) => answered.next().unwrap_or_else(|| {
                Err(WriteError::Internal(
                    "the batch answered fewer members than it carried".to_owned(),
                ))
            }),
        })
        .collect()
}

#[cfg(test)]
mod tests {
    //! Orchestration tests over a fake repository — read top to bottom, the
    //! test names are the service's contract. What they hold is the BRANCHING
    //! and the ROUND-TRIP SHAPE: which repository calls a claim runs — each
    //! one statement in the adapter — what a replay never touches, where each
    //! refusal rolls back. The SQL behavior the single call promises (the
    //! claim's ON CONFLICT gating the append, the ordered balance upserts,
    //! the hash-in-WHERE lookup) stays proven by the e2e suite against real
    //! PostgreSQL; nothing here re-proves it, and nothing here could. The
    //! account-order property lives in the coalesced BTreeMap (held by the
    //! postings tests) and the statement's ORDER BY (held by the e2e race).

    use std::sync::{Arc, Mutex, PoisonError};

    use time::OffsetDateTime;
    use uuid::Uuid;

    use super::*;
    use crate::domain::{Invalid, Posting, TransactionStatus};
    use crate::repository::BalanceUpsert;

    // Fixed ids: SOURCE < DESTINATION, so SOURCE leads the coalesced map —
    // and is the account an all-unknown refusal must name.
    const EVENT: Uuid = Uuid::from_u128(0xE0);
    const TRANSACTION: Uuid = Uuid::from_u128(0xF0);
    const SOURCE: Uuid = Uuid::from_u128(1);
    const DESTINATION: Uuid = Uuid::from_u128(2);

    /// One valid command, one posting — two legs, two accounts. The values
    /// are irrelevant to every test below; only the shape matters.
    fn a_command() -> Result<PostTransaction, Invalid> {
        PostTransaction::new(
            "acme".to_owned(),
            "key-1".to_owned(),
            Some(OffsetDateTime::UNIX_EPOCH),
            TransactionStatus::Posted,
            None,
            None,
            vec![Posting::new(SOURCE, DESTINATION, 100, "USD".to_owned())?],
        )
    }

    /// The same posting under a key of its own — a batch's member. Two
    /// members of one batch are two independent callers, and the only thing
    /// that distinguishes them is the key each claims.
    fn a_member(idempotency_key: &str) -> Result<PostTransaction, Invalid> {
        PostTransaction::new(
            "acme".to_owned(),
            idempotency_key.to_owned(),
            Some(OffsetDateTime::UNIX_EPOCH),
            TransactionStatus::Posted,
            None,
            None,
            vec![Posting::new(SOURCE, DESTINATION, 100, "USD".to_owned())?],
        )
    }

    /// A member whose OWN PLAN refuses it, before any statement runs: two
    /// postings onto the same pair whose amounts do not fit in 64 bits, so
    /// `plan_append`'s coalesce overflows. Its refusal is this command's
    /// alone — it withholds one member from the shared statement and touches
    /// nobody else — and it is also the only place the batch's own
    /// cross-member overflow hazard has a sibling: the per-member check runs
    /// in Rust with `checked_add`, here, before storage sees anything.
    fn a_member_whose_plan_overflows(idempotency_key: &str) -> Result<PostTransaction, Invalid> {
        PostTransaction::new(
            "acme".to_owned(),
            idempotency_key.to_owned(),
            Some(OffsetDateTime::UNIX_EPOCH),
            TransactionStatus::Posted,
            None,
            None,
            vec![
                Posting::new(SOURCE, DESTINATION, i64::MAX, "USD".to_owned())?,
                Posting::new(SOURCE, DESTINATION, 1, "USD".to_owned())?,
            ],
        )
    }

    /// The ids the fake's batched statement writes for the member at this
    /// position — distinct per member, so an answer can be traced back to
    /// the member that earned it and a batch that crossed two answers fails
    /// instead of passing.
    fn nth_event(position: usize) -> Uuid {
        Uuid::from_u128(0xE00 + position as u128)
    }

    fn nth_transaction(position: usize) -> Uuid {
        Uuid::from_u128(0xF00 + position as u128)
    }

    /// One caller's answer, rendered as the sentence it makes, so a batch's
    /// answers read as a table of meanings rather than a nest of matches.
    fn spoken(answer: &Result<Posted, WriteError>) -> String {
        let named = |transaction_id: Option<Uuid>| {
            transaction_id.map_or_else(|| "nothing".to_owned(), |id| id.to_string())
        };
        match answer {
            Ok(posted) if posted.replayed => format!("replayed {}", named(posted.transaction_id)),
            Ok(posted) => format!("posted {}", named(posted.transaction_id)),
            Err(WriteError::AccountUnknown {
                account_id,
                currency,
            }) => format!("unknown account {account_id} in {currency}"),
            Err(WriteError::KeyReused) => "key reused".to_owned(),
            Err(WriteError::Overflow) => "overflowed".to_owned(),
            Err(WriteError::Storage(failure)) => format!("storage failed: {failure}"),
            Err(WriteError::Internal(detail)) => format!("internally: {detail}"),
            Err(_) => "something else".to_owned(),
        }
    }

    /// The same shape, resolving a pending target — for the refusal path,
    /// whose named answer must carry this id back.
    const TARGET: Uuid = Uuid::from_u128(0xA0);

    fn a_resolving_command() -> Result<PostTransaction, Invalid> {
        PostTransaction::new(
            "acme".to_owned(),
            "key-2".to_owned(),
            Some(OffsetDateTime::UNIX_EPOCH),
            TransactionStatus::Posted,
            Some(TARGET),
            None,
            vec![Posting::new(SOURCE, DESTINATION, 100, "USD".to_owned())?],
        )
    }

    /// The reversal shape: a pointer, no postings, the date deferred to the
    /// target's — the command whose append the STATEMENT derives.
    fn a_reversing_command() -> Result<PostTransaction, Invalid> {
        PostTransaction::new(
            "acme".to_owned(),
            "key-3".to_owned(),
            None,
            TransactionStatus::Posted,
            None,
            Some(TARGET),
            vec![],
        )
    }

    /// The fake's futures are always immediately ready, so one poll with a
    /// no-op waker is a complete executor; the loop never observes `Pending`.
    fn run<F: Future>(future: F) -> F::Output {
        let mut future = std::pin::pin!(future);
        let mut cx = std::task::Context::from_waker(std::task::Waker::noop());
        loop {
            if let std::task::Poll::Ready(out) = future.as_mut().poll(&mut cx) {
                return out;
            }
        }
    }

    /// The call log, shared out of the fake before the service consumes it.
    /// One entry per repository call — and every repository call is one
    /// statement in the adapter, so this log IS the round-trip count the
    /// happy-path test asserts.
    type Calls = Arc<Mutex<Vec<&'static str>>>;

    fn taken(calls: &Calls) -> Vec<&'static str> {
        calls.lock().unwrap_or_else(PoisonError::into_inner).clone()
    }

    /// What the BATCHED statement answered for one member — the test's way
    /// of saying "the gate withheld the second one" with no database in the
    /// room. One per member, in the order the members were handed over,
    /// which is the port's own contract.
    #[derive(Clone, Copy)]
    enum Answers {
        /// The member claimed its key and its transaction is written.
        Appends,
        /// A posting named an account that does not exist: the gate withheld
        /// this member's claim, and its batch-mates are untouched.
        RefusesTheAccount,
        /// An earlier caller holds this member's key; it appended nothing
        /// and its answer is the replay lookup's.
        FindsTheKeyClaimed,
    }

    /// A repository of answers, no storage: each builder names the situation
    /// the real SQL would produce, and every method records its name so the
    /// tests can hold the order.
    struct FakeRepository {
        claims: bool,
        stored: Option<StoredResult>,
        accounts_exist: bool,
        claim_and_append_fails: bool,
        supersession_refused: Option<SupersedeRefusal>,
        derived_upserts: Option<Vec<BalanceUpsert>>,
        batch: Vec<Answers>,
        /// Which of the two batched statements answers one row short — the
        /// disagreement between adapter and service that neither statement
        /// can produce, and that neither may be committed on.
        answers_short: Option<&'static str>,
        calls: Calls,
    }

    impl FakeRepository {
        fn new(claims: bool, stored: Option<StoredResult>) -> Self {
            Self {
                claims,
                stored,
                accounts_exist: true,
                claim_and_append_fails: false,
                supersession_refused: None,
                derived_upserts: None,
                batch: Vec::new(),
                answers_short: None,
                calls: Calls::default(),
            }
        }

        /// The single call returns rows: this caller claimed the key and the
        /// whole append already ran, uncommitted, in the open transaction.
        fn first_writer() -> Self {
            Self::new(true, None)
        }

        /// The key is already claimed and the body matches: the single call
        /// returns nothing and statement B finds the stored result.
        fn replaying() -> Self {
            Self::new(false, Some((EVENT, Some(TRANSACTION))))
        }

        /// The key is already claimed with a DIFFERENT body: statement B's
        /// hash-in-WHERE finds nothing.
        fn poisoned_key() -> Self {
            Self::new(false, None)
        }

        /// The claim succeeds but no posted account exists: every balance
        /// upsert inside the single call selects zero rows, so every
        /// returned counter is `None`.
        fn without_accounts() -> Self {
            let mut fake = Self::first_writer();
            fake.accounts_exist = false;
            fake
        }

        /// The backend fails mid-statement: the single call returns the
        /// opaque storage error the adapter would box up from a lost
        /// connection or a refused statement.
        fn failing_mid_flight() -> Self {
            let mut fake = Self::first_writer();
            fake.claim_and_append_fails = true;
            fake
        }

        /// The claim succeeds but the superseding target fails the gate:
        /// the single call answers the diagnosis instead of the append.
        fn refusing_the_supersession(refusal: SupersedeRefusal) -> Self {
            let mut fake = Self::first_writer();
            fake.supersession_refused = Some(refusal);
            fake
        }

        /// The claim succeeds and the statement DERIVED the append from a
        /// reversal's target — upserts the plan never predicted (the
        /// mirror's), or none at all (the void's).
        fn deriving_the_reversal(upserts: Vec<BalanceUpsert>) -> Self {
            let mut fake = Self::first_writer();
            fake.derived_upserts = Some(upserts);
            fake
        }

        /// The batched statement answers each member this way, in order —
        /// and the replay lookup, for whichever of them found their key
        /// already held, answers the one stored result this fake keeps.
        fn answering_each_member(batch: Vec<Answers>) -> Self {
            let mut fake = Self::new(true, Some((EVENT, Some(TRANSACTION))));
            fake.batch = batch;
            fake
        }

        /// The same, except the replay lookup finds NOTHING for whoever asks
        /// it: the hash rides in that statement's WHERE, so a key reused
        /// with a DIFFERENT body matches no row (ADR-0013 §2).
        fn answering_each_member_over_a_poisoned_key(batch: Vec<Answers>) -> Self {
            let mut fake = Self::new(true, None);
            fake.batch = batch;
            fake
        }

        /// The batched statement named here answers one row FEWER than it
        /// was handed members — the shape neither statement can produce
        /// (both anchor their final SELECT on the members they were given)
        /// and the one an answer nobody can read would arrive as.
        fn answering_one_row_short(statement: &'static str, batch: Vec<Answers>) -> Self {
            let mut fake = Self::answering_each_member(batch);
            fake.answers_short = Some(statement);
            fake
        }

        fn calls(&self) -> Calls {
            Arc::clone(&self.calls)
        }

        fn record(&self, name: &'static str) {
            self.calls
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .push(name);
        }
    }

    struct FakeTx;

    impl Repository for FakeRepository {
        type Tx = FakeTx;

        async fn begin(&self) -> Result<FakeTx, StorageError> {
            self.record("begin");
            Ok(FakeTx)
        }

        async fn claim_and_append(
            &self,
            _tx: &mut FakeTx,
            _command: &PostTransaction,
            _hash: &[u8],
            _payload: &serde_json::Value,
            append: &Append,
        ) -> Result<Option<Claimed>, StorageError> {
            self.record("claim_and_append");
            // The statement's own precondition, held on every path: one
            // offset per leg, in the same order.
            assert_eq!(append.seq_offsets.len(), append.legs.len());
            if self.claim_and_append_fails {
                return Err("the backend refused the statement".into());
            }
            if !self.claims {
                return Ok(None);
            }
            if let Some(refusal) = self.supersession_refused {
                return Ok(Some(Claimed::SupersessionRefused(refusal)));
            }
            // A reversal's answer is the statement's own derivation, not an
            // echo of the (empty) plan.
            if let Some(derived) = &self.derived_upserts {
                return Ok(Some(Claimed::Appended(Appended {
                    event_id: EVENT,
                    transaction_id: TRANSACTION,
                    balance_upserts: derived
                        .iter()
                        .map(|upsert| BalanceUpsert {
                            account_id: upsert.account_id,
                            currency: upsert.currency.clone(),
                            last_seq: upsert.last_seq,
                        })
                        .collect(),
                })));
            }
            // One answer per delta, in the map's own account order — the
            // real statement's LEFT JOIN back onto the deltas it was handed.
            // A fresh account: after this batch its counter reads exactly
            // this batch's leg count.
            let balance_upserts = append
                .deltas
                .iter()
                .map(|((account_id, currency), delta)| BalanceUpsert {
                    account_id: *account_id,
                    currency: currency.clone(),
                    last_seq: self.accounts_exist.then_some(delta.legs),
                })
                .collect();
            Ok(Some(Claimed::Appended(Appended {
                event_id: EVENT,
                transaction_id: TRANSACTION,
                balance_upserts,
            })))
        }

        /// The batched statement: one answer per member, in the order given.
        /// The ids it hands back are derived from each member's POSITION, so
        /// a test can tell one member's answer from another's — which is
        /// what makes per-member isolation assertable at all.
        async fn claim_and_append_batch(
            &self,
            _tx: &mut FakeTx,
            members: &[BatchMember<'_>],
        ) -> Result<Vec<MemberOutcome>, StorageError> {
            self.record("claim_and_append_batch");
            if self.claim_and_append_fails {
                return Err("the backend refused the statement".into());
            }
            // The statement's own precondition, held on every member: this
            // statement writes the literal status 'posted' and has no
            // supersede gate, so the adapter refuses anything else as a
            // storage error (ADR-0018 §4). A batch this service assembles
            // must never make it do that.
            for member in members {
                assert!(
                    member.command.resolves_id().is_none()
                        && member.command.reverses_id().is_none()
                        && member.command.status() == TransactionStatus::Posted,
                    "a batch may carry plain posted postings only"
                );
            }
            let answered = match self.answers_short {
                Some("claim_and_append_batch") => self.batch.len().saturating_sub(1),
                _ => self.batch.len(),
            };
            Ok(self
                .batch
                .iter()
                .take(answered)
                .enumerate()
                .map(|(position, answer)| match answer {
                    Answers::Appends => MemberOutcome::Appended {
                        event_id: nth_event(position),
                        transaction_id: nth_transaction(position),
                    },
                    Answers::RefusesTheAccount => MemberOutcome::AccountUnknown {
                        account_id: SOURCE,
                        currency: "USD".to_owned(),
                    },
                    Answers::FindsTheKeyClaimed => MemberOutcome::KeyAlreadyClaimed,
                })
                .collect())
        }

        async fn stored_result(
            &self,
            _tx: &mut FakeTx,
            _command: &PostTransaction,
            _hash: &[u8],
        ) -> Result<Option<StoredResult>, StorageError> {
            self.record("stored_result");
            Ok(self.stored)
        }

        /// Statement B, batched — one answer per member asked about. That it
        /// is recorded ONCE however many members replay is the round-trip
        /// property the mixed-batch test holds.
        async fn stored_result_batch(
            &self,
            _tx: &mut FakeTx,
            members: &[BatchMember<'_>],
        ) -> Result<Vec<Option<StoredResult>>, StorageError> {
            self.record("stored_result_batch");
            let answered = match self.answers_short {
                Some("stored_result_batch") => members.len().saturating_sub(1),
                _ => members.len(),
            };
            Ok(members.iter().take(answered).map(|_| self.stored).collect())
        }

        async fn commit(&self, _tx: FakeTx) -> Result<(), StorageError> {
            self.record("commit");
            Ok(())
        }

        async fn rollback(&self, _tx: FakeTx) -> Result<(), StorageError> {
            self.record("rollback");
            Ok(())
        }
    }

    #[test]
    fn a_claimed_key_posts_in_one_call_between_begin_and_commit() -> Result<(), Invalid> {
        let repository = FakeRepository::first_writer();
        let calls = repository.calls();
        let service = LedgerService::new(repository);
        let command = a_command()?;

        let posted = run(service.post(&command));

        assert!(matches!(
            posted,
            Ok(Posted {
                event_id: e,
                transaction_id: Some(t),
                replayed: false,
            }) if e == EVENT && t == TRANSACTION
        ));
        // The round-trip shape single-call posting exists to buy (roadmap
        // M3, spike 003): the whole append is the ONE call between the
        // bracket's ends — three repository calls, each one statement in
        // the adapter — and statement B never runs.
        assert_eq!(taken(&calls), ["begin", "claim_and_append", "commit"]);
        Ok(())
    }

    #[test]
    fn a_replay_returns_the_stored_result_and_never_repeats_the_work() -> Result<(), Invalid> {
        let repository = FakeRepository::replaying();
        let calls = repository.calls();
        let service = LedgerService::new(repository);
        let command = a_command()?;

        let posted = run(service.post(&command));

        assert!(matches!(
            posted,
            Ok(Posted {
                event_id: e,
                transaction_id: Some(t),
                replayed: true,
            }) if e == EVENT && t == TRANSACTION
        ));
        // Statement B, then out — the single call appended nothing, and the
        // bracket closes by rollback: a replay writes nothing.
        assert_eq!(
            taken(&calls),
            ["begin", "claim_and_append", "stored_result", "rollback"]
        );
        Ok(())
    }

    #[test]
    fn a_reused_key_with_a_different_body_is_refused_after_rollback() -> Result<(), Invalid> {
        let repository = FakeRepository::poisoned_key();
        let calls = repository.calls();
        let service = LedgerService::new(repository);
        let command = a_command()?;

        let posted = run(service.post(&command));

        assert!(matches!(posted, Err(WriteError::KeyReused)));
        assert_eq!(
            taken(&calls),
            ["begin", "claim_and_append", "stored_result", "rollback"]
        );
        Ok(())
    }

    #[test]
    fn an_unknown_account_rolls_back_before_anything_commits() -> Result<(), Invalid> {
        let repository = FakeRepository::without_accounts();
        let calls = repository.calls();
        let service = LedgerService::new(repository);
        let command = a_command()?;

        let posted = run(service.post(&command));

        // The refusal names the account whose upsert found nothing — the
        // first in account order, since the scan stops there.
        assert!(matches!(
            posted,
            Err(WriteError::AccountUnknown { account_id, .. }) if account_id == SOURCE
        ));
        assert_eq!(taken(&calls), ["begin", "claim_and_append", "rollback"]);
        Ok(())
    }

    #[test]
    fn an_unsupersedable_target_is_refused_by_name_after_rollback() -> Result<(), Invalid> {
        // Every diagnosis, mapped to its own named refusal under the verb
        // that asked — a match arm dropped or crossed here hands the caller
        // the wrong instruction (ADR-0013's framing: the error names what to
        // change). Resolve diagnoses ride a resolving command, reverse
        // diagnoses a reversing one, and the shared already-superseded fate
        // is held under both verbs.
        let resolve = a_resolving_command as fn() -> Result<PostTransaction, Invalid>;
        let reverse = a_reversing_command as fn() -> Result<PostTransaction, Invalid>;
        let cases = [
            (
                SupersedeRefusal::ResolveTargetUnknown,
                resolve,
                "unknown_resolve",
            ),
            (
                SupersedeRefusal::ResolveTargetNotPending,
                resolve,
                "not_pending",
            ),
            (
                SupersedeRefusal::ReverseTargetUnknown,
                reverse,
                "unknown_reverse",
            ),
            (
                SupersedeRefusal::ReverseTargetNotReversible,
                reverse,
                "not_reversible",
            ),
            (
                SupersedeRefusal::TargetAlreadySuperseded,
                resolve,
                "target_already_superseded",
            ),
            (
                SupersedeRefusal::TargetAlreadySuperseded,
                reverse,
                "target_already_superseded",
            ),
        ];
        for (refusal, command, expected) in cases {
            let repository = FakeRepository::refusing_the_supersession(refusal);
            let calls = repository.calls();
            let service = LedgerService::new(repository);
            let command = command()?;

            let posted = run(service.post(&command));

            let named = match posted {
                Err(WriteError::ResolveTargetUnknown { resolves_id }) if resolves_id == TARGET => {
                    "unknown_resolve"
                }
                Err(WriteError::ResolveTargetNotPending { resolves_id })
                    if resolves_id == TARGET =>
                {
                    "not_pending"
                }
                Err(WriteError::ReverseTargetUnknown { reverses_id }) if reverses_id == TARGET => {
                    "unknown_reverse"
                }
                Err(WriteError::ReverseTargetNotReversible { reverses_id })
                    if reverses_id == TARGET =>
                {
                    "not_reversible"
                }
                Err(WriteError::TargetAlreadySuperseded { transaction_id })
                    if transaction_id == TARGET =>
                {
                    "target_already_superseded"
                }
                _ => "something else",
            };
            assert_eq!(named, expected, "for {refusal:?}");
            // The bracket closes by rollback BEFORE the refusal leaves —
            // that ordering is what makes "nothing was written" true — and
            // statement B never runs: a refused supersession is not a replay.
            assert_eq!(
                taken(&calls),
                ["begin", "claim_and_append", "rollback"],
                "for {refusal:?}"
            );
        }
        Ok(())
    }

    /// The reversal branch, held against the plan-reconciliation arm: the
    /// statement derives the mirror's upserts, so the plan (empty — a
    /// reversal sends no postings) can NEVER be reconciled against the
    /// answer, and a service that routes a reversal through the ordinary
    /// commit path refuses its own success as an internal error. The void's
    /// case — zero derived upserts — commits the same way.
    #[test]
    fn a_derived_reversal_commits_without_reconciling_a_plan_it_never_made() -> Result<(), Invalid>
    {
        for derived in [
            // the mirror: two upserts the empty plan never predicted...
            vec![
                BalanceUpsert {
                    account_id: SOURCE,
                    currency: "USD".to_owned(),
                    last_seq: Some(2),
                },
                BalanceUpsert {
                    account_id: DESTINATION,
                    currency: "USD".to_owned(),
                    last_seq: Some(2),
                },
            ],
            // ...and the void: none at all.
            vec![],
        ] {
            let repository = FakeRepository::deriving_the_reversal(derived);
            let calls = repository.calls();
            let service = LedgerService::new(repository);
            let command = a_reversing_command()?;

            let posted = run(service.post(&command));

            assert!(
                matches!(
                    posted,
                    Ok(Posted {
                        event_id: e,
                        transaction_id: Some(t),
                        replayed: false,
                    }) if e == EVENT && t == TRANSACTION
                ),
                "a derived reversal must commit as its own creation"
            );
            assert_eq!(taken(&calls), ["begin", "claim_and_append", "commit"]);
        }
        Ok(())
    }

    #[test]
    fn a_storage_failure_mid_flight_propagates_and_nothing_commits() -> Result<(), Invalid> {
        // The backend fails INSIDE the single call — the adapter's boxed
        // error for a lost connection or a refused statement.
        let repository = FakeRepository::failing_mid_flight();
        let calls = repository.calls();
        let service = LedgerService::new(repository);
        let command = a_command()?;

        let posted = run(service.post(&command));

        // The error propagates as the port's opaque Storage answer — never
        // re-dressed as a caller error — and the bracket records NO commit:
        // the open database transaction dies with the connection, which is
        // what makes "nothing was committed" true without a rollback call.
        assert!(matches!(posted, Err(WriteError::Storage(_))));
        assert_eq!(taken(&calls), ["begin", "claim_and_append"]);
        Ok(())
    }

    /// The fast path that makes batching safe to ship (ADR-0018 §2): a batch
    /// of ONE takes the single statement — the one that has carried every
    /// post since M3 — and the batched statement, with its per-member gate,
    /// its window-function numbering and its three batch-wide abort modes,
    /// is never reached. Below the write ceiling every batch has exactly one
    /// member, so this is the path essentially all traffic still takes; it
    /// is also why a pending, resolving or reversing command can be queued
    /// like any other without ever meeting a statement that would silently
    /// post it.
    #[test]
    fn a_batch_of_one_takes_the_single_statement_and_never_the_batched_one() -> Result<(), Invalid>
    {
        let repository = FakeRepository::first_writer();
        let calls = repository.calls();
        let service = LedgerService::new(repository);
        let batch = [a_command()?];

        let answers = run(service.post_batch(&batch));

        assert_eq!(
            answers.iter().map(spoken).collect::<Vec<String>>(),
            vec![format!("posted {TRANSACTION}")]
        );
        assert_eq!(taken(&calls), ["begin", "claim_and_append", "commit"]);
        Ok(())
    }

    /// The round-trip shape batching exists to buy: N first writers cost the
    /// SAME three calls one of them costs — begin, one statement, commit —
    /// and each caller gets its own transaction back, not a shared one.
    #[test]
    fn a_batch_of_first_writers_posts_in_one_statement_between_begin_and_commit()
    -> Result<(), Invalid> {
        let repository = FakeRepository::answering_each_member(vec![Answers::Appends; 3]);
        let calls = repository.calls();
        let service = LedgerService::new(repository);
        let batch = [a_member("key-1")?, a_member("key-2")?, a_member("key-3")?];

        let answers = run(service.post_batch(&batch));

        assert_eq!(
            answers.iter().map(spoken).collect::<Vec<String>>(),
            vec![
                format!("posted {}", nth_transaction(0)),
                format!("posted {}", nth_transaction(1)),
                format!("posted {}", nth_transaction(2)),
            ]
        );
        assert_eq!(taken(&calls), ["begin", "claim_and_append_batch", "commit"]);
        Ok(())
    }

    /// ADR-0018's central claim, and the one whose failure is not a
    /// performance bug: a member the statement's gate withheld is refused BY
    /// NAME while its batch-mates COMMIT. The single path keeps "nothing was
    /// written" by rolling back; a batch cannot roll back for one member
    /// without destroying the others, so it keeps the promise by withholding
    /// — and the commit here is half the property. Roll the batch back
    /// instead and two innocent callers are told nothing was written when
    /// their money had cleared.
    #[test]
    fn a_batch_carrying_an_unknown_account_commits_the_rest_and_refuses_that_one_by_name()
    -> Result<(), Invalid> {
        let repository = FakeRepository::answering_each_member(vec![
            Answers::Appends,
            Answers::RefusesTheAccount,
            Answers::Appends,
        ]);
        let calls = repository.calls();
        let service = LedgerService::new(repository);
        let batch = [a_member("key-1")?, a_member("key-2")?, a_member("key-3")?];

        let answers = run(service.post_batch(&batch));

        assert_eq!(
            answers.iter().map(spoken).collect::<Vec<String>>(),
            vec![
                format!("posted {}", nth_transaction(0)),
                format!("unknown account {SOURCE} in USD"),
                format!("posted {}", nth_transaction(2)),
            ]
        );
        assert_eq!(taken(&calls), ["begin", "claim_and_append_batch", "commit"]);
        Ok(())
    }

    /// The mixed batch: a member whose key an earlier caller already holds
    /// replays, its batch-mates append, and the replay lookup runs ONCE for
    /// the whole batch however many members need it — the call log is the
    /// assertion. Per member it would be a round trip per replay, which is
    /// the cost batching exists to remove; the honest price is a FOURTH call
    /// for the batch.
    #[test]
    fn a_batch_carrying_already_claimed_keys_replays_them_on_one_lookup() -> Result<(), Invalid> {
        let repository = FakeRepository::answering_each_member(vec![
            Answers::FindsTheKeyClaimed,
            Answers::Appends,
            Answers::FindsTheKeyClaimed,
        ]);
        let calls = repository.calls();
        let service = LedgerService::new(repository);
        let batch = [a_member("key-1")?, a_member("key-2")?, a_member("key-3")?];

        let answers = run(service.post_batch(&batch));

        assert_eq!(
            answers.iter().map(spoken).collect::<Vec<String>>(),
            vec![
                format!("replayed {TRANSACTION}"),
                format!("posted {}", nth_transaction(1)),
                format!("replayed {TRANSACTION}"),
            ]
        );
        assert_eq!(
            taken(&calls),
            [
                "begin",
                "claim_and_append_batch",
                "stored_result_batch",
                "commit"
            ]
        );
        Ok(())
    }

    /// The plan's own refusal, in a batch: a member `plan_for` refused never
    /// reaches the statement, and the answers of the members that DID reach
    /// it must not shift onto it. Its postings overflow 64 bits, which is a
    /// refusal earned before any SQL exists — and the only sibling the
    /// batched statement's CROSS-MEMBER overflow has anywhere in the suite
    /// (that one re-adds at `bigint` inside the statement and aborts the
    /// whole batch, ADR-0018 §3's recorded cost).
    ///
    /// **What fails if the arrival order stops being kept**: read the
    /// statement's next answer for a refused member and member 2 is handed
    /// member 3's transaction id — a caller told its money moved, naming a
    /// stranger's write — while member 3 falls off the end.
    #[test]
    fn a_batch_whose_member_refuses_its_own_plan_keeps_that_refusal_while_the_rest_commit()
    -> Result<(), Invalid> {
        // TWO answers for THREE commands: the overflowing member is never
        // handed to the statement, so the statement never speaks for it.
        let repository = FakeRepository::answering_each_member(vec![Answers::Appends; 2]);
        let calls = repository.calls();
        let service = LedgerService::new(repository);
        let batch = [
            a_member("key-1")?,
            a_member_whose_plan_overflows("key-2")?,
            a_member("key-3")?,
        ];

        let answers = run(service.post_batch(&batch));

        assert_eq!(
            answers.iter().map(spoken).collect::<Vec<String>>(),
            vec![
                format!("posted {}", nth_transaction(0)),
                "overflowed".to_owned(),
                format!("posted {}", nth_transaction(1)),
            ]
        );
        assert_eq!(taken(&calls), ["begin", "claim_and_append_batch", "commit"]);
        Ok(())
    }

    /// A batch whose refusals leave ONE member takes the single statement.
    /// Not a performance detail: ADR-0018 §2's safety argument is that the
    /// batched statement — its per-member gate, its window-function
    /// numbering, its three batch-wide abort modes — is reached only under
    /// genuine queueing pressure, and a batch reduced to one member by
    /// attrition is not that.
    #[test]
    fn a_batch_reduced_to_one_member_by_its_refusals_takes_the_single_statement()
    -> Result<(), Invalid> {
        let repository = FakeRepository::first_writer();
        let calls = repository.calls();
        let service = LedgerService::new(repository);
        let batch = [a_member_whose_plan_overflows("key-1")?, a_member("key-2")?];

        let answers = run(service.post_batch(&batch));

        assert_eq!(
            answers.iter().map(spoken).collect::<Vec<String>>(),
            vec!["overflowed".to_owned(), format!("posted {TRANSACTION}")]
        );
        assert_eq!(taken(&calls), ["begin", "claim_and_append", "commit"]);
        Ok(())
    }

    /// A member whose key an earlier caller holds AND whose body differs is
    /// refused by that name, alone, while its batch-mates commit. The hash
    /// rides in the replay lookup's WHERE, so a different body finds no row
    /// — and no row is a REFUSAL here, never a replay answering
    /// `transaction_id: null`, which ADR-0013 says is the legitimate shape of
    /// an accepted operation and would launder the refusal into a success.
    #[test]
    fn a_batch_member_whose_key_was_reused_with_a_different_body_is_refused_by_that_name()
    -> Result<(), Invalid> {
        let repository = FakeRepository::answering_each_member_over_a_poisoned_key(vec![
            Answers::Appends,
            Answers::FindsTheKeyClaimed,
            Answers::Appends,
        ]);
        let calls = repository.calls();
        let service = LedgerService::new(repository);
        let batch = [a_member("key-1")?, a_member("key-2")?, a_member("key-3")?];

        let answers = run(service.post_batch(&batch));

        assert_eq!(
            answers.iter().map(spoken).collect::<Vec<String>>(),
            vec![
                format!("posted {}", nth_transaction(0)),
                "key reused".to_owned(),
                format!("posted {}", nth_transaction(2)),
            ]
        );
        assert_eq!(
            taken(&calls),
            [
                "begin",
                "claim_and_append_batch",
                "stored_result_batch",
                "commit"
            ]
        );
        Ok(())
    }

    /// The count the adapter and this service must agree about, on the CLAIM:
    /// an answer with fewer rows than members is a disagreement about the
    /// statement, and an answer nobody can read must not become a book. So
    /// the batch is refused as `Internal` — every member, since the fault is
    /// nobody's own — and refused AFTER the rollback that makes "nothing was
    /// written" true. Without the check, the shorter answer silently walks
    /// every member after the missing one onto a stranger's transaction, and
    /// commits it.
    #[test]
    fn a_claim_answering_fewer_rows_than_members_refuses_the_batch_after_rollback()
    -> Result<(), Invalid> {
        let repository = FakeRepository::answering_one_row_short(
            "claim_and_append_batch",
            vec![Answers::Appends; 3],
        );
        let calls = repository.calls();
        let service = LedgerService::new(repository);
        let batch = [a_member("key-1")?, a_member("key-2")?, a_member("key-3")?];

        let answers = run(service.post_batch(&batch));

        assert_eq!(
            answers.iter().map(spoken).collect::<Vec<String>>(),
            vec!["internally: the batched claim answered 2 rows for 3 members".to_owned(); 3]
        );
        assert_eq!(
            taken(&calls),
            ["begin", "claim_and_append_batch", "rollback"]
        );
        Ok(())
    }

    /// The same agreement, on the REPLAY LOOKUP — a separate call site, and
    /// deleting either one alone leaves the other's test green. A stored
    /// result short here would hand one replaying member the next one's
    /// transaction; the batch is refused as `Internal` after rollback
    /// instead.
    #[test]
    fn a_replay_lookup_answering_fewer_rows_than_members_refuses_the_batch_after_rollback()
    -> Result<(), Invalid> {
        let repository = FakeRepository::answering_one_row_short(
            "stored_result_batch",
            vec![
                Answers::FindsTheKeyClaimed,
                Answers::Appends,
                Answers::FindsTheKeyClaimed,
            ],
        );
        let calls = repository.calls();
        let service = LedgerService::new(repository);
        let batch = [a_member("key-1")?, a_member("key-2")?, a_member("key-3")?];

        let answers = run(service.post_batch(&batch));

        assert_eq!(
            answers.iter().map(spoken).collect::<Vec<String>>(),
            vec![
                "internally: the batched replay lookup answered 1 rows for 2 members".to_owned();
                3
            ]
        );
        assert_eq!(
            taken(&calls),
            [
                "begin",
                "claim_and_append_batch",
                "stored_result_batch",
                "rollback"
            ]
        );
        Ok(())
    }

    /// The blast radius batching widens, asserted rather than assumed
    /// (ADR-0018 §3): a storage failure inside the shared statement fails
    /// EVERY member, including the ones that would have succeeded, and
    /// nothing commits. It is safe because none of their keys was claimed —
    /// every one of them is a fresh request on retry — and `Storage` was
    /// always the one variant that promised nothing.
    #[test]
    fn a_storage_failure_mid_batch_fails_every_member_and_commits_nothing() -> Result<(), Invalid> {
        let repository = FakeRepository::failing_mid_flight();
        let calls = repository.calls();
        let service = LedgerService::new(repository);
        let batch = [a_member("key-1")?, a_member("key-2")?, a_member("key-3")?];

        let answers = run(service.post_batch(&batch));

        assert_eq!(
            answers.iter().map(spoken).collect::<Vec<String>>(),
            vec!["storage failed: the backend refused the statement".to_owned(); 3]
        );
        // No commit, and no rollback either: the open database transaction
        // dies with the connection, exactly as it does on the single path.
        assert_eq!(taken(&calls), ["begin", "claim_and_append_batch"]);
        Ok(())
    }
}
