//! Spike 021 — ADR-0013's write-path contract expressed with `aide` 0.15.1 (+ axum 0.8.9).
//!
//!   `cargo run --bin aide-api -- emit <path>`  writes openapi.json and exits
//!   `cargo run --bin aide-api -- serve`        serves the API on 127.0.0.1:8022
//!
//! See `src/bin/naive.rs` for what aide emits when the handler is written the
//! ordinary axum way instead of aide's way.

mod contract;

use aide::axum::routing::{get_with, post_with};
use aide::axum::ApiRouter;
use aide::generate::GenContext;
use aide::openapi::{
    Header, HeaderStyle, Info, MediaType, OpenApi, Operation, ParameterSchemaOrContent, ReferenceOr,
    Response, SchemaObject, Tag,
};
use aide::operation::OperationOutput;
use aide::transform::TransformOperation;
use axum::Json;
use axum::extract::Path;
use axum::http::{HeaderName, HeaderValue, StatusCode};
use axum::response::IntoResponse;
use indexmap::IndexMap;
use schemars::JsonSchema;
use serde::Serialize;
use uuid::Uuid;

use contract::{
    AccountBalance, AccountPath, CreateTransactionRequest, ProblemDetail, TransactionAccepted,
};

const IDEMPOTENCY_REPLAYED: HeaderName = HeaderName::from_static("idempotency-replayed");

// ------------------------------------------------------------------------
// A 201 that carries a documented response header.
//
// axum's own `(StatusCode, [(HeaderName, HeaderValue); 1], Json<T>)` is a
// tuple, and aide's `OperationOutput` impl for tuples is EMPTY (aide 0.15.1,
// src/impls/mod.rs:429 — `type Inner = Infallible;` and no method bodies), so a
// handler returning one contributes NOTHING to the spec. See src/bin/naive.rs.
// The header therefore has to travel inside a type that implements
// `OperationOutput` itself.
// ------------------------------------------------------------------------

pub struct CreatedWithReplayHeader<T> {
    pub body: T,
    pub replayed: bool,
}

impl<T: Serialize> IntoResponse for CreatedWithReplayHeader<T> {
    fn into_response(self) -> axum::response::Response {
        (
            StatusCode::CREATED,
            [(
                IDEMPOTENCY_REPLAYED,
                HeaderValue::from_static(if self.replayed { "true" } else { "false" }),
            )],
            Json(self.body),
        )
            .into_response()
    }
}

impl<T: JsonSchema> OperationOutput for CreatedWithReplayHeader<T> {
    type Inner = T;

    fn operation_response(ctx: &mut GenContext, _op: &mut Operation) -> Option<Response> {
        let body_schema = ctx.schema.subschema_for::<T>();
        let bool_schema = ctx.schema.subschema_for::<bool>();
        Some(Response {
            description: "Accepted, or replayed with the original stored result.".into(),
            headers: IndexMap::from_iter([(
                "Idempotency-Replayed".to_string(),
                ReferenceOr::Item(Header {
                    description: Some(
                        "`true` when this call replayed an existing event rather than claiming \
                         the key. The body is byte-identical either way."
                            .into(),
                    ),
                    style: HeaderStyle::Simple,
                    required: true,
                    deprecated: None,
                    format: ParameterSchemaOrContent::Schema(SchemaObject {
                        json_schema: bool_schema,
                        example: None,
                        external_docs: None,
                    }),
                    example: None,
                    examples: IndexMap::default(),
                    extensions: IndexMap::default(),
                }),
            )]),
            content: IndexMap::from_iter([(
                "application/json".to_string(),
                MediaType {
                    schema: Some(SchemaObject {
                        json_schema: body_schema,
                        example: None,
                        external_docs: None,
                    }),
                    ..Default::default()
                },
            )]),
            ..Default::default()
        })
    }

    fn inferred_responses(ctx: &mut GenContext, op: &mut Operation) -> Vec<(Option<u16>, Response)> {
        Self::operation_response(ctx, op)
            .into_iter()
            .map(|r| (Some(201), r))
            .collect()
    }
}


// ------------------------------------------- the error enum -> two responses

#[derive(Debug)]
pub enum ApiError {
    /// The idempotency key was reused with a different body. Correct the request
    /// and resend; nothing was written (ADR-0013 §2).
    PoisonedReplay(ProblemDetail),
    /// No such account in this tenant.
    UnknownAccount(ProblemDetail),
}

impl IntoResponse for ApiError {
    fn into_response(self) -> axum::response::Response {
        let (status, body) = match self {
            ApiError::PoisonedReplay(p) => (StatusCode::UNPROCESSABLE_ENTITY, p),
            ApiError::UnknownAccount(p) => (StatusCode::NOT_FOUND, p),
        };
        (status, Json(body)).into_response()
    }
}

fn problem_response(ctx: &mut GenContext, description: &str) -> Response {
    let schema = ctx.schema.subschema_for::<ProblemDetail>();
    Response {
        description: description.into(),
        content: IndexMap::from_iter([(
            "application/json".to_string(),
            MediaType {
                schema: Some(SchemaObject {
                    json_schema: schema,
                    example: None,
                    external_docs: None,
                }),
                ..Default::default()
            },
        )]),
        ..Default::default()
    }
}

impl OperationOutput for ApiError {
    type Inner = ProblemDetail;

    fn inferred_responses(
        ctx: &mut GenContext,
        _op: &mut Operation,
    ) -> Vec<(Option<u16>, Response)> {
        vec![
            (
                Some(422),
                problem_response(
                    ctx,
                    "The idempotency key was reused with a different body. Correct the request \
                     and resend; nothing was written (ADR-0013 §2).",
                ),
            ),
            (
                Some(404),
                problem_response(ctx, "No such account in this tenant."),
            ),
        ]
    }
}


// ------------------------------------------------------------------- handlers

async fn create_transaction(
    Json(req): Json<CreateTransactionRequest>,
) -> Result<CreatedWithReplayHeader<TransactionAccepted>, ApiError> {
    if req.idempotency_key == "poison" {
        return Err(ApiError::PoisonedReplay(ProblemDetail {
            kind: "idempotency_key_reused_with_different_body".into(),
            detail: "The key has already been used with a different request body.".into(),
        }));
    }
    Ok(CreatedWithReplayHeader {
        replayed: req.idempotency_key.starts_with("replay-"),
        body: TransactionAccepted {
            event_id: Uuid::nil(),
            transaction_id: req.postings.first().map(|_| Uuid::nil()),
        },
    })
}

fn create_transaction_docs(op: TransformOperation) -> TransformOperation {
    op.id("createTransaction")
        .tag("transactions")
        .summary("Record a transaction.")
        .description(
            "Claims the idempotency key and, in the same database transaction, writes what it \
             causes. A replay of the same key with the same body returns the original answer \
             and `Idempotency-Replayed: true`.",
        )
}

async fn get_account_balance(
    Path(AccountPath { id }): Path<AccountPath>,
) -> Result<Json<AccountBalance>, ApiError> {
    Ok(Json(AccountBalance {
        account_id: id,
        currency: "USD".into(),
        balance: 0,
    }))
}

fn get_account_balance_docs(op: TransformOperation) -> TransformOperation {
    op.id("getAccountBalance")
        .tag("accounts")
        .summary("Read one account's balance.")
    // NOT written here:
    //     .response_with::<200, Json<AccountBalance>, _>(|r| r.description("..."))
    // aide has ALREADY inferred the 200 from the handler's `Result<Json<AccountBalance>, _>`,
    // and describing it again makes aide report
    //     the response for status "200" already exists for the operation
    // through `generate::on_error` -- which is off by default, so without the handler
    // installed above the collision is invisible. aide keeps the explicit response and
    // discards the inferred one; the only cost is the diagnostic. See drift/RUN-drift.sh D9.
    // The description below therefore comes from the struct's doc comment instead.
}

// ------------------------------------------------------------------- the spec

fn build(api: &mut OpenApi) -> axum::Router {
    // Report anything aide cannot describe instead of dropping it silently.
    aide::generate::on_error(|e| eprintln!("aide: {e}"));
    aide::generate::extract_schemas(true);

    ApiRouter::new()
        // The path string here is the axum route; aide reads it back out of the
        // router, so there is no second copy to keep in step.
        .api_route(
            "/v1/transactions",
            post_with(create_transaction, create_transaction_docs),
        )
        .api_route(
            "/v1/accounts/{id}/balance",
            get_with(get_account_balance, get_account_balance_docs),
        )
        .finish_api_with(api, |t| {
            t.title("OpenLedger write path")
                .version("0.0.0")
                .description("Spike 021. The ADR-0013 write-path contract, generated by aide.")
                .tag(Tag {
                    name: "transactions".into(),
                    description: Some("The write path.".into()),
                    ..Default::default()
                })
                .tag(Tag {
                    name: "accounts".into(),
                    description: Some("Reads.".into()),
                    ..Default::default()
                })
        })
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut args = std::env::args().skip(1);
    match args.next().as_deref() {
        Some("emit") => {
            let out = args.next().ok_or("usage: aide-api emit <path>")?;
            let mut api = OpenApi {
                info: Info::default(),
                ..OpenApi::default()
            };
            let _router = build(&mut api);
            let mut json = serde_json::to_string_pretty(&api)?;
            json.push('\n');
            std::fs::write(&out, json)?;
            eprintln!("wrote {out}");
            Ok(())
        }
        Some("serve") => {
            let rt = tokio::runtime::Runtime::new()?;
            rt.block_on(async {
                let mut api = OpenApi::default();
                let app = build(&mut api);
                let l = tokio::net::TcpListener::bind("127.0.0.1:8022").await?;
                eprintln!("listening on http://127.0.0.1:8022");
                axum::serve(l, app).await?;
                Ok::<_, Box<dyn std::error::Error>>(())
            })
        }
        _ => Err("usage: aide-api emit <path> | serve".into()),
    }
}
