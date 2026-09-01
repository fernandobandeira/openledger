//! The posting math: what the writer computes before its SQL runs — legs,
//! coalesced deltas, each leg's offset back from its account's counter.
//! Plain values in, plain values out; the zero-sqlx property of this CRATE
//! is the point (deny.toml enforces it), which is why these live here and
//! not beside the SQL that consumes them. The service (`service.rs`) owns
//! the order they run in, and is their only caller — the functions are
//! `pub(crate)`; the crate exports only the types the
//! [`Repository`](crate::Repository) port's signatures name.

use std::collections::BTreeMap;

use uuid::Uuid;

use crate::domain::{Posting, TransactionStatus};

/// Which side of an account a leg lands on. Two variants and no catch-all
/// anywhere: every match over a direction is exhaustive, so a third value is
/// a compile error rather than a leg silently credited. The SQL string
/// (`'debit'`/`'credit'`, the `ledger_direction` enum) is rendered by the
/// adapter at its bind site — the domain never speaks the dialect.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Direction {
    Debit,
    Credit,
}

/// One row-to-be: the row is a leg; the primitive you can call is a pair
/// (ADR-0005).
pub struct Leg {
    pub account_id: Uuid,
    pub currency: String,
    pub direction: Direction,
    pub amount_minor: i64,
}

/// What one account accumulates across this transaction's legs, coalesced so N
/// legs cost one balance upsert — the only batching that does not deadlock
/// (spike 003). `input` accumulates debit legs and `output` credit legs, the
/// schema-wide convention stated on `ledger_account_balances`.
#[derive(Default)]
pub struct Delta {
    pub input: i64,
    pub output: i64,
    pub legs: i64,
}

/// Coalescing the legs overflowed 64-bit minor units. The service maps this to
/// the port's `WriteError::Overflow`; the domain does not name the port.
#[derive(Debug)]
pub struct Overflow;

/// Expand each posting into its two legs: an amount leaves `source` (a credit
/// leg) and arrives at `destination` (a debit leg), in posting order.
pub(crate) fn expand_postings(postings: &[Posting]) -> Vec<Leg> {
    let mut legs: Vec<Leg> = Vec::new();
    for posting in postings {
        legs.push(Leg {
            account_id: posting.source,
            currency: posting.currency.clone(),
            direction: Direction::Credit,
            amount_minor: posting.amount_minor,
        });
        legs.push(Leg {
            account_id: posting.destination,
            currency: posting.currency.clone(),
            direction: Direction::Debit,
            amount_minor: posting.amount_minor,
        });
    }
    legs
}

/// Coalesce legs per (account, currency), with overflow-checked accumulation.
/// A BTreeMap so the writer's upserts run in account-id order: deterministic
/// lock ordering must hold batch-wide, not per posting (spike 003 measured
/// the alternative collapsing 10× into deadlocks).
pub(crate) fn coalesce(legs: &[Leg]) -> Result<BTreeMap<(Uuid, String), Delta>, Overflow> {
    let mut deltas: BTreeMap<(Uuid, String), Delta> = BTreeMap::new();
    for leg in legs {
        let delta = deltas
            .entry((leg.account_id, leg.currency.clone()))
            .or_default();
        let side = match leg.direction {
            Direction::Debit => &mut delta.input,
            Direction::Credit => &mut delta.output,
        };
        *side = side.checked_add(leg.amount_minor).ok_or(Overflow)?;
        delta.legs += 1;
    }
    Ok(deltas)
}

/// Each leg's distance back from its account's counter after this batch:
/// leg i's offset is the number of LATER legs on the same (account,
/// currency), so the account's final leg carries 0 and its first carries
/// `delta.legs - 1`. The single call numbers each entry `last_seq - offset`
/// right beside the counter the balance upsert returned — ADR-0013's
/// walk-back, with the counting here where it is pure and the one
/// subtraction in the statement where the counter lives. Returns one offset
/// per leg, parallel to `legs`.
pub(crate) fn offsets_back_from_last_seq(legs: &[Leg]) -> Vec<i64> {
    let mut later_legs: BTreeMap<(Uuid, &str), i64> = BTreeMap::new();
    let mut offsets: Vec<i64> = legs
        .iter()
        .rev()
        .map(|leg| {
            let count = later_legs
                .entry((leg.account_id, leg.currency.as_str()))
                .or_insert(0);
            let offset = *count;
            *count += 1;
            offset
        })
        .collect();
    offsets.reverse();
    offsets
}

/// The append, planned: everything the single call writes for a first
/// writer, computed here where it is pure — the legs in posting order, one
/// seq offset per leg, and the coalesced per-account deltas in account-id
/// order. One value, because the three travel together: the statement that
/// consumes them binds all three, and an offset without its leg — or a leg
/// without its delta — is not a state the writer can be in.
pub struct Append {
    pub legs: Vec<Leg>,
    pub seq_offsets: Vec<i64>,
    pub deltas: BTreeMap<(Uuid, String), Delta>,
}

/// Plan the append for these postings: expand to legs, coalesce, number —
/// and, for a pending transaction, withhold the balance movement. Refuses
/// when coalescing overflows 64-bit minor units (checked before the
/// withholding on purpose: a pending set that cannot post should be refused
/// now, not at resolution).
pub(crate) fn plan_append(
    postings: &[Posting],
    status: TransactionStatus,
) -> Result<Append, Overflow> {
    let legs = expand_postings(postings);
    let mut deltas = coalesce(&legs)?;
    // THE CACHE MEANS POSTED (ADR-0010's ruling, restated on
    // `ledger_account_balances` in the baseline): `input`/`output`
    // accumulate posted transactions only, while `last_seq` advances on
    // EVERY entry because a pending entry still needs its `account_seq`
    // issued under the same lock. A delta is what the cache accumulates, so
    // a pending transaction's deltas carry the leg count and zero movement —
    // decided here, where it is pure and testable, not in the statement.
    if status == TransactionStatus::Pending {
        for delta in deltas.values_mut() {
            delta.input = 0;
            delta.output = 0;
        }
    }
    let seq_offsets = offsets_back_from_last_seq(&legs);
    Ok(Append {
        legs,
        seq_offsets,
        deltas,
    })
}

#[cfg(test)]
mod tests {
    //! The posting math's contract, held without a database in the room:
    //! coalescing iterates in account-id order (the writer's deadlock
    //! defense — spike 003), the per-leg offsets number legs gaplessly once
    //! the single call subtracts them from each returned counter, and
    //! coalescing refuses overflow rather than wrapping a balance.

    use super::*;

    fn account(n: u128) -> Uuid {
        Uuid::from_u128(n)
    }

    fn leg(account_id: Uuid, direction: Direction, amount_minor: i64) -> Leg {
        Leg {
            account_id,
            currency: "USD".to_owned(),
            direction,
            amount_minor,
        }
    }

    /// The deterministic lock-order property, held directly: however the legs
    /// arrive, the coalesced map iterates in account-id order, and two runs
    /// over the same legs agree — that ordering is what the writer's upserts
    /// rely on to never deadlock (spike 003).
    #[test]
    fn coalescing_is_deterministic_and_account_ordered() -> Result<(), Overflow> {
        // Scrambled on purpose: high account first, interleaved directions.
        let legs = [
            leg(account(9), Direction::Credit, 100),
            leg(account(1), Direction::Debit, 100),
            leg(account(5), Direction::Debit, 40),
            leg(account(9), Direction::Credit, 60),
            leg(account(1), Direction::Debit, 7),
        ];

        let deltas = coalesce(&legs)?;
        // Determinism: the same legs coalesce a second time, and the two
        // maps must agree.
        let again = coalesce(&legs)?;

        let order: Vec<Uuid> = deltas.keys().map(|(id, _)| *id).collect();
        assert_eq!(order, vec![account(1), account(5), account(9)]);

        let summed: Vec<(Uuid, i64, i64, i64)> = deltas
            .iter()
            .map(|((id, _), d)| (*id, d.input, d.output, d.legs))
            .collect();
        assert_eq!(
            summed,
            vec![
                (account(1), 107, 0, 2),
                (account(5), 40, 0, 1),
                (account(9), 0, 160, 2),
            ]
        );

        let again: Vec<(Uuid, i64, i64, i64)> = again
            .iter()
            .map(|((id, _), d)| (*id, d.input, d.output, d.legs))
            .collect();
        assert_eq!(summed, again);
        Ok(())
    }

    /// The walk-back arithmetic, offsets half: each leg's offset counts the
    /// LATER legs on its own account, interleaved across accounts. What the
    /// offsets then NUMBER, once the single call subtracts them from each
    /// account's returned counter, is the test below's.
    #[test]
    fn offsets_count_the_later_legs_of_each_account() {
        let legs = [
            leg(account(2), Direction::Credit, 10),
            leg(account(1), Direction::Debit, 10),
            leg(account(2), Direction::Credit, 5),
            leg(account(1), Direction::Debit, 5),
        ];

        let offsets = offsets_back_from_last_seq(&legs);

        assert_eq!(offsets, vec![1, 1, 0, 0]);
    }

    /// The walk-back arithmetic, numbering half: the subtraction the
    /// statement performs, replayed here over the same interleaved legs.
    /// Account 1 had 3 entries before this batch (counter now 5); account 2
    /// was fresh (counter now 2). `last_seq - offset` numbers the legs
    /// [1, 4, 2, 5] — gapless per account, ending AT `last_seq`, in leg
    /// order.
    #[test]
    fn the_walk_back_numbers_each_accounts_legs_gaplessly() {
        let legs = [
            leg(account(2), Direction::Credit, 10),
            leg(account(1), Direction::Debit, 10),
            leg(account(2), Direction::Credit, 5),
            leg(account(1), Direction::Debit, 5),
        ];
        let counters = BTreeMap::from([(account(1), 5_i64), (account(2), 2_i64)]);

        let offsets = offsets_back_from_last_seq(&legs);
        let seqs: Vec<i64> = legs
            .iter()
            .zip(&offsets)
            .map(|(leg, offset)| {
                counters.get(&leg.account_id).copied().unwrap_or_default() - offset
            })
            .collect();

        assert_eq!(seqs, vec![1, 4, 2, 5]);
    }

    /// The cache means posted (ADR-0010): a pending plan carries every leg —
    /// each still needs its `account_seq` issued, so `legs` counts stand and
    /// the offsets are the posted plan's — while the balance movement is
    /// withheld: zero `input`, zero `output`, for every account. Break the
    /// withholding and this fails on the movement; break the counter and it
    /// fails on the leg count.
    #[test]
    fn a_pending_plan_issues_seqs_and_withholds_the_balance_movement()
    -> Result<(), Box<dyn std::error::Error>> {
        let postings = vec![
            Posting::new(account(1), account(2), 500, "USD".to_owned())
                .map_err(|invalid| invalid.detail())?,
        ];

        let pending =
            plan_append(&postings, TransactionStatus::Pending).map_err(|Overflow| "overflowed")?;

        let planned: Vec<(Uuid, i64, i64, i64)> = pending
            .deltas
            .iter()
            .map(|((id, _), d)| (*id, d.input, d.output, d.legs))
            .collect();
        assert_eq!(
            planned,
            vec![(account(1), 0, 0, 1), (account(2), 0, 0, 1)],
            "a pending delta must carry its legs and no balance movement"
        );
        assert_eq!(pending.seq_offsets, vec![0, 0]);
        Ok(())
    }

    /// The overflow refusal: two legs on one side of one account summing past
    /// i64 refuse the whole batch rather than wrapping a balance.
    #[test]
    fn coalescing_refuses_i64_overflow() {
        let legs = [
            leg(account(1), Direction::Debit, i64::MAX),
            leg(account(1), Direction::Debit, 1),
        ];

        let coalesced = coalesce(&legs);

        assert!(coalesced.is_err());
    }
}
