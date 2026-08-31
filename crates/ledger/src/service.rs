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

use std::collections::BTreeMap;

use uuid::Uuid;

use crate::domain::{PostTransaction, Posted};
use crate::port::{Ledger, WriteError};
use crate::postings::{self, Delta};
use crate::repository::{Appended, Claimed, Repository, SupersedeRefusal};

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

    // The posting math, all of it pure and all of it before any SQL: expand
    // each posting into its two legs — the row is a leg; the primitive you
    // can call is a pair (ADR-0005) — coalesce per (account, currency) so N
    // legs cost one balance upsert, and count each leg's offset back from
    // its account's counter so the statement can number the entries.
    // ...and, for a pending transaction, the plan withholds the balance
    // movement while keeping every leg's seq: the cache means POSTED
    // (ADR-0010), and that ruling is applied here in the pure math, never
    // by a branch in the statement.
    let append = postings::plan_append(command.postings(), command.status())
        .map_err(|postings::Overflow| WriteError::Overflow)?;

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
    use crate::postings::Append;
    use crate::repository::{BalanceUpsert, StorageError};

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

    /// A repository of answers, no storage: each builder names the situation
    /// the real SQL would produce, and every method records its name so the
    /// tests can hold the order.
    struct FakeRepository {
        claims: bool,
        stored: Option<(Uuid, Option<Uuid>)>,
        accounts_exist: bool,
        claim_and_append_fails: bool,
        supersession_refused: Option<SupersedeRefusal>,
        derived_upserts: Option<Vec<BalanceUpsert>>,
        calls: Calls,
    }

    impl FakeRepository {
        fn new(claims: bool, stored: Option<(Uuid, Option<Uuid>)>) -> Self {
            Self {
                claims,
                stored,
                accounts_exist: true,
                claim_and_append_fails: false,
                supersession_refused: None,
                derived_upserts: None,
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

        async fn stored_result(
            &self,
            _tx: &mut FakeTx,
            _command: &PostTransaction,
            _hash: &[u8],
        ) -> Result<Option<(Uuid, Option<Uuid>)>, StorageError> {
            self.record("stored_result");
            Ok(self.stored)
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
}
