import { formatMinor } from "@/lib/amount";
import { cn } from "@/lib/utils";

/**
 * A figure, at two decimals, with the exact minor-unit string on the element
 * itself. The wire carries no currency exponent — two decimals is this
 * dashboard's assumption, said out loud in the footer — so the unrounded
 * integer has to stay reachable, and `title` is where it lives.
 *
 * `exact={false}` marks a figure that was already imprecise when it arrived:
 * an entry amount is a JSON number over a `bigint` column, so a leg above 2^53
 * is rounded by `JSON.parse` before any code here runs.
 */
export function Amount({
  minor,
  currency,
  exact = true,
  className,
}: {
  minor: string;
  currency?: string;
  exact?: boolean;
  className?: string;
}) {
  const unit = currency ? `${currency} minor units` : "minor units";
  const title = exact
    ? `${minor} ${unit}`
    : `${minor} ${unit} — outside the exact-integer range of a JSON number, so this value was already rounded by the parser`;

  return (
    <span
      className={cn(
        "font-mono tabular-nums",
        !exact && "text-credit underline decoration-dotted underline-offset-2",
        className
      )}
      title={title}
    >
      {formatMinor(minor)}
    </span>
  );
}
