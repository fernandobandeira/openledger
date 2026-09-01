//! The period resource's two verbs (ADR-0024): define one, and close one for
//! one currency. Their wire types, their handlers, and the `#[utoipa::path]`
//! annotations the committed spec is generated from.
//!
//! **Why this file exists at all.** `ledger_periods`, `ledger_period_closes`
//! and `ledger_period_balances` have existed since the baseline and nothing in
//! Rust had ever written any of them — only the e2e fixtures, by hand, in SQL.
//! That is the same hole ADR-0021 closed for accounts and ADR-0014 named for
//! the writer: *"a writer only Rust code can call is not a deliverable"* is
//! the argument against a ledger you cannot close the books on without a
//! `psql` session. The roadmap's settled framing is that *"the core ships a
//! period close, statements, and checkpoints together"*; the statements
//! shipped with M5 and the checkpoint reader with ADR-0020, and this is the
//! third leg.
//!
//! **Both verbs are WRITES, so both reach [`ledger::Ledger`]** — unlike the
//! account resource next door, which splits by direction because listing
//! accounts is a read. There is no `GET /v1/periods` here and that is
//! deliberate rather than pending: ADR-0024 specifies two routes, every route
//! is permanent under ADR-0014's machine-checked table, and a listing needs an
//! ordering and a page key this decision did not design (ADR-0019's standing
//! reason, which ADR-0021 withdrew for accounts on evidence and nobody has
//! withdrawn here).
//!
//! **A definition looks exactly like an account opening, and a close looks
//! like nothing else on this surface.** Defining a period claims a CALLER's
//! idempotency key and replays under `Idempotency-Replayed: true`, unchanged.
//! Closing one derives its key — `tenant:close:period:currency`, ADR-0011 §2 —
//! so a second attempt is `period_already_closed` rather than a replay: a
//! close happens once, and correcting one is a later posting like everything
//! else here (ADR-0016 refuses reversing a close).
//!
//! What this layer owns is what every handler here owns: which status, which
//! header, which error `type`. The judgement is one ring in — the derived key,
//! the sweep's arithmetic and every named refusal are `ledger`'s writer
//! service — and the SQL another ring out.

use axum::extract::State;
use axum::http::{HeaderName, StatusCode};
use axum::response::{IntoResponse, Response};
use ledger::{Ledger, Reports};
use serde::{Deserialize, Serialize};
use time::OffsetDateTime;
use utoipa::ToSchema;
use uuid::Uuid;

use crate::wire::{Body, ErrorBody, Segment, refuse};

const IDEMPOTENCY_REPLAYED: HeaderName = HeaderName::from_static("idempotency-replayed");

/// The body of `POST /v1/periods`.
///
/// **`starts_at` and `ends_at` are RESOLVED INSTANTS and `tz` is provenance,
/// and that split is the whole design** (ADR-0011 §5, ADR-0024). The API never
/// accepts a local date and a zone and resolves them itself, because that is
/// measured to be wrong twice over: a local midnight is not always a real
/// instant — `2018-11-04 00:00` in `America/Sao_Paulo` never happened, and
/// PostgreSQL silently resolves it to 01:00 — and the same local date resolves
/// an hour apart across a tzdata update. The caller resolves once, sends the
/// instants, and names the zone so a reader can say *"February in
/// America/New_York"*.
#[derive(Deserialize, ToSchema)]
pub(crate) struct PeriodBody {
    /// The book this period belongs to. Named in the body by decision
    /// (ADR-0017): data scoping, never an identity claim.
    #[schema(example = "t1")]
    tenant_id: String,
    /// Caller-supplied replay key, unique per tenant — and in the SAME
    /// namespace a posting's and an opening's key live in, because it is the
    /// same spine (`ledger_events`, ADR-0005). Sending the same key with the
    /// same body replays the stored result; with a different body it is
    /// refused as `idempotency_key_reused` (ADR-0013 §2).
    #[schema(min_length = 1, example = "period-2026-08")]
    idempotency_key: String,
    /// The period's label — `2026-08`, `FY2026Q1`. **A label, not a key of
    /// time**: nothing parses it, and the instants below are what every report
    /// filters on. It is unique per tenant (`pk_periods`) and it is the
    /// `{code}` the close route names.
    #[schema(example = "2026-08")]
    code: String,
    /// The first instant IN the period, RFC 3339.
    #[serde(with = "time::serde::rfc3339")]
    #[schema(value_type = String, format = DateTime, example = "2026-08-01T00:00:00Z")]
    starts_at: OffsetDateTime,
    /// The first instant NOT in the period, RFC 3339 — the range is
    /// **half-open**, `[starts_at, ends_at)`. A close's own transaction is
    /// dated one microsecond below this, which `timestamptz`'s microsecond
    /// resolution makes exact rather than a `23:59:59` approximation.
    #[serde(with = "time::serde::rfc3339")]
    #[schema(value_type = String, format = DateTime, example = "2026-09-01T00:00:00Z")]
    ends_at: OffsetDateTime,
    /// The IANA zone whose business date this period is — `UTC`,
    /// `America/New_York`. **Provenance, never the boundary**: it is recorded
    /// and never re-resolved, and a name the server's tzdata does not carry is
    /// `period_zone_unknown`.
    #[schema(example = "UTC")]
    tz: String,
}

/// One period as `ledger_periods` holds it, on the wire — read back from the
/// insert, never re-rendered from the request, for the reason an account's
/// answer is read back from the register: the instants the ROW carries are the
/// ones every report will filter on.
#[derive(Serialize, ToSchema)]
pub(crate) struct PeriodRead {
    code: String,
    #[serde(with = "time::serde::rfc3339")]
    #[schema(value_type = String, format = DateTime)]
    starts_at: OffsetDateTime,
    #[serde(with = "time::serde::rfc3339")]
    #[schema(value_type = String, format = DateTime)]
    ends_at: OffsetDateTime,
    /// The zone as provenance, exactly as it was sent.
    tz: String,
}

/// The stored result of an accepted definition: the event, and the period it
/// caused.
///
/// `event_id` is here for the reason it is on an opening's answer: defining a
/// period writes an EVENT and no ledger transaction, which is the case
/// ADR-0005 justified the event log by, and the spine is a fact a caller
/// should be able to see.
#[derive(Serialize, ToSchema)]
pub(crate) struct PeriodCreated {
    /// The event row this call claimed — or, on a replay, the one it found.
    event_id: Uuid,
    period: PeriodRead,
}

/// One temporary account the close swept, and how much it moved.
#[derive(Serialize, ToSchema)]
pub(crate) struct SweptRead {
    account_id: Uuid,
    /// The DEBIT-POSITIVE position moved into `retained_earnings`, as an
    /// exact-integer decimal STRING (ADR-0022): a revenue account reads
    /// negative and an expense account positive, which is this schema's one
    /// sign convention (ADR-0007 §15) and the same one a trial balance's
    /// `balance_debit_positive` publishes.
    ///
    /// A string and not a number because JSON has no integer type and a
    /// `bigint` position reaches past 2^53, where a consumer's parser rounds
    /// silently.
    #[schema(example = "-2500")]
    position_minor: String,
}

/// What a close wrote.
///
/// **No `replayed` flag, and its absence is the contract** (ADR-0011 §2): the
/// idempotency key is derived, so a second close of one period and currency is
/// `period_already_closed` and there is no stored result to re-render.
#[derive(Serialize, ToSchema)]
pub(crate) struct PeriodClosedRead {
    /// The event row that claimed the derived key.
    event_id: Uuid,
    /// The closing transaction — an ordinary balanced transaction, posted
    /// through the same primitive as any other (ADR-0011 §2). It is readable
    /// on `GET /v1/transactions/{transaction_id}` like any other, and it
    /// cannot be reversed (ADR-0016).
    transaction_id: Uuid,
    period_code: String,
    currency: String,
    /// The closing transaction's own date: `ends_at - 1 microsecond`, the last
    /// *representable* instant inside a half-open period.
    #[serde(with = "time::serde::rfc3339")]
    #[schema(value_type = String, format = DateTime, example = "2026-08-31T23:59:59.999999Z")]
    effective_at: OffsetDateTime,
    /// The commit cursor the checkpoint was computed at, as a decimal STRING —
    /// an `xid8` is 64-bit, and every cursor on this surface travels as a
    /// string for the reason every amount does (ADR-0022).
    ///
    /// It is the value `ledger_period_closes.computed_at_xid` carries, and
    /// everything below it had committed: an entry backdated into this period
    /// afterwards arrives ABOVE it, so it is a tail term rather than an
    /// invalidation, and `close_disclosures` is where such arrivals are
    /// enumerated.
    #[schema(example = "16024")]
    computed_at_xid: String,
    /// One entry per temporary account the close moved, in account order.
    /// **Empty is a legitimate close**, not a refusal: a period with no
    /// revenue or expense movement has nothing to sweep, and migration
    /// `00004` carved that case out of `recon_transaction_breaks` precisely so
    /// a quiet month is not an error (ADR-0020).
    swept: Vec<SweptRead>,
    /// How many rows the checkpoint wrote — one per account with a posted
    /// entry in this currency effective before the period end, not only the
    /// swept ones. The checkpoint is the whole effective-axis position at the
    /// boundary, which is what `balance_sheet_at` reads.
    #[schema(example = 3)]
    checkpoint_rows: u64,
}

/// Define a period.
///
/// The response set below is this endpoint's real one, not a shared error
/// enum's: the five 422 `type`s named are exactly the ones the writer can
/// produce here. **`period_exists` is not in ADR-0024's refusal table**, and
/// it is here because the table is incomplete rather than because this file
/// invented a refusal: `pk_periods` is `(tenant_id, code)` and PostgreSQL
/// checks it before `ex_periods__no_overlap`, so redefining a code — the same
/// one with a corrected boundary, or the same request under a fresh key —
/// reached the caller as an unnamed `23505`. It is the direct analogue of
/// ADR-0021's `account_exists` one table over.
#[utoipa::path(
    post,
    path = "/v1/periods",
    operation_id = "definePeriod",
    tag = "periods",
    request_body = PeriodBody,
    responses(
        (
            status = 201,
            description = "Defined: this call claimed the idempotency key and wrote the period \
                           and its event atomically. The answer carries the period as the \
                           register holds it — the resolved instants a report will filter on, \
                           read back from the insert (ADR-0024).",
            body = PeriodCreated,
            headers(
                ("Idempotency-Replayed" = bool,
                 description = "`false`: this response is the first for its idempotency key.")
            )
        ),
        (
            status = 200,
            description = "Replayed: this key was already accepted with this same body. The \
                           stored result is re-rendered — never a cached response body — and \
                           nothing was written (ADR-0013 §2).",
            body = PeriodCreated,
            headers(
                ("Idempotency-Replayed" = bool,
                 description = "`true`: this response re-renders a previously stored result.")
            )
        ),
        (
            status = 422,
            description = "Refused, and nothing was written. `type` is one of: \
                           `invalid_request` (a precondition on the body failed — an `ends_at` \
                           not after `starts_at`, a blank tenant, code or zone — or a field \
                           failed to deserialize into its documented type, an instant that is \
                           not RFC 3339 included), `idempotency_key_reused` (same key, \
                           different body — send a new key, or resend the original request \
                           unchanged; the key namespace is shared with the other writes, \
                           deliberately, because it is the same spine), `period_overlaps` \
                           (`ex_periods__no_overlap` — this tenant already has a period \
                           covering part of this one; the API surfaces the exclusion \
                           constraint rather than re-checking it, because no read before the \
                           insert can see an uncommitted rival), `period_exists` \
                           (`pk_periods` — this book already holds a period under this code; \
                           it is checked BEFORE the exclusion index, so it is what redefining \
                           a code actually meets), `period_zone_unknown` \
                           (`ck_periods__tz_known` — the server's tzdata does not carry this \
                           zone name).",
            body = ErrorBody
        ),
        (
            status = 400,
            description = "The request body is not syntactically valid JSON. `type` is \
                           `invalid_request`; `detail` carries the parser's message.",
            body = ErrorBody
        ),
        (
            status = 413,
            description = "The request body exceeds the size limit. `type` is \
                           `invalid_request`.",
            body = ErrorBody
        ),
        (
            status = 415,
            description = "The request's `Content-Type` is not `application/json`. `type` is \
                           `invalid_request`.",
            body = ErrorBody
        ),
        (
            status = 500,
            description = "The write failed; nothing was committed. `type` is `internal`, and \
                           the caller gets no internals — the operator's log has the error.",
            body = ErrorBody
        ),
    ),
)]
pub(crate) async fn define_period<L, R>(
    State(state): State<crate::AppState<L, R>>,
    Body(body): Body<PeriodBody>,
) -> Response
where
    L: Ledger,
    R: Reports,
{
    let command = match ledger::DefinePeriod::new(
        body.tenant_id,
        body.idempotency_key,
        body.code,
        body.starts_at,
        body.ends_at,
        body.tz,
    ) {
        Ok(command) => command,
        Err(invalid) => {
            return refuse(
                StatusCode::UNPROCESSABLE_ENTITY,
                "invalid_request",
                invalid.detail().to_owned(),
            );
        }
    };
    match state.ledger.define_period(&command).await {
        Ok(defined) => answer_the_stored_period(defined),
        Err(refused) => refusal_for_defining(refused),
    }
}

/// The accepted answer, rendered from what the writer stored. The one decision
/// here is 201-vs-200, and the `Idempotency-Replayed` header is read off the
/// same flag so the two cannot disagree — the same rule every other write on
/// this surface follows, because it is the same contract.
fn answer_the_stored_period(defined: ledger::PeriodDefined) -> Response {
    let status = if defined.replayed {
        StatusCode::OK
    } else {
        StatusCode::CREATED
    };
    let replayed = if defined.replayed { "true" } else { "false" };
    (
        status,
        [(IDEMPOTENCY_REPLAYED, replayed)],
        axum::Json(PeriodCreated {
            event_id: defined.event_id,
            period: PeriodRead {
                code: defined.period.code,
                starts_at: defined.period.starts_at,
                ends_at: defined.period.ends_at,
                tz: defined.period.tz,
            },
        }),
    )
        .into_response()
}

/// Every refusal the writer can produce when defining a period, on the wire —
/// the whole table in one place, because the named `type`s ARE the domain and
/// they are what the `#[utoipa::path]` responses above document. Exhaustive by
/// construction: a new [`ledger::DefinePeriodError`] variant does not compile
/// until it is named a `type` and given its prose.
fn refusal_for_defining(error: ledger::DefinePeriodError) -> Response {
    match error {
        // 422 and not 409, for the same reason every other refusal on this
        // surface is: the caller must CHANGE the request to escape
        // (ADR-0013 §2).
        ledger::DefinePeriodError::KeyReused => refuse(
            StatusCode::UNPROCESSABLE_ENTITY,
            "idempotency_key_reused",
            "this idempotency key was already used by a request with a different body; \
             nothing was written — send a new key, or resend the original request unchanged"
                .to_owned(),
        ),
        ledger::DefinePeriodError::PeriodExists { code } => refuse(
            StatusCode::UNPROCESSABLE_ENTITY,
            "period_exists",
            format!(
                "this book already holds a period under the code {code:?}; a period's code is \
                 its key on this book, and a period is corrected by defining the next one \
                 rather than by redefining this one"
            ),
        ),
        ledger::DefinePeriodError::PeriodOverlaps { code } => refuse(
            StatusCode::UNPROCESSABLE_ENTITY,
            "period_overlaps",
            format!(
                "period {code:?} overlaps a period this book already holds; a tenant's periods \
                 may not overlap, and the range is half-open — a period ending at an instant \
                 and one starting at that same instant do not"
            ),
        ),
        ledger::DefinePeriodError::PeriodZoneUnknown { tz } => refuse(
            StatusCode::UNPROCESSABLE_ENTITY,
            "period_zone_unknown",
            format!(
                "this server's time zone database does not carry {tz:?}; the zone is \
                 provenance — whose business date this period is — and it is stored as sent, \
                 never used to resolve the boundary"
            ),
        ),
        // Same wire shape for both 500 classes: the caller gets no
        // internals, the operator's log gets the difference.
        ledger::DefinePeriodError::Internal(detail) => internal("defining a period", &detail),
        ledger::DefinePeriodError::Storage(e) => internal("defining a period", &e.to_string()),
    }
}

/// Close a period, for one currency.
///
/// **One call closes one currency, because `pk_closes` is per currency**
/// (ADR-0024): closing a book that holds three is three calls. That is not a
/// convenience gap — a close computes and stores a per-currency position, and
/// one call that swept three would either succeed partially or need a
/// transaction spanning three independent closes.
#[utoipa::path(
    post,
    path = "/v1/periods/{code}/close",
    operation_id = "closePeriod",
    tag = "periods",
    params(
        ("code" = String, Path,
         description = "The period's label, as `POST /v1/periods` defined it.",
         example = "2026-08"),
    ),
    request_body = ClosePeriodBody,
    responses(
        (
            status = 201,
            description = "Closed. In ONE database transaction, in this order (ADR-0024): the \
                           deterministic idempotency key `tenant:close:period:currency` is \
                           claimed; the `period_close` transaction is written — one posting \
                           per temporary account holding a non-zero position, destination \
                           `retained_earnings`, dated `ends_at - 1 microsecond`; the close \
                           record naming that transaction and its cursor; and THEN the \
                           checkpoint, one row per account, because the closing entries must \
                           exist before they can be admitted to their own checkpoint by \
                           identity (ADR-0020). A period with nothing to sweep closes cleanly \
                           and answers an empty `swept`.",
            body = PeriodClosedRead,
            headers(
                ("Idempotency-Replayed" = bool,
                 description = "Always `false`. The key is derived, so a close never replays: \
                                a second attempt is `period_already_closed`. The header is \
                                here because every accepted response on this surface carries \
                                it (ADR-0013).")
            )
        ),
        (
            status = 422,
            description = "Refused, and nothing was written — the transaction, its entries, \
                           every swept account's balance row, the close record and the \
                           checkpoint all roll back together. `type` is one of: \
                           `period_unknown` (`{code}` names no period on this tenant; refused \
                           before the derived key is claimed, which matters because a derived \
                           key burnt by a refusal could never be retried under another name), \
                           `period_already_closed` (`pk_closes` — this period and currency are \
                           closed, and a close happens once; correct one with a later posting, \
                           since reversing a close is refused by ADR-0016), \
                           `retained_earnings_unknown` (this book holds no `retained_earnings` \
                           house account in this currency, so the sweep has no destination — \
                           there is no Income Summary account to fall back on, ADR-0011 §2), \
                           `invalid_request` (a blank tenant or code, a currency that is not \
                           three uppercase letters), `idempotency_key_reused` (the derived key \
                           string is held by a request with a different body).",
            body = ErrorBody
        ),
        (
            status = 400,
            description = "The request body is not syntactically valid JSON. `type` is \
                           `invalid_request`; `detail` carries the parser's message.",
            body = ErrorBody
        ),
        (
            status = 413,
            description = "The request body exceeds the size limit. `type` is \
                           `invalid_request`.",
            body = ErrorBody
        ),
        (
            status = 415,
            description = "The request's `Content-Type` is not `application/json`. `type` is \
                           `invalid_request`.",
            body = ErrorBody
        ),
        (
            status = 500,
            description = "The close failed; nothing was committed. `type` is `internal`, and \
                           the caller gets no internals — the operator's log has the error.",
            body = ErrorBody
        ),
    ),
)]
pub(crate) async fn close_period<L, R>(
    State(state): State<crate::AppState<L, R>>,
    Segment(code): Segment<String>,
    Body(body): Body<ClosePeriodBody>,
) -> Response
where
    L: Ledger,
    R: Reports,
{
    let command = match ledger::ClosePeriod::new(body.tenant_id, code, body.currency) {
        Ok(command) => command,
        Err(invalid) => {
            return refuse(
                StatusCode::UNPROCESSABLE_ENTITY,
                "invalid_request",
                invalid.detail().to_owned(),
            );
        }
    };
    match state.ledger.close_period(&command).await {
        Ok(closed) => answer_the_close(closed),
        Err(refused) => refusal_for_closing(refused),
    }
}

/// The body of `POST /v1/periods/{code}/close`.
///
/// **There is no `idempotency_key` field, and its absence is the design**
/// (ADR-0011 §2): the key is `tenant:close:period:currency`, derived by the
/// writer, so `uq_events__idempotency` refuses a second attempt on its own
/// rather than by a check anyone had to remember to write. A caller has
/// nothing to vary here — a close is per `(tenant, period, currency)` because
/// `pk_closes` is.
#[derive(Deserialize, ToSchema)]
pub(crate) struct ClosePeriodBody {
    /// The book being closed. Named in the body by decision (ADR-0017): data
    /// scoping, never an identity claim.
    #[schema(example = "t1")]
    tenant_id: String,
    /// ISO 4217 alphabetic code, three uppercase ASCII letters. One call
    /// closes one currency.
    #[schema(min_length = 3, max_length = 3, example = "USD")]
    currency: String,
}

/// The accepted answer. Always 201 and always `Idempotency-Replayed: false` —
/// a close has no replay to report, because a repeat is a refusal.
fn answer_the_close(closed: ledger::PeriodClosed) -> Response {
    (
        StatusCode::CREATED,
        [(IDEMPOTENCY_REPLAYED, "false")],
        axum::Json(PeriodClosedRead {
            event_id: closed.event_id,
            transaction_id: closed.transaction_id,
            period_code: closed.period_code,
            currency: closed.currency,
            effective_at: closed.effective_at,
            computed_at_xid: closed.computed_at_xid,
            swept: closed
                .swept
                .into_iter()
                .map(|swept| SweptRead {
                    account_id: swept.account_id,
                    // Exact-integer decimal STRING, like every amount on this
                    // surface (ADR-0022) — a `bigint` position reaches past
                    // 2^53, where a JSON consumer's parser rounds silently.
                    position_minor: swept.position_minor.to_string(),
                })
                .collect(),
            // A row count, not an amount: it is not money, so ADR-0022's
            // string rule does not reach it, and a book with more accounts
            // than a JSON number can hold does not exist.
            checkpoint_rows: closed.checkpoint_rows,
        }),
    )
        .into_response()
}

/// Every refusal the writer can produce when closing a period, on the wire —
/// exhaustive by construction, exactly as the definition's table is.
fn refusal_for_closing(error: ledger::ClosePeriodError) -> Response {
    match error {
        ledger::ClosePeriodError::PeriodUnknown { code } => refuse(
            StatusCode::UNPROCESSABLE_ENTITY,
            "period_unknown",
            format!(
                "this book holds no period {code:?}; define it with POST /v1/periods before \
                 closing it"
            ),
        ),
        ledger::ClosePeriodError::PeriodAlreadyClosed { code, currency } => refuse(
            StatusCode::UNPROCESSABLE_ENTITY,
            "period_already_closed",
            format!(
                "period {code:?} is already closed in {currency}; a close happens once, and a \
                 closed period is corrected by a later posting rather than by un-closing it — \
                 the closing transaction cannot be reversed, because that would contradict \
                 its standing checkpoint"
            ),
        ),
        ledger::ClosePeriodError::RetainedEarningsUnknown { currency } => refuse(
            StatusCode::UNPROCESSABLE_ENTITY,
            "retained_earnings_unknown",
            format!(
                "this book holds no retained_earnings house account in {currency}, so the \
                 sweep has no destination; temporary accounts close directly to it and there \
                 is no income summary account in between"
            ),
        ),
        ledger::ClosePeriodError::KeyReused => refuse(
            StatusCode::UNPROCESSABLE_ENTITY,
            "idempotency_key_reused",
            "the idempotency key this close derives — tenant:close:period:currency — is held \
             by a request with a different body; nothing was written"
                .to_owned(),
        ),
        ledger::ClosePeriodError::Internal(detail) => internal("closing a period", &detail),
        ledger::ClosePeriodError::Storage(e) => internal("closing a period", &e.to_string()),
    }
}

/// A 500 with no internals, and the reason on the operator's log — the one
/// place either error's string goes. Spelled once here because both of this
/// file's refusal tables end on the same two arms, in both of this file's
/// operations: four identical bodies, one function.
fn internal(doing: &str, detail: &str) -> Response {
    eprintln!("openledger: {doing} failed: {detail}");
    refuse(
        StatusCode::INTERNAL_SERVER_ERROR,
        "internal",
        "the write failed; nothing was committed".to_owned(),
    )
}
