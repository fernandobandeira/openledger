"use client";

import { useState } from "react";

import { Amount } from "@/components/amount";
import { Trouble } from "@/components/answer-view";
import { InstantField } from "@/components/field";
import { Identifier, Mono } from "@/components/mono";
import { Empty, Panel } from "@/components/panel";
import {
  CursorField,
  PinnedCursor,
  RunRow,
} from "@/components/report-frame";
import { sumMinor } from "@/lib/amount";
import {
  runTrialBalance,
  type AccountRead,
  type Answer,
  type TrialBalanceRead,
} from "@/lib/ledger";
import { ownerById } from "@/lib/owner";
import { startOfThisYear, toInstant, tomorrow } from "@/lib/time";

/**
 * One endpoint, both time axes: the RECORDED axis is the cursor and the
 * EFFECTIVE axis is the range. Two resources for two parameters of one
 * function would be a mode flag by another name.
 */
export function TrialBalance({
  tenant,
  accounts,
  pinned,
  onPin,
  onAnswer,
}: {
  tenant: string;
  /**
   * The register this page already listed. The report row carries no owner —
   * it is `(account, currency)` and nothing else — so the field that tells
   * two `customer_wallet` rows apart is joined in from here.
   */
  accounts: readonly AccountRead[];
  pinned: string | null;
  onPin: (cursor: string) => void;
  onAnswer: (cursor: string, ranWithoutCursor: boolean, from: string) => void;
}) {
  const [from, setFrom] = useState(startOfThisYear);
  const [to, setTo] = useState(tomorrow);
  const [cursor, setCursor] = useState("");
  const [busy, setBusy] = useState(false);
  const [answer, setAnswer] = useState<Answer<TrialBalanceRead> | null>(null);
  const [refusedHere, setRefusedHere] = useState<string | null>(null);

  async function run(atCursor: string) {
    const fromInstant = toInstant(from);
    const toInstantValue = toInstant(to);
    if (fromInstant === null || toInstantValue === null) {
      setRefusedHere("Both bounds of the effective range are needed.");
      return;
    }
    setRefusedHere(null);
    setBusy(true);
    const result = await runTrialBalance({
      tenant_id: tenant,
      effective_from: fromInstant,
      effective_to: toInstantValue,
      ...(atCursor.trim() === "" ? {} : { cursor: atCursor.trim() }),
    });
    setAnswer(result);
    if (result.outcome === "answered") {
      onAnswer(
        result.body.pinned_cursor,
        atCursor.trim() === "",
        "the trial balance"
      );
    }
    setBusy(false);
  }

  const report = answer?.outcome === "answered" ? answer.body : null;
  const debits = sumMinor(report?.rows.map((row) => row.debits) ?? []);
  const credits = sumMinor(report?.rows.map((row) => row.credits) ?? []);

  return (
    <Panel title="Trial balance" route="GET /v1/reports/trial-balance">
      <div className="grid gap-3 sm:grid-cols-3">
        <InstantField
          label="effective_from"
          value={from}
          onChange={setFrom}
          hint="Inclusive."
        />
        <InstantField
          label="effective_to"
          value={to}
          onChange={setTo}
          hint="Exclusive — the range is half-open."
        />
        <CursorField value={cursor} onChange={setCursor} />
      </div>

      <div className="mt-3">
        <RunRow
          busy={busy}
          runLabel="Run the trial balance"
          onRun={() => void run(cursor)}
          pinned={pinned}
          onRunAtPin={(pin) => {
            setCursor(pin);
            void run(pin);
          }}
        />
      </div>

      {refusedHere ? (
        <p className="mt-3 border-l-2 border-credit bg-credit-bg/55 px-3 py-2 text-[0.75rem] text-credit">
          {refusedHere}
        </p>
      ) : null}

      <Trouble answer={answer} />

      {report ? (
        <>
          <PinnedCursor
            cursor={report.pinned_cursor}
            pinned={pinned}
            onPin={onPin}
          />

          {report.rows.length === 0 ? (
            <div className="mt-3">
              <Empty>No entries in this range at this cursor.</Empty>
            </div>
          ) : (
            <div className="mt-3 overflow-x-auto">
              {/* Four columns, not seven, and the three on the right are the
                  figures. A trial balance is read across the numbers: the
                  account is the index to a row and the row IS its three
                  amounts, so the identity — purpose, then category, currency
                  and the account_id under it — takes whatever width is left
                  (`w-full`, `max-w-0`, truncating) and the figures take
                  theirs first and never wrap. Seven columns each asking for
                  room is what pushed the balance column off the right edge. */}
              <table className="w-full border-collapse text-[0.75rem]">
                <thead>
                  <tr className="border-b border-line text-[0.68rem] tracking-wide text-dim">
                    <th className="w-full py-1 pr-3 text-left font-medium">
                      account
                    </th>
                    <th className="hidden w-px py-1 pr-3 text-right font-medium whitespace-nowrap sm:table-cell">
                      debits
                    </th>
                    <th className="hidden w-px py-1 pr-3 text-right font-medium whitespace-nowrap sm:table-cell">
                      credits
                    </th>
                    <th className="w-px py-1 text-right font-medium whitespace-nowrap">
                      balance
                    </th>
                  </tr>
                </thead>
                <tbody>
                  {report.rows.map((row) => (
                    <tr
                      key={`${row.account_id}-${row.currency}`}
                      className="border-b border-rule"
                    >
                      <td className="w-full max-w-0 py-1.5 pr-3 align-top">
                        <Mono className="block truncate" title={row.purpose}>
                          {row.purpose}
                        </Mono>
                        <span className="flex min-w-0 items-baseline gap-2">
                          <Mono className="min-w-0 truncate text-[0.66rem] text-dim">
                            {row.category} · {row.currency}
                            {ownerById(accounts, row.account_id) === null
                              ? ""
                              : ` · ${ownerById(accounts, row.account_id)}`}
                          </Mono>
                          <Identifier value={row.account_id} truncate />
                        </span>
                        {/* Too narrow for three figure columns — a gross of
                            90,071,992,547,409.93 is 130px on its own. The
                            gross pair moves UNDER the account rather than
                            behind a scrollbar; the balance keeps its column,
                            because it is the one a trial balance is read
                            down. Nothing is dropped, and no figure is ever
                            what scrolls away. */}
                        <span className="mt-0.5 flex flex-wrap items-baseline gap-x-3 sm:hidden">
                          <span className="text-[0.66rem] text-dim">
                            debits{" "}
                            <Amount
                              minor={row.debits}
                              currency={row.currency}
                              className="text-[0.72rem] text-ink"
                            />
                          </span>
                          <span className="text-[0.66rem] text-dim">
                            credits{" "}
                            <Amount
                              minor={row.credits}
                              currency={row.currency}
                              className="text-[0.72rem] text-credit"
                            />
                          </span>
                        </span>
                      </td>
                      <td className="hidden w-px py-1.5 pr-3 text-right align-top whitespace-nowrap sm:table-cell">
                        <Amount minor={row.debits} currency={row.currency} />
                      </td>
                      <td className="hidden w-px py-1.5 pr-3 text-right align-top whitespace-nowrap sm:table-cell">
                        <Amount
                          minor={row.credits}
                          currency={row.currency}
                          className="text-credit"
                        />
                      </td>
                      <td className="w-px py-1.5 text-right align-top whitespace-nowrap">
                        <Amount
                          minor={row.balance_debit_positive}
                          currency={row.currency}
                        />
                      </td>
                    </tr>
                  ))}
                </tbody>
                <tfoot>
                  <tr className="border-t border-line">
                    <td className="w-full py-2 pr-3 text-[0.7rem] text-dim">
                      gross{debits.exact && credits.exact ? "" : " (a value did not parse)"}
                      <span className="mt-0.5 flex flex-wrap items-baseline gap-x-3 sm:hidden">
                        <span>
                          debits <Amount minor={debits.total} className="text-[0.72rem] text-ink" />
                        </span>
                        <span>
                          credits{" "}
                          <Amount minor={credits.total} className="text-[0.72rem] text-credit" />
                        </span>
                      </span>
                    </td>
                    <td className="hidden w-px py-2 pr-3 text-right whitespace-nowrap sm:table-cell">
                      <Amount minor={debits.total} />
                    </td>
                    <td className="hidden w-px py-2 pr-3 text-right whitespace-nowrap sm:table-cell">
                      <Amount minor={credits.total} className="text-credit" />
                    </td>
                    <td className="w-px py-2 text-right whitespace-nowrap">
                      <span
                        className={`text-[0.7rem] ${
                          debits.total === credits.total
                            ? "text-ok"
                            : "text-credit"
                        }`}
                      >
                        {debits.total === credits.total
                          ? "equal"
                          : "not equal"}
                      </span>
                    </td>
                  </tr>
                </tfoot>
              </table>
            </div>
          )}

        </>
      ) : null}

    </Panel>
  );
}
