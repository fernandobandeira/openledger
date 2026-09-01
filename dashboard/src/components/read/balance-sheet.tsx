"use client";

import { useState } from "react";

import { Trouble } from "@/components/answer-view";
import { InstantField, TextField } from "@/components/field";
import { Mono } from "@/components/mono";
import { Panel, PanelNote } from "@/components/panel";
import {
  CursorField,
  PinnedCursor,
  ReproducibilityNote,
  RunRow,
} from "@/components/report-frame";
import { StatementFace } from "@/components/read/statement-face";
import { runBalanceSheet, type Answer, type StatementRead } from "@/lib/api";
import { nowLocal, toInstant } from "@/lib/time";

/**
 * `as_of` is an ENDS_AT, not a business date: the predicate is
 * `effective_at < as_of`. A caller who passes a business date gets the
 * position at the START of that day and silently loses a day at every period
 * boundary — silently being the operative word, because nothing raises and the
 * number is plausible. The field says so.
 */
export function BalanceSheet({
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
  const [asOf, setAsOf] = useState(nowLocal);
  const [cursor, setCursor] = useState("");
  const [chartVersion, setChartVersion] = useState("");
  const [busy, setBusy] = useState(false);
  const [answer, setAnswer] = useState<Answer<StatementRead> | null>(null);
  const [refusedHere, setRefusedHere] = useState<string | null>(null);

  async function run(atCursor: string) {
    const instant = toInstant(asOf);
    if (instant === null) {
      setRefusedHere("as_of is needed, as an instant.");
      return;
    }
    setRefusedHere(null);
    setBusy(true);
    const result = await runBalanceSheet({
      tenant_id: tenant,
      as_of: instant,
      ...(atCursor.trim() === "" ? {} : { cursor: atCursor.trim() }),
      ...(chartVersion.trim() === ""
        ? {}
        : { chart_version: Number(chartVersion.trim()) }),
    });
    setAnswer(result);
    if (result.outcome === "answered") {
      onAnswer(
        result.body.pinned_cursor,
        atCursor.trim() === "",
        "the balance sheet"
      );
    }
    setBusy(false);
  }

  const report = answer?.outcome === "answered" ? answer.body : null;

  return (
    <Panel title="Balance sheet" route="GET /v1/reports/balance-sheet">
      <div className="grid gap-3 sm:grid-cols-3">
        <InstantField
          label="as_of"
          value={asOf}
          onChange={setAsOf}
          hint="An ends_at: entries strictly before this instant. A business date here loses a day."
        />
        <CursorField value={cursor} onChange={setCursor} />
        <TextField
          label="chart_version"
          value={chartVersion}
          onChange={setChartVersion}
          inputMode="numeric"
          placeholder="empty — the server names one"
          hint="Naming a version pins the presentation only below max(version)."
        />
      </div>

      <div className="mt-3">
        <RunRow
          busy={busy}
          runLabel="Run the balance sheet"
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
          <p className="mt-2 text-[0.72rem] text-dim">
            presented at chart version{" "}
            <Mono className="text-ink">{report.chart_version}</Mono> — always
            named, never defaulted
          </p>
          <StatementFace lines={report.lines} check="balance-sheet" />
          <ReproducibilityNote kind="balance-sheet" />
        </>
      ) : null}

      <PanelNote>
        A version that does not present every account type with posted entries
        as at this instant is refused as{" "}
        <code>chart_version_incomplete</code> rather than silently dropping a
        sub-book from a face that would still balance.
      </PanelNote>
    </Panel>
  );
}
