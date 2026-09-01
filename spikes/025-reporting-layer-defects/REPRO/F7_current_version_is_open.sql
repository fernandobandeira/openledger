-- F7 -- the default chart version is the one version whose content can still change.
--
-- Both statement functions COALESCE their version to max(chart_versions.version),
-- and refuse_stale_chart_version refuses fs_lines/chart_presentation inserts only
-- BELOW that maximum -- its own comment says the current version is "deliberately
-- open". So the version every default-version report is presented through is the
-- one version that is still being built, and an issued statement pinned to a
-- cursor AND a version can still change under both.
--
-- Three parts: the SHAPE moves (part 2), the NUMBERS move in the one reachable
-- case (part 3), and the finding's proposed re-pointing is REFUSED (part 4).
\set ON_ERROR_STOP off

\echo '=== 0. the negative control, and the cursor this statement is issued at'
SELECT * FROM reconciliation;
SELECT report_cursor() AS c \gset
\echo '--- cursor pinned:' :'c'
\echo '--- current chart version:'
SELECT * FROM chart_version_current;

\echo
\echo '=== 1. the statement as issued, at (cursor, version) = (:c, 3)'
SELECT chart_version, fs_line, caption, side, sort_order, amount_minor, pinned_cursor
FROM balance_sheet_at('t1','infinity', :'c', 3) ORDER BY sort_order;

\echo
\echo '=== 2. THE SHAPE MOVES. One fs_lines row appended to version 3 -- the current,'
\echo '--- deliberately open version. Accepted: the trigger refuses only below max.'
INSERT INTO fs_lines (chart_version, code, caption, statement, side, sort_order)
VALUES (3,'goodwill','Goodwill','balance_sheet','asset',250);

\echo '--- the SAME call, at the SAME cursor and the SAME version'
SELECT chart_version, fs_line, caption, side, sort_order, amount_minor, pinned_cursor
FROM balance_sheet_at('t1','infinity', :'c', 3) ORDER BY sort_order;
\echo '--- eleven rows where ten were issued; chart_version reads 3 in both runs.'
\echo '--- and the summary, so the reader can see nothing noticed:'
SELECT * FROM reconciliation;

\echo
\echo '=== 3. THE NUMBERS MOVE. The reachable case: a current version that does not'
\echo '--- yet present a type with posted entries. Version 4 omits customer_wallet.'
BEGIN;
INSERT INTO chart_versions (version, note) VALUES (4,'built in two steps, as the trigger permits');
INSERT INTO fs_lines (chart_version, code, caption, statement, side, sort_order)
SELECT 4, code, caption, statement, side, sort_order FROM fs_lines WHERE chart_version = 3;
INSERT INTO chart_presentation (chart_version, type_code, category, counterparty_scope,
                                fs_line, fs_line_contra)
SELECT 4, type_code, category, counterparty_scope, fs_line, fs_line_contra
FROM chart_presentation WHERE chart_version = 3 AND type_code <> 'customer_wallet';
COMMIT;
\echo '--- the statement at (:c, 4) -- FIRST RUN'
SELECT chart_version, fs_line, amount_minor FROM balance_sheet_at('t1','infinity', :'c', 4)
ORDER BY sort_order;
\echo '--- the missing row, appended to version 4, which is still current and still open'
INSERT INTO chart_presentation (chart_version, type_code, category, counterparty_scope,
                                fs_line, fs_line_contra)
VALUES (4,'customer_wallet','liability','per_shard','customer_funds','receivables');
\echo '--- the statement at (:c, 4) -- SECOND RUN, identical call'
SELECT chart_version, fs_line, amount_minor FROM balance_sheet_at('t1','infinity', :'c', 4)
ORDER BY sort_order;

\echo
\echo '=== 4. REFUTED, in part: an existing type cannot be RE-POINTED within a version.'
\echo '--- a second presentation row for the same type: pk_presentation'
INSERT INTO chart_presentation (chart_version, type_code, category, counterparty_scope,
                                fs_line, fs_line_contra)
VALUES (4,'customer_wallet','liability','per_shard','payables','receivables');
\echo '--- an UPDATE: the append-only trigger'
UPDATE chart_presentation SET fs_line='payables'
WHERE chart_version=4 AND type_code='customer_wallet';
\echo '--- a DELETE-then-reinsert: the same trigger'
DELETE FROM chart_presentation WHERE chart_version=4 AND type_code='customer_wallet';
\echo '--- and an fs_lines caption, which is what a reader actually reads'
UPDATE fs_lines SET caption='Cash' WHERE chart_version=4 AND code='goodwill';
