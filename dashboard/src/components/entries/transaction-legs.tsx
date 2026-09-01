"use client";

import { useEffect, useState } from "react";
import { ArrowRightIcon, XIcon } from "lucide-react";

import { Amount } from "@/components/amount";
import { Trouble } from "@/components/answer-view";
import { Identifier, Mono } from "@/components/mono";
import { Button } from "@/components/ui/button";
import { sumMinor } from "@/lib/amount";
import {
  readTransaction,
  type AccountRead,
  type Answer,
  type TransactionRead,
} from "@/lib/ledger";
import { cn } from "@/lib/utils";

/**
 * The rest of the transaction one entry belongs to.
 *
 * An account's entries carry only the leg that touched THAT account — the
 * other legs belong to other accounts. This is the other half, and it is where
 * the book stops being a list and becomes something you can walk: every leg
 * names an account, and every account is one click away.
 */
export function TransactionLegs({
  tenant,
  transactionId,
  accounts,
  currentAccount,
  onSelectAccount,
  onClose,
}: {
  tenant: string;
  transactionId: string;
  accounts: readonly AccountRead[];
  currentAccount: string | null;
  onSelectAccount: (accountId: string) => void;
  onClose: () => void;
}) {
  // Keyed by what it is an answer TO, so the previous transaction's legs are
  // never on screen under this one's id while the read is in flight — and so
  // nothing has to be blanked out by an effect on the way past.
  const [loaded, setLoaded] = useState<{
    id: string;
    answer: Answer<TransactionRead>;
  } | null>(null);

  useEffect(() => {
    let live = true;
    void readTransaction(transactionId, { tenant_id: tenant }).then((result) => {
      if (live) setLoaded({ id: transactionId, answer: result });
    });
    return () => {
      live = false;
    };
  }, [tenant, transactionId]);

  const answer = loaded?.id === transactionId ? loaded.answer : null;
  const transaction = answer?.outcome === "answered" ? answer.body : null;

  return (
    <section
      aria-label="The transaction this entry belongs to"
      className="border border-line bg-surface/60 px-3 py-3"
    >
      <header className="flex flex-wrap items-baseline justify-between gap-x-3 gap-y-1">
        <h3 className="text-[0.8rem] font-medium">
          The whole transaction
          <Mono className="ml-2 text-[0.68rem] text-dim">
            GET /v1/transactions/{"{transaction_id}"}
          </Mono>
        </h3>
        <Button size="icon-xs" variant="ghost" aria-label="Close" onClick={onClose}>
          <XIcon aria-hidden />
        </Button>
      </header>

      <div className="mt-1">
        <Identifier value={transactionId} />
      </div>

      {answer === null ? (
        <p className="mt-3 text-[0.75rem] text-dim">Reading…</p>
      ) : null}

      <Trouble answer={answer} />

      {transaction === null ? null : (
        <>
          <Facts transaction={transaction} />
          <Legs
            transaction={transaction}
            accounts={accounts}
            currentAccount={currentAccount}
            onSelectAccount={onSelectAccount}
          />
        </>
      )}
    </section>
  );
}

/** Status, and the two ids that say what this transaction is about. */
function Facts({ transaction }: { transaction: TransactionRead }) {
  const pending = transaction.status === "pending";
  return (
    <dl className="mt-3 grid gap-x-4 gap-y-1 text-[0.75rem] sm:grid-cols-[8.5rem_1fr]">
      <dt className="text-dim">status</dt>
      <dd>
        <Mono className={pending ? "text-peach" : "text-ok"}>
          {transaction.status}
        </Mono>{" "}
        <span className="text-[0.7rem] text-dim">
          {pending
            ? "money that MAY move — its legs are in the journal and out of every balance"
            : "on the books"}
        </span>
      </dd>
      <dt className="text-dim">kind</dt>
      <dd>
        <Mono>{transaction.kind}</Mono>
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
        {transaction.resolves_id === null ? (
          <span className="text-dim">null</span>
        ) : (
          <>
            <Identifier value={transaction.resolves_id} truncate />
            <span className="ml-2 text-[0.7rem] text-dim">
              the pending transaction this one turned into a posting
            </span>
          </>
        )}
      </dd>
      <dt className="text-dim">reverses_id</dt>
      <dd>
        {transaction.reverses_id === null ? (
          <span className="text-dim">null</span>
        ) : (
          <>
            <Identifier value={transaction.reverses_id} truncate />
            <span className="ml-2 text-[0.7rem] text-dim">
              the transaction this one undid — same legs, directions flipped
            </span>
          </>
        )}
      </dd>
      <dt className="text-dim">event_id</dt>
      <dd>
        <Identifier value={transaction.event_id} truncate />
      </dd>
    </dl>
  );
}

/** Every leg, and a way to stand on the other side of any of them. */
function Legs({
  transaction,
  accounts,
  currentAccount,
  onSelectAccount,
}: {
  transaction: TransactionRead;
  accounts: readonly AccountRead[];
  currentAccount: string | null;
  onSelectAccount: (accountId: string) => void;
}) {
  if (transaction.entries.length === 0) {
    return (
      <p className="mt-3 border border-dashed border-rule px-3 py-3 text-[0.75rem] text-dim">
        No entries at all. This is a void — the zero-posting marker a reversal
        of a PENDING transaction writes, because there was nothing posted to
        mirror.
      </p>
    );
  }

  const debits = sumMinor(
    transaction.entries
      .filter((entry) => entry.direction === "debit")
      .map((entry) => entry.amount_minor)
  );
  const credits = sumMinor(
    transaction.entries
      .filter((entry) => entry.direction === "credit")
      .map((entry) => entry.amount_minor)
  );

  return (
    <div className="mt-3 overflow-x-auto">
      <table className="w-full min-w-[34rem] border-collapse text-[0.75rem]">
        <thead>
          <tr className="border-b border-line text-[0.66rem] tracking-wide text-dim">
            <th className="py-1 pr-3 text-left font-medium">account</th>
            <th className="py-1 pr-3 text-left font-medium">direction</th>
            <th className="py-1 pr-3 text-right font-medium">amount</th>
            <th className="py-1 text-right font-medium">account_seq</th>
          </tr>
        </thead>
        <tbody>
          {transaction.entries.map((entry) => {
            const isCredit = entry.direction === "credit";
            const here = entry.account_id === currentAccount;
            const known = accounts.find(
              (account) => account.account_id === entry.account_id
            );
            return (
              <tr
                key={`${entry.account_id}:${entry.account_seq}`}
                className={cn("border-b border-rule", here && "bg-surface")}
              >
                <td className="py-1.5 pr-3">
                  {here ? (
                    <span className="flex flex-wrap items-baseline gap-2">
                      <Mono className="text-[0.72rem] text-peach">
                        {known?.purpose ?? entry.account_id}
                      </Mono>
                      <span className="text-[0.66rem] text-dim">
                        the account you are on
                      </span>
                    </span>
                  ) : (
                    <button
                      type="button"
                      onClick={() => onSelectAccount(entry.account_id)}
                      className="flex max-w-full items-baseline gap-1.5 text-left underline decoration-dotted underline-offset-2 hover:text-peach"
                    >
                      <ArrowRightIcon className="size-3 shrink-0" aria-hidden />
                      <Mono className="truncate text-[0.72rem]">
                        {known?.purpose ?? entry.account_id}
                      </Mono>
                    </button>
                  )}
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
                <td className="py-1.5 text-right">
                  <Mono className="text-dim">{entry.account_seq}</Mono>
                </td>
              </tr>
            );
          })}
        </tbody>
        <tfoot>
          <tr>
            <td colSpan={2} className="py-2 text-[0.68rem] text-dim">
              debits · credits
            </td>
            <td colSpan={2} className="py-2 text-right">
              <Amount minor={debits.total} /> ·{" "}
              <Amount minor={credits.total} className="text-credit" />
              <span
                className={cn(
                  "ml-2 text-[0.68rem]",
                  debits.total === credits.total ? "text-ok" : "text-credit"
                )}
              >
                {debits.total === credits.total ? "equal" : "not equal"}
              </span>
            </td>
          </tr>
        </tfoot>
      </table>
      <p className="mt-1 text-[0.66rem] text-dim">
        Summed with <code>BigInt</code>: every <code>amount_minor</code> arrives
        as an exact-integer string and none of them goes through{" "}
        <code>Number</code>.
      </p>
    </div>
  );
}
