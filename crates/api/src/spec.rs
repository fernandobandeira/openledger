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
        description = "The write path of OpenLedger, an open-source double-entry ledger on \
                       PostgreSQL. One endpoint while the core structure is under review: \
                       posting a transaction, under the idempotent replay contract of \
                       ADR-0013 — the same key with the same body returns the stored result, \
                       marked by the `Idempotency-Replayed` header.",
        license(name = "MIT", identifier = "MIT"),
    ),
    paths(crate::transactions::post_transaction),
    tags(
        (name = "transactions", description = "The write path.")
    ),
)]
struct ApiDoc;
