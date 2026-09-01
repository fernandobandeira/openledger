-- Spike 023 · the accounts the whole spike posts against.
--
-- Two tenants, so every RLS question has a second book to leak into, and the
-- SAME pair the e2e suite uses (crates/e2e/tests/e2e/support/book.rs): a
-- per_shard `customer_receivable` owned by a company, and a house
-- `fee_revenue`. Neither type is `is_perimeter`, which is what keeps
-- chart_lint.perimeter_unattested — correct, and permanently firing until the
-- attestation feed exists (roadmap M7) — out of the ten-check oracle. Accounts
-- are created by hand because the HTTP surface has no account endpoint; that
-- is the same thing the e2e suite does, for the same reason.
--
-- Every account carries 8 stripes so that a "current balance" read is a SUM
-- over several rows rather than one (ADR-0018; the roadmap's own correction to
-- "an O(1) read"). stripe_count is a hint to the writer, so the rows appear
-- lazily as writers pick stripes.

BEGIN;

INSERT INTO ledger_accounts
       (tenant_id, owner_type, owner_id, purpose, category, normal_balance,
        counterparty_scope, currency, stripe_count)
VALUES ('t1', 'company', 'co_1', 'customer_receivable', 'asset', 'debit', 'per_shard', 'USD', 8),
       ('t1', 'house',   NULL,   'fee_revenue',         'revenue', 'credit', 'none',    'USD', 8),
       ('t2', 'company', 'co_2', 'customer_receivable', 'asset', 'debit', 'per_shard', 'USD', 8),
       ('t2', 'house',   NULL,   'fee_revenue',         'revenue', 'credit', 'none',    'USD', 8);

COMMIT;

\pset format unaligned
\pset tuples_only on
SELECT tenant_id || ' ' || purpose || ' ' || id FROM ledger_accounts ORDER BY tenant_id, purpose;
