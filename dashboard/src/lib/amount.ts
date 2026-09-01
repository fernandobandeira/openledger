/**
 * Money, handled the way ADR-0019 requires.
 *
 * A REPORT amount arrives as an exact-integer decimal STRING, because an
 * aggregate can exceed 2^53 and a JSON number above that is silently rounded
 * by the parser. So no value on this file is ever passed through `Number` or
 * `parseInt`: formatting is string surgery, and arithmetic is `BigInt`.
 *
 * A single POSTING or ENTRY amount is a JSON number, bounded by its own
 * `bigint` column. That asymmetry is deliberate, and it has one sharp edge
 * this file cannot file down — see `minorFromEntry`.
 *
 * The wire carries no currency exponent. Two decimals is this dashboard's
 * assumption about the minor unit, stated in the footer and never hidden: the
 * exact minor-unit string travels beside every rendered figure so an operator
 * can check it.
 */

const INTEGER = /^[+-]?\d+$/;

export function isMinorString(value: string): boolean {
  return INTEGER.test(value.trim());
}

/** Thousands separators, inserted by walking the string from the right. */
function groupDigits(digits: string): string {
  let grouped = "";
  for (let i = digits.length; i > 0; i -= 3) {
    const chunk = digits.slice(Math.max(0, i - 3), i);
    grouped = grouped === "" ? chunk : `${chunk},${grouped}`;
  }
  return grouped === "" ? "0" : grouped;
}

/**
 * `"123456"` → `"1,234.56"`, at any magnitude, without arithmetic.
 *
 * A value that is not an integer string is returned untouched rather than
 * guessed at: the caller renders whatever the API actually said.
 */
export function formatMinor(minor: string): string {
  const trimmed = minor.trim();
  if (!INTEGER.test(trimmed)) return minor;

  const negative = trimmed.startsWith("-");
  const digits = trimmed.replace(/^[+-]/, "").replace(/^0+(?=\d)/, "");
  const padded = digits.padStart(3, "0");
  const whole = padded.slice(0, padded.length - 2);
  const fraction = padded.slice(padded.length - 2);
  const rendered = `${groupDigits(whole)}.${fraction}`;
  return negative && /[1-9]/.test(digits) ? `-${rendered}` : rendered;
}

/** `BigInt` or nothing: a total that cannot be parsed exactly is not summed. */
export function toMinorBigInt(minor: string): bigint | null {
  const trimmed = minor.trim();
  if (!INTEGER.test(trimmed)) return null;
  return BigInt(trimmed);
}

/**
 * Subtotals. `exact` is false when any input was not an integer string, which
 * lets a caller show the sum it could compute and say what it left out rather
 * than print a confidently wrong total.
 */
export function sumMinor(values: readonly string[]): {
  total: string;
  exact: boolean;
} {
  let total = 0n;
  let exact = true;
  for (const value of values) {
    const parsed = toMinorBigInt(value);
    if (parsed === null) {
      exact = false;
      continue;
    }
    total += parsed;
  }
  return { total: total.toString(), exact };
}

export function negateMinor(minor: string): string {
  const parsed = toMinorBigInt(minor);
  return parsed === null ? minor : (-parsed).toString();
}

export function isZeroMinor(minor: string): boolean {
  const parsed = toMinorBigInt(minor);
  return parsed !== null && parsed === 0n;
}

export function isNegativeMinor(minor: string): boolean {
  const parsed = toMinorBigInt(minor);
  return parsed !== null && parsed < 0n;
}

/**
 * An entry's `amount_minor` is a JSON number over a `bigint` column, so a leg
 * above 2^53 was already rounded by `JSON.parse` before this function ever saw
 * it. Nothing downstream can undo that, so the one honest thing is to say so:
 * `exact` is false exactly when the number is outside the safe-integer range.
 */
export function minorFromEntry(amount: number): {
  minor: string;
  exact: boolean;
} {
  if (!Number.isInteger(amount)) {
    return { minor: String(amount), exact: false };
  }
  return {
    minor: BigInt(amount).toString(),
    exact: Number.isSafeInteger(amount),
  };
}
