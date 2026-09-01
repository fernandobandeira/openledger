"use client";

import { useCallback, useEffect, useState } from "react";

import { readAccountBalance, type AccountRead } from "@/lib/ledger";

export interface AccountBalances {
  /** The posted balance in minor units, or `null` while it is unknown. */
  of: (accountId: string) => string | null;
  refresh: () => Promise<void>;
}

/**
 * One balance per account in the sidenav — which is one REQUEST per account.
 *
 * That is the shape of the API and not an oversight in it: a balance is per
 * currency and per stripe, so carrying one on every row of `GET /v1/accounts`
 * would be N+1 inside the register instead of out here, and it would be
 * ambiguous besides. `GET /v1/accounts/{account_id}/balance` answers one
 * account exactly, summed over the stripe rows that exist.
 *
 * Every figure stays the exact-integer decimal string the ledger sent. Nothing
 * is added up here — a balance is already an aggregate, and this dashboard
 * does not put an aggregate through `Number`.
 */
export function useAccountBalances(
  tenant: string,
  accounts: readonly AccountRead[]
): AccountBalances {
  const [balances, setBalances] = useState<Record<string, string>>({});

  /**
   * No state is set before the first `await`, deliberately: this runs from an
   * effect as well as from a button, and a synchronous `setState` inside an
   * effect is a cascading render.
   */
  const read = useCallback(async () => {
    const answers = await Promise.all(
      accounts.map((account) =>
        readAccountBalance(account.account_id, {
          tenant_id: tenant,
          currency: account.currency,
        })
      )
    );
    const next: Record<string, string> = {};
    accounts.forEach((account, index) => {
      const answer = answers[index];
      if (answer.outcome === "answered") {
        next[account.account_id] = answer.body.posted_minor;
      }
    });
    return next;
  }, [accounts, tenant]);

  useEffect(() => {
    let live = true;
    void read().then((next) => {
      if (live) setBalances(next);
    });
    return () => {
      live = false;
    };
  }, [read]);

  const refresh = useCallback(async () => {
    setBalances(await read());
  }, [read]);

  const of = useCallback(
    (accountId: string) => balances[accountId] ?? null,
    [balances]
  );

  return { of, refresh };
}
