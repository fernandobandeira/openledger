"use client";

import { Amount } from "@/components/amount";
import { Mono } from "@/components/mono";
import { Empty } from "@/components/panel";
import { sumMinor, toMinorBigInt } from "@/lib/amount";
import type { StatementLineRead } from "@/lib/ledger";

/**
 * A face: the chart's own lines, in the chart's own `sort_order`, grouped by
 * currency and then by side.
 *
 * Every amount here is a decimal STRING carrying an exact integer, because an
 * aggregate can exceed 2^53 and a JSON number above that would be rounded by
 * the parser. So the subtotals below are `BigInt` sums of those strings, and
 * nothing on this file goes near `Number`.
 */
export function StatementFace({
  lines,
  check,
}: {
  lines: StatementLineRead[];
  check: "balance-sheet" | "income-statement";
}) {
  if (lines.length === 0) {
    return (
      <div className="mt-3">
        <Empty>
          No lines at this cursor. An unknown tenant answers the same way — 200
          with nothing — because there is no tenant registry to consult.
        </Empty>
      </div>
    );
  }

  const currencies = [...new Set(lines.map((line) => line.currency))].sort();

  return (
    <div className="mt-3 flex flex-col gap-5">
      {currencies.map((currency) => (
        <FaceForCurrency
          key={currency}
          currency={currency}
          lines={lines.filter((line) => line.currency === currency)}
          check={check}
        />
      ))}
    </div>
  );
}

function FaceForCurrency({
  currency,
  lines,
  check,
}: {
  currency: string;
  lines: StatementLineRead[];
  check: "balance-sheet" | "income-statement";
}) {
  const sides = [...new Set(lines.map((line) => line.side))];
  const totals = new Map<string, string>(
    sides.map((side) => [
      side,
      sumMinor(
        lines.filter((line) => line.side === side).map((line) => line.amount_minor)
      ).total,
    ])
  );

  return (
    <div>
      <p className="mb-1 text-[0.7rem] tracking-wide text-dim">{currency}</p>
      <div className="overflow-x-auto">
        <table className="w-full min-w-[24rem] border-collapse text-[0.78rem]">
          <tbody>
            {sides.map((side) => (
              <SideBlock
                key={side}
                side={side}
                currency={currency}
                lines={lines
                  .filter((line) => line.side === side)
                  .sort((a, b) => a.sort_order - b.sort_order)}
                total={totals.get(side) ?? "0"}
              />
            ))}
          </tbody>
        </table>
      </div>
      <Reconciles check={check} totals={totals} />
    </div>
  );
}

function SideBlock({
  side,
  currency,
  lines,
  total,
}: {
  side: string;
  currency: string;
  lines: StatementLineRead[];
  total: string;
}) {
  return (
    <>
      <tr>
        <th
          colSpan={2}
          className="pt-3 pb-1 text-left text-[0.68rem] tracking-wide text-dim"
        >
          {side}
        </th>
      </tr>
      {lines.map((line) => (
        <tr key={line.fs_line} className="border-b border-rule">
          <td className="py-1 pr-3">
            <span>{line.caption}</span>{" "}
            <Mono className="text-[0.68rem] text-dim">{line.fs_line}</Mono>
          </td>
          <td className="py-1 text-right">
            <Amount minor={line.amount_minor} currency={currency} />
          </td>
        </tr>
      ))}
      <tr className="border-b border-line">
        <td className="py-1 pr-3 text-[0.72rem] text-dim">total {side}</td>
        <td className="py-1 text-right">
          <Amount minor={total} currency={currency} className="text-peach" />
        </td>
      </tr>
    </>
  );
}

/**
 * The face's own arithmetic, done here rather than trusted: assets against
 * liabilities plus equity, or credits against debits. `BigInt` throughout.
 */
function Reconciles({
  check,
  totals,
}: {
  check: "balance-sheet" | "income-statement";
  totals: Map<string, string>;
}) {
  if (check === "balance-sheet") {
    const assets = toMinorBigInt(totals.get("asset") ?? "0");
    const liabilities = toMinorBigInt(totals.get("liability") ?? "0");
    const equity = toMinorBigInt(totals.get("equity") ?? "0");
    if (assets === null || liabilities === null || equity === null) return null;
    const other = liabilities + equity;
    const balanced = assets === other;
    return (
      <p className="mt-2 text-[0.72rem]">
        <span className="text-dim">assets − (liabilities + equity) = </span>
        <Amount
          minor={(assets - other).toString()}
          className={balanced ? "text-ok" : "text-credit"}
        />
        <span className={balanced ? "text-ok" : "text-credit"}>
          {balanced ? " · the face balances" : " · the face does not balance"}
        </span>
      </p>
    );
  }

  const credit = toMinorBigInt(totals.get("credit") ?? "0");
  const debit = toMinorBigInt(totals.get("debit") ?? "0");
  if (credit === null || debit === null) return null;
  const net = credit - debit;
  return (
    <p className="mt-2 text-[0.72rem]">
      <span className="text-dim">credits − debits = </span>
      <Amount
        minor={net.toString()}
        className={net < 0n ? "text-credit" : "text-ok"}
      />
      <span className="text-dim"> · the period&rsquo;s result</span>
    </p>
  );
}
