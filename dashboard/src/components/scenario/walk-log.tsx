"use client";

import { StepReport } from "@/components/scenario/step-report";
import type { Scenario } from "@/components/scenario/use-scenario";

/**
 * The record of the walk: every step that ran, newest first, with the calls
 * it made, the status each was answered with and the one line saying what it
 * wrote.
 *
 * This exists because the strip used to render the report of the last step
 * and nothing else, so ten steps left one paragraph. What a walk through a
 * ledger produces IS a sequence of writes, and a page that shows only the
 * most recent one cannot answer the question the walk is for — what happened
 * to this book, in order.
 *
 * It scrolls rather than growing the page. A log is a thing you scroll; the
 * book underneath is a thing you read.
 */
export function WalkLog({
  scenario,
  onOpenTransaction,
}: {
  scenario: Scenario;
  onOpenTransaction: (transactionId: string) => void;
}) {
  if (scenario.log.length === 0) return null;

  const runs = scenario.log.length;
  const calls = scenario.log.reduce(
    (total, entry) => total + entry.result.writes.length,
    0
  );
  const halted = scenario.log.filter(
    (entry) => entry.result.kind === "halted"
  ).length;

  return (
    <section
      aria-label="The record of this walk"
      className="flex flex-col gap-2 border-t border-rule pt-3"
    >
      <div className="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
        <h3 className="text-[0.72rem] tracking-[0.14em] text-peach uppercase">
          The record of this walk
        </h3>
        <p className="text-[0.7rem] text-dim">
          {runs} step{runs === 1 ? "" : "s"} run · {calls} accepted call
          {calls === 1 ? "" : "s"}
          {halted === 0 ? null : (
            <span className="text-credit">
              {" "}
              · {halted} halted on a refusal
            </span>
          )}{" "}
          · newest first
        </p>
      </div>

      <ol className="flex max-h-[26rem] flex-col gap-1 overflow-y-auto pr-1">
        {scenario.log.map((entry) => {
          const step = scenario.steps.find(
            (candidate) => candidate.id === entry.stepId
          );
          if (step === undefined) return null;
          return (
            <li key={entry.seq} className="flex min-w-0 flex-col">
              <StepReport
                step={step}
                result={entry.result}
                ordinal={entry.ordinal}
                at={entry.at}
                onOpenTransaction={onOpenTransaction}
              />
            </li>
          );
        })}
      </ol>
    </section>
  );
}
