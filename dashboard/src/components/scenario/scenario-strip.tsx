"use client";

import { StepReport } from "@/components/scenario/step-report";
import { StepTile } from "@/components/scenario/step-tile";
import type { Scenario } from "@/components/scenario/use-scenario";

/**
 * The guided walk: one card purchase from authorization to a facility repaid,
 * plus the two ways it goes wrong.
 *
 * The strip is rendered from a LIST of step definitions, not written out step
 * by step. A step is a label, a line on what it demonstrates, the steps it
 * needs first and a function that makes the calls — so a new step is a record
 * appended to `src/lib/scenario/steps.ts` and nothing here changes to receive
 * it.
 *
 * It is an on-ramp, not a demo mode: every step writes to the live book this
 * page is pointed at, through the same routes the composer below uses.
 */
export function ScenarioStrip({
  scenario,
  onOpenTransaction,
}: {
  scenario: Scenario;
  onOpenTransaction: (transactionId: string) => void;
}) {
  const showing =
    scenario.showing === null
      ? null
      : (scenario.steps.find((step) => step.id === scenario.showing) ?? null);
  const showingResult =
    showing === null ? null : scenario.stateOf(showing.id).result;

  return (
    <section aria-label="The card lifecycle" className="flex flex-col gap-3">
      <header className="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
        <h2 className="text-[0.8rem] tracking-[0.14em] text-peach uppercase">
          A card, end to end
        </h2>
        <p className="max-w-prose text-[0.72rem] text-dim">
          One 500.00 purchase, in the order it happens. Each step writes to the
          book named above through the same routes the composer uses — click
          one and read what it wrote.
        </p>
      </header>

      <ol className="grid gap-2 sm:grid-cols-2 xl:grid-cols-3 2xl:grid-cols-4">
        {scenario.steps.map((step, index) => (
          <li key={step.id} className="flex min-w-0">
            <StepTile
              ordinal={index + 1}
              step={step}
              state={scenario.stateOf(step.id)}
              blocked={scenario.blockedBecause(step)}
              running={scenario.running === step.id}
              showing={scenario.showing === step.id}
              onRun={() => void scenario.run(step)}
            />
          </li>
        ))}
      </ol>

      {showing !== null && showingResult !== null ? (
        <StepReport
          step={showing}
          result={showingResult}
          onOpenTransaction={onOpenTransaction}
        />
      ) : null}
    </section>
  );
}
