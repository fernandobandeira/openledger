"use client";

import { useState } from "react";
import { CheckIcon, CopyIcon } from "lucide-react";

import { cn } from "@/lib/utils";

/**
 * Mono with tabular figures — the default for every identifier, cursor,
 * instant and amount in this dashboard. Sans is for headings and prose.
 */
export function Mono({
  children,
  className,
  title,
}: {
  children: React.ReactNode;
  className?: string;
  title?: string;
}) {
  return (
    <span className={cn("font-mono tabular-nums", className)} title={title}>
      {children}
    </span>
  );
}

/**
 * A UUID. Shown whole where there is room and truncated where there is not —
 * never abbreviated into something that cannot be copied, which is why the
 * copy button is part of the identifier rather than an afterthought.
 */
export function Identifier({
  value,
  className,
  truncate = false,
}: {
  value: string;
  className?: string;
  truncate?: boolean;
}) {
  return (
    <span className={cn("inline-flex max-w-full items-center gap-1", className)}>
      <Mono
        // `min-w-0` is what makes `truncate` actually truncate here: a flex
        // item's default `min-width: auto` refuses to shrink below its
        // content, so without it the identifier pushes its row wider instead
        // of ellipsing — which is how a UUID ends up shoving an amount off
        // the right edge of a statement.
        className={cn("text-[0.72rem]", truncate && "min-w-0 truncate")}
        title={value}
      >
        {value}
      </Mono>
      <CopyButton value={value} />
    </span>
  );
}

export function CopyButton({ value }: { value: string }) {
  const [copied, setCopied] = useState(false);

  return (
    <button
      type="button"
      aria-label={`Copy ${value}`}
      className="shrink-0 text-dim transition-colors hover:text-peach"
      onClick={() => {
        void navigator.clipboard
          .writeText(value)
          .then(() => {
            setCopied(true);
            window.setTimeout(() => setCopied(false), 1200);
          })
          .catch(() => setCopied(false));
      }}
    >
      {copied ? (
        <CheckIcon className="size-3 text-ok" aria-hidden />
      ) : (
        <CopyIcon className="size-3" aria-hidden />
      )}
    </button>
  );
}
