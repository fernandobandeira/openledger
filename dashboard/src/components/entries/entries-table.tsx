"use client";

import { Amount } from "@/components/amount";
import { Mono } from "@/components/mono";
import type { EntryAxis } from "@/components/entries/use-account-entries";
import type { StatementEntryRead } from "@/lib/ledger";
import { cn } from "@/lib/utils";

/**
 * The rows where the two axes disagree — the SAME rows on either axis, which
 * is the point.
 *
 * On the recorded axis a row is one of them when its business date is earlier
 * than one already listed above it: the ledger learnt it after something that
 * happened later. On the effective axis it is the mirror — a row the ledger
 * learnt AFTER something listed below it. Both conditions pick out the entry
 * that was dated back, and both are computed from the page in hand rather
 * than asserted.
 */
function outOfOrder(
  entries: readonly StatementEntryRead[],
  axis: EntryAxis
): Set<string> {
  const found = new Set<string>();
  if (axis === "recorded") {
    let latestSoFar: string | null = null;
    for (const entry of entries) {
      if (latestSoFar !== null && entry.effective_at < latestSoFar) {
        found.add(entry.entry_id);
      }
      if (latestSoFar === null || entry.effective_at > latestSoFar) {
        latestSoFar = entry.effective_at;
      }
    }
    return found;
  }
  let earliestBelow: string | null = null;
  for (let index = entries.length - 1; index >= 0; index -= 1) {
    const entry = entries[index];
    if (earliestBelow !== null && entry.recorded_at > earliestBelow) {
      found.add(entry.entry_id);
    }
    if (earliestBelow === null || entry.recorded_at < earliestBelow) {
      earliestBelow = entry.recorded_at;
    }
  }
  return found;
}

/** `2026-08-01T10:00:00Z` → `2026-08-01 10:00:00`, with the instant on hover. */
function readable(instant: string): string {
  return instant.slice(0, 19).replace("T", " ");
}

/**
 * One account's entries — **the legs that touched THIS account**, never the
 * transaction's other legs, which belong to other accounts. The transaction id
 * is on every row and opens the rest.
 */
export function EntriesTable({
  entries,
  axis,
  onOpenTransaction,
  openTransaction,
}: {
  entries: readonly StatementEntryRead[];
  axis: EntryAxis;
  onOpenTransaction: (transactionId: string) => void;
  openTransaction: string | null;
}) {
  const moved = outOfOrder(entries, axis);
  const leading = axis === "recorded" ? "recorded_at" : "effective_at";

  return (
    <div className="overflow-x-auto">
      <table className="w-full min-w-[48rem] border-collapse text-[0.75rem]">
        <caption className="sr-only">
          The entries on this account, {axis === "recorded"
            ? "in the order the ledger recorded them"
            : "in the order they happened"}
        </caption>
        <thead>
          <tr className="border-b border-line text-[0.66rem] tracking-wide text-dim">
            <th className="w-px py-1 pr-3 text-right font-medium">#</th>
            <th
              className={cn(
                "py-1 pr-3 text-left font-medium",
                leading === "recorded_at" && "text-peach"
              )}
            >
              recorded_at
            </th>
            <th
              className={cn(
                "py-1 pr-3 text-left font-medium",
                leading === "effective_at" && "text-peach"
              )}
            >
              effective_at
            </th>
            <th className="py-1 pr-3 text-left font-medium">direction</th>
            <th className="py-1 pr-3 text-right font-medium">amount</th>
            <th className="py-1 pr-3 text-right font-medium">account_seq</th>
            <th className="py-1 text-left font-medium">transaction</th>
          </tr>
        </thead>
        <tbody>
          {entries.map((entry, index) => {
            const isCredit = entry.direction === "credit";
            const disagrees = moved.has(entry.entry_id);
            return (
              <tr
                key={entry.entry_id}
                className={cn(
                  "border-b border-rule",
                  entry.transaction_id === openTransaction && "bg-surface"
                )}
              >
                <td className="py-1.5 pr-3 text-right">
                  <Mono className="text-[0.66rem] text-dim">{index + 1}</Mono>
                </td>
                <td className="py-1.5 pr-3 whitespace-nowrap">
                  <Mono
                    className={cn(
                      "text-[0.7rem]",
                      leading === "recorded_at" ? "text-ink" : "text-dim"
                    )}
                    title={entry.recorded_at}
                  >
                    {readable(entry.recorded_at)}
                  </Mono>
                </td>
                <td className="py-1.5 pr-3 whitespace-nowrap">
                  <Mono
                    className={cn(
                      "text-[0.7rem]",
                      leading === "effective_at" ? "text-ink" : "text-dim"
                    )}
                    title={entry.effective_at}
                  >
                    {readable(entry.effective_at)}
                  </Mono>
                  {disagrees ? <Backdated axis={axis} /> : null}
                </td>
                <td className="py-1.5 pr-3">
                  <Mono className={isCredit ? "text-credit" : "text-ink"}>
                    {entry.direction}
                  </Mono>
                </td>
                <td className="py-1.5 pr-3 text-right">
                  <Amount
                    minor={entry.amount_minor}
                    currency={entry.currency}
                    className={isCredit ? "text-credit" : undefined}
                  />
                </td>
                <td className="py-1.5 pr-3 text-right">
                  <Mono className="text-dim">{entry.account_seq}</Mono>
                </td>
                <td className="py-1.5">
                  <button
                    type="button"
                    onClick={() => onOpenTransaction(entry.transaction_id)}
                    className="max-w-[13rem] truncate font-mono text-[0.68rem] text-dim underline decoration-dotted underline-offset-2 hover:text-peach"
                    title={`Open ${entry.transaction_id}`}
                  >
                    {entry.transaction_id}
                  </button>
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}

/**
 * The same entry, named for what is odd about it on the axis you are reading.
 * On one it is dated before its neighbours; on the other it was learnt after
 * them. Said where it is visible, not in a legend nobody reads.
 */
function Backdated({ axis }: { axis: EntryAxis }) {
  return (
    <span
      className="ml-2 border border-peach px-1 py-px align-middle text-[0.6rem] tracking-wide text-peach"
      title={
        axis === "recorded"
          ? "Its business date is before one already listed above it: the ledger learnt this entry late."
          : "The ledger learnt this entry after ones listed below it: it was dated back."
      }
    >
      {axis === "recorded" ? "dated back" : "recorded late"}
    </span>
  );
}
