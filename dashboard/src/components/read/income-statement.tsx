"use client";

import { useState } from "react";

import { Trouble } from "@/components/answer-view";
import { InstantField, TextField } from "@/components/field";
import { Mono } from "@/components/mono";
import { Panel } from "@/components/panel";
import {
  CursorField,
  PinnedCursor,
  RunRow,
} from "@/components/report-frame";
import { StatementFace } from "@/components/read/statement-face";
import { runIncomeStatement, type Answer, type StatementRead } from "@/lib/ledger";
import { startOfThisYear, toInstant, tomorrow } from "@/lib/time";

/**
 * The half-open window `[effective_from, effective_to)`, and the one report
 * whose amounts are not fully reproducible: a period close recorded after this
 * answer removes its transactions from a re-run at the same cursor, because
 * `ledger_period_closes` carries no commit position of its own.
 */
export function IncomeStatement({
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
  const [chartVersion, setChartVersion] = useState("");
  const [busy, setBusy] = useState(false);
  const [answer, setAnswer] = useState<Answer<StatementRead> | null>(null);
  const [refusedHere, setRefusedHere] = useState<string | null>(null);

  async function run(atCursor: string) {
    const fromInstant = toInstant(from);
    const toInstantValue = toInstant(to);
    if (fromInstant === null || toInstantValue === null) {
      setRefusedHere("Both bounds of the effective window are needed.");
      return;
    }
    setRefusedHere(null);
    setBusy(true);
    const result = await runIncomeStatement({
      tenant_id: tenant,
      effective_from: fromInstant,
      effective_to: toInstantValue,
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
        "the income statement"
      );
    }
    setBusy(false);
  }

  const report = answer?.outcome === "answered" ? answer.body : null;

  return (
    <Panel title="Income statement" route="GET /v1/reports/income-statement">
      <div className="grid gap-3 sm:grid-cols-2">
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
          hint="Exclusive — half-open."
        />
        <CursorField value={cursor} onChange={setCursor} />
        <TextField
          label="chart_version"
          value={chartVersion}
          onChange={setChartVersion}
          inputMode="numeric"
          placeholder="empty — the server names one"
        />
      </div>

      <div className="mt-3">
        <RunRow
          busy={busy}
          runLabel="Run the income statement"
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
            chart version <Mono className="text-ink">{report.chart_version}</Mono>
          </p>
          <StatementFace lines={report.lines} check="income-statement" />
        </>
      ) : null}

    </Panel>
  );
}
