//! The five read endpoints that are not a transaction read-back or an account
//! listing: one balance, three reports, and the commit horizon on its own —
//! their wire types, and the `#[utoipa::path]` annotations the committed spec
//! is generated from.
//!
//! This layer is a mapping and grows no judgement of its own — the cursor
//! rule, the chart version and the tenant check are all `ledger::ReportService`'s
//! (ADR-0019 E2), and the session bracket is the adapter's. What IS decided
//! here, because it is a wire question and nothing else:
//!
//! - **instants and cursors arrive as text and are parsed here**, so a
//!   malformed one is a `422 invalid_request` naming the parameter rather
//!   than a 400 naming a serde path;
//! - **every amount is a decimal STRING**, on every report row (ADR-0019) —
//!   and, since a client was built against this surface, on every single
//!   entry and posting too (`transactions.rs`). A `numeric` total above 2⁵³
//!   would be silently rounded by the consumer's JSON parser, which is
//!   trading a loud refusal for a quiet wrong answer; a `bigint` posting
//!   above 2⁵³ was, and the demonstration was a posting of 9007199254740993
//!   read back one lower;
//! - **`pinned_cursor` is on every report answer**, always, including when
//!   the caller supplied no cursor: it is the only way a caller can notice
//!   that the cluster horizon is lagging, and it is the value they should
//!   store to re-run this exact report;
//! - **no stripe appears anywhere** (ADR-0013 §4). The balance answer is a
//!   `SUM` over an account's stripe rows and says so nowhere — shipping this
//!   endpoint is precisely how an integrator is stopped from writing the
//!   single-row read that under-reports.
//!
//! And one absence that is now PARTLY filled, stated as it stands: **none of
//! the five endpoints in this file pages, searches or filters**, and at a
//! million entries the three reports return 2, 10 and 4 rows, so there is
//! nothing here to page. ADR-0019 refused a listing outright on the ground
//! that one *"needs an ordering and a page key this spike did not design"*;
//! ADR-0021 withdrew that for ACCOUNTS, whose ordering already exists
//! (`pk_accounts` is `(tenant_id, id)` and `id` is `uuidv7()`), and the
//! keyset-paginated register lives in `accounts.rs` next door. What is not
//! withdrawn is the refusal of a TRANSACTION listing, which would have to
//! choose between the recorded and the effective axis — and under ADR-0014's
//! machine-checked route table a route that ships is documented forever.

use axum::extract::State;
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use ledger::{Ledger, Reports};
use serde::{Deserialize, Serialize};
use time::OffsetDateTime;
use time::format_description::well_known::Rfc3339;
use utoipa::{IntoParams, ToSchema};
use uuid::Uuid;

use crate::wire::{ErrorBody, Params, Refusal, Segment, refuse};

/// `GET /v1/accounts/{account_id}/balance` — the query half. `currency` is
/// required because the balance row's key includes it: one account holds one
/// currency, and asking without naming it would be asking a question the
/// schema does not have a row for.
#[derive(Deserialize, IntoParams)]
#[into_params(parameter_in = Query)]
pub(crate) struct AccountBalanceParams {
    /// The book to read.
    #[param(example = "t1")]
    tenant_id: String,
    /// ISO 4217 alphabetic code.
    #[param(example = "USD")]
    currency: String,
}

/// `GET /v1/reports/trial-balance` — both of ADR-0006's axes, by parameter.
#[derive(Deserialize, IntoParams)]
#[into_params(parameter_in = Query)]
pub(crate) struct TrialBalanceParams {
    #[param(example = "t1")]
    tenant_id: String,
    /// Inclusive lower bound on `effective_at`, RFC 3339.
    #[param(example = "2026-01-01T00:00:00Z")]
    effective_from: String,
    /// EXCLUSIVE upper bound on `effective_at`, RFC 3339 — the range is
    /// half-open, as it is on all three report functions (ADR-0011 §A3).
    #[param(example = "2026-02-01T00:00:00Z")]
    effective_to: String,
    /// The commit position to pin the report to — a `pinned_cursor` from an
    /// earlier report. Omit it and one is pinned server-side and returned.
    #[param(example = "231000")]
    cursor: Option<String>,
}

/// `GET /v1/reports/balance-sheet` — a POSITION, so one instant.
#[derive(Deserialize, IntoParams)]
#[into_params(parameter_in = Query)]
pub(crate) struct BalanceSheetParams {
    #[param(example = "t1")]
    tenant_id: String,
    /// The instant to report the position as at, RFC 3339. **This is a
    /// period's `ends_at`, never a business date**: the predicate is
    /// `effective_at < as_of`, so a business date returns the position at the
    /// START of that day and silently loses a day at every period boundary
    /// (ADR-0019). Nothing raises, and the number is plausible.
    #[param(example = "2026-02-01T00:00:00Z")]
    as_of: String,
    #[param(example = "231000")]
    cursor: Option<String>,
    /// The chart version to present at. Omitted means the version the book is
    /// on now, resolved by the read path and reported back in
    /// `chart_version` — never left to the SQL default, which resolves at run
    /// time (ADR-0019 B6).
    #[param(example = 1)]
    chart_version: Option<i32>,
}

/// `GET /v1/reports/income-statement` — a FLOW, so a half-open range. *"A
/// statement without a period is not a statement"* (ADR-0011 §4).
#[derive(Deserialize, IntoParams)]
#[into_params(parameter_in = Query)]
pub(crate) struct IncomeStatementParams {
    #[param(example = "t1")]
    tenant_id: String,
    /// Inclusive lower bound on `effective_at`, RFC 3339.
    #[param(example = "2026-01-01T00:00:00Z")]
    effective_from: String,
    /// EXCLUSIVE upper bound on `effective_at`, RFC 3339.
    #[param(example = "2026-02-01T00:00:00Z")]
    effective_to: String,
    #[param(example = "231000")]
    cursor: Option<String>,
    #[param(example = 1)]
    chart_version: Option<i32>,
}

/// `GET /v1/cursor` — the query half, which is one parameter and is here for
/// consistency rather than for correctness.
#[derive(Deserialize, IntoParams)]
#[into_params(parameter_in = Query)]
pub(crate) struct CursorParams {
    /// The book to read. **The horizon is the CLUSTER's**, not this book's —
    /// `report_cursor()` is `pg_snapshot_xmin` — so two tenants are answered
    /// the same number. It is required anyway so that this route runs the
    /// identical scoped read bracket every other read runs, rather than being
    /// the one read that reaches the database unscoped.
    #[param(example = "t1")]
    tenant_id: String,
}

/// The commit horizon, on its own.
#[derive(Serialize, ToSchema)]
pub(crate) struct CursorRead {
    /// The current horizon, as a decimal string — an `xid8` is a 64-bit
    /// unsigned value and JSON numbers are not. Send it back as `cursor` on
    /// any report route to pin that report here; everything strictly below it
    /// has finished committing and can never grow.
    #[schema(example = "231000")]
    cursor: String,
}

/// One account's posted balance.
#[derive(Serialize, ToSchema)]
pub(crate) struct AccountBalanceRead {
    account_id: Uuid,
    currency: String,
    /// Minor units, debit-positive, as an exact-integer decimal string. A
    /// credit-normal account reads negative here and the presentation flip is
    /// the reader's (ADR-0010).
    #[schema(example = "442000")]
    posted_minor: String,
    /// Always `now`. This endpoint reads the balance CACHE, which means
    /// POSTED (ADR-0010), and pinning it to a cursor would be a second
    /// definition of a balance — so the field is a statement of what the
    /// number means rather than a parameter's echo.
    as_of: &'static str,
}

/// The trial balance, and the cursor it was pinned at.
#[derive(Serialize, ToSchema)]
pub(crate) struct TrialBalanceRead {
    /// The commit position this report ran at — supplied or server-pinned.
    /// Store it to re-run this exact report; a decimal string, because an
    /// `xid8` is a 64-bit unsigned value and JSON numbers are not.
    #[schema(example = "231000")]
    pinned_cursor: String,
    /// One row per `(account, currency)` with any activity in the window.
    /// **An empty list is a legitimate answer** and never a 404: it is what
    /// an unknown tenant, a typo'd tenant, a tenant with no accounts, a
    /// reader scoped elsewhere and an unscoped session all produce, and two
    /// of those five are the fail-closed path working correctly (ADR-0019).
    rows: Vec<TrialBalanceRowRead>,
}

/// One `(account, currency)` of the trial balance. Every amount is a decimal
/// string.
#[derive(Serialize, ToSchema)]
pub(crate) struct TrialBalanceRowRead {
    account_id: Uuid,
    /// The account type — the chart's code, e.g. `operating_cash`.
    purpose: String,
    /// `asset`, `liability`, `equity`, `revenue` or `expense`.
    category: String,
    currency: String,
    /// Gross debits in the window.
    #[schema(example = "442000")]
    debits: String,
    /// Gross credits in the window.
    #[schema(example = "0")]
    credits: String,
    /// The ARITHMETIC value — roll up with this one. `normal_balance` never
    /// enters it, so a contra account carries its own sign instead of being
    /// flipped twice.
    #[schema(example = "442000")]
    balance_debit_positive: String,
}

/// A statement face — the same shape for the balance sheet and the income
/// statement, because the two functions return the same columns.
#[derive(Serialize, ToSchema)]
pub(crate) struct StatementRead {
    #[schema(example = "231000")]
    pinned_cursor: String,
    /// The chart version this face was presented at — always named, never
    /// defaulted. **The residual, stated** (ADR-0019 B6): naming a version
    /// pins the presentation only BELOW `max(version)`, because
    /// `refuse_stale_chart_version()` freezes history and not the present.
    chart_version: i32,
    /// The face, in the chart's own `sort_order`.
    ///
    /// **What is reproducible at a stored cursor, and what is not**
    /// (ADR-0019 B7): the AMOUNTS are; the ROW SET is not. The lines are
    /// enumerated from tables that carry no `xact_id` — one new account with
    /// nothing posted to it added ten balance-sheet rows at a fixed cursor,
    /// every pre-existing amount byte-identical. And an income statement's
    /// amounts carry one carve-out of their own: a period close inserted
    /// AFTER a statement is issued retroactively removes that transaction's
    /// entries from it, because `ledger_period_closes` has no commit position.
    lines: Vec<StatementLineRead>,
}

/// One line of a statement face.
#[derive(Serialize, ToSchema)]
pub(crate) struct StatementLineRead {
    currency: String,
    /// The chart's line code.
    fs_line: String,
    caption: String,
    /// The chart's ordering, not a row number.
    sort_order: i32,
    /// Minor units, as an exact-integer decimal string — **not a JSON
    /// number**. A report total is an aggregate and can exceed what a JSON
    /// number carries exactly, which would be rounded silently by the parser
    /// at the other end (ADR-0019). It costs every caller one parse,
    /// deliberately.
    #[schema(example = "442000")]
    amount_minor: String,
    /// Which side of the face this line belongs to.
    side: String,
}

/// The one thing this layer parses: an RFC 3339 instant, named, so a
/// malformed one refuses under the parameter the caller has to fix rather
/// than under a deserializer's path.
///
/// `pub(crate)` because the account statement next door takes the same
/// half-open range under the same two parameter names (ADR-0023), and a
/// second parsing site is a second place for the message to drift from this
/// one.
pub(crate) fn instant(parameter: &'static str, text: &str) -> Result<OffsetDateTime, Refusal> {
    OffsetDateTime::parse(text, &Rfc3339).map_err(|failed| {
        Refusal::new(
            StatusCode::UNPROCESSABLE_ENTITY,
            "invalid_request",
            format!("{parameter} is not an RFC 3339 instant: {failed}"),
        )
    })
}

/// Every refusal a read can produce, on the wire — the whole table in one
/// place, because the nine named `type`s ARE ADR-0019's error grammar and
/// they are what the annotations below and in `transactions.rs` document.
/// Exhaustive by construction: a new [`ledger::ReadError`] variant does not
/// compile until it is named a `type`, a status and its prose.
///
/// **`account_unknown` carries 404 here against the write path's 422**, on
/// one `type` name. That is legal only because ADR-0014 declares responses
/// per endpoint rather than per enum, and it is deliberate: on the write path
/// the caller must change the request, and here the resource does not exist.
pub(crate) fn refusal_for_read(error: ledger::ReadError) -> Response {
    match error {
        ledger::ReadError::InvalidRequest(detail) => {
            refuse(StatusCode::UNPROCESSABLE_ENTITY, "invalid_request", detail)
        }
        ledger::ReadError::CursorInvalid(detail) => {
            refuse(StatusCode::UNPROCESSABLE_ENTITY, "cursor_invalid", detail)
        }
        ledger::ReadError::ChartVersionUnknown(detail) => refuse(
            StatusCode::UNPROCESSABLE_ENTITY,
            "chart_version_unknown",
            detail,
        ),
        ledger::ReadError::ChartVersionIncomplete(detail) => refuse(
            StatusCode::UNPROCESSABLE_ENTITY,
            "chart_version_incomplete",
            detail,
        ),
        // 404, not the write path's 422: nothing is being asked to change,
        // the named resource simply is not on this book.
        ledger::ReadError::AccountUnknown {
            account_id,
            currency,
        } => refuse(
            StatusCode::NOT_FOUND,
            "account_unknown",
            match currency {
                // The balance read names a currency because its row key
                // includes one, and "or does not hold USD" is half of what
                // went wrong there. A read that named none must not claim it.
                Some(currency) => format!(
                    "account {account_id} does not exist on this book, or does not hold \
                     {currency}"
                ),
                None => format!("account {account_id} does not exist on this book"),
            },
        ),
        ledger::ReadError::TransactionUnknown { transaction_id } => refuse(
            StatusCode::NOT_FOUND,
            "transaction_unknown",
            format!("transaction {transaction_id} does not exist on this book"),
        ),
        ledger::ReadError::TenantMismatch { requested, scoped } => refuse(
            StatusCode::UNPROCESSABLE_ENTITY,
            "tenant_mismatch",
            format!(
                "this read was scoped to tenant {scoped:?} and asked about {requested:?}; the \
                 answer would not have been this tenant's book"
            ),
        ),
        // 503, not 500 and not 504: the service is healthy, the request was
        // too expensive, and retrying it unchanged fails identically — which
        // is what a caller needs told (ADR-0019).
        ledger::ReadError::ReportTimedOut => refuse(
            StatusCode::SERVICE_UNAVAILABLE,
            "report_timed_out",
            "the read exceeded this deployment's statement timeout; narrow the range, or read \
             a period that has been closed"
                .to_owned(),
        ),
        // Same wire shape for both 500 classes: the caller gets no internals,
        // the operator's log gets the difference.
        ledger::ReadError::Storage(failure) => {
            eprintln!("openledger: read failed: {failure}");
            refuse(
                StatusCode::INTERNAL_SERVER_ERROR,
                "internal",
                "the read failed".to_owned(),
            )
        }
        ledger::ReadError::Internal(detail) => {
            eprintln!("openledger: read failed: {detail}");
            refuse(
                StatusCode::INTERNAL_SERVER_ERROR,
                "internal",
                "the read failed".to_owned(),
            )
        }
    }
}

/// Read the commit horizon.
///
/// **ADR-0019 refused a cursor-minting endpoint** — *"every report already
/// returns the cursor it used"* — and that refusal is qualified rather than
/// contradicted here: it is true, and it is what made asking for the horizon
/// ALONE cost a whole report. A dashboard refreshing it issues a trial balance
/// over `0001-01-01`…`9999-12-31` for one scalar, which on a large book is the
/// ~28-second query ADR-0019's own cost list records. One statement answers
/// the same value, on the same read path, under the same bracket.
#[utoipa::path(
    get,
    path = "/v1/cursor",
    operation_id = "getCursor",
    tag = "reports",
    params(CursorParams),
    responses(
        (
            status = 200,
            description = "The current commit horizon — one `SELECT report_cursor()`, no \
                           report. Store it and send it back as `cursor` to pin a report \
                           here. **It is the cluster's horizon and not this tenant's**: \
                           `report_cursor()` is `pg_snapshot_xmin`, so every tenant is \
                           answered the same number, and `tenant_id` is required for the \
                           scoping every other read has rather than because the answer \
                           depends on it.",
            body = CursorRead
        ),
        (
            status = 422,
            description = "Refused. `type` is `tenant_mismatch` — the `tenant_id` asked about \
                           is not the scope the read path set on the session. Vacuous today by \
                           construction and declared anyway (ADR-0019).",
            body = ErrorBody
        ),
        (
            status = 400,
            description = "The `tenant_id` query parameter is missing, or would not \
                           deserialize into its documented type. `type` is `invalid_request`.",
            body = ErrorBody
        ),
        (
            status = 503,
            description = "The read exceeded this deployment's `statement_timeout` (`57014`). \
                           `type` is `report_timed_out`.",
            body = ErrorBody
        ),
        (
            status = 500,
            description = "The read failed. `type` is `internal`.",
            body = ErrorBody
        ),
    ),
)]
pub(crate) async fn get_cursor<L, R>(
    State(state): State<crate::AppState<L, R>>,
    Params(params): Params<CursorParams>,
) -> Response
where
    L: Ledger,
    R: Reports,
{
    let query = ledger::CursorQuery {
        tenant_id: params.tenant_id,
    };
    match state.reports.cursor(&query).await {
        Ok(horizon) => answer_the_horizon(horizon),
        Err(refused) => refusal_for_read(refused),
    }
}

/// The horizon on the wire — the same decimal rendering `pinned_cursor`
/// carries on every report, because it is the same value in the same form.
fn answer_the_horizon(horizon: ledger::Cursor) -> Response {
    axum::Json(CursorRead {
        cursor: horizon.to_string(),
    })
    .into_response()
}

/// Read one account's posted balance.
///
/// **No cursor, and that is the contract**: this reads the balance cache,
/// which means POSTED, NOW (ADR-0010). Pinning it to a cursor would be a
/// second definition of a balance, and the journal-based answer is the trial
/// balance next door.
#[utoipa::path(
    get,
    path = "/v1/accounts/{account_id}/balance",
    operation_id = "getAccountBalance",
    tag = "accounts",
    params(
        ("account_id" = Uuid, Path, description = "The account to read."),
        AccountBalanceParams,
    ),
    responses(
        (
            status = 200,
            description = "The posted balance, summed over the account's balance rows. An \
                           account that exists and has never been written answers `\"0\"` — \
                           which is why this endpoint reads the account register and not only \
                           the balance cache (ADR-0019).",
            body = AccountBalanceRead
        ),
        (
            status = 404,
            description = "No such account on this book, or the account does not hold that \
                           currency. `type` is `account_unknown` — note that the write path \
                           returns 422 under this same `type`, deliberately: there the caller \
                           must change the request, here the resource does not exist.",
            body = ErrorBody
        ),
        (
            status = 422,
            description = "Refused. `type` is `tenant_mismatch`.",
            body = ErrorBody
        ),
        (
            status = 400,
            description = "A required query parameter is missing, or a value would not \
                           deserialize into its documented type — including an `account_id` \
                           path segment that is not a UUID. `type` is `invalid_request`.",
            body = ErrorBody
        ),
        (
            status = 503,
            description = "The read exceeded this deployment's `statement_timeout` (`57014`). \
                           `type` is `report_timed_out`.",
            body = ErrorBody
        ),
        (
            status = 500,
            description = "The read failed. `type` is `internal`.",
            body = ErrorBody
        ),
    ),
)]
pub(crate) async fn get_account_balance<L, R>(
    State(state): State<crate::AppState<L, R>>,
    Segment(account_id): Segment<Uuid>,
    Params(params): Params<AccountBalanceParams>,
) -> Response
where
    L: Ledger,
    R: Reports,
{
    let query = ledger::AccountBalanceQuery {
        tenant_id: params.tenant_id,
        account_id,
        currency: params.currency,
    };
    match state.reports.account_balance(&query).await {
        Ok(balance) => answer_the_balance(balance),
        Err(refused) => refusal_for_read(refused),
    }
}

/// Read the trial balance.
///
/// **One endpoint serves both of ADR-0006's time axes, by parameter and never
/// by a mode flag**: the RECORDED axis is the cursor — widen the range and
/// vary it — and the EFFECTIVE axis is the range — fix the cursor and vary
/// it. Two resources for two parameters of one function is Formance's
/// `pit`-resolves-to-six-columns mistake (ADR-0019 C2).
#[utoipa::path(
    get,
    path = "/v1/reports/trial-balance",
    operation_id = "getTrialBalance",
    tag = "reports",
    params(TrialBalanceParams),
    responses(
        (
            status = 200,
            description = "The trial balance, and the cursor it was pinned at. An unknown \
                           tenant answers 200 with an empty list, never 404: there is no tenant \
                           registry to consult, so inventing the status would mean inventing \
                           the registry (ADR-0019).",
            body = TrialBalanceRead
        ),
        (
            status = 422,
            description = "Refused. `type` is one of: `invalid_request` (an `effective_from` or \
                           `effective_to` that is not an RFC 3339 instant, or a `cursor` that \
                           is not an `xid8` at all), `cursor_invalid` (a syntactically valid \
                           `xid8` that is above this cluster's horizon or at or below the \
                           book's oldest entry — `-1` wraps to the maximum and would return the \
                           entire UNPINNED book, `0` would return an all-zero balanced \
                           fabrication, and the database cannot refuse either), or \
                           `tenant_mismatch`.",
            body = ErrorBody
        ),
        (
            status = 400,
            description = "A required query parameter is missing, or a value would not \
                           deserialize into its documented type. `type` is `invalid_request`.",
            body = ErrorBody
        ),
        (
            status = 503,
            description = "The report exceeded this deployment's `statement_timeout` (`57014`). \
                           `type` is `report_timed_out`. **503, not 500 and not 504**: the \
                           service is healthy, the request was too expensive, and retrying it \
                           unchanged fails identically (ADR-0019).",
            body = ErrorBody
        ),
        (
            status = 500,
            description = "The report failed. `type` is `internal`.",
            body = ErrorBody
        ),
    ),
)]
pub(crate) async fn get_trial_balance<L, R>(
    State(state): State<crate::AppState<L, R>>,
    Params(params): Params<TrialBalanceParams>,
) -> Response
where
    L: Ledger,
    R: Reports,
{
    let query = match trial_balance_query(params) {
        Ok(query) => query,
        Err(refused) => return refused.into_response(),
    };
    match state.reports.trial_balance(&query).await {
        Ok(report) => answer_the_trial_balance(report),
        Err(refused) => refusal_for_read(refused),
    }
}

/// Read the balance-sheet face as at one instant.
#[utoipa::path(
    get,
    path = "/v1/reports/balance-sheet",
    operation_id = "getBalanceSheet",
    tag = "reports",
    params(BalanceSheetParams),
    responses(
        (
            status = 200,
            description = "The face, the chart version it was presented at, and the cursor it \
                           was pinned at. An unknown tenant answers 200 with an empty list, \
                           never 404 (ADR-0019).",
            body = StatementRead
        ),
        (
            status = 422,
            description = "Refused. `type` is one of: `invalid_request` (an `as_of` that is not \
                           an RFC 3339 instant, or a `cursor` that is not an `xid8`), \
                           `cursor_invalid` (a legal `xid8` outside the plausible range), \
                           `chart_version_unknown` (no such version, or no chart has been \
                           seeded at all), `chart_version_incomplete` (the version does not \
                           present every account type with posted entries as at this instant — \
                           refused rather than silently dropping a sub-book from a face that \
                           would still balance), or `tenant_mismatch`.",
            body = ErrorBody
        ),
        (
            status = 400,
            description = "A required query parameter is missing, or a value would not \
                           deserialize into its documented type. `type` is `invalid_request`.",
            body = ErrorBody
        ),
        (
            status = 503,
            description = "The report exceeded this deployment's `statement_timeout` (`57014`). \
                           `type` is `report_timed_out`.",
            body = ErrorBody
        ),
        (
            status = 500,
            description = "The report failed. `type` is `internal`.",
            body = ErrorBody
        ),
    ),
)]
pub(crate) async fn get_balance_sheet<L, R>(
    State(state): State<crate::AppState<L, R>>,
    Params(params): Params<BalanceSheetParams>,
) -> Response
where
    L: Ledger,
    R: Reports,
{
    let query = match balance_sheet_query(params) {
        Ok(query) => query,
        Err(refused) => return refused.into_response(),
    };
    match state.reports.balance_sheet(&query).await {
        Ok(statement) => answer_the_face(statement),
        Err(refused) => refusal_for_read(refused),
    }
}

/// Read the income statement over a half-open effective range.
#[utoipa::path(
    get,
    path = "/v1/reports/income-statement",
    operation_id = "getIncomeStatement",
    tag = "reports",
    params(IncomeStatementParams),
    responses(
        (
            status = 200,
            description = "The statement, the chart version it was presented at, and the cursor \
                           it was pinned at. An unknown tenant answers 200 with an empty list, \
                           never 404 (ADR-0019).",
            body = StatementRead
        ),
        (
            status = 422,
            description = "Refused. `type` is one of: `invalid_request` (an `effective_from` or \
                           `effective_to` that is not an RFC 3339 instant, or a `cursor` that \
                           is not an `xid8`), `cursor_invalid` (a legal `xid8` outside the \
                           plausible range), `chart_version_unknown`, \
                           `chart_version_incomplete` (the version does not present every \
                           account type with posted entries in this window), or \
                           `tenant_mismatch`.",
            body = ErrorBody
        ),
        (
            status = 400,
            description = "A required query parameter is missing, or a value would not \
                           deserialize into its documented type. `type` is `invalid_request`.",
            body = ErrorBody
        ),
        (
            status = 503,
            description = "The report exceeded this deployment's `statement_timeout` (`57014`). \
                           `type` is `report_timed_out`.",
            body = ErrorBody
        ),
        (
            status = 500,
            description = "The report failed. `type` is `internal`.",
            body = ErrorBody
        ),
    ),
)]
pub(crate) async fn get_income_statement<L, R>(
    State(state): State<crate::AppState<L, R>>,
    Params(params): Params<IncomeStatementParams>,
) -> Response
where
    L: Ledger,
    R: Reports,
{
    let query = match income_statement_query(params) {
        Ok(query) => query,
        Err(refused) => return refused.into_response(),
    };
    match state.reports.income_statement(&query).await {
        Ok(statement) => answer_the_face(statement),
        Err(refused) => refusal_for_read(refused),
    }
}

/// The half-open effective range, parsed once — both report routes that take
/// a range take the same two parameters under the same two names, and a
/// second parsing site is a second place for them to drift.
fn effective_range(from: &str, to: &str) -> Result<(OffsetDateTime, OffsetDateTime), Refusal> {
    Ok((
        instant("effective_from", from)?,
        instant("effective_to", to)?,
    ))
}

fn trial_balance_query(params: TrialBalanceParams) -> Result<ledger::TrialBalanceQuery, Refusal> {
    let (effective_from, effective_to) =
        effective_range(&params.effective_from, &params.effective_to)?;
    Ok(ledger::TrialBalanceQuery {
        tenant_id: params.tenant_id,
        effective_from,
        effective_to,
        cursor: params.cursor,
    })
}

fn balance_sheet_query(params: BalanceSheetParams) -> Result<ledger::BalanceSheetQuery, Refusal> {
    Ok(ledger::BalanceSheetQuery {
        tenant_id: params.tenant_id,
        as_of: instant("as_of", &params.as_of)?,
        cursor: params.cursor,
        chart_version: params.chart_version,
    })
}

fn income_statement_query(
    params: IncomeStatementParams,
) -> Result<ledger::IncomeStatementQuery, Refusal> {
    let (effective_from, effective_to) =
        effective_range(&params.effective_from, &params.effective_to)?;
    Ok(ledger::IncomeStatementQuery {
        tenant_id: params.tenant_id,
        effective_from,
        effective_to,
        cursor: params.cursor,
        chart_version: params.chart_version,
    })
}

/// One account's balance on the wire. `as_of` is the constant `now` rather
/// than a value read from anywhere: this endpoint reads the cache, the cache
/// means POSTED (ADR-0010), and the field says which question was answered.
fn answer_the_balance(balance: ledger::AccountBalance) -> Response {
    axum::Json(AccountBalanceRead {
        account_id: balance.account_id,
        currency: balance.currency,
        posted_minor: balance.posted_minor,
        as_of: "now",
    })
    .into_response()
}

/// The trial balance on the wire, with the cursor it ran at — which the read
/// path answers with on all three report routes, whether the caller supplied
/// one or not.
fn answer_the_trial_balance(report: ledger::TrialBalance) -> Response {
    axum::Json(TrialBalanceRead {
        pinned_cursor: report.pinned_cursor.to_string(),
        rows: report
            .rows
            .into_iter()
            .map(|row| TrialBalanceRowRead {
                account_id: row.account_id,
                purpose: row.purpose,
                category: row.category,
                currency: row.currency,
                debits: row.debits,
                credits: row.credits,
                balance_debit_positive: row.balance_debit_positive,
            })
            .collect(),
    })
    .into_response()
}

/// A statement face on the wire. One renderer for both statements, because
/// both functions return the same columns and two renderings could disagree
/// about which.
fn answer_the_face(statement: ledger::Statement) -> Response {
    axum::Json(StatementRead {
        pinned_cursor: statement.pinned_cursor.to_string(),
        chart_version: statement.chart_version,
        lines: statement
            .lines
            .into_iter()
            .map(|line| StatementLineRead {
                currency: line.currency,
                fs_line: line.fs_line,
                caption: line.caption,
                sort_order: line.sort_order,
                amount_minor: line.amount_minor,
                side: line.side,
            })
            .collect(),
    })
    .into_response()
}
