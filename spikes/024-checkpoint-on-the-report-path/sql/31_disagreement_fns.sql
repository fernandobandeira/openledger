CREATE OR REPLACE FUNCTION bs_disagreements(p_tenant text, p_asof timestamptz, p_cursor xid8)
RETURNS TABLE (currency char(3), fs_line text, shipped bigint, candidate bigint)
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(s.currency, c.currency), COALESCE(s.fs_line, c.fs_line),
           s.amount_minor, c.amount_minor
    FROM balance_sheet_at(p_tenant, p_asof, p_cursor) s
    FULL JOIN balance_sheet_at_ckpt(p_tenant, p_asof, p_cursor) c
      ON c.currency = s.currency AND c.fs_line = s.fs_line
    WHERE s.amount_minor IS DISTINCT FROM c.amount_minor
       OR s.caption      IS DISTINCT FROM c.caption
       OR s.side         IS DISTINCT FROM c.side
       OR s.sort_order   IS DISTINCT FROM c.sort_order;
$$;
CREATE OR REPLACE FUNCTION tb_disagreements(p_tenant text, p_from timestamptz,
                                            p_to timestamptz, p_cursor xid8)
RETURNS TABLE (account_id uuid, currency char(3),
               shipped_dr bigint, cand_dr bigint, shipped_cr bigint, cand_cr bigint)
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(s.account_id, c.account_id), COALESCE(s.currency, c.currency),
           s.debits, c.debits, s.credits, c.credits
    FROM trial_balance_at(p_tenant, p_from, p_to, p_cursor) s
    FULL JOIN trial_balance_at_ckpt(p_tenant, p_from, p_to, p_cursor) c
      ON c.account_id = s.account_id AND c.currency = s.currency
    WHERE s.debits  IS DISTINCT FROM c.debits
       OR s.credits IS DISTINCT FROM c.credits
       OR s.balance_debit_positive IS DISTINCT FROM c.balance_debit_positive
       OR s.purpose  IS DISTINCT FROM c.purpose
       OR s.category IS DISTINCT FROM c.category;
$$;
