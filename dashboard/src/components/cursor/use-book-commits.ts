"use client";

import { useEffect, useState } from "react";

import { commitOfRecordedKey, sortedDistinctCommits } from "@/lib/cursor";
import { readAccountEntries } from "@/lib/ledger";

/**
 * The furthest back the walk goes. A rail with more ticks than this is a
 * picture of a hairbrush, and the walk costs one request per commit, so the
 * cap is the honest place to stop rather than a number to raise later.
 */
const MOST_COMMITS = 48;

/** What the rail knows about this book's own commits, and how it knows it. */
export interface BookCommits {
  /** Ascending, distinct. Empty means nothing is known — say so, do not draw. */
  commits: readonly string[];
  busy: boolean;
  /** True when the walk stopped at `MOST_COMMITS` rather than at the end. */
  capped: boolean;
  /** Why there is nothing to draw, in a sentence, or `null`. */
  unknownBecause: string | null;
}

const NOTHING: readonly string[] = [];

const NO_ACCOUNT = "No account open — nothing to read commits from.";

const NO_ENTRIES = "No entries on this account yet.";

/**
 * What one walk found, and what question it was a walk OF — the book, the
 * account, and the write count the page was at when it ran. A walk is shown
 * only while it still answers the question on screen, which is what keeps one
 * account's commits from appearing for a moment under another's.
 */
interface Walked {
  key: string;
  token: number;
  commits: readonly string[];
  capped: boolean;
  stopped: string | null;
}

/**
 * The commit positions this book actually committed at, read off the account
 * on screen.
 *
 * **Where they come from.** No response carries an entry's commit position as
 * a field of its own. One thing carries it: `next_after`, the recorded axis's
 * page key, which the spec spells as `xact_id` and entry id — so a page of
 * ONE entry answers with that entry's own commit position, and walking the
 * axis a page at a time reads them all. That is one request per entry, which
 * is why it is capped and why it is scoped to the account on screen rather
 * than the whole book: the ticks under the rail are the commits that touched
 * the account whose entries are on the page, and the rail says so.
 *
 * **Why not something cheaper.** The cheap alternative is the difference
 * between two `xid8` values, and that is exactly the thing being removed: the
 * counter is cluster-global, so the gap between two of this book's commits
 * counts transactions in other databases. A count of real commits costs
 * requests. A subtraction costs nothing and means nothing.
 *
 * The whole walk rides ONE cursor — the first page's `pinned_cursor` — so it
 * reads a single consistent book rather than picking up whatever committed
 * while it was walking. It never moves the horizon mark: every page after the
 * first supplies a cursor, and a background read is not the deliberate
 * unpinned answer rule 1 lets move it.
 */
export function useBookCommits(
  tenant: string,
  accountId: string | null,
  /** Bumped by the page whenever the book may have moved on. */
  token: number
): BookCommits {
  const [walked, setWalked] = useState<Walked | null>(null);

  const key = accountId === null ? null : [tenant, accountId].join(" · ");
  const sameQuestion = walked !== null && walked.key === key;
  const answered = sameQuestion && walked.token === token;

  useEffect(() => {
    if (key === null || accountId === null) return;
    let live = true;

    void (async () => {
      const found: string[] = [];
      let after: string | null = null;
      let cursor: string | null = null;
      let capped = false;
      let stopped: string | null = null;

      for (let read = 0; read < MOST_COMMITS; read += 1) {
        const answer = await readAccountEntries(accountId, {
          tenant_id: tenant,
          axis: "recorded",
          limit: 1,
          ...(after === null ? {} : { after }),
          ...(cursor === null ? {} : { cursor }),
        });
        if (!live) return;
        if (answer.outcome !== "answered") {
          stopped =
            answer.outcome === "refused"
              ? `Refused: ${answer.error.type}.`
              : "No answer — these are what had been read.";
          break;
        }
        // Every page after the first rides the first one's cursor, so the
        // walk reads one book rather than a moving one.
        cursor ??= answer.body.pinned_cursor;
        // A page that did not fill has no `next_after`: that is the end of
        // the axis, not a failure and not a page to ask for again.
        if (answer.body.next_after === null) break;
        const commit = commitOfRecordedKey(answer.body.next_after);
        if (commit === null) {
          stopped =
            "A page key came back in a shape this axis does not use.";
          break;
        }
        found.push(commit);
        after = answer.body.next_after;
        capped = read === MOST_COMMITS - 1;
      }

      if (!live) return;
      setWalked({
        key,
        token,
        commits: sortedDistinctCommits(found),
        capped,
        stopped,
      });
    })();

    return () => {
      live = false;
    };
  }, [accountId, key, tenant, token]);

  const commits = sameQuestion ? walked.commits : NOTHING;
  return {
    commits,
    busy: key !== null && !answered,
    capped: sameQuestion ? walked.capped : false,
    unknownBecause:
      key === null
        ? NO_ACCOUNT
        : commits.length > 0
          ? (sameQuestion ? walked.stopped : null)
          : ((sameQuestion ? walked.stopped : null) ??
            (answered ? NO_ENTRIES : null)),
  };
}
