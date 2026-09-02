"use client";

import { GuideLink } from "@/components/guide-link";
import { StepTile } from "@/components/scenario/step-tile";
import { WalkLog } from "@/components/scenario/walk-log";
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
 * page is pointed at, through the same routes the composer's drawers use.
 *
 * Under the tiles is the record of the walk — every run kept, newest first —
 * because a walk is a sequence of writes and the last one is not the story.
 */
export function ScenarioStrip({
  scenario,
  onOpenTransaction,
}: {
  scenario: Scenario;
  onOpenTransaction: (transactionId: string) => void;
}) {
  return (
    <section aria-label="The card lifecycle" className="flex flex-col gap-3">
      <header className="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
        <h2 className="text-[0.8rem] tracking-[0.14em] text-peach uppercase">
          A card, end to end
        </h2>
        <p className="flex items-baseline gap-3 text-[0.72rem] text-dim">
          One 500.00 purchase, in order.
          <GuideLink>booking a payment</GuideLink>
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

      <WalkLog scenario={scenario} onOpenTransaction={onOpenTransaction} />
    </section>
  );
}
