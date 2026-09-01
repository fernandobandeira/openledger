//! The refusal shape, and the three extractors that keep every refusal on
//! this surface wearing it.
//!
//! ADR-0014's rule is that `type` is stable and machine-readable and `detail`
//! is not. axum's own rejections do not know that: a broken body, a missing
//! query parameter and a path segment that is not a UUID all render axum's
//! default plain-text bodies, which are not the [`ErrorBody`] the spec
//! documents. The wrappers below keep the STATUS axum chose — it is the right
//! one — and re-render the message, so a caller can parse every refusal the
//! same way whether it came from the writer, from a report, or from axum's
//! deserializer.

use axum::extract::{FromRequest, FromRequestParts, Path, Query, Request};
use axum::http::StatusCode;
use axum::http::request::Parts;
use axum::response::{IntoResponse, Response};
use serde::Serialize;
use utoipa::ToSchema;

/// The error body: a stable machine-readable `type`, prose in `detail`.
#[derive(Serialize, ToSchema)]
pub(crate) struct ErrorBody {
    /// Stable machine-readable identifier. Parse this, never `detail`.
    #[schema(example = "invalid_request")]
    r#type: &'static str,
    /// Human-readable explanation. Not stable; do not parse.
    detail: String,
}

pub(crate) fn refuse(status: StatusCode, r#type: &'static str, detail: String) -> Response {
    Refusal {
        status,
        r#type,
        detail,
    }
    .into_response()
}

/// A refusal before it is a response — the same three fields [`refuse`]
/// renders, carried as a value.
///
/// It exists because a refusal sometimes has to TRAVEL: the read handlers
/// parse an instant and a cursor's text before they call a port, and a helper
/// that does the parsing has to hand back either the value or the refusal. An
/// `axum::Response` in a `Result`'s `Err` is 128 bytes and
/// `clippy::result_large_err` refuses it — correctly, since every caller of
/// such a helper pays for the big variant on the happy path. So the diagnosis
/// travels small and becomes a response once, at the handler.
pub(crate) struct Refusal {
    status: StatusCode,
    r#type: &'static str,
    detail: String,
}

impl Refusal {
    pub(crate) fn new(status: StatusCode, r#type: &'static str, detail: String) -> Self {
        Self {
            status,
            r#type,
            detail,
        }
    }

    /// The prose this refusal carries, for a unit test that holds WHICH
    /// refusal a parse produced. `#[cfg(test)]` because nothing in the
    /// shipped surface reads a refusal back — a refusal is rendered once and
    /// travels no further — and an accessor nobody calls is dead code the
    /// workspace's lints would rightly complain about.
    #[cfg(test)]
    pub(crate) fn detail(&self) -> &str {
        &self.detail
    }
}

impl IntoResponse for Refusal {
    fn into_response(self) -> Response {
        (
            self.status,
            axum::Json(ErrorBody {
                r#type: self.r#type,
                detail: self.detail,
            }),
        )
            .into_response()
    }
}

/// `axum::Json`, wearing the documented refusal shape: axum's own body
/// rejections (syntax, wrong type, missing content-type, oversized) render
/// its default plain-text bodies. This wrapper keeps the status axum chose —
/// 400 for broken JSON, 413 for an oversized body, 415 for the wrong
/// `Content-Type`, 422 for a field that fails to deserialize — and
/// re-renders the message as `{type: "invalid_request", detail}`.
pub(crate) struct Body<T>(pub(crate) T);

impl<S, T> FromRequest<S> for Body<T>
where
    S: Send + Sync,
    T: serde::de::DeserializeOwned,
{
    type Rejection = Response;

    async fn from_request(req: Request, state: &S) -> Result<Self, Self::Rejection> {
        match axum::Json::<T>::from_request(req, state).await {
            Ok(axum::Json(value)) => Ok(Self(value)),
            Err(rejection) => Err(refuse(
                rejection.status(),
                "invalid_request",
                rejection.body_text(),
            )),
        }
    }
}

/// `axum::extract::Query`, wearing the same shape — the read path's
/// equivalent of [`Body`], since every read carries its `tenant_id` and its
/// range in the query string rather than in a body (ADR-0019's five routes
/// are all `GET`).
///
/// A missing required parameter, a repeated one, or one that will not
/// deserialize into its documented type is axum's 400, re-rendered as
/// `invalid_request`. What is NOT here: instants and cursors, which arrive as
/// text and are parsed one layer up, so that a malformed one is a 422 naming
/// what to fix rather than a 400 naming a serde path.
pub(crate) struct Params<T>(pub(crate) T);

impl<S, T> FromRequestParts<S> for Params<T>
where
    S: Send + Sync,
    T: serde::de::DeserializeOwned,
{
    type Rejection = Response;

    async fn from_request_parts(parts: &mut Parts, state: &S) -> Result<Self, Self::Rejection> {
        match Query::<T>::from_request_parts(parts, state).await {
            Ok(Query(value)) => Ok(Self(value)),
            Err(rejection) => Err(refuse(
                rejection.status(),
                "invalid_request",
                rejection.body_text(),
            )),
        }
    }
}

/// `axum::extract::Path`, wearing the same shape: two read routes name their
/// subject in the path, and a segment that is not a UUID is a refusal a
/// caller should be able to parse like any other.
pub(crate) struct Segment<T>(pub(crate) T);

impl<S, T> FromRequestParts<S> for Segment<T>
where
    S: Send + Sync,
    T: serde::de::DeserializeOwned + Send,
{
    type Rejection = Response;

    async fn from_request_parts(parts: &mut Parts, state: &S) -> Result<Self, Self::Rejection> {
        match Path::<T>::from_request_parts(parts, state).await {
            Ok(Path(value)) => Ok(Self(value)),
            Err(rejection) => Err(refuse(
                rejection.status(),
                "invalid_request",
                rejection.body_text(),
            )),
        }
    }
}
