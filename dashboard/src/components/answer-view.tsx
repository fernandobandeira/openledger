import type { ReactNode } from "react";

import { Mono } from "@/components/mono";
import type { Answer } from "@/lib/ledger";

/**
 * A refusal is rendered VERBATIM: the status code, the API's own stable `type`
 * and its `detail`, unedited. That grammar is designed — subject first,
 * condition second (ADR-0014) — and paraphrasing it would hide the contract
 * the caller is supposed to program against.
 *
 * The three non-refusal failures are labelled as the dashboard's own, because
 * nothing that did not come off the wire may be dressed up as though it did.
 */
export function Trouble({ answer }: { answer: Answer<unknown> | null }) {
  if (answer === null || answer.outcome === "answered") return null;

  if (answer.outcome === "refused") {
    return (
      <div className="mt-3 border-l-2 border-credit bg-credit-bg/55 px-3 py-2">
        <p className="flex flex-wrap items-baseline gap-2">
          <Mono className="text-[0.8rem] text-credit">{answer.status}</Mono>
          <Mono className="text-[0.8rem] text-credit">{answer.error.type}</Mono>
        </p>
        <Mono className="mt-1 block text-[0.75rem] leading-relaxed break-words text-ink">
          {answer.error.detail}
        </Mono>
        <p className="mt-2 text-[0.68rem] text-dim">
          Parse <code>type</code>; never <code>detail</code>.
        </p>
      </div>
    );
  }

  if (answer.outcome === "unreadable") {
    return (
      <div className="mt-3 border-l-2 border-credit bg-credit-bg/55 px-3 py-2">
        <p className="flex flex-wrap items-baseline gap-2">
          <Mono className="text-[0.8rem] text-credit">{answer.status}</Mono>
          <span className="text-[0.75rem] text-credit">
            the body is not an error the API declares
          </span>
        </p>
        <Mono className="mt-1 block max-h-32 overflow-auto text-[0.72rem] break-words whitespace-pre-wrap text-dim">
          {answer.text.slice(0, 800)}
        </Mono>
      </div>
    );
  }

  return (
    <div className="mt-3 border-l-2 border-credit bg-credit-bg/55 px-3 py-2">
      <p className="text-[0.78rem] text-credit">
        No answer — the request never reached the ledger.
      </p>
      <Mono className="mt-1 block text-[0.72rem] break-words text-dim">
        {answer.detail}
      </Mono>
      <p className="mt-2 text-[0.68rem] text-dim">
        Is <code>openledger serve</code> running on{" "}
        <code>OPENLEDGER_API_ORIGIN</code>?
      </p>
    </div>
  );
}

/**
 * The write path's whole contract in one strip: the status pair and the
 * header that tells them apart. `201` claimed the idempotency key and wrote;
 * `200` found the key already claimed with this same body and re-rendered the
 * stored result, writing nothing (ADR-0013 §2).
 */
export function WriteOutcome({
  status,
  replayed,
  wrote,
  children,
}: {
  status: number;
  replayed: boolean | null;
  /** What a 201 wrote, in the panel's own noun: "the account", "the transaction". */
  wrote: string;
  children?: ReactNode;
}) {
  const isReplay = replayed === true;
  return (
    <div
      className={`mt-3 border-l-2 px-3 py-2 ${
        isReplay ? "border-line bg-surface" : "border-ok bg-ok-bg/55"
      }`}
    >
      <p className="flex flex-wrap items-baseline gap-x-3 gap-y-1">
        <Mono className={`text-[0.8rem] ${isReplay ? "text-ink" : "text-ok"}`}>
          {status}
        </Mono>
        <Mono className="text-[0.75rem] text-dim">
          Idempotency-Replayed:{" "}
          {replayed === null ? "absent" : String(replayed)}
        </Mono>
      </p>
      <p className="mt-1 text-[0.78rem]">
        {isReplay
          ? `Replayed — nothing written, ${wrote} is the stored result.`
          : `Written — this call claimed the key and wrote ${wrote}.`}
      </p>
      {children}
    </div>
  );
}
