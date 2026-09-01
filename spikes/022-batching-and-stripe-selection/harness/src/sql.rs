//! The two statements under measurement.
//!
//! `single_member()` is the shipped `CLAIM_AND_APPEND`
//! (crates/ledger/postgres/src/repository.rs) VERBATIM, with exactly one
//! change: the literal `0` stripe in the balance insert and in the entry
//! insert is replaced by a `striped` CTE that computes the stripe once,
//! materialized, and by `balance`'s `RETURNING ... stripe` threaded into the
//! entries. With `--mode none` the expression is the literal `0::smallint`,
//! so V0 reproduces today's writer.
//!
//! `batched()` generalizes it with a member ordinal, per SPEC.md §Batching:
//! B events claimed in one `INSERT ... ON CONFLICT DO NOTHING`, an
//! in-statement per-member admissibility gate, cross-member coalescing, and
//! the walk-back arithmetic moved into a window function.
//!
//! MATERIALIZED is not decoration. `random()` is VOLATILE and a
//! single-reference CTE is inlined by PostgreSQL 12+ by default; inlining
//! `striped` would put the expression in both the INSERT's target list and
//! its ORDER BY, which is precisely the two-evaluations hazard SPEC.md's
//! "compute it once" paragraph is about.

use std::fmt::Write as _;

#[derive(Clone, Copy, PartialEq, Eq, Debug, clap::ValueEnum)]
pub enum Mode {
    None,
    Random,
    Tenant,
    Worker,
}

impl Mode {
    pub fn as_str(self) -> &'static str {
        match self {
            Mode::None => "none",
            Mode::Random => "random",
            Mode::Tenant => "tenant",
            Mode::Worker => "worker",
        }
    }

    /// The stripe expression, per SPEC.md's table. `tenant_col` is the
    /// qualified column holding the tenant this stripe is being chosen for
    /// (a scalar `$1` on the single-member path, a per-member column on the
    /// batched one); `affinity` is the parameter number carrying the writer
    /// task's index.
    /// `abs()` is NOT how a signed hash is folded into a range. `hashtext`
    /// returns int4, and `abs(-2147483648)` raises 22003 — a whole-run abort
    /// waiting on one unlucky tenant name. Masking the sign bit off is total:
    /// `x & 2147483647` is non-negative for every int4, so the `%` cannot
    /// produce the negative stripe that `ck_balances__stripe_non_negative`
    /// would reject. The same mask is applied to `--mode worker`'s affinity:
    /// the harness only ever binds a non-negative task index, so the mask is
    /// a no-op there, and a no-op is what an invariant should cost when it
    /// already holds.
    fn expression(self, tenant_col: &str, affinity: usize) -> String {
        match self {
            Mode::None => "0::smallint".to_owned(),
            Mode::Random => "(floor(random() * a.stripe_count))::smallint".to_owned(),
            Mode::Tenant => {
                format!("((hashtext({tenant_col}) & 2147483647) % a.stripe_count)::smallint")
            }
            Mode::Worker => {
                format!("((${affinity}::int & 2147483647) % a.stripe_count)::smallint")
            }
        }
    }
}

/// The order the balance upsert presents its rows in.
///
/// `Canonical` is the shipped statement's `ORDER BY`: every writer takes the
/// contended rows in one agreed order, which is the whole reason the clause
/// exists. `PlanOrder` removes it and takes whatever the aggregate emits.
///
/// `Reversed` is a MODEL, and it is named as one. Removing the `ORDER BY`
/// does not by itself make two writers disagree: on the batched path the
/// insert's row order comes from a group-key set that is identical for every
/// writer, so `--no-order-by` alone leaves the batched arm as ordered in
/// practice as the sorted one, and section E would measure zero and call it
/// safety. What the clause actually defends against is two writers whose
/// plans emit the contended rows in OPPOSITE orders. `Reversed` spells that
/// worst case out — an explicit DESC on the same key — so the batched arm
/// tests the hazard rather than assuming the planner will produce it.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum BalanceOrder {
    Canonical,
    Reversed,
    PlanOrder,
}

impl BalanceOrder {
    pub fn as_str(self) -> &'static str {
        match self {
            BalanceOrder::Canonical => "canonical",
            BalanceOrder::Reversed => "reversed",
            BalanceOrder::PlanOrder => "plan-order",
        }
    }
}

/// Where the stripe is chosen relative to the cross-member coalesce.
/// Identical by construction at B = 1.
#[derive(Clone, Copy, PartialEq, Eq, Debug, clap::ValueEnum)]
pub enum Placement {
    /// At `member_delta` grain, BEFORE the coalesce — the coalesce then
    /// groups by (tenant, account, currency, stripe). Spike 003's shape: a
    /// batch of 25 under `random` scatters across ~25 stripes with nothing
    /// left to coalesce.
    PerMember,
    /// AFTER the coalesce — the whole batch lands on one stripe per account
    /// whatever the mode.
    PerBatch,
}

impl Placement {
    pub fn as_str(self) -> &'static str {
        match self {
            Placement::PerMember => "per-member",
            Placement::PerBatch => "per-batch",
        }
    }
}

pub struct Shape {
    pub mode: Mode,
    pub placement: Placement,
    pub order_by: bool,
    pub balance_order: BalanceOrder,
    pub admissibility_gate: bool,
}

/// The upsert's conflict action, shared by both statements — byte for byte
/// the shipped one.
const UPSERT_TAIL: &str = "ON CONFLICT (tenant_id, account_id, currency, stripe) DO UPDATE
         SET input      = ledger_account_balances.input + EXCLUDED.input,
             output     = ledger_account_balances.output + EXCLUDED.output,
             last_seq   = ledger_account_balances.last_seq + EXCLUDED.last_seq,
             updated_at = now()
         RETURNING account_id, currency, stripe, last_seq";

/// Statement A, striped. Parameters $1..$18 are the shipped writer's, in the
/// shipped order; $19 is the writer task's affinity index, bound always and
/// read only by `--mode worker`.
pub fn single_member(shape: &Shape) -> String {
    let stripe = shape.mode.expression("$1", 19);
    let order = if shape.order_by {
        "\n         ORDER BY s.account_id, s.currency, s.stripe"
    } else {
        ""
    };
    format!(
        "WITH supersede_target AS (
         SELECT x.effective_at, x.status, x.kind,
                (x.resolves_id IS NOT NULL OR x.reverses_id IS NOT NULL) AS is_superseding,
                EXISTS (SELECT 1 FROM ledger_transactions rr
                        WHERE rr.tenant_id = $1
                          AND (rr.resolves_id = x.id OR rr.reverses_id = x.id))
                    AS target_already_superseded
         FROM ledger_transactions x
         WHERE x.tenant_id = $1 AND x.id = COALESCE($17::uuid, $18::uuid)
     ),
     effective AS (
         SELECT COALESCE($5::timestamptz,
                         (SELECT effective_at FROM supersede_target),
                         now()) AS at
     ),
     claimed AS (
         INSERT INTO ledger_events
                (tenant_id, kind, source, idempotency_key, idempotency_hash,
                 payload, effective_at)
         SELECT $1, 'posting', 'api', $2, $3, $4, e.at
         FROM effective e
         ON CONFLICT (tenant_id, idempotency_key) DO NOTHING
         RETURNING id
     ),
     txn AS (
         INSERT INTO ledger_transactions
                (tenant_id, event_id, kind, status, effective_at,
                 resolves_id, reverses_id)
         SELECT $1, c.id, 'posting', $16::ledger_txn_status,
                (SELECT at FROM effective), $17, $18
         FROM claimed c
         WHERE ($17::uuid IS NULL AND $18::uuid IS NULL)
            OR ($17::uuid IS NOT NULL
                AND EXISTS (SELECT 1 FROM supersede_target g
                            WHERE g.status = 'pending'
                              AND NOT g.target_already_superseded))
            OR ($18::uuid IS NOT NULL
                AND EXISTS (SELECT 1 FROM supersede_target g
                            WHERE g.kind = 'posting'
                              AND NOT g.is_superseding
                              AND NOT g.target_already_superseded))
         RETURNING id
     ),
     mirror_leg AS (
         SELECT e.account_id,
                CASE e.direction WHEN 'debit' THEN 'credit' ELSE 'debit' END
                    AS direction,
                e.amount_minor, e.currency::text AS currency,
                (count(*) OVER (PARTITION BY e.account_id, e.currency)
                 - row_number() OVER (PARTITION BY e.account_id, e.currency
                                      ORDER BY e.account_seq)) AS seq_offset
         FROM ledger_entries e
         WHERE $18::uuid IS NOT NULL
           AND e.tenant_id = $1 AND e.transaction_id = $18
           AND (SELECT status FROM supersede_target) = 'posted'
     ),
     mirror_delta AS (
         SELECT account_id, currency,
                COALESCE(SUM(amount_minor) FILTER (WHERE direction = 'debit'),
                         0)::bigint AS input,
                COALESCE(SUM(amount_minor) FILTER (WHERE direction = 'credit'),
                         0)::bigint AS output,
                COUNT(*) AS legs
         FROM mirror_leg
         GROUP BY account_id, currency
     ),
     delta AS (
         SELECT d.account_id, d.currency, d.input, d.output, d.legs
         FROM claimed c
         CROSS JOIN unnest($6::uuid[], $7::text[], $8::bigint[], $9::bigint[],
                           $10::bigint[])
              AS d(account_id, currency, input, output, legs)
         UNION ALL
         SELECT m.account_id, m.currency, m.input, m.output, m.legs
         FROM claimed c
         CROSS JOIN mirror_delta m
     ),
     striped AS MATERIALIZED (
         SELECT d.account_id, d.currency, d.input, d.output, d.legs,
                a.owner_type, a.owner_id_key, a.purpose, a.category, a.normal_balance,
                {stripe} AS stripe
         FROM delta d
         JOIN ledger_accounts a
           ON a.tenant_id = $1 AND a.id = d.account_id AND a.currency = d.currency
     ),
     balance AS (
         INSERT INTO ledger_account_balances
                (tenant_id, account_id, currency, stripe,
                 owner_type, owner_id_key, purpose, category, normal_balance,
                 input, output, last_seq)
         SELECT $1, s.account_id, s.currency, s.stripe,
                s.owner_type, s.owner_id_key, s.purpose, s.category, s.normal_balance,
                s.input, s.output, s.legs
         FROM striped s{order}
         {UPSERT_TAIL}
     ),
     entry AS (
         INSERT INTO ledger_entries
                (tenant_id, transaction_id, account_id, direction, amount_minor,
                 currency, stripe, account_seq, effective_at)
         SELECT $1, t.id, l.account_id, l.direction::ledger_direction, l.amount_minor,
                l.currency, b.stripe, b.last_seq - l.seq_offset, (SELECT at FROM effective)
         FROM txn t
         CROSS JOIN (SELECT l.account_id, l.direction, l.amount_minor,
                            l.currency, l.seq_offset
                     FROM unnest($11::uuid[], $12::text[], $13::bigint[],
                                 $14::text[], $15::bigint[])
                          AS l(account_id, direction, amount_minor, currency,
                               seq_offset)
                     UNION ALL
                     SELECT account_id, direction, amount_minor, currency,
                            seq_offset
                     FROM mirror_leg) l
         JOIN balance b ON b.account_id = l.account_id AND b.currency = l.currency
     )
     SELECT c.id AS event_id, t.id AS transaction_id,
            d.account_id, d.currency, b.last_seq
     FROM claimed c
     LEFT JOIN txn t ON true
     LEFT JOIN delta d ON true
     LEFT JOIN balance b ON b.account_id = d.account_id AND b.currency = d.currency
     ORDER BY d.account_id, d.currency"
    )
}

/// Statement A, batched. $1 is a per-member TENANT array, not a scalar: a
/// batch may span tenants unless the assembler is told not to let it
/// (`--tenant-homogeneous`), and that is one of the things being measured.
/// Everything grouped in SPEC.md by (account, currency) is grouped here by
/// (tenant, account, currency) for the same reason.
///
/// Parameters:
///   $1 tenants text[]      $2 keys text[]       $3 hashes bytea[]
///   $4 payloads text[]     $5 effective_at text $6 leg member-ordinal int[]
///   $7 leg ordinal int[]   $8 accounts uuid[]   $9 directions text[]
///  $10 amounts bigint[]   $11 currencies text[] $12 affinity int
pub fn batched(shape: &Shape) -> String {
    let mut sql = String::new();
    sql.push_str(
        "WITH member AS (
         SELECT m.ord::int AS ord, m.tenant_id, m.idempotency_key, m.hash, m.payload
         FROM unnest($1::text[], $2::text[], $3::bytea[], $4::text[]) WITH ORDINALITY
              AS m(tenant_id, idempotency_key, hash, payload, ord)
     ),
     member_leg AS (
         SELECT l.ord, l.leg_ord, m.tenant_id, l.account_id, l.direction,
                l.amount_minor, l.currency
         FROM unnest($6::int[], $7::int[], $8::uuid[], $9::text[], $10::bigint[],
                     $11::text[])
              AS l(ord, leg_ord, account_id, direction, amount_minor, currency)
         JOIN member m ON m.ord = l.ord
     ),
     member_delta AS (
         SELECT ord, tenant_id, account_id, currency,
                coalesce(sum(amount_minor) FILTER (WHERE direction = 'debit'), 0)::bigint  AS input,
                coalesce(sum(amount_minor) FILTER (WHERE direction = 'credit'), 0)::bigint AS output,
                count(*) AS legs
         FROM member_leg GROUP BY ord, tenant_id, account_id, currency
     ),
     admissible AS (
         SELECT md.ord
         FROM member_delta md
         LEFT JOIN ledger_accounts a
                ON a.tenant_id = md.tenant_id AND a.id = md.account_id
               AND a.currency = md.currency
         GROUP BY md.ord
         HAVING count(*) FILTER (WHERE a.id IS NULL) = 0
     ),
     claimed AS (
         INSERT INTO ledger_events
                (tenant_id, kind, source, idempotency_key, idempotency_hash,
                 payload, effective_at)
         SELECT m.tenant_id, 'posting', 'api', m.idempotency_key, m.hash,
                m.payload::jsonb, $5::timestamptz
         FROM member m
",
    );
    // The gate belongs HERE, above the claim, not below it. `admissible`
    // reads only `member_leg` and `member_delta` — it needs nothing the
    // claim writes — so filtering afterwards buys nothing and costs
    // everything: an inadmissible member's `ledger_events` row COMMITS with
    // its innocent neighbours, its idempotency key is burned permanently,
    // and the retry that follows finds the key held and replays a stored
    // result of `(event_id, transaction_id = NULL)`. The caller is then told
    // 200 replayed for a request the ledger refused. A refusal that is
    // indistinguishable from a success on retry is not a refusal.
    if shape.admissibility_gate {
        sql.push_str("         JOIN admissible ad ON ad.ord = m.ord\n");
    }
    sql.push_str(
        "         ON CONFLICT (tenant_id, idempotency_key) DO NOTHING
         RETURNING tenant_id, id, idempotency_key
     ),
     proceeding AS (
         SELECT c.id AS event_id, m.ord, m.tenant_id
         FROM claimed c
         JOIN member m ON m.tenant_id = c.tenant_id
                      AND m.idempotency_key = c.idempotency_key
",
    );
    if shape.admissibility_gate {
        // Redundant once `claimed` is gated, and kept: it is what makes the
        // gate legible in the dumped SQL, and it is the only line that has
        // to move if the claim is ever ungated again.
        sql.push_str("         JOIN admissible ad ON ad.ord = m.ord\n");
    }
    sql.push_str(
        "     ),
     txn AS (
         INSERT INTO ledger_transactions
                (tenant_id, event_id, kind, status, effective_at)
         SELECT p.tenant_id, p.event_id, 'posting', 'posted'::ledger_txn_status,
                $5::timestamptz
         FROM proceeding p
         RETURNING tenant_id, id, event_id
     ),
",
    );

    match shape.placement {
        Placement::PerBatch => {
            let stripe = shape.mode.expression("d.tenant_id", 12);
            let _ = write!(
                sql,
                "     delta AS (
         SELECT md.tenant_id, md.account_id, md.currency,
                sum(md.input) AS input, sum(md.output) AS output, sum(md.legs) AS legs
         FROM member_delta md JOIN proceeding p ON p.ord = md.ord
         GROUP BY md.tenant_id, md.account_id, md.currency
     ),
     striped AS MATERIALIZED (
         SELECT d.tenant_id, d.account_id, d.currency, d.input, d.output, d.legs,
                a.owner_type, a.owner_id_key, a.purpose, a.category, a.normal_balance,
                {stripe} AS stripe
         FROM delta d
         JOIN ledger_accounts a
           ON a.tenant_id = d.tenant_id AND a.id = d.account_id
          AND a.currency = d.currency
     ),
     leg_stripe AS (
         SELECT md.ord, s.tenant_id, s.account_id, s.currency, s.stripe
         FROM member_delta md
         JOIN proceeding p ON p.ord = md.ord
         JOIN striped s ON s.tenant_id = md.tenant_id AND s.account_id = md.account_id
                       AND s.currency = md.currency
     ),
"
            );
        }
        Placement::PerMember => {
            let stripe = shape.mode.expression("md.tenant_id", 12);
            let _ = write!(
                sql,
                "     member_striped AS MATERIALIZED (
         SELECT md.ord, md.tenant_id, md.account_id, md.currency,
                md.input, md.output, md.legs,
                a.owner_type, a.owner_id_key, a.purpose, a.category, a.normal_balance,
                {stripe} AS stripe
         FROM member_delta md
         JOIN proceeding p ON p.ord = md.ord
         JOIN ledger_accounts a
           ON a.tenant_id = md.tenant_id AND a.id = md.account_id
          AND a.currency = md.currency
     ),
     striped AS (
         SELECT tenant_id, account_id, currency, stripe,
                owner_type, owner_id_key, purpose, category, normal_balance,
                sum(input) AS input, sum(output) AS output, sum(legs) AS legs
         FROM member_striped
         GROUP BY tenant_id, account_id, currency, stripe,
                  owner_type, owner_id_key, purpose, category, normal_balance
     ),
     leg_stripe AS (
         SELECT ord, tenant_id, account_id, currency, stripe FROM member_striped
     ),
"
            );
        }
    }

    let order = match shape.balance_order {
        BalanceOrder::Canonical => "\n         ORDER BY s.tenant_id, s.account_id, s.currency, s.stripe",
        BalanceOrder::Reversed => {
            "\n         ORDER BY s.tenant_id DESC, s.account_id DESC, s.currency DESC, s.stripe DESC"
        }
        BalanceOrder::PlanOrder => "",
    };
    let _ = write!(
        sql,
        "     balance AS (
         INSERT INTO ledger_account_balances
                (tenant_id, account_id, currency, stripe,
                 owner_type, owner_id_key, purpose, category, normal_balance,
                 input, output, last_seq)
         SELECT s.tenant_id, s.account_id, s.currency, s.stripe,
                s.owner_type, s.owner_id_key, s.purpose, s.category, s.normal_balance,
                s.input, s.output, s.legs
         FROM striped s{order}
         {UPSERT_TAIL}, tenant_id
     ),
     numbered AS (
         SELECT t.id AS transaction_id, ml.tenant_id, ml.account_id, ml.direction,
                ml.amount_minor, ml.currency, ls.stripe,
                (count(*)     OVER (PARTITION BY ml.tenant_id, ml.account_id,
                                                 ml.currency, ls.stripe)
                 - row_number() OVER (PARTITION BY ml.tenant_id, ml.account_id,
                                                   ml.currency, ls.stripe
                                      ORDER BY ml.ord, ml.leg_ord)) AS seq_offset
         FROM member_leg ml
         JOIN proceeding p ON p.ord = ml.ord
         JOIN txn t ON t.tenant_id = p.tenant_id AND t.event_id = p.event_id
         JOIN leg_stripe ls ON ls.ord = ml.ord AND ls.tenant_id = ml.tenant_id
                           AND ls.account_id = ml.account_id
                           AND ls.currency = ml.currency
     ),
     entry AS (
         INSERT INTO ledger_entries
                (tenant_id, transaction_id, account_id, direction, amount_minor,
                 currency, stripe, account_seq, effective_at)
         SELECT n.tenant_id, n.transaction_id, n.account_id,
                n.direction::ledger_direction, n.amount_minor, n.currency,
                n.stripe, b.last_seq - n.seq_offset, $5::timestamptz
         FROM numbered n
         JOIN balance b ON b.tenant_id = n.tenant_id AND b.account_id = n.account_id
                       AND b.currency = n.currency AND b.stripe = n.stripe
     )
     SELECT m.ord, c.id AS event_id, t.id AS transaction_id,
            (ad.ord IS NOT NULL) AS admissible
     FROM member m
     LEFT JOIN claimed c ON c.tenant_id = m.tenant_id
                        AND c.idempotency_key = m.idempotency_key
     LEFT JOIN admissible ad ON ad.ord = m.ord
     LEFT JOIN proceeding p ON p.ord = m.ord
     LEFT JOIN txn t ON t.tenant_id = p.tenant_id AND t.event_id = p.event_id
     ORDER BY m.ord"
    );
    sql
}
