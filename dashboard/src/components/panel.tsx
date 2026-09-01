import type { ReactNode } from "react";

import { cn } from "@/lib/utils";

/**
 * One operation, one panel. Flat and hairline-ruled: a rule where a boundary
 * is, no fill, no shadow. The boldness in this design is the rail.
 */
export function Panel({
  title,
  route,
  children,
  className,
}: {
  title: string;
  /** The route this panel is, rendered as the subtitle it deserves to be. */
  route: string;
  children: ReactNode;
  className?: string;
}) {
  return (
    <section
      className={cn(
        "min-w-0 border-t border-rule pt-4 first:border-t-0 first:pt-0",
        className
      )}
    >
      <header className="mb-3 flex flex-wrap items-baseline justify-between gap-x-3 gap-y-1">
        <h2 className="text-[0.95rem] font-medium tracking-tight">{title}</h2>
        <code className="text-[0.7rem] text-dim">{route}</code>
      </header>
      {children}
    </section>
  );
}

/** A sentence about what the answer means, not about what the button does. */
export function PanelNote({ children }: { children: ReactNode }) {
  return (
    <p className="mt-2 max-w-prose text-[0.78rem] leading-relaxed text-dim">
      {children}
    </p>
  );
}

/** A statement about a bitemporal ledger, not a shrug. */
export function Empty({ children }: { children: ReactNode }) {
  return (
    <p className="border border-dashed border-rule px-3 py-4 text-[0.8rem] text-dim">
      {children}
    </p>
  );
}
