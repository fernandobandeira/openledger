//! The pure hexagon core's entities and value objects: the posting types,
//! their validation, the canonical byte form the idempotency hash is computed
//! over, and the versioned payload rendering the event log stores. The
//! posting math the writer runs between its SQL statements lives next door in
//! `postings`.
//!
//! Nothing here imports `sqlx` — that property is the point of the module, not
//! an accident of what happened to land in it. Everything in this file is
//! constructible, checkable and hashable without a database in the room, which
//! is what makes an unbalanced transaction *unconstructible* rather than
//! refused by a layer further down (ADR-0005).

use sha2::{Digest, Sha256};
use time::OffsetDateTime;
use time::format_description::well_known::Rfc3339;
use uuid::Uuid;

/// A movement of money: an amount leaves `source` and arrives at `destination`.
/// Two equal sides by construction — the caller cannot express one dangling leg,
/// so an unbalanced transaction is unconstructible rather than refused
/// (ADR-0005). The fields are private and there is no `Default`; `new` is the
/// only door.
// Fields are `pub(crate)`: readable by `postings::expand_postings` and the
// payload rendering below, still unconstructible and unwritable outside this
// crate — `new` stays the only door. The Postgres adapter (its own crate
// since the deny.toml capability map) sees postings only through that
// expansion.
pub struct Posting {
    pub(crate) source: Uuid,
    pub(crate) destination: Uuid,
    pub(crate) amount_minor: i64,
    pub(crate) currency: String,
}

impl Posting {
    pub fn new(
        source: Uuid,
        destination: Uuid,
        amount_minor: i64,
        currency: String,
    ) -> Result<Self, Invalid> {
        if amount_minor <= 0 {
            return Err(Invalid::new("amount_minor must be positive"));
        }
        // ISO 4217 is uppercase; 'usd' and 'USD' must not be two currencies.
        // The same rule the schema states in ck_entries__currency_iso.
        if currency.len() != 3 || !currency.bytes().all(|b| b.is_ascii_uppercase()) {
            return Err(Invalid::new(
                "currency must be three uppercase ASCII letters",
            ));
        }
        // pgledger's rule, adopted: a self-transfer nets to zero by definition
        // and records nothing an account history can use.
        if source == destination {
            return Err(Invalid::new("source and destination are the same account"));
        }
        Ok(Self {
            source,
            destination,
            amount_minor,
            currency,
        })
    }
}

/// Whether the transaction lands on the books or is a claim about what may
/// happen — the schema's `ledger_txn_status`, in the domain's own type. Two
/// variants and no catch-all, so a third status is a compile error rather
/// than a transaction silently posted. Status NEVER mutates (the baseline's
/// own words on `ledger_transactions.status`): a pending transaction becomes
/// posted by a NEW transaction carrying `resolves_id`, never by an UPDATE
/// (roadmap M3, ADR-0016). The SQL string (`'pending'`/`'posted'`) is
/// rendered by the adapter at its bind site; the canonical form the hash
/// covers is rendered here, beside the hash.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TransactionStatus {
    Pending,
    Posted,
}

impl TransactionStatus {
    /// The status word the canonical byte form covers — owned here, beside
    /// the hash that consumes it, so a rename in Rust cannot move it.
    fn canonical(self) -> &'static str {
        match self {
            Self::Pending => "pending",
            Self::Posted => "posted",
        }
    }
}

/// The cap on the two caller-chosen identity strings, in bytes. They land
/// together in the `(tenant_id, idempotency_key)` btree unique index, and
/// PostgreSQL refuses btree index rows past roughly 2704 bytes (a third of an
/// 8KB page) — at insert time, as an error the caller would see as a 500.
/// 512 bytes each keeps the pair, plus tuple overhead, far under that limit,
/// and is far beyond any honest key or tenant name.
const MAX_IDENTITY_BYTES: usize = 512;

/// One accepted operation: post these movements atomically under this
/// idempotency key, or return the stored result of having done so.
// `pub(crate)` for the same reason as `Posting`'s fields; the adapter crate
// reads through the accessors below.
pub struct PostTransaction {
    pub(crate) tenant_id: String,
    pub(crate) idempotency_key: String,
    /// `None` only for a reversal, where omission means "the target's own
    /// effective_at" — the writer's statement fills it from the target
    /// (ADR-0016's soft convention). Every other shape requires it.
    pub(crate) effective_at: Option<OffsetDateTime>,
    pub(crate) status: TransactionStatus,
    pub(crate) resolves_id: Option<Uuid>,
    /// The transaction this one reverses. A reversing command carries NO
    /// postings — the writer derives the mirror (posted target) or the
    /// zero-posting void marker (pending target) from the target itself.
    pub(crate) reverses_id: Option<Uuid>,
    pub(crate) postings: Vec<Posting>,
}

/// The contract the two identity strings — `tenant_id` and
/// `idempotency_key` — share, in one place so the fields cannot drift: no
/// NUL byte (PostgreSQL's text type cannot store one — without this check
/// the refusal would arrive from the driver, as a 500 with the reason
/// buried in an encoding error instead of named here), and the byte cap
/// (MAX_IDENTITY_BYTES' comment carries the index-row arithmetic).
fn validate_identity(
    value: &str,
    nul_bytes: &'static str,
    too_long: &'static str,
) -> Result<(), Invalid> {
    if value.contains('\0') {
        return Err(Invalid::new(nul_bytes));
    }
    if value.len() > MAX_IDENTITY_BYTES {
        return Err(Invalid::new(too_long));
    }
    Ok(())
}

impl PostTransaction {
    pub fn new(
        tenant_id: String,
        idempotency_key: String,
        effective_at: Option<OffsetDateTime>,
        status: TransactionStatus,
        resolves_id: Option<Uuid>,
        reverses_id: Option<Uuid>,
        postings: Vec<Posting>,
    ) -> Result<Self, Invalid> {
        // A resolution IS the posted half of pending → posted (roadmap M3):
        // a pending transaction that "resolves" another would retire the
        // target from the pending population (recon_pending_bridge excludes
        // it by reference) while its replacement is still only a claim — a
        // book no bridge could foot. The schema does not refuse the shape;
        // this constructor does (ADR-0016).
        if resolves_id.is_some() && status == TransactionStatus::Pending {
            return Err(Invalid::new(
                "a resolving transaction cannot itself be pending",
            ));
        }
        // The reversal shape (ADR-0016, Reversals and the void), held whole
        // at the door. One pointer per transaction — `ck_txn__not_both`'s
        // rule, refused here with a name instead of a constraint error. A
        // pending "reversal" would retire its target from the pending
        // population while its own legs join it — one request moving the
        // population twice. And a reversal derives its postings from the
        // target (posted → the mirror, pending → the zero-posting void), so
        // caller-restated legs are pure failure surface, refused outright.
        if reverses_id.is_some() {
            if resolves_id.is_some() {
                return Err(Invalid::new(
                    "a transaction cannot both resolve and reverse another",
                ));
            }
            if status == TransactionStatus::Pending {
                return Err(Invalid::new(
                    "a reversing transaction cannot itself be pending",
                ));
            }
            if !postings.is_empty() {
                return Err(Invalid::new(
                    "a reversal derives its postings from its target; the request must not carry postings",
                ));
            }
        }
        if tenant_id.trim().is_empty() {
            return Err(Invalid::new("tenant_id must not be blank"));
        }
        if idempotency_key.is_empty() {
            return Err(Invalid::new("idempotency_key must not be empty"));
        }
        // Both identity strings live under the one contract
        // `validate_identity` holds; each caller names its own refusals
        // (`Invalid` carries a &'static str, so the messages cannot be
        // formatted in).
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
        if reverses_id.is_none() && postings.is_empty() {
            return Err(Invalid::new("postings must not be empty"));
        }
        // Optional ONLY for a reversal, where omission means "the target's
        // own effective_at" and the statement fills it in (ADR-0016's soft
        // convention). Everywhere else, absence is a refusal, not a default:
        // the effective date is the caller's claim about when money moved,
        // and the writer will not invent one.
        if reverses_id.is_none() && effective_at.is_none() {
            return Err(Invalid::new(
                "effective_at is required unless the request is a reversal",
            ));
        }
        // Finite (ck_txn__effective_finite) and RFC 3339-renderable AFTER the
        // UTC normalization the canonical hash performs — the range check
        // must run on the normalized instant, not the caller's rendering:
        // `9999-12-31T23:00:00-05:00` is year 9999 where it stands and year
        // 10000 in UTC, and a bare `to_offset` on it aborts the process (the
        // time crate panics past its representable range). `checked_to_offset`
        // is the non-aborting form; `None` means the normalization itself
        // left the representable years.
        if let Some(effective_at) = effective_at {
            let utc = effective_at
                .checked_to_offset(time::UtcOffset::UTC)
                .ok_or_else(|| {
                    Invalid::new("effective_at must fall between year 1 and 9999 UTC")
                })?;
            if !(1..=9999).contains(&utc.year()) {
                return Err(Invalid::new(
                    "effective_at must fall between year 1 and 9999 UTC",
                ));
            }
        }
        Ok(Self {
            tenant_id,
            idempotency_key,
            effective_at,
            status,
            resolves_id,
            reverses_id,
            postings,
        })
    }

    /// The canonical byte form the idempotency hash is computed over. Owned by
    /// the writer and versioned, per ADR-0013's closing warning: Formance hashes
    /// its language-level JSON encoding, which couples every stored hash to
    /// field names — renaming a field silently invalidates all of them. This
    /// form names no fields: a version tag, then each value length-prefixed, so
    /// no concatenation of values is ambiguous and a rename cannot touch it.
    fn canonical_bytes(&self) -> Result<Vec<u8>, Invalid> {
        fn put(buf: &mut Vec<u8>, bytes: &[u8]) {
            buf.extend_from_slice(&(bytes.len() as u64).to_le_bytes());
            buf.extend_from_slice(bytes);
        }
        let mut buf = Vec::new();
        // The layout covers EVERY semantic field — status and resolves_id
        // included (below), or a same-key retry that changed only its status
        // would silently REPLAY instead of being refused as a reused key;
        // the e2e reuse tests hold that red on the wire. Still the v1 tag:
        // pre-v0.1 the canonical layout changes freely under the one tag,
        // because no kept database exists to hold bytes an older binary
        // wrote — versioning ceremony begins at launch, not before.
        buf.extend_from_slice(b"openledger.post.v1");
        put(&mut buf, self.tenant_id.as_bytes());
        // Normalized to UTC before formatting: "12:00+02:00" and "10:00Z" are
        // the same instant and must hash the same, or a genuine retry through a
        // client that re-renders its timestamps is refused as poisoned. `new`
        // already validated this exact normalization, so both failure arms are
        // belt over that check, not a live path. An OMITTED effective_at (a
        // reversal deferring to its target's) hashes as zero bytes under the
        // length prefix — so a retry that spells out the very date the default
        // would have chosen is a DIFFERENT request, refused as key reuse: the
        // hash covers what the caller said, never what the server derived.
        match self.effective_at {
            Some(effective_at) => {
                let effective = effective_at
                    .checked_to_offset(time::UtcOffset::UTC)
                    .ok_or_else(|| {
                        Invalid::new("effective_at must fall between year 1 and 9999 UTC")
                    })?
                    .format(&Rfc3339)
                    .map_err(|_| Invalid::new("effective_at is not representable"))?;
                put(&mut buf, effective.as_bytes());
            }
            None => put(&mut buf, b""),
        }
        put(&mut buf, self.status.canonical().as_bytes());
        // A missing target is zero bytes under the length prefix — distinct
        // from every real uuid's sixteen, so absence cannot collide with a
        // value. Both pointers are covered: a key reused with a different —
        // or dropped — target is a different request.
        match self.resolves_id {
            Some(resolves_id) => put(&mut buf, resolves_id.as_bytes()),
            None => put(&mut buf, b""),
        }
        match self.reverses_id {
            Some(reverses_id) => put(&mut buf, reverses_id.as_bytes()),
            None => put(&mut buf, b""),
        }
        buf.extend_from_slice(&(self.postings.len() as u64).to_le_bytes());
        for posting in &self.postings {
            buf.extend_from_slice(posting.source.as_bytes());
            buf.extend_from_slice(posting.destination.as_bytes());
            buf.extend_from_slice(&posting.amount_minor.to_le_bytes());
            put(&mut buf, posting.currency.as_bytes());
        }
        Ok(buf)
    }

    /// The SHA-256 over `canonical_bytes` — computed here, beside the form it
    /// is computed over, so the two cannot drift apart. The adapter stores it;
    /// it never derives it.
    pub fn idempotency_hash(&self) -> Result<Vec<u8>, Invalid> {
        Ok(Sha256::digest(self.canonical_bytes()?).to_vec())
    }

    /// The event payload the writer stores beside the claim — the command,
    /// rendered field-by-field HERE, versioned, never by a derived
    /// `Serialize`: the same ADR-0013 closing warning `canonical_bytes`
    /// carries applies to the stored rendering too — Formance stores its
    /// language-level JSON encoding, which couples every stored artifact to
    /// field names a refactor can silently move. This function is the one
    /// place the stored shape is decided, so a Rust-side rename cannot touch
    /// it without editing the string literals below.
    ///
    /// `version` is the marker a future reader dispatches on — and it stays
    /// 1 while the shape grows fields: pre-v0.1 the stored shape changes
    /// freely under the one marker, because no kept database exists to hold
    /// a rendering an older binary wrote; versioning ceremony begins at
    /// launch (the same license the ADR-0003 baseline freeze took).
    /// `effective_at` stays the caller's own offset rendering; the UTC
    /// normalization belongs to the hash, not the payload.
    pub(crate) fn payload(&self) -> Result<serde_json::Value, Invalid> {
        // Null when the caller omitted it (a reversal deferring to its
        // target's date): the payload records what the CALLER said, so a
        // replay-from-payload re-derives the default rather than freezing it.
        let effective = self
            .effective_at
            .map(|effective_at| {
                effective_at
                    .format(&Rfc3339)
                    .map_err(|_| Invalid::new("effective_at is not representable"))
            })
            .transpose()?;
        let postings: Vec<serde_json::Value> = self
            .postings
            .iter()
            .map(|posting| {
                serde_json::json!({
                    "source": posting.source,
                    "destination": posting.destination,
                    "amount_minor": posting.amount_minor,
                    "currency": posting.currency,
                })
            })
            .collect();
        Ok(serde_json::json!({
            "version": 1,
            "tenant_id": self.tenant_id,
            "idempotency_key": self.idempotency_key,
            "effective_at": effective,
            // Always present, the pointers as explicit nulls when absent: a
            // reader never has to ask whether a missing key means "posted"
            // or "not rendered".
            "status": self.status.canonical(),
            "resolves_id": self.resolves_id,
            "reverses_id": self.reverses_id,
            "postings": postings,
        }))
    }

    // Read access for the adapter crate: the fields stay unwritable and the
    // type unconstructible outside `new` — these give the writer its binds
    // without opening the door.
    pub fn tenant_id(&self) -> &str {
        &self.tenant_id
    }
    pub fn idempotency_key(&self) -> &str {
        &self.idempotency_key
    }
    /// `None` only on a reversal that defers to its target's date — the
    /// adapter binds it nullable and the statement COALESCEs from the target.
    pub fn effective_at(&self) -> Option<OffsetDateTime> {
        self.effective_at
    }
    pub fn status(&self) -> TransactionStatus {
        self.status
    }
    pub fn resolves_id(&self) -> Option<Uuid> {
        self.resolves_id
    }
    pub fn reverses_id(&self) -> Option<Uuid> {
        self.reverses_id
    }
    pub fn postings(&self) -> &[Posting] {
        &self.postings
    }
}

/// The stored result of an accepted operation, ADR-0013's replay contract:
/// `(event_id, transaction_id)`, re-rendered by the caller — never a cached
/// response body. `transaction_id` stays an `Option` because most accepted
/// operations write no transaction at all (ADR-0005); this endpoint always
/// does, but a replay reads whatever was stored.
pub struct Posted {
    pub event_id: Uuid,
    pub transaction_id: Option<Uuid>,
    pub replayed: bool,
}

/// A request the writer refuses before touching the database.
#[derive(Debug)]
pub struct Invalid(&'static str);

impl Invalid {
    pub(crate) fn new(detail: &'static str) -> Self {
        Self(detail)
    }
    pub fn detail(&self) -> &'static str {
        self.0
    }
}

#[cfg(test)]
mod tests {
    //! The constructors' refusals that only exist to keep a can't-happen
    //! path can't-happen: the effective_at range check runs on the UTC
    //! NORMALIZATION (the value the hash formats — checking the caller's
    //! rendering let `to_offset` abort the process), the identity strings
    //! are refused before PostgreSQL would refuse them worse (NUL, the
    //! btree-index byte cap), and the stored payload is the versioned shape
    //! this file owns. The everyday refusals (zero amount, self-posting,
    //! non-ISO currency) are held on the wire by the e2e suite; an
    //! UNBALANCED transaction needs no test anywhere — `Posting` makes it
    //! unconstructible (ADR-0005).

    use super::*;

    fn posting() -> Result<Posting, Invalid> {
        Posting::new(
            Uuid::from_u128(1),
            Uuid::from_u128(2),
            100,
            "USD".to_owned(),
        )
    }

    fn command_at(effective_at: OffsetDateTime) -> Result<PostTransaction, Invalid> {
        PostTransaction::new(
            "acme".to_owned(),
            "key-1".to_owned(),
            Some(effective_at),
            TransactionStatus::Posted,
            None,
            None,
            vec![posting()?],
        )
    }

    /// The C1 reproduction: year 9999 in the caller's offset, year 10000 in
    /// UTC. Before the normalized-year check this PANICKED in
    /// `canonical_bytes` (`to_offset` aborts past the representable range);
    /// now the constructor refuses it with the honest message.
    #[test]
    fn an_effective_at_that_leaves_year_9999_under_utc_normalization_is_refused()
    -> Result<(), Box<dyn std::error::Error>> {
        let last_hour = OffsetDateTime::parse("9999-12-31T23:00:00-05:00", &Rfc3339)?;

        let refused = command_at(last_hour);

        let detail = refused.err().map(|invalid| invalid.detail());
        assert_eq!(
            detail,
            Some("effective_at must fall between year 1 and 9999 UTC"),
            "a year-10000-in-UTC effective_at must be refused"
        );
        Ok(())
    }

    /// The lower edge stays open: year 1 UTC is accepted, and its hash is
    /// computable — the refusal above must not have narrowed the range.
    #[test]
    fn the_year_one_lower_edge_stays_accepted() -> Result<(), Box<dyn std::error::Error>> {
        let first_instant = OffsetDateTime::parse("0001-01-01T00:00:00Z", &Rfc3339)?;

        let command = command_at(first_instant);

        let command = command.map_err(|invalid| invalid.detail())?;
        assert!(
            !command
                .idempotency_hash()
                .map_err(|e| e.detail())?
                .is_empty()
        );
        Ok(())
    }

    /// A NUL byte in either identity string is refused HERE: PostgreSQL's
    /// text type cannot store one, so without this check the refusal would
    /// be the driver's — a 500, not a named 422.
    #[test]
    fn a_nul_byte_in_an_identity_string_is_refused() -> Result<(), Invalid> {
        let nul_tenant = PostTransaction::new(
            "ac\0me".to_owned(),
            "key-1".to_owned(),
            Some(OffsetDateTime::UNIX_EPOCH),
            TransactionStatus::Posted,
            None,
            None,
            vec![posting()?],
        );
        let nul_key = PostTransaction::new(
            "acme".to_owned(),
            "key\0".to_owned(),
            Some(OffsetDateTime::UNIX_EPOCH),
            TransactionStatus::Posted,
            None,
            None,
            vec![posting()?],
        );

        assert!(nul_tenant.is_err(), "a NUL tenant_id must be refused");
        assert!(nul_key.is_err(), "a NUL idempotency_key must be refused");
        Ok(())
    }

    /// The byte cap: 512 bytes pass, 513 are refused — the bound that keeps
    /// the (tenant_id, idempotency_key) pair out of PostgreSQL's btree
    /// index-row limit (~2704 bytes), where the failure would be a 500.
    #[test]
    fn an_identity_string_past_512_bytes_is_refused() -> Result<(), Invalid> {
        let at_cap = PostTransaction::new(
            "acme".to_owned(),
            "k".repeat(512),
            Some(OffsetDateTime::UNIX_EPOCH),
            TransactionStatus::Posted,
            None,
            None,
            vec![posting()?],
        );
        let past_cap_key = PostTransaction::new(
            "acme".to_owned(),
            "k".repeat(513),
            Some(OffsetDateTime::UNIX_EPOCH),
            TransactionStatus::Posted,
            None,
            None,
            vec![posting()?],
        );
        let past_cap_tenant = PostTransaction::new(
            "t".repeat(513),
            "key-1".to_owned(),
            Some(OffsetDateTime::UNIX_EPOCH),
            TransactionStatus::Posted,
            None,
            None,
            vec![posting()?],
        );

        assert!(at_cap.is_ok(), "512 bytes is within the cap");
        assert!(
            past_cap_key.is_err(),
            "a 513-byte idempotency_key must be refused"
        );
        assert!(
            past_cap_tenant.is_err(),
            "a 513-byte tenant_id must be refused"
        );
        Ok(())
    }

    /// The stored shape, pinned literally: the version marker — still 1,
    /// under the pre-launch license that lets the shape grow fields freely —
    /// plus every semantic field of today's command, `status` and
    /// `resolves_id` included, with `effective_at` in the CALLER's offset
    /// (the UTC normalization belongs to the hash). A Rust-side rename
    /// cannot move this test without moving `payload` too — which is the
    /// point.
    #[test]
    fn the_payload_is_the_versioned_rendering_of_todays_fields()
    -> Result<(), Box<dyn std::error::Error>> {
        let command = command_at(OffsetDateTime::parse(
            "2026-08-27T14:00:00+02:00",
            &Rfc3339,
        )?)
        .map_err(|invalid| invalid.detail())?;

        let payload = command.payload().map_err(|invalid| invalid.detail())?;

        assert_eq!(
            payload,
            serde_json::json!({
                "version": 1,
                "tenant_id": "acme",
                "idempotency_key": "key-1",
                "effective_at": "2026-08-27T14:00:00+02:00",
                "status": "posted",
                "resolves_id": null,
                "reverses_id": null,
                "postings": [{
                    "source": Uuid::from_u128(1),
                    "destination": Uuid::from_u128(2),
                    "amount_minor": 100,
                    "currency": "USD",
                }],
            })
        );
        Ok(())
    }

    /// A pending resolution is refused by the constructor, with the honest
    /// message: the schema accepts the shape (`status` and `resolves_id` are
    /// independent columns), so this refusal exists only here — remove it
    /// and a claim-about-a-claim reaches the book (ADR-0016).
    #[test]
    fn a_pending_resolution_is_refused() -> Result<(), Invalid> {
        let refused = PostTransaction::new(
            "acme".to_owned(),
            "key-1".to_owned(),
            Some(OffsetDateTime::UNIX_EPOCH),
            TransactionStatus::Pending,
            Some(Uuid::from_u128(7)),
            None,
            vec![posting()?],
        );

        let detail = refused.err().map(|invalid| invalid.detail());

        assert_eq!(
            detail,
            Some("a resolving transaction cannot itself be pending"),
            "pending + resolves_id must be refused before any SQL"
        );
        Ok(())
    }

    /// The reversal shape, held whole at the door (ADR-0016, Reversals and
    /// the void): each illegal combination is a named constructor refusal —
    /// and the two legal reversal forms construct, `effective_at` omitted
    /// (deferring to the target's) or supplied.
    #[test]
    fn the_reversal_shape_is_held_at_the_constructor() -> Result<(), Invalid> {
        let target = Some(Uuid::from_u128(7));
        let refusals = [
            (
                // carries postings: the mirror is the server's to derive.
                PostTransaction::new(
                    "acme".to_owned(),
                    "key-1".to_owned(),
                    Some(OffsetDateTime::UNIX_EPOCH),
                    TransactionStatus::Posted,
                    None,
                    target,
                    vec![posting()?],
                ),
                "a reversal derives its postings from its target; the request must not carry postings",
            ),
            (
                // both pointers: ck_txn__not_both's rule, named here.
                PostTransaction::new(
                    "acme".to_owned(),
                    "key-1".to_owned(),
                    Some(OffsetDateTime::UNIX_EPOCH),
                    TransactionStatus::Posted,
                    Some(Uuid::from_u128(8)),
                    target,
                    vec![],
                ),
                "a transaction cannot both resolve and reverse another",
            ),
            (
                // a pending "reversal" moves the pending population twice.
                PostTransaction::new(
                    "acme".to_owned(),
                    "key-1".to_owned(),
                    Some(OffsetDateTime::UNIX_EPOCH),
                    TransactionStatus::Pending,
                    None,
                    target,
                    vec![],
                ),
                "a reversing transaction cannot itself be pending",
            ),
            (
                // ...and absence of effective_at stays a refusal OUTSIDE the
                // reversal shape: the writer will not invent a date.
                PostTransaction::new(
                    "acme".to_owned(),
                    "key-1".to_owned(),
                    None,
                    TransactionStatus::Posted,
                    None,
                    None,
                    vec![posting()?],
                ),
                "effective_at is required unless the request is a reversal",
            ),
        ];

        for (refused, expected) in refusals {
            let detail = refused.err().map(|invalid| invalid.detail());

            assert_eq!(detail, Some(expected));
        }
        // Both legal forms: date omitted (defaults to the target's in the
        // statement) and date supplied — each hashes, and the two hashes
        // DIFFER, because the hash covers what the caller said, never what
        // the server would derive.
        let deferred = PostTransaction::new(
            "acme".to_owned(),
            "key-1".to_owned(),
            None,
            TransactionStatus::Posted,
            None,
            target,
            vec![],
        )?;
        let dated = PostTransaction::new(
            "acme".to_owned(),
            "key-1".to_owned(),
            Some(OffsetDateTime::UNIX_EPOCH),
            TransactionStatus::Posted,
            None,
            target,
            vec![],
        )?;
        assert_ne!(
            deferred.idempotency_hash()?,
            dated.idempotency_hash()?,
            "an omitted and a spelled-out effective_at are different requests"
        );
        // ...and the hash covers the TARGET itself: the same key pointed at
        // a different transaction is a different request. Strip reverses_id
        // from `canonical_bytes` and these two hash identical — this assert
        // is the unit-level pin (the e2e reuse test is the wire-level one).
        let other_target = PostTransaction::new(
            "acme".to_owned(),
            "key-1".to_owned(),
            None,
            TransactionStatus::Posted,
            None,
            Some(Uuid::from_u128(8)),
            vec![],
        )?;
        assert_ne!(
            deferred.idempotency_hash()?,
            other_target.idempotency_hash()?,
            "reversals of different targets must hash differently"
        );
        Ok(())
    }
}
