"use client";

import { useState } from "react";

import { Amount } from "@/components/amount";
import { Trouble } from "@/components/answer-view";
import { InstantField } from "@/components/field";
import { Identifier, Mono } from "@/components/mono";
import { Empty, Panel, PanelNote } from "@/components/panel";
import {
  CursorField,
  PinnedCursor,
  ReproducibilityNote,
  RunRow,
} from "@/components/report-frame";
import { sumMinor } from "@/lib/amount";
import { runTrialBalance, type Answer, type TrialBalanceRead } from "@/lib/ledger";
import { startOfThisYear, toInstant, tomorrow } from "@/lib/time";

/**
 * One endpoint, both time axes: the RECORDED axis is the cursor and the
 * EFFECTIVE axis is the range. Two resources for two parameters of one
 * function would be a mode flag by another name.
 */
export function TrialBalance({
  tenant,
  pinned,
  onPin,
  onAnswer,
}: {
  tenant: string;
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
              <Empty>
                No entries in this range at this cursor. That is a true
                statement about this book, not a missing answer — an unknown
                tenant, a book with no accounts and a quiet window all read the
                same here.
              </Empty>
            </div>
          ) : (
            <div className="mt-3 overflow-x-auto">
              <table className="w-full min-w-[34rem] border-collapse text-[0.75rem]">
                <thead>
                  <tr className="border-b border-line text-[0.68rem] tracking-wide text-dim">
                    <th className="py-1 pr-3 text-left font-medium">account</th>
                    <th className="py-1 pr-3 text-left font-medium">purpose</th>
                    <th className="py-1 pr-3 text-left font-medium">category</th>
                    <th className="py-1 pr-3 text-left font-medium">ccy</th>
                    <th className="py-1 pr-3 text-right font-medium">debits</th>
                    <th className="py-1 pr-3 text-right font-medium">credits</th>
                    <th className="py-1 text-right font-medium">balance</th>
                  </tr>
                </thead>
                <tbody>
                  {report.rows.map((row) => (
                    <tr
                      key={`${row.account_id}-${row.currency}`}
                      className="border-b border-rule"
                    >
                      <td className="max-w-[9rem] py-1.5 pr-3">
                        <Identifier value={row.account_id} truncate />
                      </td>
                      <td className="py-1.5 pr-3">
                        <Mono>{row.purpose}</Mono>
                      </td>
                      <td className="py-1.5 pr-3">
                        <Mono className="text-dim">{row.category}</Mono>
                      </td>
                      <td className="py-1.5 pr-3">
                        <Mono className="text-dim">{row.currency}</Mono>
                      </td>
                      <td className="py-1.5 pr-3 text-right">
                        <Amount minor={row.debits} currency={row.currency} />
                      </td>
                      <td className="py-1.5 pr-3 text-right">
                        <Amount
                          minor={row.credits}
                          currency={row.currency}
                          className="text-credit"
                        />
                      </td>
                      <td className="py-1.5 text-right">
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
                    <td colSpan={4} className="py-2 text-[0.7rem] text-dim">
                      gross, summed with BigInt
                      {debits.exact && credits.exact ? "" : " (a value did not parse as an integer)"}
                    </td>
                    <td className="py-2 pr-3 text-right">
                      <Amount minor={debits.total} />
                    </td>
                    <td className="py-2 pr-3 text-right">
                      <Amount minor={credits.total} className="text-credit" />
                    </td>
                    <td className="py-2 text-right">
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

          <ReproducibilityNote kind="trial-balance" />
        </>
      ) : null}

      <PanelNote>
        <code>balance_debit_positive</code> is the arithmetic value — roll up
        with that one. <code>normal_balance</code> never enters it, so a contra
        account carries its own sign rather than being flipped twice.
      </PanelNote>
    </Panel>
  );
}
