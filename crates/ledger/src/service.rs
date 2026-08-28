//! The writer service: ADR-0005's posting primitive under ADR-0013's
//! write-path contract. This is the use-case — hash, claim-or-replay,
//! coalesce, upsert in delta order, number, append, commit — orchestrated in
//! the core over the outbound [`Repository`] port, with no SQL in the room:
//! the statements live in the adapter (`crates/ledger/postgres`), the pure
//! computation between them in `domain`.
//!
//! What is deliberately here already, because ADR-0013 calls them contract
//! and not optimization:
//! - idempotency is the two-statement replay (claim, then a separate lookup
//!   with the hash in the `WHERE`);
//! - legs are coalesced per account before the balance upsert, and accounts
//!   are locked in id order, batch-wide;
//! - `account_seq` is issued by the balance row's counter under its own lock
//!   and each entry's seq is derived by walking back from the returned total.
//!
//! The fourth clause of that contract — the transaction opens by SETTING
//! `READ COMMITTED` rather than inheriting it — is stated on
//! [`Repository::begin`] and honored by the adapter's SQL.

use std::collections::BTreeMap;

use uuid::Uuid;

use crate::domain::{PostTransaction, Posted};
use crate::port::{Ledger, WriteError};
use crate::postings::{self, Delta, Leg};
use crate::repository::Repository;

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

    let mut tx = repository.begin().await.map_err(storage)?;

    // Statement A: claim the idempotency key by inserting the event row.
    // An event id back means the insert happened — nobody held this key.
    // Nothing back means an earlier caller already claimed it, and the
    // answer they stored is what this caller gets (ADR-0013 §2).
    match repository
        .claim_event(&mut tx, command, &hash, &payload)
        .await
        .map_err(storage)?
    {
        // This caller is the first writer: it does the work in this same
        // transaction and never looks at the store.
        Some(event_id) => append_and_commit(repository, tx, command, event_id).await,
        // The key belongs to an earlier post: replay its stored result —
        // never redo the work — or refuse the key if the body differs.
        None => replay_or_refuse(repository, tx, command, &hash).await,
    }
}

/// The first writer's path: append the claimed transaction to the ledger,
/// then close the bracket — commit on success, so the event claim and
/// everything it caused become durable together; on a refusal, rollback
/// first, which is what makes the refusal's "nothing was written" promise
/// true.
async fn append_and_commit<R: Repository>(
    repository: &R,
    mut tx: R::Tx,
    command: &PostTransaction,
    event_id: Uuid,
) -> Result<Posted, WriteError> {
    match append_to_ledger(repository, &mut tx, command, event_id).await {
        Ok(transaction_id) => {
            repository.commit(tx).await.map_err(storage)?;
            Ok(Posted {
                event_id,
                transaction_id: Some(transaction_id),
                replayed: false,
            })
        }
        // A storage error means the backend already failed mid-statement;
        // no further statement is sent — the open database transaction dies
        // with the connection, and that is what keeps "nothing was
        // committed" true.
        Err(error @ WriteError::Storage(_)) => Err(error),
        // A refusal decided here still holds a healthy connection: close
        // the bracket, then answer.
        Err(refusal) => {
            repository.rollback(tx).await.map_err(storage)?;
            Err(refusal)
        }
    }
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

/// Append the claimed transaction to the ledger, in ADR-0013's order:
/// insert the transaction row, upsert the balances, append the entries.
/// Returns the transaction id and never touches the bracket — `post` owns
/// the commit, and on a refusal from here, the rollback.
async fn append_to_ledger<R: Repository>(
    repository: &R,
    tx: &mut R::Tx,
    command: &PostTransaction,
    event_id: Uuid,
) -> Result<Uuid, WriteError> {
    let transaction_id = repository
        .insert_transaction(tx, command, event_id)
        .await
        .map_err(storage)?;

    // Expand each posting into its two legs — the row is a leg; the primitive
    // you can call is a pair (ADR-0005) — and coalesce per (account,
    // currency) before any balance is touched.
    let legs = postings::expand_postings(command.postings());
    let deltas = postings::coalesce(&legs).map_err(|postings::Overflow| WriteError::Overflow)?;

    let issued = upsert_balances(repository, tx, command, &deltas).await?;
    append_entries(
        repository,
        tx,
        command,
        transaction_id,
        &legs,
        &issued,
        &deltas,
    )
    .await?;

    Ok(transaction_id)
}

/// Apply each account's coalesced delta to its balance row and collect the
/// `last_seq` each upsert returns. The coalesced map iterates in account-id
/// order (the domain's BTreeMap choice), so the row locks are taken
/// deterministically, batch-wide. An upsert that selects no row is the
/// existence check failing: the refusal names that account.
async fn upsert_balances<R: Repository>(
    repository: &R,
    tx: &mut R::Tx,
    command: &PostTransaction,
    deltas: &BTreeMap<(Uuid, String), Delta>,
) -> Result<BTreeMap<(Uuid, String), i64>, WriteError> {
    let mut issued: BTreeMap<(Uuid, String), i64> = BTreeMap::new();
    for ((account_id, currency), delta) in deltas {
        let last_seq = repository
            .upsert_balance(tx, command.tenant_id(), account_id, currency, delta)
            .await
            .map_err(storage)?;
        let Some(last_seq) = last_seq else {
            return Err(WriteError::UnknownAccount {
                account_id: *account_id,
                currency: currency.clone(),
            });
        };
        issued.insert((*account_id, currency.clone()), last_seq);
    }
    Ok(issued)
}

/// Number each leg from its account's counter — walking back from the
/// `last_seq` the upserts returned — then append all entries in one
/// multi-row statement. `None` from the numbering means a leg's account is
/// missing from maps derived from these same legs — unreachable by
/// construction, answered as Internal rather than dressed up as a caller
/// error.
async fn append_entries<R: Repository>(
    repository: &R,
    tx: &mut R::Tx,
    command: &PostTransaction,
    transaction_id: Uuid,
    legs: &[Leg],
    issued: &BTreeMap<(Uuid, String), i64>,
    deltas: &BTreeMap<(Uuid, String), Delta>,
) -> Result<(), WriteError> {
    let Some(seqs) = postings::assign_account_seqs(legs, issued, deltas) else {
        return Err(WriteError::Internal(
            "a leg's account is missing from the seq maps derived from these same legs".to_owned(),
        ));
    };
    repository
        .insert_entries(tx, command, transaction_id, legs, &seqs)
        .await
        .map_err(storage)
}

#[cfg(test)]
mod tests {
    //! Orchestration tests over a fake repository — read top to bottom, the
    //! test names are the service's contract. What they hold is the BRANCHING
    //! and the ORDER: which methods a claim runs and in what sequence, what a
    //! replay never touches, where each refusal rolls back. The SQL behavior
    //! each method promises (the claim's ON CONFLICT, the hash-in-WHERE
    //! lookup, the upsert's existence check) stays proven by the e2e suite
    //! against real PostgreSQL; nothing here re-proves it, and nothing here
    //! could.

    use std::sync::{Arc, Mutex, PoisonError};

    use time::OffsetDateTime;
    use uuid::Uuid;

    use super::*;
    use crate::domain::{Invalid, Posting};
    use crate::postings::{Delta, Leg};
    use crate::repository::StorageError;

    // Fixed ids: SOURCE < DESTINATION, so SOURCE's upsert runs first (the
    // service walks the coalesced BTreeMap in account-id order).
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
            OffsetDateTime::UNIX_EPOCH,
            vec![Posting::new(SOURCE, DESTINATION, 100, "USD".to_owned())?],
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
    /// Each entry is `(method, account)`: the account is `Some` only for
    /// `upsert_balance`, so the delta ORDER — which account's upsert ran
    /// first — is asserted outright rather than inferred from the count.
    type Calls = Arc<Mutex<Vec<(&'static str, Option<Uuid>)>>>;

    fn taken(calls: &Calls) -> Vec<(&'static str, Option<Uuid>)> {
        calls.lock().unwrap_or_else(PoisonError::into_inner).clone()
    }

    /// A repository of answers, no storage: each builder names the situation
    /// the real SQL would produce, and every method records its name so the
    /// tests can hold the order.
    struct FakeRepository {
        claim: Option<Uuid>,
        stored: Option<(Uuid, Option<Uuid>)>,
        accounts_exist: bool,
        insert_transaction_fails: bool,
        calls: Calls,
    }

    impl FakeRepository {
        fn new(claim: Option<Uuid>, stored: Option<(Uuid, Option<Uuid>)>) -> Self {
            Self {
                claim,
                stored,
                accounts_exist: true,
                insert_transaction_fails: false,
                calls: Calls::default(),
            }
        }

        /// Statement A returns a row: this caller claimed the key.
        fn first_writer() -> Self {
            Self::new(Some(EVENT), None)
        }

        /// The key is already claimed and the body matches: statement B
        /// finds the stored result.
        fn replaying() -> Self {
            Self::new(None, Some((EVENT, Some(TRANSACTION))))
        }

        /// The key is already claimed with a DIFFERENT body: statement B's
        /// hash-in-WHERE finds nothing.
        fn poisoned_key() -> Self {
            Self::new(None, None)
        }

        /// The claim succeeds but no posted account exists: every balance
        /// upsert selects zero rows.
        fn without_accounts() -> Self {
            let mut fake = Self::first_writer();
            fake.accounts_exist = false;
            fake
        }

        /// The claim succeeds and then the backend fails mid-flight: the
        /// transaction insert returns the opaque storage error the adapter
        /// would box up from a lost connection or a refused statement.
        fn failing_mid_flight() -> Self {
            let mut fake = Self::first_writer();
            fake.insert_transaction_fails = true;
            fake
        }

        fn calls(&self) -> Calls {
            Arc::clone(&self.calls)
        }

        fn record(&self, name: &'static str) {
            self.push(name, None);
        }

        fn push(&self, name: &'static str, account: Option<Uuid>) {
            self.calls
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .push((name, account));
        }
    }

    struct FakeTx;

    impl Repository for FakeRepository {
        type Tx = FakeTx;

        async fn begin(&self) -> Result<FakeTx, StorageError> {
            self.record("begin");
            Ok(FakeTx)
        }

        async fn claim_event(
            &self,
            _tx: &mut FakeTx,
            _command: &PostTransaction,
            _hash: &[u8],
            _payload: &serde_json::Value,
        ) -> Result<Option<Uuid>, StorageError> {
            self.record("claim_event");
            Ok(self.claim)
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

        async fn insert_transaction(
            &self,
            _tx: &mut FakeTx,
            _command: &PostTransaction,
            _event_id: Uuid,
        ) -> Result<Uuid, StorageError> {
            self.record("insert_transaction");
            if self.insert_transaction_fails {
                return Err("the backend refused the statement".into());
            }
            Ok(TRANSACTION)
        }

        async fn upsert_balance(
            &self,
            _tx: &mut FakeTx,
            _tenant_id: &str,
            account_id: &Uuid,
            _currency: &str,
            delta: &Delta,
        ) -> Result<Option<i64>, StorageError> {
            self.push("upsert_balance", Some(*account_id));
            // A fresh account: after this batch its counter reads exactly
            // this batch's leg count, so the walk-back numbers from 1.
            Ok(self.accounts_exist.then_some(delta.legs))
        }

        async fn insert_entries(
            &self,
            _tx: &mut FakeTx,
            _command: &PostTransaction,
            _transaction_id: Uuid,
            _legs: &[Leg],
            _seqs: &[i64],
        ) -> Result<(), StorageError> {
            self.record("insert_entries");
            Ok(())
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
    fn a_claimed_key_does_the_work_in_delta_order_and_commits() -> Result<(), Invalid> {
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
        // One posting is two legs on two accounts: one upsert each, in
        // account-id order — SOURCE's upsert before DESTINATION's, asserted
        // by account and not just by count — and statement B never runs.
        assert_eq!(
            taken(&calls),
            [
                ("begin", None),
                ("claim_event", None),
                ("insert_transaction", None),
                ("upsert_balance", Some(SOURCE)),
                ("upsert_balance", Some(DESTINATION)),
                ("insert_entries", None),
                ("commit", None),
            ]
        );
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
        // Statement B, then out — no transaction row, no upsert, no entries,
        // and the bracket closes by rollback: a replay writes nothing.
        assert_eq!(
            taken(&calls),
            [
                ("begin", None::<Uuid>),
                ("claim_event", None),
                ("stored_result", None),
                ("rollback", None),
            ]
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
            [
                ("begin", None::<Uuid>),
                ("claim_event", None),
                ("stored_result", None),
                ("rollback", None),
            ]
        );
        Ok(())
    }

    #[test]
    fn an_unknown_account_rolls_back_before_any_entry_is_written() -> Result<(), Invalid> {
        let repository = FakeRepository::without_accounts();
        let calls = repository.calls();
        let service = LedgerService::new(repository);
        let command = a_command()?;

        let posted = run(service.post(&command));

        // The refusal names the account whose upsert found nothing — the
        // first in id order, since the walk stops there.
        assert!(matches!(
            posted,
            Err(WriteError::UnknownAccount { account_id, .. }) if account_id == SOURCE
        ));
        assert_eq!(
            taken(&calls),
            [
                ("begin", None),
                ("claim_event", None),
                ("insert_transaction", None),
                ("upsert_balance", Some(SOURCE)),
                ("rollback", None),
            ]
        );
        Ok(())
    }

    #[test]
    fn a_storage_failure_mid_flight_propagates_and_nothing_commits() -> Result<(), Invalid> {
        // The backend fails AFTER the claim — the adapter's boxed error for a
        // lost connection or a refused statement, from the transaction insert.
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
        assert_eq!(
            taken(&calls),
            [
                ("begin", None::<Uuid>),
                ("claim_event", None),
                ("insert_transaction", None),
            ]
        );
        Ok(())
    }
}
