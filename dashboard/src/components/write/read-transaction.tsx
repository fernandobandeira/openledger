"use client";

import { useState } from "react";
import { SearchIcon } from "lucide-react";

import { Amount } from "@/components/amount";
import { Trouble } from "@/components/answer-view";
import { TextField } from "@/components/field";
import { Identifier, Mono } from "@/components/mono";
import { Empty, Panel, PanelNote } from "@/components/panel";
import { Button } from "@/components/ui/button";
import {
  readTransaction,
  type Answer,
  type TransactionRead,
} from "@/lib/ledger";
import { sumMinor } from "@/lib/amount";

/**
 * Reading a write back. `POST /v1/transactions` answers with two UUIDs and
 * nothing that says what they point at — unlike an opening, which now carries
 * the whole account — so this is the endpoint that makes `status`,
 * `resolves_id` and `reverses_id` observable at all (ADR-0019).
 */
export function ReadTransaction({
  tenant,
  transactionId,
  setTransactionId,
}: {
  tenant: string;
  transactionId: string;
  setTransactionId: (value: string) => void;
}) {
  const [busy, setBusy] = useState(false);
  const [answer, setAnswer] = useState<Answer<TransactionRead> | null>(null);

  async function read() {
    if (transactionId.trim() === "") return;
    setBusy(true);
    setAnswer(await readTransaction(transactionId.trim(), { tenant_id: tenant }));
    setBusy(false);
  }

  const transaction = answer?.outcome === "answered" ? answer.body : null;

  return (
    <Panel title="Read a transaction back" route="GET /v1/transactions/{id}">
      <div className="flex flex-wrap items-end gap-2">
        <TextField
          className="min-w-[20rem] flex-1"
          label="transaction_id"
          value={transactionId}
          onChange={setTransactionId}
          placeholder="the id a post answered with"
        />
        <Button size="sm" onClick={() => void read()} disabled={busy}>
          <SearchIcon aria-hidden />
          {busy ? "Reading…" : "Read transaction"}
        </Button>
      </div>

      <Trouble answer={answer} />

      {transaction ? (
        <div className="mt-3">
          <dl className="grid gap-x-4 gap-y-1 text-[0.78rem] sm:grid-cols-[9rem_1fr]">
            <dt className="text-dim">kind</dt>
            <dd>
              <Mono>{transaction.kind}</Mono>
            </dd>
            <dt className="text-dim">status</dt>
            <dd>
              <Mono
                className={
                  transaction.status === "pending" ? "text-peach" : "text-ok"
                }
              >
                {transaction.status}
              </Mono>
            </dd>
            <dt className="text-dim">effective_at</dt>
            <dd>
              <Mono>{transaction.effective_at}</Mono>{" "}
              <span className="text-[0.7rem] text-dim">the caller&rsquo;s clock</span>
            </dd>
            <dt className="text-dim">recorded_at</dt>
            <dd>
              <Mono>{transaction.recorded_at}</Mono>{" "}
              <span className="text-[0.7rem] text-dim">the database&rsquo;s clock</span>
            </dd>
            <dt className="text-dim">resolves_id</dt>
            <dd>
              {transaction.resolves_id ? (
                <Identifier value={transaction.resolves_id} />
              ) : (
                <span className="text-dim">null</span>
              )}
            </dd>
            <dt className="text-dim">reverses_id</dt>
            <dd>
              {transaction.reverses_id ? (
                <Identifier value={transaction.reverses_id} />
              ) : (
                <span className="text-dim">null</span>
              )}
            </dd>
            <dt className="text-dim">event_id</dt>
            <dd>
              <Identifier value={transaction.event_id} />
            </dd>
          </dl>

          <Entries entries={transaction.entries} />

          <PanelNote>
            <code>status</code> is what was recorded, not a stage this row moves
            through: a pending transaction becomes posted through a new
            transaction naming it in <code>resolves_id</code>.
          </PanelNote>
        </div>
      ) : null}
    </Panel>
  );
}

function Entries({ entries }: { entries: TransactionRead["entries"] }) {
  if (entries.length === 0) {
    return (
      <div className="mt-3">
        <Empty>
          No entries. This is a void — the zero-posting marker a reversal of a
          pending transaction writes.
        </Empty>
      </div>
    );
  }

  const debits = entries
    .filter((entry) => entry.direction === "debit")
    .map((entry) => entry.amount_minor);
  const credits = entries
    .filter((entry) => entry.direction === "credit")
    .map((entry) => entry.amount_minor);
  const debitTotal = sumMinor(debits);
  const creditTotal = sumMinor(credits);
  const balanced = debitTotal.total === creditTotal.total;

  return (
    <div className="mt-3 overflow-x-auto">
      <table className="w-full min-w-[30rem] border-collapse text-[0.75rem]">
        <thead>
          <tr className="border-b border-line text-[0.68rem] tracking-wide text-dim">
            <th className="py-1 pr-3 text-left font-medium">account</th>
            <th className="py-1 pr-3 text-left font-medium">direction</th>
            <th className="py-1 pr-3 text-right font-medium">amount</th>
            <th className="py-1 pr-3 text-left font-medium">currency</th>
            <th className="py-1 text-right font-medium">account_seq</th>
          </tr>
        </thead>
        <tbody>
          {entries.map((entry, index) => {
            const isCredit = entry.direction === "credit";
            return (
              <tr key={index} className="border-b border-rule">
                <td className="max-w-[16rem] py-1 pr-3">
                  <Identifier value={entry.account_id} truncate />
                </td>
                <td className="py-1 pr-3">
                  <Mono className={isCredit ? "text-credit" : "text-ink"}>
                    {entry.direction}
                  </Mono>
                </td>
                <td className="py-1 pr-3 text-right">
                  <Amount
                    minor={entry.amount_minor}
                    currency={entry.currency}
                    className={isCredit ? "text-credit" : undefined}
                  />
                </td>
                <td className="py-1 pr-3">
                  <Mono className="text-dim">{entry.currency}</Mono>
                </td>
                <td className="py-1 text-right">
                  <Mono className="text-dim">{entry.account_seq}</Mono>
                </td>
              </tr>
            );
          })}
        </tbody>
        <tfoot>
          <tr>
            <td colSpan={2} className="py-2 text-[0.7rem] text-dim">
              debits · credits
            </td>
            <td colSpan={3} className="py-2 text-right">
              <Amount minor={debitTotal.total} /> ·{" "}
              <Amount minor={creditTotal.total} className="text-credit" />{" "}
              <span
                className={`ml-2 text-[0.7rem] ${balanced ? "text-ok" : "text-credit"}`}
              >
                {balanced ? "equal" : "not equal"}
              </span>
            </td>
          </tr>
        </tfoot>
      </table>
      <p className="mt-1 text-[0.68rem] text-dim">
        Direction carries the sign; the amount never does. Each{" "}
        <code>amount_minor</code> is an exact-integer string, and the totals are
        summed with BigInt — nothing here goes through <code>Number</code>.
      </p>
    </div>
  );
}
