-- The two time axes, which the suite had never evaluated with an as-of value.
--
-- ADR-0003's headline claim is that a running balance answers "now" and CANNOT
-- answer "as of a business date", because a backdated entry lands with a LATER
-- sequence number than entries whose business date is later than its own. Every
-- test in this repository posted with effective_at = now(), so:
--
--   * accounting_equation() ignoring p_as_of entirely,
--   * its 'effective' axis reading recorded_at instead,
--   * and it ignoring p_tenant,
--
-- were each individually deletable with the whole suite still green. Nothing here
-- asserted the design's most-cited property.
--
-- The fixture separates the axes by BUSINESS date. It cannot separate them by
-- recording date any more, and that is deliberate: recorded_at is now assigned by
-- the engine and cannot be supplied, because a client-settable insertion axis let
-- an already-issued recorded-axis report be rewritten months later by a
-- transaction claiming to predate it -- with zero drift. Everything here is
-- therefore recorded NOW, and the business dates run Jan through May.

\set ON_ERROR_STOP on
\o /dev/null
BEGIN;

-- MODE GUARD. `SET LOCAL session_replication_role = 'replica'` prepended to this
-- file's BEGIN made the whole suite run on the replication apply path, where a
-- guard marked ENABLE REPLICA fires and the ordinary write path is untested. That
-- is how an earlier leak went unnoticed for two hundred lines of negative
-- controls. One line per suite, at both ends.
DO $$ BEGIN
    IF current_setting('session_replication_role') <> 'origin' THEN
        RAISE EXCEPTION
            'this suite is running as %, not origin: every guard it exercises may be '
            'the replica-path one', current_setting('session_replication_role');
    END IF;
    RAISE NOTICE 'ok  running on the ordinary write path';
END $$;

CREATE FUNCTION eqv(p_label text, p_got bigint, p_want bigint) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    IF p_got IS DISTINCT FROM p_want THEN
        RAISE EXCEPTION '% -- expected %, got %', p_label, p_want, p_got;
    END IF;
    RAISE NOTICE 'ok  % = %', p_label, p_got;
END $$;

INSERT INTO ledger_accounts (tenant_id, owner_type, owner_id, purpose, category, normal_balance, currency)
SELECT 'bt','company','acme',code,category,normal_balance,'USD'
  FROM account_types WHERE code = 'customer_receivable';
INSERT INTO ledger_accounts (tenant_id, owner_type, owner_id, purpose, category, normal_balance, currency)
SELECT 'bt','house',NULL,code,category,normal_balance,'USD'
  FROM account_types WHERE code = 'interchange_revenue';
-- a second tenant, so p_tenant is a filter that must actually filter
INSERT INTO ledger_accounts (tenant_id, owner_type, owner_id, purpose, category, normal_balance, currency)
SELECT 'bt2','company','beta',code,category,normal_balance,'USD'
  FROM account_types WHERE code = 'customer_receivable';
INSERT INTO ledger_accounts (tenant_id, owner_type, owner_id, purpose, category, normal_balance, currency)
SELECT 'bt2','house',NULL,code,category,normal_balance,'USD'
  FROM account_types WHERE code = 'interchange_revenue';

-- post(tenant, key, effective_at, recorded_at, amount)
CREATE FUNCTION bpost(p_tenant text, p_key text, p_eff timestamptz,
                      p_amt bigint) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE v_event uuid; v_txn uuid; r record; v_seq bigint; v_bal bigint;
BEGIN
    INSERT INTO ledger_events (tenant_id,kind,source,idempotency_key,idempotency_hash,payload,effective_at)
    VALUES (p_tenant,'bt','internal',p_key,sha256(convert_to(p_key,'UTF8')),'{}',p_eff)
    RETURNING id INTO v_event;
    INSERT INTO ledger_transactions (tenant_id,event_id,kind,status,effective_at)
    VALUES (p_tenant,v_event,'bt','posted',p_eff) RETURNING id INTO v_txn;

    FOR r IN SELECT a.id AS account_id, v.d::ledger_direction AS dir
               FROM (VALUES ('customer_receivable','debit'),('interchange_revenue','credit')) v(p,d)
               JOIN ledger_accounts a ON a.tenant_id=p_tenant AND a.purpose=v.p
              ORDER BY a.id
    LOOP
        INSERT INTO ledger_account_balances AS b (tenant_id,account_id,currency,input,output,last_seq)
        VALUES (p_tenant,r.account_id,'USD',
                CASE WHEN r.dir='debit'  THEN p_amt ELSE 0 END,
                CASE WHEN r.dir='credit' THEN p_amt ELSE 0 END,1)
        ON CONFLICT (tenant_id,account_id,currency) DO UPDATE
           SET input=b.input+EXCLUDED.input, output=b.output+EXCLUDED.output,
               last_seq=b.last_seq+1
        RETURNING b.last_seq, b.input-b.output INTO v_seq, v_bal;

        INSERT INTO ledger_entries (tenant_id,transaction_id,account_id,direction,amount_minor,
                                    currency,account_seq,balance_after,effective_at)
        VALUES (p_tenant,v_txn,r.account_id,r.dir,p_amt,'USD',v_seq,v_bal,p_eff);
    END LOOP;
END $$;

SELECT bpost('bt','jan', '2026-01-15', 100);
-- business date MARCH, recorded FEBRUARY -- ahead of its own recording? no:
-- recorded later than the January one, business date later too. The normal case.
SELECT bpost('bt','mar', '2026-03-15', 400);
-- THE BACKDATED ARRIVAL: business date FEBRUARY, learned about in APRIL. It lands
-- with a HIGHER account_seq than the March entry, which is the whole point.
SELECT bpost('bt','feb', '2026-02-15', 20);
-- ...and the mirror case: a POST-dated arrival. Business date May, learned about
-- in February. On the recorded axis it is already known on 28 Feb; on the
-- effective axis it has not happened yet. The two axes therefore diverge in BOTH
-- directions, which a fixture that only backdates cannot show.
SELECT bpost('bt','may', '2026-05-15', 7);
SELECT bpost('bt2','other','2026-01-15', 7777);

-- the sequence really is out of business-date order
SELECT eqv('the backdated entry has the highest account_seq',
    (SELECT account_seq FROM ledger_entries e
      JOIN ledger_transactions t ON t.tenant_id=e.tenant_id AND t.id=e.transaction_id
      JOIN ledger_events v ON v.tenant_id=t.tenant_id AND v.id=t.event_id
     WHERE e.tenant_id='bt' AND v.idempotency_key='feb' AND e.direction='debit'), 3);

-- ============================================================ the effective axis
-- What was TRUE of the business on 28 February: January + February = 120.
SELECT eqv('effective axis, as of 28 Feb: revenue',
    (SELECT revenue FROM accounting_equation('bt','2026-02-28','effective')), 120);
SELECT eqv('effective axis, as of 31 Jan: revenue',
    (SELECT revenue FROM accounting_equation('bt','2026-01-31','effective')), 100);
SELECT eqv('effective axis, as of 31 Mar: revenue',
    (SELECT revenue FROM accounting_equation('bt','2026-03-31','effective')), 520);
SELECT eqv('effective axis, as of 31 May: revenue (the post-dated one lands)',
    (SELECT revenue FROM accounting_equation('bt','2026-05-31','effective')), 527);

-- ============================================================ the recorded axis
-- What we KNEW on 28 February: nothing. Every fixture row was inserted by this
-- file in one session, so the engine assigned all of them today's recorded_at --
-- which is the point of the axis: you cannot backdate what you knew. An earlier
-- version of this comment predicted 500, written before recorded_at stopped being
-- client-supplied. The assertion below has always said 0.
SELECT eqv('recorded axis, as of 28 Feb: nothing had been recorded yet',
    (SELECT revenue FROM accounting_equation('bt','2026-02-28','recorded')), 0);
SELECT eqv('recorded axis, as of 31 Mar: still nothing',
    (SELECT revenue FROM accounting_equation('bt','2026-03-31','recorded')), 0);
SELECT eqv('recorded axis, as of now: everything',
    (SELECT revenue FROM accounting_equation('bt', now(), 'recorded')), 527);

-- ...and the predicate must READ THE ROW. The three assertions above are all
-- BOUNDARY tests -- 0, 0, everything -- because every fixture row was recorded in
-- this one session, so the recorded axis has no intermediate value to check
-- against. Replacing `en.recorded_at <= p_as_of` with a comparison between two
-- constants therefore satisfied all three, and the recorded axis was attested by
-- nothing at all.
--
-- The fix is to aim at the boundary itself, from both sides, using the value the
-- ENGINE assigned rather than a date this file chose. No constant predicate can
-- be true at `recorded_at` and false one microsecond earlier.
DO $$
DECLARE v_rec timestamptz; v_at bigint; v_before bigint;
BEGIN
    SELECT max(en.recorded_at) INTO v_rec FROM ledger_entries en WHERE en.tenant_id='bt';
    SELECT revenue INTO v_at     FROM accounting_equation('bt', v_rec, 'recorded');
    SELECT revenue INTO v_before FROM accounting_equation('bt',
        v_rec - interval '1 microsecond', 'recorded');
    IF v_at <> 527 THEN
        RAISE EXCEPTION 'as of the recording instant itself the ledger reports %, not 527 '
                        '-- the axis is exclusive where it should be inclusive', v_at;
    END IF;
    IF v_before >= 527 THEN
        RAISE EXCEPTION 'one microsecond BEFORE the last recording the ledger already '
                        'reports % -- the predicate is not reading recorded_at at all', v_before;
    END IF;
    RAISE NOTICE 'ok  the recorded axis turns over AT the recording instant (% -> %)',
        v_before, v_at;
END $$;

-- THE POINT, as an assertion: on the same instant the two axes disagree, and each
-- holds something the other does not. Effective knows February (backdated, not yet
-- recorded on 28 Feb); recorded knows May (post-dated, already recorded).
SELECT eqv('the axes disagree on 28 Feb by everything that had HAPPENED but not been RECORDED',
    (SELECT revenue FROM accounting_equation('bt','2026-02-28','effective'))
  - (SELECT revenue FROM accounting_equation('bt','2026-02-28','recorded')), 120);
SELECT eqv('...and agree once the as-of is past both the business date and the recording',
    (SELECT revenue FROM accounting_equation('bt', now(), 'effective'))
  - (SELECT revenue FROM accounting_equation('bt', now(), 'recorded')), 0);

-- ...and both still balance at every instant.
DO $$
DECLARE r record; n int := 0;
BEGIN
    FOR r IN SELECT * FROM accounting_equation('bt','2026-02-28','effective')
             UNION ALL SELECT * FROM accounting_equation('bt','2026-02-28','recorded')
             UNION ALL SELECT * FROM accounting_equation('bt','2026-01-31','effective')
    LOOP
        n := n + 1;
        IF NOT r.balanced THEN
            RAISE EXCEPTION 'as-of report does not balance: % % lhs=% rhs=%',
                r.tenant_id, r.currency, r.lhs, r.rhs;
        END IF;
    END LOOP;
    IF n <> 3 THEN RAISE EXCEPTION 'expected 3 as-of reports, got %', n; END IF;
    RAISE NOTICE 'ok  every as-of report balances (% checked)', n;
END $$;

-- ============================================================ p_tenant filters
-- bt2 holds 7777 and must not appear in bt's numbers, on either axis.
-- Explicitly: a filtered report returns ONE scope. Without this the assertions
-- below still "pass" when p_tenant is ignored, because a scalar subquery over two
-- rows either takes the first (which happens to be 'bt') or errors with a message
-- that says nothing about tenancy.
SELECT eqv('a filtered report covers exactly one scope',
    (SELECT count(*) FROM accounting_equation('bt','2026-05-31','effective')), 1);
SELECT eqv('...and so does the other one',
    (SELECT count(*) FROM accounting_equation('bt2','2026-05-31','effective')), 1);

SELECT eqv('p_tenant filters, effective axis',
    (SELECT revenue FROM accounting_equation('bt','2026-05-31','effective')), 527);
SELECT eqv('p_tenant filters, recorded axis',
    (SELECT revenue FROM accounting_equation('bt', now(), 'recorded')), 527);
SELECT eqv('...and the other tenant is genuinely there',
    (SELECT revenue FROM accounting_equation('bt2','2026-05-31','effective')), 7777);
SELECT eqv('unfiltered covers both scopes',
    (SELECT count(*) FROM accounting_equation(NULL,'2026-05-31','effective')), 2);

-- ============================================================ balance_after
-- ADR-0003's actual claim: balance_after answers the RECORDED axis and is WRONG
-- for a business-date question. Asserting it rather than describing it.
SELECT eqv('running balance = the recorded-axis total (it is the insertion axis)',
    (SELECT balance_after FROM ledger_entries
      WHERE tenant_id='bt' AND account_id=(SELECT id FROM ledger_accounts
                                            WHERE tenant_id='bt' AND purpose='customer_receivable')
      ORDER BY account_seq DESC LIMIT 1), 527);

DO $$
DECLARE v_running bigint; v_true bigint;
BEGIN
    -- the last entry whose BUSINESS date is on or before 28 Feb, by sequence
    SELECT balance_after INTO v_running FROM ledger_entries
     WHERE tenant_id='bt' AND effective_at <= '2026-02-28'
       AND account_id=(SELECT id FROM ledger_accounts
                        WHERE tenant_id='bt' AND purpose='customer_receivable')
     ORDER BY account_seq DESC LIMIT 1;
    SELECT COALESCE(SUM(CASE WHEN direction='debit' THEN amount_minor ELSE -amount_minor END),0)
      INTO v_true FROM ledger_entries
     WHERE tenant_id='bt' AND effective_at <= '2026-02-28'
       AND account_id=(SELECT id FROM ledger_accounts
                        WHERE tenant_id='bt' AND purpose='customer_receivable');
    IF v_running IS NOT DISTINCT FROM v_true THEN
        RAISE EXCEPTION 'the running balance agreed with the business-date truth (% = %) -- '
            'the fixture no longer separates the axes, so this file proves nothing',
            v_running, v_true;
    END IF;
    RAISE NOTICE 'ok  running balance % is WRONG for the business date; truth is % (ADR-0003)',
        v_running, v_true;
END $$;

-- ...and again at the end, because a SET LOCAL in a DO block that SUCCEEDS
-- persists for the rest of the transaction. MODE GUARD. `SET LOCAL session_replication_role = 'replica'` prepended to this
-- file's BEGIN made the whole suite run on the replication apply path, where a
-- guard marked ENABLE REPLICA fires and the ordinary write path is untested. That
-- is how an earlier leak went unnoticed for two hundred lines of negative
-- controls. One line per suite, at both ends.
DO $$ BEGIN
    IF current_setting('session_replication_role') <> 'origin' THEN
        RAISE EXCEPTION
            'this suite is running as %, not origin: every guard it exercises may be '
            'the replica-path one', current_setting('session_replication_role');
    END IF;
    RAISE NOTICE 'ok  running on the ordinary write path';
END $$;

ROLLBACK;

DO $$ BEGIN RAISE NOTICE 'ok  SUITE-COMPLETE bitemporal'; END $$;
