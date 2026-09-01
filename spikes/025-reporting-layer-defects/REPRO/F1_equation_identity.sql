-- F1 -- recon_equation_breaks is an algebraic identity, and cannot falsify a
-- presentation defect.
--
-- THE ALGEBRA. `lines` computes, per balance-sheet line,
--     amount = SUM(CASE WHEN f.side = 'asset' THEN v ELSE -v END)
-- and the check then forms
--     gap = SUM(amount WHERE side='asset') - SUM(amount WHERE side IN ('liability','equity'))
-- The second subtraction re-flips the sign the first one applied, so
--     gap = SUM(v over asset lines) + SUM(v over liability/equity lines) - plug
--         = SUM(v over balance-sheet positions) + SUM(v over revenue/expense positions)
--         = SUM(v over every posted, presented, in-scope position)
-- and that is zero on any journal that foots per (tenant, currency). WHICH LINE a
-- position was routed to, and which of the three sides that line carries, cancel
-- out of the expression entirely.
--
-- Part 1 REFUTES the finding's proposed injection: three keys make it unwritable.
-- Part 2 reproduces the same blindness through the routing the keys DO allow.
\set ON_ERROR_STOP off
\echo '=== 0. the negative control: ten checks, zero breaks; and the face as issued'
SELECT * FROM reconciliation;
SELECT fs_line, caption, side, amount_minor
FROM balance_sheet_at('t1','infinity', report_cursor()) ORDER BY sort_order;

\echo
\echo '=== 1. REFUTED: a liability position cannot be routed to an asset-side line.'
\echo '--- chart_presentation.fs_side is GENERATED from category and carried into'
\echo '--- fk_presentation__fs_line, so the line it names must carry the same side.'
BEGIN;
INSERT INTO chart_versions (version, note) VALUES (4,'probe');
INSERT INTO fs_lines (chart_version, code, caption, statement, side, sort_order)
SELECT 4, code, caption, statement, side, sort_order FROM fs_lines WHERE chart_version = 3;
INSERT INTO chart_presentation (chart_version, type_code, category, counterparty_scope,
                               fs_line, fs_line_contra)
VALUES (4,'customer_wallet','liability','per_shard','receivables','customer_funds');
ROLLBACK;
\echo '--- ...nor onto an income-statement line (fs_statement is generated too)'
BEGIN;
INSERT INTO chart_versions (version, note) VALUES (4,'probe');
INSERT INTO fs_lines (chart_version, code, caption, statement, side, sort_order)
SELECT 4, code, caption, statement, side, sort_order FROM fs_lines WHERE chart_version = 3;
INSERT INTO chart_presentation (chart_version, type_code, category, counterparty_scope,
                               fs_line, fs_line_contra)
VALUES (4,'customer_wallet','liability','per_shard','revenue','customer_funds');
ROLLBACK;
\echo '--- ...nor can a balance-sheet line carry a side outside the three-valued split'
BEGIN;
INSERT INTO chart_versions (version, note) VALUES (4,'probe');
INSERT INTO fs_lines (chart_version, code, caption, statement, side, sort_order)
VALUES (4,'limbo','Limbo','balance_sheet','debit',999);
ROLLBACK;

\echo
\echo '=== 2. REPRODUCED: the routing the keys DO allow is equally invisible.'
\echo '--- Chart version 4 is a complete, well-formed chart that differs from'
\echo '--- version 3 in two presentation rows, both WITHIN their declared side:'
\echo '---   customer_wallet   liability -> `payables`          (was `customer_funds`)'
\echo '---   paid_in_capital   equity    -> `retained_earnings` (was `equity`)'
\echo '--- Customer money is presented as a trade payable -- the same defect class'
\echo '--- the shipped seed spends chart version 2 correcting for ach_pull_returnable'
\echo '--- -- and contributed capital is presented as accumulated earnings, which is'
\echo '--- a distributable-reserves claim the entity has not earned.'
BEGIN;
INSERT INTO chart_versions (version, note) VALUES
  (4,'Present customer_wallet under `payables` and paid_in_capital under '
     '`retained_earnings`. Both moves stay inside the side the category '
     'declares, so every key is satisfied.');
INSERT INTO fs_lines (chart_version, code, caption, statement, side, sort_order)
SELECT 4, code, caption, statement, side, sort_order FROM fs_lines WHERE chart_version = 3;
INSERT INTO chart_presentation (chart_version, type_code, category, counterparty_scope,
                                fs_line, fs_line_contra)
SELECT 4, type_code, category, counterparty_scope,
       CASE type_code WHEN 'customer_wallet'  THEN 'payables'
                      WHEN 'paid_in_capital'  THEN 'retained_earnings'
                      ELSE fs_line END,
       fs_line_contra
FROM chart_presentation WHERE chart_version = 3;
COMMIT;

\echo '--- the face at the SAME cursor, under the new current version'
SELECT fs_line, caption, side, amount_minor
FROM balance_sheet_at('t1','infinity', report_cursor()) ORDER BY sort_order;
\echo '--- the accounting-equation check (must be EMPTY to read green)'
SELECT * FROM recon_equation_breaks(report_cursor(),'infinity');
\echo '--- and the whole summary'
SELECT * FROM reconciliation;
