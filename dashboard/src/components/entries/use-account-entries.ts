"use client";

import { useCallback, useEffect, useState } from "react";

import {
  readAccountEntries,
  type AccountStatementRead,
  type Answer,
  type StatementEntryRead,
} from "@/lib/ledger";

/**
 * The two orders the same set of entries can be in.
 *
 * The spec types `axis` as a plain string — it carries no enum — so this union
 * is the one piece of the entries query the generated client cannot hold us
 * to, and it is named here rather than spelled at a call site.
 */
export type EntryAxis = "recorded" | "effective";

/** Small enough that `next_after` is reachable on a book of any size. */
const PAGE = 25;

/**
 * What was read, and what it was a read OF.
 *
 * The key is the whole question — the book, the account and the axis — and a
 * page is only shown while it still answers the question on screen. That is
 * what keeps a stale account's entries from appearing for a moment under a
 * newly typed tenant, without an effect that blanks state on the way past.
 */
interface Page {
  key: string;
  entries: StatementEntryRead[];
  nextAfter: string | null;
  pinnedCursor: string | null;
  pages: number;
  answer: Answer<AccountStatementRead>;
}

export interface AccountEntries {
  axis: EntryAxis;
  setAxis: (axis: EntryAxis) => void;
  entries: readonly StatementEntryRead[];
  nextAfter: string | null;
  /** The commit position the FIRST page pinned; every later page rides it. */
  pinnedCursor: string | null;
  pages: number;
  answer: Answer<AccountStatementRead> | null;
  busy: boolean;
  reload: () => void;
  loadNextPage: () => Promise<void>;
}

const NO_ENTRIES: readonly StatementEntryRead[] = [];

/**
 * One account's entries, keyset-paged, on one axis.
 *
 * Two rules this hook exists to keep:
 *
 * 1. **The page key belongs to an axis.** `after` is the last row's ordering
 *    key — commit position and entry id on the recorded axis, the business
 *    date as well on the effective one — and the API refuses a key from the
 *    other axis rather than using it as a bound of an order it does not name.
 *    Changing the axis changes the key of the whole question, so the page key
 *    goes with it and that refusal is unreachable from the UI rather than
 *    merely handled.
 *
 * 2. **Only the first page moves the horizon.** The first page supplies no
 *    cursor and the read path pins one; every page after it sends that same
 *    cursor back, so the walk stays on one book rather than picking up
 *    whatever committed while you were reading. A page run AT a cursor
 *    answers with that cursor, and taking it at face value would drag the
 *    horizon mark backwards.
 */
export function useAccountEntries(
  tenant: string,
  accountId: string | null,
  onAnswer: (cursor: string, ranWithoutCursor: boolean, from: string) => void
): AccountEntries {
  const [axis, setAxis] = useState<EntryAxis>("recorded");
  const [page, setPage] = useState<Page | null>(null);
  const [rereading, setRereading] = useState(false);
  const [appending, setAppending] = useState(false);
  const [token, setToken] = useState(0);

  const key = accountId === null ? null : [tenant, accountId, axis].join(" · ");
  const current = page !== null && page.key === key ? page : null;

  useEffect(() => {
    if (key === null || accountId === null) return;
    let live = true;
    void (async () => {
      const result = await readAccountEntries(accountId, {
        tenant_id: tenant,
        axis,
        limit: PAGE,
      });
      if (!live) return;
      setRereading(false);
      setPage({
        key,
        entries: result.outcome === "answered" ? result.body.entries : [],
        nextAfter: result.outcome === "answered" ? result.body.next_after : null,
        pinnedCursor:
          result.outcome === "answered" ? result.body.pinned_cursor : null,
        pages: result.outcome === "answered" ? 1 : 0,
        answer: result,
      });
      if (result.outcome === "answered") {
        onAnswer(
          result.body.pinned_cursor,
          true,
          "GET /v1/accounts/{account_id}/entries"
        );
      }
    })();
    return () => {
      live = false;
    };
  }, [accountId, axis, key, onAnswer, tenant, token]);

  /** Read the first page again — after a write, or on demand. */
  const reload = useCallback(() => {
    setRereading(true);
    setToken((previous) => previous + 1);
  }, []);

  const loadNextPage = useCallback(async () => {
    if (current === null || current.nextAfter === null || accountId === null) {
      return;
    }
    setAppending(true);
    const result = await readAccountEntries(accountId, {
      tenant_id: tenant,
      axis,
      limit: PAGE,
      after: current.nextAfter,
      ...(current.pinnedCursor === null ? {} : { cursor: current.pinnedCursor }),
    });
    setAppending(false);
    setPage((previous) => {
      if (previous === null || previous.key !== current.key) return previous;
      if (result.outcome !== "answered") {
        return { ...previous, answer: result };
      }
      return {
        ...previous,
        entries: [...previous.entries, ...result.body.entries],
        nextAfter: result.body.next_after,
        pages: previous.pages + 1,
        answer: result,
      };
    });
    if (result.outcome === "answered") {
      // A page run AT a cursor answers with that cursor, so it is observed and
      // never allowed to move the horizon mark.
      onAnswer(
        result.body.pinned_cursor,
        false,
        "GET /v1/accounts/{account_id}/entries"
      );
    }
  }, [accountId, axis, current, onAnswer, tenant]);

  return {
    axis,
    setAxis,
    entries: current?.entries ?? NO_ENTRIES,
    nextAfter: current?.nextAfter ?? null,
    pinnedCursor: current?.pinnedCursor ?? null,
    pages: current?.pages ?? 0,
    answer: current?.answer ?? null,
    busy: key !== null && (current === null || rereading || appending),
    reload,
    loadNextPage,
  };
}
