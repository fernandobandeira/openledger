-- Spike 024 -- is the presence ("span") half of the bounded form load-bearing,
-- or is it belt and braces? Build the bounded form WITHOUT it and re-run the one
-- cell that is supposed to need it. A claim that a guard matters is worth
-- nothing until the version without the guard has been shown to fail.
\set ON_ERROR_STOP on
CREATE OR REPLACE VIEW recon_checkpoint_breaks_bounded_nospan AS
SELECT * FROM recon_checkpoint_breaks_bounded WHERE reason <> 'row_span';

BEGIN;
DELETE FROM ledger_period_balances b
WHERE (b.tenant_id, b.period_code, b.currency, b.account_id) = (
    SELECT b3.tenant_id, b3.period_code, b3.currency, b3.account_id
    FROM ledger_period_balances b3
    JOIN ledger_period_balances b2
      ON b2.tenant_id=b3.tenant_id AND b2.currency=b3.currency
     AND b2.account_id=b3.account_id AND b2.period_code='2026-02'
    WHERE b3.tenant_id='bk' AND b3.currency='USD' AND b3.period_code='2026-03'
      AND (b3.input, b3.output) = (b2.input, b2.output)
      AND (b3.input + b3.output) > 0
    ORDER BY b3.account_id LIMIT 1);
SELECT (SELECT count(*) FROM recon_checkpoint_breaks)                    AS level_form,
       (SELECT count(*) FROM recon_checkpoint_breaks_bounded)            AS bounded_with_span,
       (SELECT count(*) FROM recon_checkpoint_breaks_bounded_nospan)     AS bounded_without_span;
ROLLBACK;
