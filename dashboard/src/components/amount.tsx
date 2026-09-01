import { formatMinor } from "@/lib/amount";
import { cn } from "@/lib/utils";

/**
 * A figure, at two decimals, with the exact minor-unit string on the element
 * itself. The wire carries no currency exponent — two decimals is this
 * dashboard's assumption, said out loud in the footer — so the unrounded
 * integer has to stay reachable, and `title` is where it lives.
 *
 * Every amount this renders arrived as an exact-integer decimal string, an
 * entry's as much as a report total's (ADR-0022), so there is no such thing
 * here as a figure that was already imprecise when it landed.
 */
export function Amount({
  minor,
  currency,
  className,
}: {
  minor: string;
  currency?: string;
  className?: string;
}) {
  const unit = currency ? `${currency} minor units` : "minor units";

  return (
    <span
      className={cn("font-mono tabular-nums", className)}
      title={`${minor} ${unit}`}
    >
      {formatMinor(minor)}
    </span>
  );
}
