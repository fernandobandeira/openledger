/**
 * Money, handled the way ADR-0022 requires.
 *
 * EVERY amount on the wire is an exact-integer decimal STRING, in both
 * directions and at every size: a report aggregate, a posting on the way in,
 * an entry on the way out. A `bigint` column reaches far past 2^53 and JSON
 * has no integer type, so a number would be rounded by the parser — a posting
 * of 9007199254740993 came back as ...992 before the contract was fixed. So no
 * value in this file is ever passed through `Number` or `parseInt`: formatting
 * is string surgery, and arithmetic is `BigInt`.
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

/** The range `ledger_entries.amount_minor` holds. */
const I64_MIN = -9223372036854775808n;
const I64_MAX = 9223372036854775807n;

/**
 * The one value this dashboard parses on the way OUT: a posting amount, typed
 * into a form and sent as the exact-integer string `POST /v1/transactions`
 * takes.
 *
 * The grammar is the API's own — `-?[0-9]+`, and nothing else — and the three
 * refusals carry the API's own meanings in the API's own words, so the same
 * input is refused the same way whichever side sees it first. `"2,500"` and
 * `"25.00"` never leave this page: a round trip to be told what the form
 * already knows teaches an operator nothing.
 *
 * Whitespace is refused rather than trimmed, exactly as the API refuses it: a
 * request is answered or named, never quietly rewritten into a different one.
 * Sign is judged last and separately, because "too large" and "not positive"
 * are different things to fix — which is also where the API draws the line,
 * between its parse and the domain's rule.
 */
export function minorUnitsToPost(
  text: string
): { minor: string } | { error: string } {
  if (!/^-?[0-9]+$/.test(text)) {
    return {
      error:
        `amount_minor ${JSON.stringify(text)} is not an exact integer: send ` +
        "minor units as a decimal string of digits, optionally signed, with " +
        "no leading plus, no whitespace, no decimal point and no exponent",
    };
  }
  const exact = BigInt(text);
  if (exact < I64_MIN || exact > I64_MAX) {
    return {
      error:
        `amount_minor ${JSON.stringify(text)} is outside the range of 64-bit ` +
        "minor units, which is what ledger_entries.amount_minor holds",
    };
  }
  if (exact <= 0n) return { error: "amount_minor must be positive" };
  return { minor: text };
}
