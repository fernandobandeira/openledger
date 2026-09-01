/**
 * The card lifecycle, as a list.
 *
 * One 500.00 purchase from authorization to a facility repaid, plus the two
 * things that go wrong and the one call that writes nothing. Every amount is
 * the one in the lifecycle document; every idempotency key is that document's
 * own event name.
 *
 * Two places the ledger made the trace argue back, and the copy says so rather
 * than papering over it:
 *
 *  * **A hold has exactly one fate.** A pending transaction is superseded once
 *    — resolved or reversed — and the second attempt is refused. So the first
 *    capture posts on its own and the LAST one resolves the hold. The document
 *    has both captures resolving it, and that is not a thing this ledger will
 *    do.
 *  * **The customer's repayment is not on this walk**, so operating cash goes
 *    below zero when the facility is repaid. The ledger has no opinion about
 *    that, and the step says as much instead of hiding it.
 */
import type { ScenarioStep } from "./types";

/** Minor units. Written out so a reader can check them against the trace. */
const OPENING_EQUITY = "6600";
const AUTHORIZED = "50000";
const FIRST_CAPTURE_TO_NETWORK = "29460";
const FIRST_CAPTURE_INTERCHANGE = "540";
const FIRST_CAPTURE_REV_SHARE = "162";
const SECOND_CAPTURE_TO_NETWORK = "19640";
const SECOND_CAPTURE_INTERCHANGE = "360";
const SECOND_CAPTURE_REV_SHARE = "108";
const FACILITY_DRAW = "42500";
const NETWORK_WIRE = "49100";
const ACCRUED_INTEREST = "354";
const REV_SHARE_OWED = "270";

/**
 * The transaction ids one step leaves for another, by name. `recall` answers
 * `null` before the step that writes them has run, which is exactly what
 * `requires` keeps from happening.
 */
const HOLD = "the 500.00 hold";
const FAT_FINGERED_DRAW = "the duplicate draw";

export const CARD_LIFECYCLE: readonly ScenarioStep[] = [
  {
    id: "authorized",
    label: "Card authorized · 500.00",
    teaches:
      "A hold is recorded and no balance moves: the legs are in the journal, and the balance cache holds posted only.",
    requires: [],
    async run(context) {
      await context.openTheChart();
      await context.post({
        key: "open:capital",
        wrote: "66.00 of paid-in capital into operating cash — the gap an 85% advance rate leaves on every purchase",
        effectiveAt: context.at(0, 9),
        postings: [
          { from: "paid_in_capital", to: "operating_cash", minor: OPENING_EQUITY },
        ],
      });
      const hold = await context.post({
        key: "evt_auth:hold",
        wrote: "a pending 500.00 against the cardholder — the purchase is authorized, not owed",
        effectiveAt: context.at(0, 10),
        status: "pending",
        postings: [
          {
            from: "network_settlement_payable",
            to: "customer_receivable",
            minor: AUTHORIZED,
          },
        ],
      });
      context.remember(HOLD, hold);
      await context.observe(
        "customer_receivable",
        "customer_receivable, posted balance",
        "Zero, with a 500.00 leg already in the entries below. Nothing is owed until it clears, and it may never clear."
      );
    },
  },
  {
    id: "cleared_300",
    label: "Cleared · 300.00",
    teaches:
      "The merchant shipped half the order. You never owed the network 300 — the settlement obligation arrives already net of the interchange you keep.",
    requires: ["authorized"],
    async run(context) {
      await context.post({
        key: "evt_clear_1:posting",
        wrote: "300.00 owed by the cardholder: 294.60 to the network, 5.40 kept as interchange",
        effectiveAt: context.at(1, 10),
        postings: [
          {
            from: "network_settlement_payable",
            to: "customer_receivable",
            minor: FIRST_CAPTURE_TO_NETWORK,
          },
          {
            from: "interchange_revenue",
            to: "customer_receivable",
            minor: FIRST_CAPTURE_INTERCHANGE,
          },
        ],
      });
      await context.observe(
        "customer_receivable",
        "customer_receivable, posted balance",
        "300.00 — the part that cleared, and only that part. The hold still stands for the rest."
      );
    },
  },
  {
    id: "revenue_share",
    label: "Revenue share · 1.62",
    teaches:
      "One event, two obligations. The platform's cut goes out under a second idempotency key because it has its own life — you settle the network daily and the platform monthly.",
    requires: ["cleared_300"],
    async run(context) {
      await context.post({
        key: "evt_clear_1:revshare",
        wrote: "1.62 of the 5.40 interchange promised to the platform partner",
        effectiveAt: context.at(1, 10),
        postings: [
          {
            from: "platform_rev_share_payable",
            to: "platform_rev_share_expense",
            minor: FIRST_CAPTURE_REV_SHARE,
          },
        ],
      });
    },
  },
  {
    id: "cleared_200",
    label: "Cleared · 200.00",
    teaches:
      "The rest of the order ships and the hold is consumed. A pending transaction becomes posted through a NEW transaction naming it — and it gets exactly one such fate, which is why the first capture could not claim it.",
    requires: ["authorized", "cleared_300"],
    async run(context) {
      const hold = context.recall(HOLD);
      await context.post({
        key: "evt_clear_2:posting",
        wrote: "200.00 more: 196.40 to the network, 3.60 kept — and the hold resolved",
        effectiveAt: context.at(2, 10),
        resolves: hold ?? undefined,
        postings: [
          {
            from: "network_settlement_payable",
            to: "customer_receivable",
            minor: SECOND_CAPTURE_TO_NETWORK,
          },
          {
            from: "interchange_revenue",
            to: "customer_receivable",
            minor: SECOND_CAPTURE_INTERCHANGE,
          },
        ],
      });
      await context.post({
        key: "evt_clear_2:revshare",
        wrote: "1.08 more to the platform partner, under its own key again",
        effectiveAt: context.at(2, 10),
        postings: [
          {
            from: "platform_rev_share_payable",
            to: "platform_rev_share_expense",
            minor: SECOND_CAPTURE_REV_SHARE,
          },
        ],
      });
      await context.observe(
        "network_settlement_payable",
        "network_settlement_payable, posted balance",
        "Debit-positive, so a payable reads negative: 491.00 is owed to the network — 294.60 from the first capture and 196.40 from this one. That is the wire two steps down."
      );
    },
  },
  {
    id: "facility_draw",
    label: "Facility draw · 425.00",
    teaches:
      "Funding has nothing to do with exposure. Treasury draws 85% of the purchase on the warehouse line, batched daily, and what the cardholder can spend does not move.",
    requires: [],
    async run(context) {
      await context.post({
        key: "evt_facility:draw",
        wrote: "425.00 drawn onto the warehouse line and into operating cash",
        effectiveAt: context.at(2, 12),
        postings: [
          {
            from: "facility_borrowings",
            to: "operating_cash",
            minor: FACILITY_DRAW,
          },
        ],
      });
    },
  },
  {
    id: "settled",
    label: "Settle to network · 491.00",
    teaches:
      "You wire 491, not 500. The 9 you kept was never a receipt — it is the gap between what the cardholder owes you and what you owed the network.",
    requires: ["cleared_300", "cleared_200", "facility_draw"],
    async run(context) {
      await context.post({
        key: "evt_settle:wire",
        wrote: "491.00 wired to the network, clearing the settlement payable",
        effectiveAt: context.at(3, 10),
        postings: [
          {
            from: "operating_cash",
            to: "network_settlement_payable",
            minor: NETWORK_WIRE,
          },
        ],
      });
      await context.observe(
        "network_settlement_payable",
        "network_settlement_payable, posted balance",
        "Zero. Both captures and the wire net out, and the 9.00 of interchange stayed with us."
      );
    },
  },
  {
    id: "facility_repaid",
    label: "Facility repaid",
    teaches:
      "Principal, the month's interest and the platform's share settle together. Interest was an expense for thirty days before it was ever cash.",
    requires: ["facility_draw"],
    async run(context) {
      await context.post({
        key: "evt_interest:accrual",
        wrote: "3.54 of interest accrued on 425.00 — 10% for 30/360 — owed and not yet paid",
        effectiveAt: context.at(30, 0),
        postings: [
          {
            from: "accrued_interest_payable",
            to: "interest_expense",
            minor: ACCRUED_INTEREST,
          },
        ],
      });
      await context.post({
        key: "evt_facility:repay",
        wrote: "425.00 of principal, 3.54 of interest and 2.70 to the platform, all out of operating cash",
        effectiveAt: context.at(30, 10),
        postings: [
          { from: "operating_cash", to: "facility_borrowings", minor: FACILITY_DRAW },
          {
            from: "operating_cash",
            to: "accrued_interest_payable",
            minor: ACCRUED_INTEREST,
          },
          {
            from: "operating_cash",
            to: "platform_rev_share_payable",
            minor: REV_SHARE_OWED,
          },
        ],
      });
      await context.observe(
        "operating_cash",
        "operating_cash, posted balance",
        "Below zero, and the ledger let it be: this walk never collects from the cardholder, so the cash to repay with was never pulled in. An overdrawn account is a legal state here, not an assertion failure."
      );
    },
  },
  {
    id: "disputed",
    label: "Disputed → chargeback",
    teaches:
      "A chargeback is not an undo. It is a new economic event with its own business date, so it posts as an ordinary transaction — both the clearing and the chargeback stay on the cardholder's statement.",
    requires: ["cleared_300"],
    async run(context) {
      await context.post({
        key: "evt_dispute:chargeback",
        wrote: "300.00 taken back off the cardholder — 294.60 recovered from the network, 5.40 of interchange given up. Dated back to the day of the purchase, and recorded today.",
        effectiveAt: context.at(1, 10),
        postings: [
          {
            from: "customer_receivable",
            to: "network_settlement_payable",
            minor: FIRST_CAPTURE_TO_NETWORK,
          },
          {
            from: "customer_receivable",
            to: "interchange_revenue",
            minor: FIRST_CAPTURE_INTERCHANGE,
          },
        ],
      });
      await context.observe(
        "customer_receivable",
        "customer_receivable, posted balance",
        "The disputed 300.00 is off the cardholder. Both transactions are still in the entries below — and because this one is dated back to the purchase, the two orders in the table disagree about where it sits."
      );
    },
  },
  {
    id: "reversed",
    label: "Operator error → reverse",
    teaches:
      "The undo that really is one. Reversing sends no postings at all: the server mirrors the target's own legs with the directions flipped, as a new transaction that names it.",
    requires: [],
    async run(context) {
      const mistake = await context.post({
        key: "evt_mistake:draw",
        wrote: "a second 425.00 draw, keyed by hand and wrong — treasury already drew today",
        effectiveAt: context.at(30, 12),
        postings: [
          {
            from: "facility_borrowings",
            to: "operating_cash",
            minor: FACILITY_DRAW,
          },
        ],
      });
      context.remember(FAT_FINGERED_DRAW, mistake);
      await context.post({
        key: "evt_mistake:reverse",
        wrote: "the duplicate draw reversed — same legs, directions flipped, derived by the server",
        reverses: mistake ?? undefined,
      });
    },
  },
  {
    id: "sent_twice",
    label: "Send it twice",
    teaches:
      "The same key with the same body is not a second write. The ledger answers 200 with the result it stored, and says so in a header rather than leaving you to guess.",
    requires: ["revenue_share"],
    async run(context) {
      await context.post({
        key: "evt_clear_1:revshare",
        wrote: "the platform's 1.62 again, byte for byte — the key was already claimed",
        effectiveAt: context.at(1, 10),
        postings: [
          {
            from: "platform_rev_share_payable",
            to: "platform_rev_share_expense",
            minor: FIRST_CAPTURE_REV_SHARE,
          },
        ],
      });
    },
  },
];
