/**
 * Instants. Both report ranges are HALF-OPEN and `as_of` is an `ends_at`
 * rather than a business date (ADR-0019, ADR-0011 §A3): a caller who passes a
 * business date gets the position at the START of that day and silently loses
 * a day at every period boundary. The panels say so where the field is.
 *
 * `<input type="datetime-local">` speaks local wall time with no zone. These
 * two functions are the only conversion, and the panels always show the exact
 * RFC 3339 instant that will be sent.
 */

/** The widest range the reports accept — used by the horizon probe. */
export const EARLIEST = "0001-01-01T00:00:00Z";
export const LATEST = "9999-12-31T23:59:59Z";

/** Local wall time from a `datetime-local` input → an RFC 3339 UTC instant. */
export function toInstant(local: string): string | null {
  if (local.trim() === "") return null;
  const parsed = new Date(local);
  if (Number.isNaN(parsed.getTime())) return null;
  return parsed.toISOString();
}

/** An RFC 3339 instant → the `datetime-local` value that produced it. */
export function toLocalInput(instant: Date): string {
  const pad = (n: number) => String(n).padStart(2, "0");
  return (
    `${instant.getFullYear()}-${pad(instant.getMonth() + 1)}-${pad(instant.getDate())}` +
    `T${pad(instant.getHours())}:${pad(instant.getMinutes())}`
  );
}

export function startOfThisYear(): string {
  return toLocalInput(new Date(new Date().getFullYear(), 0, 1));
}

export function tomorrow(): string {
  const date = new Date();
  date.setDate(date.getDate() + 1);
  date.setHours(0, 0, 0, 0);
  return toLocalInput(date);
}

export function nowLocal(): string {
  return toLocalInput(new Date());
}
