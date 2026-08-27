-- PROPOSED DDL -- the one schema change the reconciliation layer needs.
--
-- Nothing in the shipped chart names the type on the other side of a cross-scope
-- obligation. `is_perimeter` asserts that an account mirrors an EXTERNAL balance;
-- `counterparty_scope` asserts whether members of a split may be netted. Neither
-- says that a tenant's `due_from_treasury` is the same money as the operator's
-- `due_to_tenants`, and without that, recon_scope_breaks has nothing to join on.
--
-- Deriving the pair from the `due_from_` / `due_to_` naming is the obvious cheap
-- answer and it is the one this project's own rule refuses: a convention is not a
-- constraint (ADR-0007). A nullable foreign key is a constraint.
--
-- Declared on ONE side of each pair, arbitrarily the asset side. Symmetry is not
-- enforced -- a CHECK cannot see the other row and a trigger would need a written
-- justification it does not have -- so a pair declared in both directions produces
-- the same comparison twice, which is noise rather than error.
--
-- NOT APPLIED to migrations/00001_baseline.sql by this spike. Whether the chart's
-- declarative columns -- is_perimeter, counterparty_scope, and now this one --
-- become enforced is a separate question with its own owner; this file states
-- exactly the column the comparison needs, and nothing more.

ALTER TABLE account_types
    ADD COLUMN mirror_type text
        CONSTRAINT fk_types__mirror REFERENCES account_types (code)
        -- a type is not its own mirror: the FK admits code = mirror_type, and the
        -- comparison would then sum one side against itself and always foot
        CONSTRAINT ck_types__mirror_not_self CHECK (mirror_type <> code);

COMMENT ON COLUMN account_types.mirror_type IS
    'The account type holding the other side of the same cross-scope obligation. '
    'Two scopes, two transactions, opposite signs: the deployment-wide sum of '
    'debit-positive balances over the pair is zero per currency. Read by '
    'recon_scope_breaks and by nothing else.';

UPDATE account_types SET mirror_type = 'due_to_tenants' WHERE code = 'due_from_treasury';
