"use client";

import { useCallback, useEffect, useRef, useState } from "react";

import {
  listAccounts,
  type AccountListRead,
  type AccountRead,
  type Answer,
} from "@/lib/ledger";

export interface AccountRegister {
  /**
   * The page, and only ever THIS book's page: a listing held from a tenant
   * that has since been changed is not shown, because a stale account id
   * under a new `tenant_id` is a refusal waiting to be rendered.
   */
  accounts: readonly AccountRead[];
  nextAfter: string | null;
  pages: number;
  answer: Answer<AccountListRead> | null;
  busy: boolean;
  hasListed: boolean;
  purpose: string;
  setPurpose: (value: string) => void;
  ownerId: string;
  setOwnerId: (value: string) => void;
  limit: string;
  setLimit: (value: string) => void;
  list: () => Promise<void>;
  loadNextPage: () => Promise<void>;
}

/**
 * The account register, keyset-paginated.
 *
 * `after` carries the last `account_id` of the previous page — never an
 * offset, which would shift under concurrent inserts and silently skip rows.
 * A full page means "there may be more", never "there is": `next_after` is
 * null only when the page did not fill.
 *
 * The state lives in a hook rather than in the panel because a successful
 * account opening has to re-list, and the write panel is nowhere near this one
 * in the tree.
 */
/** Stable identity, so "no accounts yet" does not re-run every reader's effects. */
const NO_ACCOUNTS: readonly AccountRead[] = [];

export function useAccountRegister(tenant: string): AccountRegister {
  const [listed, setListed] = useState<{
    book: string;
    accounts: AccountRead[];
  }>({ book: tenant, accounts: [] });
  const [nextAfter, setNextAfter] = useState<string | null>(null);
  const [pages, setPages] = useState(0);
  const [answer, setAnswer] = useState<Answer<AccountListRead> | null>(null);
  const [busy, setBusy] = useState(false);
  const [hasListed, setHasListed] = useState(false);

  const [purpose, setPurpose] = useState("");
  const [ownerId, setOwnerId] = useState("");
  const [limit, setLimit] = useState("");

  const fetchPage = useCallback(
    async (after: string | null, append: boolean) => {
      setBusy(true);
      const result = await listAccounts({
        tenant_id: tenant,
        ...(purpose.trim() === "" ? {} : { purpose: purpose.trim() }),
        ...(ownerId.trim() === "" ? {} : { owner_id: ownerId.trim() }),
        ...(limit.trim() === "" ? {} : { limit: Number(limit.trim()) }),
        ...(after === null ? {} : { after }),
      });
      setAnswer(result);
      if (result.outcome === "answered") {
        setListed((previous) => ({
          book: tenant,
          accounts:
            append && previous.book === tenant
              ? [...previous.accounts, ...result.body.accounts]
              : result.body.accounts,
        }));
        setNextAfter(result.body.next_after);
        setPages((previous) => (append ? previous + 1 : 1));
        setHasListed(true);
      }
      setBusy(false);
    },
    [limit, ownerId, purpose, tenant]
  );

  const list = useCallback(() => fetchPage(null, false), [fetchPage]);

  /**
   * The register lists itself when the BOOK changes, and only then.
   *
   * The sidenav this feeds is always on screen, so "no accounts" has to mean
   * the book has none rather than that nobody pressed a button. The filters
   * deliberately do not trigger it: a filter is a question you finish typing
   * and then ask, and re-listing on every keystroke would be three requests
   * for `own`, `owne`, `owner`.
   */
  const latest = useRef(fetchPage);
  useEffect(() => {
    latest.current = fetchPage;
  }, [fetchPage]);
  useEffect(() => {
    void latest.current(null, false);
  }, [tenant]);

  const loadNextPage = useCallback(
    () => (nextAfter === null ? Promise.resolve() : fetchPage(nextAfter, true)),
    [fetchPage, nextAfter]
  );

  return {
    accounts: listed.book === tenant ? listed.accounts : NO_ACCOUNTS,
    nextAfter,
    pages,
    answer,
    busy,
    hasListed,
    purpose,
    setPurpose,
    ownerId,
    setOwnerId,
    limit,
    setLimit,
    list,
    loadNextPage,
  };
}
