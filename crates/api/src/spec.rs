//! The OpenAPI document — assembled here, emitted by [`openapi_json`],
//! committed as `crates/api/openapi.json`, and held against both the
//! annotations (`tests/spec.rs`) and the live router (the e2e conformance
//! test).

use utoipa::OpenApi;

/// The whole OpenAPI document, pretty-printed with a trailing newline — the
/// exact bytes of `crates/api/openapi.json`. `tests/spec.rs` regenerates and
/// compares; the e2e conformance test replays it against a live server.
pub fn openapi_json() -> Result<String, serde_json::Error> {
    let mut json = ApiDoc::openapi().to_pretty_json()?;
    json.push('\n');
    Ok(json)
}

/// The document. `info` is filled in deliberately — spike 021 found utoipa
/// emitting `"license": {"name": ""}` into the rendered output when the
/// license is omitted, and an empty `License:` heading in a committed artifact
/// is the kind of lie this project organises against.
#[derive(OpenApi)]
#[openapi(
    info(
        title = "OpenLedger API",
        description = "OpenLedger, an open-source double-entry ledger on PostgreSQL. \
                       The write path is one endpoint under the idempotent replay contract of \
                       ADR-0013 — the same key with the same body returns the stored result, \
                       marked by the `Idempotency-Replayed` header. The read path is five, and \
                       three things about it are contract rather than presentation (ADR-0019): \
                       every report answers with the `pinned_cursor` it ran at, including when \
                       the caller supplied none, and that value is what re-runs the report; \
                       every report AMOUNT is an exact-integer decimal STRING, because a total \
                       above 2^53 would be silently rounded by a JSON parser while a posting \
                       amount, bounded by its own column, stays a number; and an unknown tenant \
                       is answered 200-with-nothing rather than 404, because nothing in the \
                       schema declares a tenant and inventing the status would mean inventing \
                       the registry.",
        license(name = "MIT", identifier = "MIT"),
    ),
    paths(
        crate::transactions::post_transaction,
        crate::transactions::get_transaction,
        crate::accounts::open_account,
        crate::accounts::list_accounts,
        crate::reports::get_account_balance,
        crate::reports::get_trial_balance,
        crate::reports::get_balance_sheet,
        crate::reports::get_income_statement,
    ),
    tags(
        (name = "transactions", description = "Post a transaction, and read one back."),
        (name = "accounts", description = "Open an account, list them, and read one's posted \
                                           balance."),
        (name = "reports", description = "The pinned reports: both time axes, by parameter."),
    ),
)]
struct ApiDoc;
