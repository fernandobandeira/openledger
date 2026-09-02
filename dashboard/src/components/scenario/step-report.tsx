"use client";

import { Amount } from "@/components/amount";
import { Trouble } from "@/components/answer-view";
import { Mono } from "@/components/mono";
import { Button } from "@/components/ui/button";
import type {
  ScenarioStep,
  StepObservation,
  StepResult,
  StepWrite,
} from "@/lib/scenario/types";

/**
 * What the step actually did — every call it made, the status each was
 * answered with, and the ids it wrote. Nothing here is narration: each line
 * comes from a response this dashboard received.
 *
 * A step that halted keeps the writes it had already made. Nothing is rolled
 * back, because nothing could be: those transactions are on the book, and a
 * report that hid them would be describing a book that does not exist.
 */
export function StepReport({
  step,
  result,
  ordinal,
  at,
  onOpenTransaction,
}: {
  step: ScenarioStep;
  result: StepResult;
  /** The step's place in the walk, when this is a line of the record. */
  ordinal?: number;
  /** When this dashboard recorded the run, RFC 3339. */
  at?: string;
  onOpenTransaction: (transactionId: string) => void;
}) {
  // Both outcomes carry what was written: a halt does not undo the calls that
  // had already been answered.
  const { writes } = result;

  return (
    <section
      aria-label="What this step did"
      className="border-t border-rule pt-3"
    >
      <div className="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
        <h3 className="flex items-baseline gap-2 text-[0.85rem] font-medium">
          {ordinal === undefined ? null : (
            <Mono className="text-[0.7rem] text-dim">{ordinal}</Mono>
          )}
          {step.label}
          {at === undefined ? null : (
            <Mono className="text-[0.66rem] font-normal text-dim">
              {new Date(at).toLocaleTimeString()}
            </Mono>
          )}
        </h3>
      </div>

      {result.kind === "halted" ? (
        <div className="mt-2">
          <p className="text-[0.75rem] text-credit">
            Stopped at <Mono className="text-[0.72rem]">{result.at}</Mono>.
          </p>
          <Trouble answer={result.answer} />
        </div>
      ) : null}

      {writes.length === 0 ? null : (
        <ul className="mt-3 flex flex-col gap-2">
          {writes.map((write) => (
            <WriteLine
              key={`${write.route}:${write.eventId}`}
              write={write}
              onOpenTransaction={onOpenTransaction}
            />
          ))}
        </ul>
      )}

      {result.kind === "wrote" && result.observations.length > 0 ? (
        <ul className="mt-3 flex flex-col gap-2">
          {result.observations.map((observation) => (
            <ObservationLine
              key={`${observation.what}:${observation.minor}`}
              observation={observation}
            />
          ))}
        </ul>
      ) : null}
    </section>
  );
}

/** One accepted call. `200` with the header means it wrote nothing. */
function WriteLine({
  write,
  onOpenTransaction,
}: {
  write: StepWrite;
  onOpenTransaction: (transactionId: string) => void;
}) {
  const replay = write.replayed === true;

  return (
    <li
      className={`border-l-2 px-3 py-1.5 ${
        replay ? "border-line bg-surface" : "border-ok bg-ok-bg/40"
      }`}
    >
      <p className="flex flex-wrap items-baseline gap-x-3 gap-y-0.5">
        <Mono className={`text-[0.75rem] ${replay ? "text-ink" : "text-ok"}`}>
          {write.status}
        </Mono>
        <Mono className="text-[0.68rem] text-dim">{write.route}</Mono>
        {replay ? (
          <Mono className="text-[0.68rem] text-peach">
            Idempotency-Replayed: true
          </Mono>
        ) : null}
      </p>
      <p className="mt-0.5 text-[0.78rem] leading-snug">{write.wrote}</p>
      {replay ? (
        <p className="mt-0.5 text-[0.68rem] text-dim">
          Nothing written — the stored result, re-rendered.
        </p>
      ) : null}
      {write.transactionId === null ? null : (
        <Button
          size="xs"
          variant="ghost"
          className="mt-1 -ml-2"
          onClick={() => onOpenTransaction(write.transactionId ?? "")}
        >
          Open its legs
        </Button>
      )}
    </li>
  );
}

/** A number read back off the book, so the sentence beside it is checkable. */
function ObservationLine({ observation }: { observation: StepObservation }) {
  return (
    <li className="border border-rule px-3 py-1.5">
      <p className="flex flex-wrap items-baseline justify-between gap-x-3 gap-y-0.5">
        <Mono className="text-[0.7rem] text-dim">{observation.what}</Mono>
        <Amount
          minor={observation.minor}
          currency={observation.currency}
          className="text-[0.95rem]"
        />
      </p>
      <p className="mt-0.5 max-w-prose text-[0.72rem] leading-snug text-dim">
        {observation.reading}
      </p>
      <Mono className="mt-0.5 block text-[0.65rem] text-dim">
        {observation.route}
      </Mono>
    </li>
  );
}
