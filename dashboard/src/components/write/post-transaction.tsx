"use client";

import { useState } from "react";
import { ArrowRightIcon, PlusIcon, RefreshCwIcon, XIcon } from "lucide-react";

import { Trouble, WriteOutcome } from "@/components/answer-view";
import { Choice, InstantField, TextField } from "@/components/field";
import { Identifier, Mono } from "@/components/mono";
import { GuideLink } from "@/components/guide-link";
import { Panel } from "@/components/panel";
import { Button } from "@/components/ui/button";
import {
  postTransaction,
  replayedHeader,
  type Answer,
  type PostingBody,
  type Status,
  type TransactionBody,
  type TransactionCreated,
} from "@/lib/ledger";
import { minorUnitsToPost } from "@/lib/amount";
import { toInstant } from "@/lib/time";

export interface Leg {
  source: string;
  destination: string;
  amount: string;
  currency: string;
}

export function emptyLeg(): Leg {
  return { source: "", destination: "", amount: "", currency: "USD" };
}

const STATUSES: { value: Status; label: string }[] = [
  { value: "posted", label: "posted" },
  { value: "pending", label: "pending" },
];

function freshKey(): string {
  return `post-${crypto.randomUUID()}`;
}

export function PostTransaction({
  tenant,
  legs,
  setLegs,
  activeLeg,
  setActiveLeg,
  onPosted,
}: {
  tenant: string;
  legs: Leg[];
  setLegs: (legs: Leg[]) => void;
  activeLeg: number;
  setActiveLeg: (index: number) => void;
  onPosted: (transactionId: string | null) => void;
}) {
  const [idempotencyKey, setIdempotencyKey] = useState("");
  const [status, setStatus] = useState<Status>("posted");
  const [effectiveAt, setEffectiveAt] = useState("");
  const [resolvesId, setResolvesId] = useState("");
  const [reversesId, setReversesId] = useState("");

  const [busy, setBusy] = useState(false);
  const [answer, setAnswer] = useState<Answer<TransactionCreated> | null>(null);
  const [replayed, setReplayed] = useState<boolean | null>(null);
  const [refusedHere, setRefusedHere] = useState<string | null>(null);

  const isReversal = reversesId.trim() !== "";

  function editLeg(index: number, patch: Partial<Leg>) {
    setLegs(legs.map((leg, i) => (i === index ? { ...leg, ...patch } : leg)));
  }

  async function submit() {
    const key = idempotencyKey.trim() === "" ? freshKey() : idempotencyKey.trim();
    setIdempotencyKey(key);
    setRefusedHere(null);

    const instant = effectiveAt.trim() === "" ? null : toInstant(effectiveAt);
    if (effectiveAt.trim() !== "" && instant === null) {
      setRefusedHere("effective_at is not a readable instant.");
      return;
    }

    let postings: PostingBody[] | undefined;
    if (!isReversal) {
      const built: PostingBody[] = [];
      for (const [index, leg] of legs.entries()) {
        const amount = minorUnitsToPost(leg.amount);
        if ("error" in amount) {
          setRefusedHere(`Leg ${index + 1}: ${amount.error}`);
          return;
        }
        if (leg.source.trim() === "" || leg.destination.trim() === "") {
          setRefusedHere(
            `Leg ${index + 1}: both a source and a destination account are needed. Pick an account in the sidenav and send it here with “Use as leg ${activeLeg + 1} source” on its header, behind this drawer.`
          );
          return;
        }
        built.push({
          source: leg.source.trim(),
          destination: leg.destination.trim(),
          amount_minor: amount.minor,
          currency: leg.currency.trim(),
        });
      }
      postings = built;
    }

    const body: TransactionBody = {
      tenant_id: tenant,
      idempotency_key: key,
      ...(status === "pending" ? { status } : {}),
      ...(instant === null ? {} : { effective_at: instant }),
      ...(resolvesId.trim() === "" ? {} : { resolves_id: resolvesId.trim() }),
      ...(isReversal ? { reverses_id: reversesId.trim() } : { postings }),
    };

    setBusy(true);
    const result = await postTransaction(body);
    setAnswer(result);
    setReplayed(
      result.outcome === "answered" ? replayedHeader(result.headers) : null
    );
    if (result.outcome === "answered") {
      onPosted(result.body.transaction_id);
    }
    setBusy(false);
  }

  return (
    <Panel title="Post a transaction" route="POST /v1/transactions">
      <div className="grid gap-3 sm:grid-cols-2">
        <Choice
          label="status"
          value={status}
          options={STATUSES}
          onChange={setStatus}
          hint="Omitted means posted. It never mutates."
        />
        <InstantField
          label="effective_at"
          value={effectiveAt}
          onChange={setEffectiveAt}
          hint={
            isReversal ? "Optional — the target's own date." : "Required."
          }
        />
        <TextField
          label="resolves_id"
          value={resolvesId}
          onChange={setResolvesId}
          placeholder="empty"
          hint="The pending transaction this resolves."
        />
        <TextField
          label="reverses_id"
          value={reversesId}
          onChange={setReversesId}
          placeholder="empty"
          hint="The transaction this reverses. Send no postings."
        />
      </div>

      <div className="mt-4">
        <div className="mb-2 flex items-baseline justify-between gap-2">
          <h3 className="text-[0.78rem] text-dim">
            postings{" "}
            {isReversal ? (
              <span className="text-credit">
                — not sent, this is a reversal
              </span>
            ) : (
              <span>
                — the selected account behind this drawer fills leg{" "}
                <Mono className="text-peach">{activeLeg + 1}</Mono>
              </span>
            )}
          </h3>
          {!isReversal ? (
            <Button
              size="xs"
              variant="ghost"
              onClick={() => {
                setLegs([...legs, emptyLeg()]);
                setActiveLeg(legs.length);
              }}
            >
              <PlusIcon aria-hidden /> Add a leg
            </Button>
          ) : null}
        </div>

        {isReversal ? (
          <p className="border border-dashed border-rule px-3 py-3 text-[0.75rem] text-dim">
            Posted: mirrored, directions flipped. Pending: a void, no entries.
          </p>
        ) : (
          <ul className="flex flex-col gap-3">
            {legs.map((leg, index) => (
              <li
                key={index}
                className={`border-l-2 pl-3 ${
                  index === activeLeg ? "border-peach" : "border-rule"
                }`}
              >
                <div className="mb-1 flex items-center justify-between gap-2">
                  <button
                    type="button"
                    className="text-[0.7rem] text-dim hover:text-peach"
                    onClick={() => setActiveLeg(index)}
                  >
                    leg {index + 1}
                    {index === activeLeg ? " · filling" : ""}
                  </button>
                  {legs.length > 1 ? (
                    <Button
                      size="icon-xs"
                      variant="ghost"
                      aria-label={`Remove leg ${index + 1}`}
                      onClick={() => {
                        setLegs(legs.filter((_, i) => i !== index));
                        setActiveLeg(Math.max(0, Math.min(activeLeg, legs.length - 2)));
                      }}
                    >
                      <XIcon aria-hidden />
                    </Button>
                  ) : null}
                </div>
                <div className="grid gap-2 sm:grid-cols-2">
                  <TextField
                    label="source"
                    value={leg.source}
                    onChange={(value) => editLeg(index, { source: value })}
                    onFocus={() => setActiveLeg(index)}
                    placeholder="account the amount leaves"
                  />
                  <TextField
                    label="destination"
                    value={leg.destination}
                    onChange={(value) => editLeg(index, { destination: value })}
                    onFocus={() => setActiveLeg(index)}
                    placeholder="account the amount arrives at"
                  />
                  <TextField
                    label="amount_minor"
                    value={leg.amount}
                    onChange={(value) => editLeg(index, { amount: value })}
                    onFocus={() => setActiveLeg(index)}
                    inputMode="numeric"
                    placeholder="2500"
                  />
                  <TextField
                    label="currency"
                    value={leg.currency}
                    onChange={(value) => editLeg(index, { currency: value })}
                    onFocus={() => setActiveLeg(index)}
                  />
                </div>
              </li>
            ))}
          </ul>
        )}
      </div>

      <div className="mt-3 flex flex-wrap items-end gap-2">
        <TextField
          className="min-w-[18rem] flex-1"
          label="idempotency_key"
          value={idempotencyKey}
          onChange={setIdempotencyKey}
          placeholder="minted when you send"
          hint="Same key, same body: 200. Different body: 422."
        />
        <Button
          variant="outline"
          size="sm"
          onClick={() => setIdempotencyKey(freshKey())}
        >
          <RefreshCwIcon aria-hidden /> New key
        </Button>
        <Button size="sm" onClick={() => void submit()} disabled={busy}>
          <ArrowRightIcon aria-hidden />
          {busy ? "Posting…" : "Post transaction"}
        </Button>
      </div>

      {refusedHere ? (
        <div className="mt-3 border-l-2 border-credit bg-credit-bg/55 px-3 py-2">
          <p className="text-[0.75rem] text-credit">
            The dashboard refused this before sending it — not the API.
          </p>
          <Mono className="mt-1 block text-[0.72rem] text-ink">{refusedHere}</Mono>
        </div>
      ) : null}

      <Trouble answer={answer} />

      {answer?.outcome === "answered" ? (
        <WriteOutcome
          status={answer.status}
          replayed={replayed}
          wrote="the transaction and its entries"
        >
          <dl className="mt-2 grid gap-x-4 gap-y-1 text-[0.75rem] sm:grid-cols-[8rem_1fr]">
            <dt className="text-dim">transaction_id</dt>
            <dd>
              {answer.body.transaction_id === null ? (
                <span className="text-dim">null</span>
              ) : (
                <Identifier value={answer.body.transaction_id} />
              )}
            </dd>
            <dt className="text-dim">event_id</dt>
            <dd>
              <Identifier value={answer.body.event_id} />
            </dd>
          </dl>
        </WriteOutcome>
      ) : null}

      <p className="mt-3 text-[0.7rem] text-dim">
        <GuideLink>postings, and why amounts travel as strings</GuideLink>
      </p>
    </Panel>
  );
}
