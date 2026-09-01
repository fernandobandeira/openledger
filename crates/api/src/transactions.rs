//! The transaction resource: post one, and read one back. Their wire types,
//! their handlers, and the `#[utoipa::path]` annotations the committed spec is
//! generated from. The types double as the schema — what the handler
//! deserializes IS what the spec documents, so body drift is structurally
//! impossible; status, header and path drift are not, which is what
//! `tests/spec.rs` and the e2e conformance test hold.
//!
//! The read-back half arrived with ADR-0019, and its argument is that a
//! write-only API is not an adoption surface: the post below answers two
//! UUIDs, and until now nothing over HTTP could say what they point at —
//! while ADR-0016 made `status`, `resolves_id` and `reverses_id` wire concepts
//! a caller could not read back. It is cheap in the way scope creep is not:
//! one statement, by primary key, no cursor (the rows are immutable) and no
//! chart version.

use axum::extract::State;
use axum::http::{HeaderName, StatusCode};
use axum::response::{IntoResponse, Response};
use ledger::{Ledger, Reports};
use serde::{Deserialize, Serialize};
use time::OffsetDateTime;
use utoipa::{IntoParams, ToSchema};
use uuid::Uuid;

use crate::reports::refusal_for_read;
use crate::wire::{Body, ErrorBody, Params, Refusal, Segment, refuse};

const IDEMPOTENCY_REPLAYED: HeaderName = HeaderName::from_static("idempotency-replayed");

/// One movement of money: `amount_minor` leaves `source` and arrives at
/// `destination`. Direction is carried by the pair, never by a sign.
#[derive(Deserialize, ToSchema)]
pub(crate) struct PostingBody {
    /// Account the amount leaves.
    source: Uuid,
    /// Account the amount arrives at.
    destination: Uuid,
    /// Minor units of `currency`, strictly positive, as an exact-integer
    /// decimal STRING — never a JSON number.
    ///
    /// **The column is exact and the wire was not.** `ledger_entries.amount_minor`
    /// is a `bigint`, which reaches far past 2⁵³, and JSON has no integer type
    /// at all: RFC 8259 leaves precision beyond an IEEE-754 double to the
    /// implementation, and JavaScript's parser is one that loses it.
    /// Demonstrated against this API rather than reasoned — a posting of
    /// 9007199254740993 was accepted and `JSON.parse` read it back as
    /// 9007199254740992, silently off by one in both directions. So a single
    /// amount travels the way every report total already does.
    #[schema(pattern = r"^-?[0-9]+$", example = "2500")]
    amount_minor: String,
    /// ISO 4217 alphabetic code, three uppercase ASCII letters.
    #[schema(min_length = 3, max_length = 3, example = "USD")]
    currency: String,
}

/// Whether the transaction lands on the books or records money that MAY
/// move. Status never mutates: a pending transaction becomes posted by a NEW
/// transaction naming it in `resolves_id`, never by an update (ADR-0016).
#[derive(Clone, Copy, Deserialize, ToSchema)]
#[serde(rename_all = "lowercase")]
pub(crate) enum StatusBody {
    /// A claim about what may happen: entries are written and sequenced, but
    /// no report and no balance counts them until a resolution posts. The
    /// pending population is enumerated by `recon_pending_bridge`.
    Pending,
    /// Money that moved. The default.
    Posted,
}

/// The body of `POST /v1/transactions`.
#[derive(Deserialize, ToSchema)]
pub(crate) struct TransactionBody {
    /// The book this transaction belongs to. Named in the body by decision
    /// (ADR-0017): data scoping, never an identity claim — the trust story is
    /// the deployment perimeter's, and authenticating callers is the
    /// deployer's layer.
    #[schema(example = "t1")]
    tenant_id: String,
    /// Caller-supplied replay key, unique per tenant. Sending the same key
    /// with the same body replays the stored result; with a different body it
    /// is refused as `idempotency_key_reused` (ADR-0013 §2).
    #[schema(min_length = 1, example = "charge-1")]
    idempotency_key: String,
    /// When the movement is deemed to have happened, RFC 3339. Required —
    /// the writer will not invent a date — EXCEPT on a reversal, where
    /// omission means "the target's own effective_at" (ADR-0016's soft
    /// convention). A supplied date is taken as given, including one below
    /// the target's; the cost of that window is recorded in ADR-0016.
    #[serde(default, with = "time::serde::rfc3339::option")]
    effective_at: Option<OffsetDateTime>,
    /// Omitted means `posted`.
    #[serde(default)]
    status: Option<StatusBody>,
    /// The PENDING transaction this one resolves — pending → posted is this
    /// new, posted transaction, never an update to the original (ADR-0016).
    /// The resolution's postings need not mirror the pending amounts (a
    /// partial capture resolves with less); a resolving transaction cannot
    /// itself be pending.
    #[serde(default)]
    resolves_id: Option<Uuid>,
    /// The transaction this one reverses — operational undo, as a NEW
    /// posted transaction (ADR-0016): a posted target is mirrored in full
    /// (same legs, directions flipped, derived by the server — send NO
    /// postings), and a pending target is voided by a zero-posting marker.
    /// The target must be an ordinary posting on this tenant's book,
    /// itself neither a resolution nor a reversal, and not already
    /// superseded.
    #[serde(default)]
    reverses_id: Option<Uuid>,
    /// At least one posting — except on a reversal, which must carry NONE:
    /// the server derives the mirror from the target.
    #[serde(default)]
    postings: Vec<PostingBody>,
}

/// The stored result of an accepted operation: the event, and the transaction
/// it caused.
#[derive(Serialize, ToSchema)]
pub(crate) struct TransactionCreated {
    /// The event row this call claimed — or, on a replay, the one it found.
    event_id: Uuid,
    /// The transaction the event caused. Nullable by contract: most accepted
    /// operations write no transaction at all (ADR-0013 §2). This endpoint
    /// always writes one, but a replay re-renders whatever was stored.
    // `required`: serde renders `None` as an explicit `null`, so the key is
    // always present — nullable and optional are different claims.
    #[schema(required)]
    transaction_id: Option<Uuid>,
}

/// Post a transaction.
///
/// The response set below is this endpoint's real one, not a shared error
/// enum's: the eight 422 `type`s named are exactly the ones the writer can
/// produce here, and nothing else is documented (spike 021 found both
/// candidate libraries fanning shared enums across statuses their endpoints
/// cannot return — the fix is to declare per endpoint, so this project
/// does).
#[utoipa::path(
    post,
    path = "/v1/transactions",
    operation_id = "postTransaction",
    tag = "transactions",
    request_body = TransactionBody,
    responses(
        (
            status = 201,
            description = "Posted: this call claimed the idempotency key and wrote the \
                           transaction atomically.",
            body = TransactionCreated,
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
            body = TransactionCreated,
            headers(
                ("Idempotency-Replayed" = bool,
                 description = "`true`: this response re-renders a previously stored result.")
            )
        ),
        (
            status = 422,
            description = "Refused, and nothing was written. The caller must CHANGE the request \
                           to escape — which is why this is 422, not 400 or 409 (ADR-0013 §2). \
                           `type` is one of: `invalid_request` (a precondition on the body \
                           failed, or a field failed to deserialize into its documented type), \
                           `idempotency_key_reused` (same key, different body — send a \
                           new key or resend the original request unchanged), `account_unknown` \
                           (a posting names an account that does not exist or does not hold \
                           that currency), `resolve_target_unknown` (`resolves_id` names no \
                           transaction on this tenant's book), `resolve_target_not_pending` \
                           (only a pending transaction can be resolved — its status never \
                           mutates), `reverse_target_unknown` (`reverses_id` names no \
                           transaction on this tenant's book), `reverse_target_not_reversible` \
                           (only an ordinary posting that is itself neither a resolution nor a \
                           reversal can be reversed), `target_already_superseded` (the named target \
                           already has its one supersession — resolved or reversed, either \
                           fate is final).",
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
pub(crate) async fn post_transaction<L, R>(
    State(state): State<crate::AppState<L, R>>,
    Body(body): Body<TransactionBody>,
) -> Response
where
    L: Ledger,
    R: Reports,
{
    let command = match to_command(body) {
        Ok(command) => command,
        Err(refused) => return refused.into_response(),
    };
    match state.ledger.post(&command).await {
        Ok(posted) => answer_the_stored_result(posted),
        Err(refused) => refusal_for(refused),
    }
}

/// The accepted answer, rendered from what the writer stored. The one decision
/// here is 201-vs-200, and the `Idempotency-Replayed` header is read off the
/// same flag, so the two cannot disagree: a replay re-renders the stored
/// result, and the caller is told apart by the header and the code, not by a
/// cached body (ADR-0013 §2).
fn answer_the_stored_result(posted: ledger::Posted) -> Response {
    let status = if posted.replayed {
        StatusCode::OK
    } else {
        StatusCode::CREATED
    };
    let replayed = if posted.replayed { "true" } else { "false" };
    (
        status,
        [(IDEMPOTENCY_REPLAYED, replayed)],
        axum::Json(TransactionCreated {
            event_id: posted.event_id,
            transaction_id: posted.transaction_id,
        }),
    )
        .into_response()
}

/// Every refusal the writer can produce here, on the wire — the whole table in
/// one place, because the nine named `type`s ARE the domain and they are what
/// the `#[utoipa::path]` responses above document. Exhaustive by construction:
/// a new [`ledger::WriteError`] variant does not compile until it is named a
/// `type` and given its prose.
fn refusal_for(error: ledger::WriteError) -> Response {
    match error {
        // 422, not 400 or 409: the caller must CHANGE the request to escape
        // (ADR-0013 §2 takes the IETF draft's split by what the client must do).
        ledger::WriteError::KeyReused => refuse(
            StatusCode::UNPROCESSABLE_ENTITY,
            "idempotency_key_reused",
            "this idempotency key was already used by a request with a different body; \
             nothing was written — send a new key, or resend the original request unchanged"
                .to_owned(),
        ),
        ledger::WriteError::AccountUnknown {
            account_id,
            currency,
        } => refuse(
            StatusCode::UNPROCESSABLE_ENTITY,
            "account_unknown",
            format!("account {account_id} does not exist, or does not hold {currency}"),
        ),
        ledger::WriteError::Overflow => refuse(
            StatusCode::UNPROCESSABLE_ENTITY,
            "invalid_request",
            "the posting amounts overflow 64-bit minor units".to_owned(),
        ),
        ledger::WriteError::ResolveTargetUnknown { resolves_id } => refuse(
            StatusCode::UNPROCESSABLE_ENTITY,
            "resolve_target_unknown",
            format!("resolves_id {resolves_id} names no transaction on this tenant's book"),
        ),
        ledger::WriteError::ResolveTargetNotPending { resolves_id } => refuse(
            StatusCode::UNPROCESSABLE_ENTITY,
            "resolve_target_not_pending",
            format!(
                "transaction {resolves_id} is not pending — only a pending transaction can be \
                 resolved, and its status never mutates"
            ),
        ),
        ledger::WriteError::ReverseTargetUnknown { reverses_id } => refuse(
            StatusCode::UNPROCESSABLE_ENTITY,
            "reverse_target_unknown",
            format!("reverses_id {reverses_id} names no transaction on this tenant's book"),
        ),
        ledger::WriteError::ReverseTargetNotReversible { reverses_id } => refuse(
            StatusCode::UNPROCESSABLE_ENTITY,
            "reverse_target_not_reversible",
            format!(
                "transaction {reverses_id} cannot be reversed — only an ordinary posting that \
                 is itself neither a resolution nor a reversal can be; recovery from a \
                 mistaken correction is a fresh posting"
            ),
        ),
        ledger::WriteError::TargetAlreadySuperseded { transaction_id } => refuse(
            StatusCode::UNPROCESSABLE_ENTITY,
            "target_already_superseded",
            format!(
                "transaction {transaction_id} already has its one supersession — it was \
                 resolved or reversed, and either fate is final"
            ),
        ),
        // Same wire shape for both 500 classes: the caller gets no
        // internals, the operator's log gets the difference — a storage
        // failure reads as the backend's error, an Internal as the writer
        // naming its own can't-happen state.
        ledger::WriteError::Storage(e) => {
            eprintln!("openledger: write failed: {e}");
            refuse(
                StatusCode::INTERNAL_SERVER_ERROR,
                "internal",
                "the write failed; nothing was committed".to_owned(),
            )
        }
        ledger::WriteError::Internal(detail) => {
            eprintln!("openledger: write failed: {detail}");
            refuse(
                StatusCode::INTERNAL_SERVER_ERROR,
                "internal",
                "the write failed; nothing was committed".to_owned(),
            )
        }
    }
}

/// The one value this endpoint PARSES: a posting amount, which arrives as
/// text so that no JSON parser between here and the caller can round it
/// (ADR-0019's hole, found by building a client).
///
/// The grammar is deliberately narrower than `i64::from_str`'s, and each
/// narrowing is a value that would otherwise be accepted quietly:
///
/// - **a leading `+`** — `"+2500"` parses in Rust and is not what a
///   database, a spreadsheet or another client would render, so accepting it
///   would make two spellings of one amount, hashing differently under the
///   idempotency key that covers the request bytes;
/// - **surrounding whitespace** — `" 2500"` is refused rather than trimmed,
///   for the same reason a clamped page size is refused rather than clamped:
///   the caller's request is answered or named, never quietly rewritten;
/// - **anything that is not digits** — a float (`"25.00"`), an exponent
///   (`"2.5e3"`), an empty string, a thousands separator;
/// - **a value outside 64-bit minor units**, which is the column's own range
///   and is named as its own sentence, because "too large" and "not a number"
///   are different things for a caller to fix.
///
/// What it does NOT judge is the sign: `"0"` and `"-1"` parse here and are
/// refused by `Posting::new`'s strictly-positive rule, which is the domain's
/// and stays there.
fn minor_units(text: &str) -> Result<i64, Refusal> {
    let digits = text.strip_prefix('-').unwrap_or(text);
    if digits.is_empty() || !digits.bytes().all(|byte| byte.is_ascii_digit()) {
        return Err(invalid_request(format!(
            "amount_minor {text:?} is not an exact integer: send minor units as a decimal \
             string of digits, optionally signed, with no leading plus, no whitespace, no \
             decimal point and no exponent"
        )));
    }
    text.parse::<i64>().map_err(|_| {
        invalid_request(format!(
            "amount_minor {text:?} is outside the range of 64-bit minor units, which is what \
             ledger_entries.amount_minor holds"
        ))
    })
}

/// A body refusal in the one shape every refusal on this surface wears —
/// 422, because the caller must CHANGE the request to escape (ADR-0013 §2).
fn invalid_request(detail: String) -> Refusal {
    Refusal::new(StatusCode::UNPROCESSABLE_ENTITY, "invalid_request", detail)
}

fn to_command(body: TransactionBody) -> Result<ledger::PostTransaction, Refusal> {
    let postings = body
        .postings
        .into_iter()
        .map(|posting| {
            let amount_minor = minor_units(&posting.amount_minor)?;
            ledger::Posting::new(
                posting.source,
                posting.destination,
                amount_minor,
                posting.currency,
            )
            .map_err(refusing_the_body)
        })
        .collect::<Result<Vec<_>, Refusal>>()?;
    // Omitted means posted — the wire's default is decided here, at the
    // boundary, so the domain constructor never sees an absence.
    let status = match body.status.unwrap_or(StatusBody::Posted) {
        StatusBody::Pending => ledger::TransactionStatus::Pending,
        StatusBody::Posted => ledger::TransactionStatus::Posted,
    };
    ledger::PostTransaction::new(
        body.tenant_id,
        body.idempotency_key,
        body.effective_at,
        status,
        body.resolves_id,
        body.reverses_id,
        postings,
    )
    .map_err(refusing_the_body)
}

/// A domain refusal on the wire. The domain says what is wrong in one
/// sentence and this layer says with what status and under which `type`,
/// which is the division of labour every handler here keeps.
fn refusing_the_body(invalid: ledger::Invalid) -> Refusal {
    invalid_request(invalid.detail().to_owned())
}

/// The query half of `GET /v1/transactions/{transaction_id}` — which book to
/// look in. Named in the query string for the same reason the write path
/// names it in the body (ADR-0017): data scoping, never an identity claim.
#[derive(Deserialize, IntoParams)]
#[into_params(parameter_in = Query)]
pub(crate) struct TransactionParams {
    /// The book to read.
    #[param(example = "t1")]
    tenant_id: String,
}

/// A transaction as the book holds it, with its entries.
#[derive(Serialize, ToSchema)]
pub(crate) struct TransactionRead {
    transaction_id: Uuid,
    /// `posting` for an ordinary transaction, `period_close` for a close.
    kind: String,
    /// `pending` or `posted`. **It never mutates**: a pending transaction
    /// becomes posted by a NEW transaction naming it in `resolves_id`
    /// (ADR-0016), so a `pending` here is what was recorded and not a stage
    /// this row is passing through.
    status: String,
    /// When the movement is deemed to have happened — the caller's clock.
    #[serde(with = "time::serde::rfc3339")]
    effective_at: OffsetDateTime,
    /// When the row was written — the database's clock. The two axes are
    /// different questions (ADR-0006) and neither is derivable from the other.
    #[serde(with = "time::serde::rfc3339")]
    recorded_at: OffsetDateTime,
    /// The pending transaction this one resolved, if it is a resolution.
    #[schema(required)]
    resolves_id: Option<Uuid>,
    /// The transaction this one reversed, if it is a reversal.
    #[schema(required)]
    reverses_id: Option<Uuid>,
    /// The event that caused this transaction.
    event_id: Uuid,
    /// The legs. **Empty is a real answer**: a reversal of a pending
    /// transaction is a zero-posting void marker (ADR-0016).
    entries: Vec<EntryRead>,
}

/// One leg. `amount_minor` is an exact-integer decimal STRING, the same shape
/// the request sends and every report total already carried: a `bigint`
/// reaches far past 2⁵³ and a JSON number does not carry it exactly, so the
/// read-back of a large posting was silently one lower than what was written
/// (ADR-0019's asymmetry, corrected by building a client against it).
#[derive(Serialize, ToSchema)]
pub(crate) struct EntryRead {
    account_id: Uuid,
    /// `debit` or `credit`. Direction carries the sign; the amount never does.
    direction: String,
    #[schema(example = "2500")]
    amount_minor: String,
    currency: String,
    /// The account's own gapless sequence number for this leg. The counter is
    /// per `(account, stripe)` — documented, never exposed: no stripe appears
    /// in any response (ADR-0013 §4).
    account_seq: i64,
}

/// Read a transaction back.
///
/// No cursor and no chart version: a transaction and its entries are
/// immutable (`ck_txn__append_only` and `ck_entries__append_only`, both
/// `ENABLE ALWAYS`), so there is nothing for an as-of to pin (ADR-0019).
#[utoipa::path(
    get,
    path = "/v1/transactions/{transaction_id}",
    operation_id = "getTransaction",
    tag = "transactions",
    params(
        ("transaction_id" = Uuid, Path, description = "The transaction to read."),
        TransactionParams,
    ),
    responses(
        (
            status = 200,
            description = "The transaction and its entries. `entries` is empty for a void — the \
                           zero-posting marker a reversal of a PENDING transaction writes \
                           (ADR-0016).",
            body = TransactionRead
        ),
        (
            status = 404,
            description = "No such transaction on this tenant's book. `type` is \
                           `transaction_unknown`. Note that an unknown TENANT is not 404 but \
                           200-with-nothing on the report routes, and 404 here: there is no \
                           tenant registry to consult, so a wrong `tenant_id` is \
                           indistinguishable from a book that does not hold this transaction.",
            body = ErrorBody
        ),
        (
            status = 422,
            description = "Refused. `type` is `tenant_mismatch` — the `tenant_id` asked about is \
                           not the scope the read path set on the session. Vacuous today by \
                           construction and declared anyway (ADR-0019).",
            body = ErrorBody
        ),
        (
            status = 400,
            description = "A required query parameter is missing, or a value would not \
                           deserialize into its documented type — including a \
                           `transaction_id` path segment that is not a UUID. `type` is \
                           `invalid_request`.",
            body = ErrorBody
        ),
        (
            status = 503,
            description = "The read exceeded the read pool's `statement_timeout` (`57014`). \
                           `type` is `report_timed_out`. **503, not 500 and not 504**: the \
                           service is healthy, the request was too expensive, and retrying it \
                           unchanged fails identically (ADR-0019).",
            body = ErrorBody
        ),
        (
            status = 500,
            description = "The read failed. `type` is `internal`, and the caller gets no \
                           internals — the operator's log has the error.",
            body = ErrorBody
        ),
    ),
)]
pub(crate) async fn get_transaction<L, R>(
    State(state): State<crate::AppState<L, R>>,
    Segment(transaction_id): Segment<Uuid>,
    Params(params): Params<TransactionParams>,
) -> Response
where
    L: Ledger,
    R: Reports,
{
    let query = ledger::TransactionQuery {
        tenant_id: params.tenant_id,
        transaction_id,
    };
    match state.reports.transaction(&query).await {
        Ok(found) => answer_the_transaction(found),
        Err(refused) => refusal_for_read(refused),
    }
}

/// The transaction on the wire, rendered from what the book holds.
fn answer_the_transaction(found: ledger::Transaction) -> Response {
    axum::Json(TransactionRead {
        transaction_id: found.transaction_id,
        kind: found.kind,
        status: found.status,
        effective_at: found.effective_at,
        recorded_at: found.recorded_at,
        resolves_id: found.resolves_id,
        reverses_id: found.reverses_id,
        event_id: found.event_id,
        entries: found
            .entries
            .into_iter()
            .map(|entry| EntryRead {
                account_id: entry.account_id,
                direction: entry.direction,
                amount_minor: entry.amount_minor.to_string(),
                currency: entry.currency,
                account_seq: entry.account_seq,
            })
            .collect(),
    })
    .into_response()
}

#[cfg(test)]
mod tests {
    //! The one parse this endpoint owns, held hard — because it is the fix
    //! for a defect that was SILENT: a posting of 2⁵³+1 was accepted and read
    //! back one lower, with nothing on the wire to say so. What these hold is
    //! the grammar and the round trip; what a real posting does with the
    //! number is the domain's and the e2e suite's.

    use super::*;

    /// 2⁵³+1 — the smallest integer an IEEE-754 double cannot represent, and
    /// the value the defect was demonstrated with.
    const BEYOND_A_DOUBLE: i64 = 9_007_199_254_740_993;

    /// The refusal's prose, or the value it declined to refuse.
    fn spoken(parsed: &Result<i64, Refusal>) -> String {
        match parsed {
            Ok(minor) => format!("answered {minor}"),
            Err(refusal) => refusal.detail().to_owned(),
        }
    }

    #[test]
    fn the_smallest_integer_a_double_cannot_hold_survives_the_parse_and_the_rendering() {
        let sent = "9007199254740993";

        let parsed = minor_units(sent);

        // In: the exact i64, not the double's nearest neighbour. Out: the
        // same digits, byte for byte — which is the whole point of the string.
        assert_eq!(parsed.ok(), Some(BEYOND_A_DOUBLE));
        assert_eq!(BEYOND_A_DOUBLE.to_string(), sent);
    }

    #[test]
    fn the_range_the_column_holds_is_the_range_the_wire_accepts() {
        let cases = [
            ("9223372036854775807", Some(i64::MAX)),
            ("-9223372036854775808", Some(i64::MIN)),
            ("0", Some(0)),
            ("-1", Some(-1)),
            ("2500", Some(2500)),
        ];

        for (sent, expected) in cases {
            let parsed = minor_units(sent);

            assert_eq!(parsed.ok(), expected, "for {sent:?}");
        }
    }

    /// Zero and a negative PARSE and are refused one layer in, by
    /// `Posting::new`'s strictly-positive rule — the domain's judgement, which
    /// this parse deliberately does not duplicate: a second opinion on the
    /// same question is a second place for it to change.
    #[test]
    fn the_sign_is_the_domains_question_and_not_this_parses() {
        let zero = minor_units("0");
        let negative = minor_units("-2500");

        let refused =
            ledger::Posting::new(Uuid::from_u128(1), Uuid::from_u128(2), 0, "USD".to_owned());

        assert_eq!(zero.ok(), Some(0));
        assert_eq!(negative.ok(), Some(-2500));
        assert_eq!(
            refused.err().map(|invalid| invalid.detail()),
            Some("amount_minor must be positive")
        );
    }

    #[test]
    fn a_value_past_sixty_four_bits_is_refused_as_out_of_range_and_never_wrapped() {
        // One past `i64::MAX`, and one past `u64::MAX` for good measure: a
        // wrap here would post a large positive amount as a negative one.
        for sent in ["9223372036854775808", "18446744073709551616"] {
            let parsed = minor_units(sent);

            assert!(
                spoken(&parsed).contains("outside the range of 64-bit minor units"),
                "{sent:?} was answered {:?}",
                spoken(&parsed)
            );
        }
    }

    #[test]
    fn everything_that_is_not_an_exact_integer_in_digits_is_refused_by_name() {
        // The float and the exponent are the dangerous two: both are what a
        // consumer that lost precision would send BACK, and both would parse
        // in a language that accepts them.
        for sent in [
            "+2500", " 2500", "2500 ", "\t2500", "25.00", "2.5e3", "", "-", "abc", "12x", "2_500",
            "2,500", "٢٥", "0x10",
        ] {
            let parsed = minor_units(sent);

            assert!(
                spoken(&parsed).contains("is not an exact integer"),
                "{sent:?} was answered {:?}",
                spoken(&parsed)
            );
        }
    }
}
