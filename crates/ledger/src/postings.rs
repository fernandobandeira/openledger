//! The posting math: what the writer computes between its SQL statements —
//! legs, coalesced deltas, the per-account seq walk-back. Plain values in,
//! plain values out; the zero-sqlx property of this CRATE is the point
//! (deny.toml enforces it), which is why these live here and not beside the
//! SQL that consumes them. The service (`service.rs`) owns the order they run
//! in, and is their only caller — the functions are `pub(crate)`; the crate
//! exports only the types the [`Repository`](crate::Repository) port's
//! signatures name.

use std::collections::BTreeMap;

use uuid::Uuid;

use crate::domain::Posting;

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

/// Number each leg from its account's counter, in leg order, by walking back
/// from the totals the balance upserts returned: an account whose counter now
/// reads `last_seq` after `delta.legs` new legs starts numbering them at
/// `last_seq - delta.legs + 1`. Returns one seq per leg, parallel to `legs`;
/// `None` when a leg's account is missing from either map, which cannot
/// happen when both were derived from these same legs.
pub(crate) fn assign_account_seqs(
    legs: &[Leg],
    issued: &BTreeMap<(Uuid, String), i64>,
    deltas: &BTreeMap<(Uuid, String), Delta>,
) -> Option<Vec<i64>> {
    let mut next_seq: BTreeMap<(Uuid, String), i64> = BTreeMap::new();
    for ((account_id, currency), delta) in deltas {
        let last_seq = issued.get(&(*account_id, currency.clone()))?;
        next_seq.insert((*account_id, currency.clone()), last_seq - delta.legs);
    }
    let mut seqs = Vec::with_capacity(legs.len());
    for leg in legs {
        let seq = next_seq.get_mut(&(leg.account_id, leg.currency.clone()))?;
        *seq += 1;
        seqs.push(*seq);
    }
    Some(seqs)
}

#[cfg(test)]
mod tests {
    //! The posting math's contract, held without a database in the room:
    //! coalescing iterates in account-id order (the writer's deadlock
    //! defense — spike 003), the seq walk-back numbers legs gaplessly from
    //! the totals the upserts returned, and both refuse rather than guess.

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

        // Determinism: the same legs coalesce to the same map.
        let again = coalesce(&legs)?;
        let again: Vec<(Uuid, i64, i64, i64)> = again
            .iter()
            .map(|((id, _), d)| (*id, d.input, d.output, d.legs))
            .collect();
        assert_eq!(summed, again);
        Ok(())
    }

    /// The walk-back arithmetic: an account whose upsert returned `last_seq`
    /// after `legs` new legs numbers them ending AT `last_seq`, gaplessly, in
    /// leg order — interleaved across accounts.
    #[test]
    fn seqs_walk_back_from_the_returned_totals() -> Result<(), Overflow> {
        let legs = [
            leg(account(2), Direction::Credit, 10),
            leg(account(1), Direction::Debit, 10),
            leg(account(2), Direction::Credit, 5),
            leg(account(1), Direction::Debit, 5),
        ];
        let deltas = coalesce(&legs)?;
        // Account 1 had 3 entries before this batch (counter now 5); account 2
        // was fresh (counter now 2).
        let issued = BTreeMap::from([
            ((account(1), "USD".to_owned()), 5_i64),
            ((account(2), "USD".to_owned()), 2_i64),
        ]);

        let seqs = assign_account_seqs(&legs, &issued, &deltas);

        assert_eq!(seqs, Some(vec![1, 4, 2, 5]));
        Ok(())
    }

    /// A leg pointing at an account the maps do not carry is refused, not
    /// numbered from nothing.
    #[test]
    fn a_leg_without_a_counter_is_refused() -> Result<(), Overflow> {
        let legs = [leg(account(1), Direction::Debit, 10)];
        let deltas = coalesce(&legs)?;

        let seqs = assign_account_seqs(&legs, &BTreeMap::new(), &deltas);

        assert!(seqs.is_none());
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
