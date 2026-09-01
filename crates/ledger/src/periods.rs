//! Defining a period and closing one (ADR-0024): the two commands, their
//! validation, the canonical byte forms their idempotency hashes are computed
//! over, the versioned payloads the event log stores, and the one instant a
//! close derives — the same four things `domain` owns for a posting and
//! `accounts` owns for an opening.
//!
//! It is a module of its own for the reason `accounts` is: a period shares
//! nothing with a posting but the idempotency spine, and the spine is
//! `ledger_events` rather than a Rust type. What the two commands here DO
//! share is stated where it is shared — the identity-string contract
//! (`validate_identity`, in `domain`) is one function used four times now,
//! and the replay contract is ADR-0013 §2's, inherited whole.
//!
//! **The two commands are not symmetric, and the asymmetry is ADR-0011 §2's.**
//! Defining a period carries a CALLER's idempotency key and inherits the
//! replay contract unchanged, exactly as opening an account does (ADR-0021).
//! Closing one carries a key it DERIVES — `tenant:close:period:currency` — so
//! `uq_events__idempotency` refuses the second attempt on its own rather than
//! by a check the writer would have to remember to make. A close therefore
//! never replays: a second one is `period_already_closed`, which is the same
//! index speaking in a different sentence.
//!
//! **The zone is stored and never re-resolved** (ADR-0011 §5, ADR-0024). The
//! caller sends RESOLVED instants plus the zone as provenance; nothing here
//! accepts a local date and a zone and resolves them. A local midnight is not
//! always a real instant — `2018-11-04 00:00` in `America/Sao_Paulo` never
//! happened, and PostgreSQL resolves it silently to 01:00 — and the same pair
//! resolves an hour apart across a tzdata update. `ck_periods__tz_known` is
//! what refuses a zone the server does not recognise, and this module does not
//! second-guess it: an IANA name list in Rust would be a second tzdata, drifting
//! against the server's own.
//!
//! Nothing here imports `sqlx`, for the reason the whole crate does not.

use sha2::{Digest, Sha256};
use time::format_description::well_known::Rfc3339;
use time::{Duration, OffsetDateTime};
use uuid::Uuid;

use crate::domain::{Invalid, validate_identity};

/// One accepted operation: define this period under this idempotency key, or
/// return the stored result of having done so.
///
/// **`starts_at` and `ends_at` are instants, and `tz` is provenance** — the
/// distinction ADR-0011 §5 measured twice over. The period is half-open,
/// `[starts_at, ends_at)`, which is why a close's effective instant is
/// [`the_last_instant_inside`] rather than a `23:59:59` approximation.
#[derive(Clone)]
pub struct DefinePeriod {
    tenant_id: String,
    idempotency_key: String,
    code: String,
    starts_at: OffsetDateTime,
    ends_at: OffsetDateTime,
    tz: String,
}

impl DefinePeriod {
    pub fn new(
        tenant_id: String,
        idempotency_key: String,
        code: String,
        starts_at: OffsetDateTime,
        ends_at: OffsetDateTime,
        tz: String,
    ) -> Result<Self, Invalid> {
        if tenant_id.trim().is_empty() {
            return Err(Invalid::new("tenant_id must not be blank"));
        }
        if idempotency_key.is_empty() {
            return Err(Invalid::new("idempotency_key must not be empty"));
        }
        validate_identity(
            &tenant_id,
            "tenant_id must not contain NUL bytes",
            "tenant_id must be at most 512 bytes",
        )?;
        validate_identity(
            &idempotency_key,
            "idempotency_key must not contain NUL bytes",
            "idempotency_key must be at most 512 bytes",
        )?;
        // `code` is a LABEL, not a key of time (the column's own comment):
        // '2026-02', 'FY2026Q1'. It travels into `pk_periods` and into the
        // close's derived key, so it holds the same identity contract the
        // other two strings do.
        if code.trim().is_empty() {
            return Err(Invalid::new("code must not be blank"));
        }
        validate_identity(
            &code,
            "code must not contain NUL bytes",
            "code must be at most 512 bytes",
        )?;
        // The zone NAME is refused for shape here and for existence by
        // `ck_periods__tz_known` there — deliberately, because the set of
        // recognised zones is the SERVER's tzdata and a copy of it in Rust
        // would drift against the very database that stores the row.
        if tz.trim().is_empty() {
            return Err(Invalid::new("tz must not be blank"));
        }
        validate_identity(
            &tz,
            "tz must not contain NUL bytes",
            "tz must be at most 512 bytes",
        )?;
        // `ck_periods__non_empty`, refused by name before the constraint has
        // to speak — and an empty period is the one shape a close could not
        // give an effective instant to at all.
        if ends_at <= starts_at {
            return Err(Invalid::new("ends_at must be after starts_at"));
        }
        // Both instants are formatted into the canonical byte form, and
        // `to_offset` aborts the process outside the representable range —
        // the same check `PostTransaction::new` makes for the same reason, on
        // the UTC NORMALIZATION rather than on the caller's rendering.
        for instant in [starts_at, ends_at] {
            if instant.checked_to_offset(time::UtcOffset::UTC).is_none() {
                return Err(Invalid::new(
                    "starts_at and ends_at must fall between year 1 and 9999 UTC",
                ));
            }
        }
        Ok(Self {
            tenant_id,
            idempotency_key,
            code,
            starts_at,
            ends_at,
            tz,
        })
    }

    /// The canonical byte form the idempotency hash is computed over — the
    /// same construction the other two commands use, and for the same reason
    /// (ADR-0013's closing warning: Formance hashes its language-level JSON
    /// encoding, so a field rename silently invalidates every stored hash). It
    /// names no fields: a version tag, then each value length-prefixed.
    ///
    /// Its tag differs from a posting's, an opening's and a close's, which is
    /// what keeps the four operations' hashes in separate spaces inside the
    /// one `(tenant_id, idempotency_key)` index: the same key used for two of
    /// them is `idempotency_key_reused`, never one operation replayed as
    /// another.
    fn canonical_bytes(&self) -> Result<Vec<u8>, Invalid> {
        fn put(buf: &mut Vec<u8>, bytes: &[u8]) {
            buf.extend_from_slice(&(bytes.len() as u64).to_le_bytes());
            buf.extend_from_slice(bytes);
        }
        let mut buf = Vec::new();
        buf.extend_from_slice(b"openledger.period.v1");
        put(&mut buf, self.tenant_id.as_bytes());
        put(&mut buf, self.code.as_bytes());
        // Normalized to UTC before formatting, exactly as a posting's
        // `effective_at` is: `2026-08-01T02:00+02:00` and `2026-08-01T00:00Z`
        // are the same instant and must hash the same, or a genuine retry
        // through a client that re-renders its timestamps is refused as
        // poisoned. `new` already made both arms unreachable.
        for instant in [self.starts_at, self.ends_at] {
            let rendered = instant
                .checked_to_offset(time::UtcOffset::UTC)
                .ok_or_else(|| Invalid::new("starts_at and ends_at must be representable"))?
                .format(&Rfc3339)
                .map_err(|_| Invalid::new("starts_at and ends_at must be representable"))?;
            put(&mut buf, rendered.as_bytes());
        }
        put(&mut buf, self.tz.as_bytes());
        Ok(buf)
    }

    /// The SHA-256 over [`canonical_bytes`](Self::canonical_bytes) — computed
    /// beside the form it is computed over, so the two cannot drift.
    pub fn idempotency_hash(&self) -> Result<Vec<u8>, Invalid> {
        Ok(Sha256::digest(self.canonical_bytes()?).to_vec())
    }

    /// The event payload stored beside the claim — rendered field by field
    /// HERE and versioned, never by a derived `Serialize`, for the reason
    /// `PostTransaction::payload` gives at length: this is the one place the
    /// stored shape is decided, so a Rust-side rename cannot touch it without
    /// editing the string literals below.
    ///
    /// The instants ride as the CALLER's own rendering, not the UTC
    /// normalization — the payload records what was said and the hash records
    /// what it means, the same split a posting makes.
    pub(crate) fn payload(&self) -> Result<serde_json::Value, Invalid> {
        let mut rendered = Vec::with_capacity(2);
        for instant in [self.starts_at, self.ends_at] {
            rendered.push(
                instant
                    .format(&Rfc3339)
                    .map_err(|_| Invalid::new("starts_at and ends_at must be representable"))?,
            );
        }
        let [starts_at, ends_at] = <[String; 2]>::try_from(rendered)
            .map_err(|_| Invalid::new("starts_at and ends_at must be representable"))?;
        Ok(serde_json::json!({
            "version": 1,
            "tenant_id": self.tenant_id,
            "idempotency_key": self.idempotency_key,
            "code": self.code,
            "starts_at": starts_at,
            "ends_at": ends_at,
            "tz": self.tz,
        }))
    }

    // Read access for the adapter crate: the fields stay unwritable and the
    // type unconstructible outside `new`.
    pub fn tenant_id(&self) -> &str {
        &self.tenant_id
    }
    pub fn idempotency_key(&self) -> &str {
        &self.idempotency_key
    }
    pub fn code(&self) -> &str {
        &self.code
    }
    pub fn starts_at(&self) -> OffsetDateTime {
        self.starts_at
    }
    pub fn ends_at(&self) -> OffsetDateTime {
        self.ends_at
    }
    pub fn tz(&self) -> &str {
        &self.tz
    }
}

/// One period as `ledger_periods` holds it — the whole row, and the shape an
/// accepted definition answers with, read back from the insert's own
/// `RETURNING` (and from the replay's lookup) rather than reconstructed from
/// the request. Same rule [`crate::Account`] follows and for the same reason:
/// the instants the row carries are the ones every report will filter on.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Period {
    pub code: String,
    pub starts_at: OffsetDateTime,
    pub ends_at: OffsetDateTime,
    /// PROVENANCE, and never the boundary — whose business date this period
    /// is. The column's own comment says it: recorded so a reader can say
    /// "February in America/New_York", never re-resolved.
    pub tz: String,
}

/// The stored result of an accepted definition, ADR-0013's replay contract in
/// this operation's own shape: the event that claimed the key, and the period
/// it caused. Re-rendered by the caller on a replay — never a cached response
/// body.
pub struct PeriodDefined {
    pub event_id: Uuid,
    pub period: Period,
    pub replayed: bool,
}

/// One accepted operation: close this period, for this currency.
///
/// **It carries no idempotency key from the caller, and that is the design**
/// (ADR-0011 §2, ADR-0024). The key is derived —
/// [`idempotency_key`](Self::idempotency_key) — so two callers racing one
/// close meet on `uq_events__idempotency` and the loser is refused by the
/// index rather than by a read that could have been stale. Nothing about this
/// command is a claim the caller could vary: a close is per
/// `(tenant, period, currency)` because `pk_closes` is.
#[derive(Clone)]
pub struct ClosePeriod {
    tenant_id: String,
    period_code: String,
    currency: String,
}

impl ClosePeriod {
    pub fn new(tenant_id: String, period_code: String, currency: String) -> Result<Self, Invalid> {
        if tenant_id.trim().is_empty() {
            return Err(Invalid::new("tenant_id must not be blank"));
        }
        validate_identity(
            &tenant_id,
            "tenant_id must not contain NUL bytes",
            "tenant_id must be at most 512 bytes",
        )?;
        if period_code.trim().is_empty() {
            return Err(Invalid::new("code must not be blank"));
        }
        validate_identity(
            &period_code,
            "code must not contain NUL bytes",
            "code must be at most 512 bytes",
        )?;
        // ISO 4217 is uppercase — the same rule `Posting::new` and
        // `OpenAccount::new` hold, and `ck_closes__currency_iso` states.
        if currency.len() != 3 || !currency.bytes().all(|b| b.is_ascii_uppercase()) {
            return Err(Invalid::new(
                "currency must be three uppercase ASCII letters",
            ));
        }
        let command = Self {
            tenant_id,
            period_code,
            currency,
        };
        // The DERIVED key lands in the same btree index a caller-chosen one
        // does, so it holds the same byte cap — and it is longer than either
        // string that feeds it. Refused here by name: a tenant and a code
        // each just inside 512 bytes would otherwise reach PostgreSQL as an
        // index-row error, which is a 500 where a refusal belongs.
        validate_identity(
            &command.idempotency_key(),
            "the derived close key must not contain NUL bytes",
            "tenant_id and code are together too long for the derived close key",
        )?;
        Ok(command)
    }

    /// The deterministic idempotency key, `tenant:close:period:currency` —
    /// ADR-0011 §2's own spelling, so `uq_events__idempotency` refuses the
    /// second attempt on its own.
    ///
    /// The tenant is in the key even though the index is already per tenant.
    /// That is the ADR's construction rather than an oversight, and it costs
    /// nothing: the key is scoped by the index and named by the string, and
    /// the string is what an operator reads in `ledger_events`.
    pub fn idempotency_key(&self) -> String {
        format!(
            "{}:close:{}:{}",
            self.tenant_id, self.period_code, self.currency
        )
    }

    /// The canonical byte form, under this operation's own version tag —
    /// which is what tells a REPEATED close (the same key, the same body,
    /// answered `period_already_closed`) from a key some other operation
    /// happens to have claimed under the same string (answered
    /// `idempotency_key_reused`). Without the hash the two are one refusal.
    fn canonical_bytes(&self) -> Vec<u8> {
        fn put(buf: &mut Vec<u8>, bytes: &[u8]) {
            buf.extend_from_slice(&(bytes.len() as u64).to_le_bytes());
            buf.extend_from_slice(bytes);
        }
        let mut buf = Vec::new();
        buf.extend_from_slice(b"openledger.close.v1");
        put(&mut buf, self.tenant_id.as_bytes());
        put(&mut buf, self.period_code.as_bytes());
        put(&mut buf, self.currency.as_bytes());
        buf
    }

    /// The SHA-256 over [`canonical_bytes`](Self::canonical_bytes). It cannot
    /// fail: a close has no instant to normalize — the one it posts at is
    /// derived from the STORED period, not from anything the caller sent.
    pub fn idempotency_hash(&self) -> Vec<u8> {
        Sha256::digest(self.canonical_bytes()).to_vec()
    }

    /// The event payload stored beside the claim — the request, versioned and
    /// rendered field by field, exactly as the other three commands render
    /// theirs. It records no period bounds and no cursor: both are the
    /// database's at the moment of writing, and `ledger_period_closes` is
    /// where they have a home.
    pub(crate) fn payload(&self) -> serde_json::Value {
        serde_json::json!({
            "version": 1,
            "tenant_id": self.tenant_id,
            "idempotency_key": self.idempotency_key(),
            "period_code": self.period_code,
            "currency": self.currency,
        })
    }

    pub fn tenant_id(&self) -> &str {
        &self.tenant_id
    }
    pub fn period_code(&self) -> &str {
        &self.period_code
    }
    pub fn currency(&self) -> &str {
        &self.currency
    }
}

/// The last *representable* instant inside a half-open period — `ends_at`
/// minus one microsecond, which `timestamptz`'s microsecond resolution makes
/// exact rather than a `23:59:59` approximation (ADR-0011 §2, ADR-0024).
///
/// This is the closing transaction's `effective_at`, and it has to be inside
/// the period: `ck_closes__txn_in_period` refuses a close whose transaction is
/// dated outside `[starts_at, ends_at)`, and `ends_at` itself is the first
/// instant NOT in the period.
///
/// `None` only at the very floor of the representable range, where subtracting
/// a microsecond has no answer. The writer answers that as an internal state
/// rather than inventing a date, which is the same rule ADR-0006 holds
/// everywhere: `recorded_at` is the database's, `effective_at` is the
/// caller's, and nothing invents a third.
pub(crate) fn the_last_instant_inside(ends_at: OffsetDateTime) -> Option<OffsetDateTime> {
    ends_at.checked_sub(Duration::microseconds(1))
}

/// What a close swept out of one temporary account: the account, and the
/// DEBIT-POSITIVE position that was moved into `retained_earnings`.
///
/// Debit-positive because that is this schema's one sign convention
/// (ADR-0007 §15) — the trial balance publishes the same column — so a
/// revenue account reads negative and an expense account positive, and the
/// direction of the leg the close posted is the sign rather than a second
/// field that could disagree with it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SweptPosition {
    pub account_id: Uuid,
    pub position_minor: i64,
}

/// The stored result of an accepted close: the event that claimed the derived
/// key, the transaction that swept, the cursor its checkpoint was computed at,
/// and the position it moved out of each temporary account.
///
/// There is no `replayed` flag, unlike [`PeriodDefined`] and
/// [`crate::AccountOpened`], and its absence is the contract rather than an
/// omission: a close happens once (`pk_closes`), so the second attempt is
/// `period_already_closed` and there is no stored result to re-render.
pub struct PeriodClosed {
    pub event_id: Uuid,
    pub transaction_id: Uuid,
    pub period_code: String,
    pub currency: String,
    /// `ends_at - 1 microsecond` — [`the_last_instant_inside`], as the
    /// transaction carries it.
    pub effective_at: OffsetDateTime,
    /// `computed_at_xid`, as text. An `xid8` is 64-bit and every cursor on
    /// this surface travels as a STRING for the reason ADR-0022 gives about
    /// amounts: JSON has no integer type, and a consumer's parser rounds past
    /// 2^53 silently.
    pub computed_at_xid: String,
    /// One entry per temporary account the close moved, in account order.
    /// EMPTY is the legitimate answer for a period with nothing to sweep —
    /// migration `00004` carved the entryless close out of
    /// `recon_transaction_breaks` for exactly this, and the writer relies on
    /// the carve-out rather than refusing the case (ADR-0024).
    pub swept: Vec<SweptPosition>,
    /// How many accounts the checkpoint wrote a row for — every account with
    /// a posted entry in this currency effective before the period end, not
    /// only the temporary ones.
    pub checkpoint_rows: u64,
}

#[cfg(test)]
mod tests {
    //! The constructors' refusals, the derived key, and the one instant a
    //! close computes — all without a database in the room. What is NOT here:
    //! the zone's existence (`ck_periods__tz_known`'s, and deliberately not
    //! re-implemented in Rust) and the overlap rule (`ex_periods__no_overlap`'s,
    //! which is about OTHER rows and cannot be judged from one command).

    use super::*;

    type TestResult = Result<(), Box<dyn std::error::Error>>;

    /// A validated command, or the refusal as an error a test can `?` on —
    /// `Invalid` is not a `std::error::Error` (it is a wire refusal, not a
    /// failure), so the detail is what travels.
    fn built<T>(command: Result<T, Invalid>) -> Result<T, Box<dyn std::error::Error>> {
        command.map_err(|invalid| invalid.detail().into())
    }

    fn an_instant(text: &str) -> Result<OffsetDateTime, Box<dyn std::error::Error>> {
        Ok(OffsetDateTime::parse(text, &Rfc3339)?)
    }

    /// The definition every test varies one thing about.
    fn a_definition(starts_at: &str, ends_at: &str) -> Result<DefinePeriod, Invalid> {
        let (Ok(starts_at), Ok(ends_at)) = (
            OffsetDateTime::parse(starts_at, &Rfc3339),
            OffsetDateTime::parse(ends_at, &Rfc3339),
        ) else {
            return Err(Invalid::new("the test's own instants must parse"));
        };
        DefinePeriod::new(
            "acme".to_owned(),
            "period-2026-08".to_owned(),
            "2026-08".to_owned(),
            starts_at,
            ends_at,
            "UTC".to_owned(),
        )
    }

    #[test]
    fn a_period_that_ends_before_it_starts_is_refused() {
        let refused = a_definition("2026-09-01T00:00:00Z", "2026-08-01T00:00:00Z");

        assert_eq!(
            refused.err().map(|invalid| invalid.detail()),
            Some("ends_at must be after starts_at")
        );
    }

    #[test]
    fn a_period_of_no_duration_is_refused() {
        let refused = a_definition("2026-08-01T00:00:00Z", "2026-08-01T00:00:00Z");

        // Half-open and empty is not a period, and it is the one shape a
        // close could give no effective instant at all — `ends_at - 1
        // microsecond` would fall below `starts_at` and
        // `ck_closes__txn_in_period` would refuse it.
        assert_eq!(
            refused.err().map(|invalid| invalid.detail()),
            Some("ends_at must be after starts_at")
        );
    }

    #[test]
    fn two_renderings_of_one_boundary_hash_the_same() -> TestResult {
        let in_utc = built(a_definition("2026-08-01T00:00:00Z", "2026-09-01T00:00:00Z"))?;
        let in_another_offset = built(a_definition(
            "2026-08-01T02:00:00+02:00",
            "2026-09-01T02:00:00+02:00",
        ))?;

        let hashes_alike =
            built(in_utc.idempotency_hash())? == built(in_another_offset.idempotency_hash())?;

        // The same instant, said two ways, is the same request — a retry
        // through a client that re-renders its timestamps must replay rather
        // than be refused as poisoned.
        assert!(hashes_alike);
        Ok(())
    }

    #[test]
    fn a_period_hashes_the_zone_it_names() -> TestResult {
        let in_utc = built(a_definition("2026-08-01T00:00:00Z", "2026-09-01T00:00:00Z"))?;
        let same_instants_another_zone = built(DefinePeriod::new(
            "acme".to_owned(),
            "period-2026-08".to_owned(),
            "2026-08".to_owned(),
            an_instant("2026-08-01T00:00:00Z")?,
            an_instant("2026-09-01T00:00:00Z")?,
            "America/New_York".to_owned(),
        ))?;

        let hashes_alike = built(in_utc.idempotency_hash())?
            == built(same_instants_another_zone.idempotency_hash())?;

        // The zone is provenance and it is part of the request: the same
        // boundary claimed for a different business date is a different
        // period, refused as key reuse rather than replayed.
        assert!(!hashes_alike);
        Ok(())
    }

    #[test]
    fn the_payload_records_the_request_and_the_callers_own_rendering() -> TestResult {
        let defined = built(a_definition(
            "2026-08-01T02:00:00+02:00",
            "2026-09-01T00:00:00Z",
        ))?;

        let payload = built(defined.payload())?;

        assert_eq!(
            payload,
            serde_json::json!({
                "version": 1,
                "tenant_id": "acme",
                "idempotency_key": "period-2026-08",
                "code": "2026-08",
                "starts_at": "2026-08-01T02:00:00+02:00",
                "ends_at": "2026-09-01T00:00:00Z",
                "tz": "UTC",
            })
        );
        Ok(())
    }

    #[test]
    fn the_close_key_is_the_tenant_the_period_and_the_currency() -> TestResult {
        let closing = built(ClosePeriod::new(
            "acme".to_owned(),
            "2026-08".to_owned(),
            "USD".to_owned(),
        ))?;

        let key = closing.idempotency_key();

        // ADR-0011 §2's own spelling. It is what makes a second close of one
        // period and currency a matter for `uq_events__idempotency` rather
        // than for a check the writer would have to remember.
        assert_eq!(key, "acme:close:2026-08:USD");
        Ok(())
    }

    #[test]
    fn a_close_of_another_currency_is_another_key() -> TestResult {
        let in_dollars = built(ClosePeriod::new(
            "acme".to_owned(),
            "2026-08".to_owned(),
            "USD".to_owned(),
        ))?;
        let in_euros = built(ClosePeriod::new(
            "acme".to_owned(),
            "2026-08".to_owned(),
            "EUR".to_owned(),
        ))?;

        let keys_alike = in_dollars.idempotency_key() == in_euros.idempotency_key();

        // `pk_closes` is per currency, so closing a book that holds two is
        // two calls — and two keys, or the second would be refused as the
        // first's repeat.
        assert!(!keys_alike);
        Ok(())
    }

    #[test]
    fn a_close_hashes_the_period_it_names() -> TestResult {
        let august = built(ClosePeriod::new(
            "acme".to_owned(),
            "2026-08".to_owned(),
            "USD".to_owned(),
        ))?;
        let september = built(ClosePeriod::new(
            "acme".to_owned(),
            "2026-09".to_owned(),
            "USD".to_owned(),
        ))?;

        let hashes_alike = august.idempotency_hash() == september.idempotency_hash();

        // The hash is what tells `period_already_closed` from
        // `idempotency_key_reused` when the derived key is found held, so two
        // closes must not share one.
        assert!(!hashes_alike);
        Ok(())
    }

    #[test]
    fn a_currency_that_is_not_three_uppercase_letters_is_refused() {
        let refused = ClosePeriod::new("acme".to_owned(), "2026-08".to_owned(), "usd".to_owned());

        assert_eq!(
            refused.err().map(|invalid| invalid.detail()),
            Some("currency must be three uppercase ASCII letters")
        );
    }

    #[test]
    fn a_tenant_and_a_code_too_long_for_the_derived_key_are_refused_by_name() {
        let refused = ClosePeriod::new("t".repeat(400), "p".repeat(400), "USD".to_owned());

        // Each string is inside its own 512-byte cap; the key they compose is
        // not. Refused here, or PostgreSQL refuses the index row as a 500.
        assert_eq!(
            refused.err().map(|invalid| invalid.detail()),
            Some("tenant_id and code are together too long for the derived close key")
        );
    }

    #[test]
    fn the_closing_instant_is_one_microsecond_inside_the_period() -> TestResult {
        let ends_at = an_instant("2026-09-01T00:00:00Z")?;

        let closes_at = the_last_instant_inside(ends_at);

        // The last REPRESENTABLE instant inside a half-open period, which is
        // what makes it exact rather than a 23:59:59 approximation
        // (ADR-0011 §2) — and what keeps it under
        // `ck_closes__txn_in_period`, whose upper bound is exclusive.
        assert_eq!(closes_at, Some(an_instant("2026-08-31T23:59:59.999999Z")?));
        Ok(())
    }
}
