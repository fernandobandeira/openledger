//! Opening an account: the command, its validation, the canonical byte form
//! its idempotency hash is computed over, and the versioned payload the event
//! log stores — the same four things `domain` owns for a posting, for the
//! operation ADR-0021 added.
//!
//! It is a module of its own rather than more of `domain` because the two
//! commands share nothing but the spine: a posting is legs and a balance, an
//! opening is one row in the account register and no money at all. What they
//! DO share is stated where it is shared — the identity-string contract
//! (`validate_identity`, in `domain`) is one function used twice, and the
//! replay contract is ADR-0013 §2's, inherited whole rather than restated.
//!
//! **The caller names a purpose and the server derives the rest**
//! (ADR-0021). `ledger_accounts` carries `category`, `normal_balance` and
//! `counterparty_scope` as COPIES of the chart row, held honest by
//! `fk_accounts__type` and `fk_accounts__scope` — so a body that stated them
//! could disagree with the chart, and the caller would be handed a foreign-key
//! error rather than an answer. [`ChartTriple`] is therefore something the
//! writer READS and never something a caller can supply: the disagreement is
//! unconstructible rather than reported (ADR-0004's preference, applied).
//!
//! Nothing here imports `sqlx`, for the reason the whole crate does not.

use sha2::{Digest, Sha256};
use time::OffsetDateTime;
use uuid::Uuid;

use crate::domain::{Invalid, validate_identity};

/// Who an account belongs to — the schema's `account_owner_type`, in the
/// domain's own type. Four variants and no catch-all, so a fifth owner kind
/// is a compile error rather than a string the database refuses at insert
/// time. `house` is the ledger's own side of a movement and is the one
/// variant that carries NO owner id; the other three name one.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AccountOwnerType {
    Company,
    Platform,
    BankAccount,
    House,
}

impl AccountOwnerType {
    /// The owner word the canonical byte form covers and the payload renders
    /// — owned here, beside the hash that consumes it, so a rename in Rust
    /// cannot move it. The adapter renders the same four words at its own
    /// bind site, exactly as it does for a transaction's status.
    pub fn canonical(self) -> &'static str {
        match self {
            Self::Company => "company",
            Self::Platform => "platform",
            Self::BankAccount => "bank_account",
            Self::House => "house",
        }
    }

    /// Whether this owner kind is the ledger's own side. The one question
    /// `ck_accounts__house_has_no_owner` asks, asked here so the writer can
    /// answer it before the constraint has to.
    pub fn is_the_house(self) -> bool {
        self == Self::House
    }
}

/// Who an account belongs to, as the request states it: an owner type, and
/// the id that goes with it.
///
/// The two travel together because the RULE that binds them is one rule —
/// `ck_accounts__house_has_no_owner`, *a house account has no owner and an
/// owned account must have one* — and the writer judges the pair rather than
/// either half.
///
/// **A plain pair and deliberately not an enum with a house variant.** An
/// enum would make the disagreeing shape unconstructible, which is normally
/// this project's preference (ADR-0004) and is the wrong answer here:
/// ADR-0021 gives that disagreement a wire name of its own,
/// `account_owner_mismatched`, and an unconstructible shape can only ever be
/// answered `invalid_request`. So the pair is constructible, and the writer
/// refuses it by name before the CHECK has to.
pub struct AccountOwner {
    pub owner_type: AccountOwnerType,
    /// `None` on a house account, and required on every other owner type.
    pub owner_id: Option<String>,
}

/// What an account type IS, as `account_types` holds it — the three columns
/// `ledger_accounts` copies and two composite foreign keys hold honest.
///
/// The writer reads this and the caller may not send it (ADR-0021): a body
/// that stated a triple disagreeing with the chart would earn
/// `fk_accounts__type`'s error, which is the database's diagnostics standing
/// in for the API's own sentence.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ChartTriple {
    pub category: String,
    pub normal_balance: String,
    /// `none`, `shared` or `per_shard`. `per_shard` is the one that decides
    /// whether a house account may hold this type at all
    /// (`ck_accounts__per_shard_is_owned`).
    pub counterparty_scope: String,
}

/// The `counterparty_scope` whose split key IS the counterparty — a type a
/// house account nets at write time, where no report can recover it
/// (ADR-0012). Spelled once, beside the check that reads it.
const PER_SHARD: &str = "per_shard";

impl ChartTriple {
    /// Whether this type may only be held in an OWNED account —
    /// `ck_accounts__per_shard_is_owned`'s rule, asked here so the writer can
    /// refuse by name before the check has to speak.
    pub fn must_be_owned(&self) -> bool {
        self.counterparty_scope == PER_SHARD
    }
}

/// The stripe-count window `ck_accounts__stripe_count` holds. A HINT and not
/// an invariant (ADR-0013 §4): a reader sums the stripe rows that exist, so
/// lowering it strands nothing and raising it needs no backfill — but the
/// column is a `smallint` with a `CHECK`, and a value outside the window is a
/// refusal the caller can act on rather than a constraint error.
const STRIPE_COUNT: std::ops::RangeInclusive<i16> = 1..=1024;

/// One accepted operation: open this account under this idempotency key, or
/// return the stored result of having done so.
///
/// **What this type does NOT hold is the point of it.** There is no
/// `category`, no `normal_balance` and no `counterparty_scope` field, because
/// the writer reads all three from `account_types` (ADR-0021) — a caller
/// cannot state them, so a caller cannot contradict the chart.
///
/// **And one shape it deliberately DOES admit**: an owner that disagrees with
/// its owner type — a house account carrying an owner, or an owned one
/// without. `Invalid` renders as `invalid_request` on the wire and ADR-0021
/// requires that refusal to be named `account_owner_mismatched`, so the check
/// lives in the writer service, where it has a name, rather than here where it
/// would only have a status. `new` is still the only door, and every refusal
/// it does make is one the wire calls `invalid_request`.
#[derive(Clone)]
pub struct OpenAccount {
    tenant_id: String,
    idempotency_key: String,
    purpose: String,
    owner_type: AccountOwnerType,
    owner_id: Option<String>,
    currency: String,
    /// `None` means "whatever the column defaults to" — one stripe. The hash
    /// covers the caller's ABSENCE rather than the resolved value, exactly as
    /// it does for a reversal's omitted date: the hash records what the caller
    /// said, never what the server derived.
    stripe_count: Option<i16>,
    /// `None` means "no metadata", which the column renders as `{}`. A value
    /// must be a JSON OBJECT: `jsonb` would happily store `3`, and a
    /// metadata field that is sometimes a scalar is a shape every reader has
    /// to defend against.
    metadata: Option<serde_json::Value>,
}

impl OpenAccount {
    pub fn new(
        tenant_id: String,
        idempotency_key: String,
        purpose: String,
        owner: AccountOwner,
        currency: String,
        stripe_count: Option<i64>,
        metadata: Option<serde_json::Value>,
    ) -> Result<Self, Invalid> {
        if tenant_id.trim().is_empty() {
            return Err(Invalid::new("tenant_id must not be blank"));
        }
        if idempotency_key.is_empty() {
            return Err(Invalid::new("idempotency_key must not be empty"));
        }
        // The two caller-chosen identity strings live under one contract, the
        // same one a posting's do — no NUL byte, and under the btree index
        // row's byte cap.
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
        // `purpose` is a foreign key into `account_types`, so an unknown one
        // is `account_type_unknown` and not this refusal — but a blank or
        // NUL-bearing one would reach the driver as an encoding error, which
        // is a 500 where a named refusal belongs.
        if purpose.trim().is_empty() {
            return Err(Invalid::new("purpose must not be blank"));
        }
        validate_identity(
            &purpose,
            "purpose must not contain NUL bytes",
            "purpose must be at most 512 bytes",
        )?;
        let AccountOwner {
            owner_type,
            owner_id,
        } = owner;
        if let Some(owner_id) = &owner_id {
            if owner_id.trim().is_empty() {
                return Err(Invalid::new("owner_id must not be blank"));
            }
            validate_identity(
                owner_id,
                "owner_id must not contain NUL bytes",
                "owner_id must be at most 512 bytes",
            )?;
        }
        // ISO 4217 is uppercase, the same rule `Posting::new` holds and
        // `ck_accounts__currency_iso` states.
        if currency.len() != 3 || !currency.bytes().all(|b| b.is_ascii_uppercase()) {
            return Err(Invalid::new(
                "currency must be three uppercase ASCII letters",
            ));
        }
        // Out of the `smallint`'s range and out of the CHECK's window are the
        // same refusal to a caller — there is one window and one sentence for
        // missing it, so the narrowing conversion has no second failure mode
        // to invent a message for.
        let stripe_count = stripe_count
            .map(|stripes| {
                i16::try_from(stripes)
                    .ok()
                    .filter(|stripes| STRIPE_COUNT.contains(stripes))
                    .ok_or_else(|| Invalid::new("stripe_count must be between 1 and 1024"))
            })
            .transpose()?;
        // `jsonb` stores a bare `3` as happily as an object, and a metadata
        // field that is sometimes a scalar is a shape every reader downstream
        // has to defend against. One shape, refused at the door.
        if metadata.as_ref().is_some_and(|value| !value.is_object()) {
            return Err(Invalid::new("metadata must be a JSON object"));
        }
        Ok(Self {
            tenant_id,
            idempotency_key,
            purpose,
            owner_type,
            owner_id,
            currency,
            stripe_count,
            metadata,
        })
    }

    /// The canonical byte form the idempotency hash is computed over — the
    /// same construction `PostTransaction` uses and for the same reason
    /// (ADR-0013's closing warning: Formance hashes its language-level JSON
    /// encoding, so a field rename silently invalidates every stored hash).
    /// It names no fields: a version tag, then each value length-prefixed, so
    /// no concatenation of values is ambiguous.
    ///
    /// The tag differs from a posting's, which is what keeps the two
    /// operations' hashes in separate spaces even though they share one
    /// `(tenant_id, idempotency_key)` index: the same key used for both is
    /// `idempotency_key_reused`, never a posting replayed as an account.
    fn canonical_bytes(&self) -> Vec<u8> {
        fn put(buf: &mut Vec<u8>, bytes: &[u8]) {
            buf.extend_from_slice(&(bytes.len() as u64).to_le_bytes());
            buf.extend_from_slice(bytes);
        }
        let mut buf = Vec::new();
        buf.extend_from_slice(b"openledger.account.v1");
        put(&mut buf, self.tenant_id.as_bytes());
        put(&mut buf, self.purpose.as_bytes());
        put(&mut buf, self.owner_type.canonical().as_bytes());
        // Zero bytes under the length prefix for an absent owner — distinct
        // from every real owner id, so absence cannot collide with a value.
        match &self.owner_id {
            Some(owner_id) => put(&mut buf, owner_id.as_bytes()),
            None => put(&mut buf, b""),
        }
        put(&mut buf, self.currency.as_bytes());
        // The caller's ABSENCE, not the resolved default: a retry that spells
        // out the very stripe count the default would have chosen is a
        // different request, refused as key reuse. The hash covers what the
        // caller said (the same rule a reversal's omitted date follows).
        match self.stripe_count {
            Some(stripe_count) => put(&mut buf, &stripe_count.to_le_bytes()),
            None => put(&mut buf, b""),
        }
        // Metadata rides as its canonical JSON text. `serde_json::Value`'s
        // map is a `BTreeMap` by default, so the rendering is key-ordered and
        // two bodies that differ only in key order hash the same — which is
        // the right answer: they are the same request.
        match &self.metadata {
            Some(metadata) => put(&mut buf, metadata.to_string().as_bytes()),
            None => put(&mut buf, b""),
        }
        buf
    }

    /// The SHA-256 over [`canonical_bytes`](Self::canonical_bytes) — computed
    /// beside the form it is computed over, so the two cannot drift. Unlike a
    /// posting's, it cannot fail: nothing in this command needs a rendering
    /// that could refuse (there is no instant to normalize).
    pub fn idempotency_hash(&self) -> Vec<u8> {
        Sha256::digest(self.canonical_bytes()).to_vec()
    }

    /// The event payload stored beside the claim — rendered field by field
    /// HERE and versioned, never by a derived `Serialize`, for the reason
    /// `PostTransaction::payload` gives at length: this is the one place the
    /// stored shape is decided, so a Rust-side rename cannot touch it without
    /// editing the string literals below.
    ///
    /// It records the REQUEST and not the answer: no `category`, no
    /// `normal_balance`, no `counterparty_scope`, and no account id. The
    /// triple is the chart's at the moment of writing and the account id is
    /// the register's; a payload that carried either would be a second,
    /// unversioned copy of a fact that already has a home.
    pub(crate) fn payload(&self) -> serde_json::Value {
        serde_json::json!({
            "version": 1,
            "tenant_id": self.tenant_id,
            "idempotency_key": self.idempotency_key,
            "purpose": self.purpose,
            "owner_type": self.owner_type.canonical(),
            // Always present, absences as explicit nulls: a reader never has
            // to ask whether a missing key means "house" or "not rendered".
            "owner_id": self.owner_id,
            "currency": self.currency,
            "stripe_count": self.stripe_count,
            "metadata": self.metadata,
        })
    }

    // Read access for the adapter crate: the fields stay unwritable and the
    // type unconstructible outside `new`.
    pub fn tenant_id(&self) -> &str {
        &self.tenant_id
    }
    pub fn idempotency_key(&self) -> &str {
        &self.idempotency_key
    }
    pub fn purpose(&self) -> &str {
        &self.purpose
    }
    pub fn owner_type(&self) -> AccountOwnerType {
        self.owner_type
    }
    pub fn owner_id(&self) -> Option<&str> {
        self.owner_id.as_deref()
    }
    pub fn currency(&self) -> &str {
        &self.currency
    }
    /// `None` means the column's own default — the adapter binds it nullable
    /// and the statement coalesces.
    pub fn stripe_count(&self) -> Option<i16> {
        self.stripe_count
    }
    /// `None` means `{}` — the adapter binds it nullable and the statement
    /// coalesces, for the same reason.
    pub fn metadata(&self) -> Option<&serde_json::Value> {
        self.metadata.as_ref()
    }
}

/// One account as the register holds it — the whole row, and the shape both
/// verbs answer with: the listing renders it per row, and an accepted opening
/// renders exactly one.
///
/// **It carries the DERIVED triple, and that is the point of returning it at
/// all.** ADR-0021's central design is that the caller names a `purpose` and
/// the server reads `category`, `normal_balance` and `counterparty_scope` from
/// the chart — so an opening that answered two UUIDs made the one thing the
/// design is for reachable only by a second call plus a client-side scan.
/// The record is read back from the register in BOTH paths, the insert's own
/// `RETURNING` and the replay's lookup, so nothing here is this crate's
/// reconstruction of what it thinks it asked for.
///
/// **No balance**, and that is contract rather than omission (ADR-0021):
/// balances are per currency and per stripe, one per row would be N+1, and
/// `GET /v1/accounts/{id}/balance` answers that question one account at a
/// time.
#[derive(Clone, Debug, PartialEq)]
pub struct Account {
    pub account_id: Uuid,
    pub owner_type: String,
    /// `None` on a house account, which is the ledger's own side and has no
    /// owner (`ck_accounts__house_has_no_owner`).
    pub owner_id: Option<String>,
    pub purpose: String,
    pub category: String,
    pub normal_balance: String,
    pub counterparty_scope: String,
    pub currency: String,
    /// How many stripes the writer spreads this account's balance row across
    /// — a HINT and not an invariant (ADR-0013 §4). It is the one operational
    /// number on this answer, and it is here because it is the one a caller
    /// can act on: a hot account is re-opened with more stripes, never
    /// re-striped by an update.
    pub stripe_count: i16,
    /// The caller's own object, as the column holds it — `{}` when the
    /// opening named none, because the column is `NOT NULL DEFAULT '{}'`.
    /// Never an `Option`: an absent metadata and an empty one are the same
    /// row, and a reader that had to tell them apart would be defending
    /// against a distinction the schema does not make.
    pub metadata: serde_json::Value,
    pub created_at: OffsetDateTime,
}

/// The stored result of an accepted opening, ADR-0013's replay contract in
/// this operation's own shape: the event that claimed the key, and the account
/// it caused. Re-rendered by the caller on a replay — never a cached response
/// body.
///
/// `account` is NOT an `Option`, where a posting's `transaction_id` is: an
/// accepted opening always wrote an account, and a replay finds it by the
/// natural key its own body names. An event whose account cannot be found is
/// a can't-happen state the writer answers as one.
pub struct AccountOpened {
    pub event_id: Uuid,
    pub account: Account,
    pub replayed: bool,
}

#[cfg(test)]
mod tests {
    //! The constructor's refusals and the canonical form, held without a
    //! database in the room. What is NOT here: the owner-shape rule and the
    //! per-shard rule, which are the writer service's because ADR-0021 gives
    //! each of them a wire name of its own — they are held in `service`,
    //! beside the refusal they produce.

    use super::*;

    fn an_opening() -> Result<OpenAccount, Invalid> {
        OpenAccount::new(
            "acme".to_owned(),
            "open-1".to_owned(),
            "customer_receivable".to_owned(),
            AccountOwner {
                owner_type: AccountOwnerType::Company,
                owner_id: Some("co_1".to_owned()),
            },
            "USD".to_owned(),
            None,
            None,
        )
    }

    #[test]
    fn a_stripe_count_above_the_window_is_refused_rather_than_narrowed() {
        let refused = OpenAccount::new(
            "acme".to_owned(),
            "open-1".to_owned(),
            "customer_receivable".to_owned(),
            AccountOwner {
                owner_type: AccountOwnerType::Company,
                owner_id: Some("co_1".to_owned()),
            },
            "USD".to_owned(),
            Some(1025),
            None,
        );

        assert_eq!(
            refused.err().map(|invalid| invalid.detail()),
            Some("stripe_count must be between 1 and 1024")
        );
    }

    #[test]
    fn a_stripe_count_past_a_smallint_is_the_same_refusal_and_not_a_wrapped_value() {
        // 65_537 is 1 in sixteen bits: narrowed rather than refused, this
        // would open a one-striped account for a caller that asked for
        // sixty-five thousand and never hear about it.
        let refused = OpenAccount::new(
            "acme".to_owned(),
            "open-1".to_owned(),
            "customer_receivable".to_owned(),
            AccountOwner {
                owner_type: AccountOwnerType::Company,
                owner_id: Some("co_1".to_owned()),
            },
            "USD".to_owned(),
            Some(65_537),
            None,
        );

        assert_eq!(
            refused.err().map(|invalid| invalid.detail()),
            Some("stripe_count must be between 1 and 1024")
        );
    }

    #[test]
    fn metadata_that_is_not_an_object_is_refused_at_the_door() {
        let refused = OpenAccount::new(
            "acme".to_owned(),
            "open-1".to_owned(),
            "customer_receivable".to_owned(),
            AccountOwner {
                owner_type: AccountOwnerType::Company,
                owner_id: Some("co_1".to_owned()),
            },
            "USD".to_owned(),
            None,
            Some(serde_json::json!(3)),
        );

        assert_eq!(
            refused.err().map(|invalid| invalid.detail()),
            Some("metadata must be a JSON object")
        );
    }

    #[test]
    fn an_omitted_stripe_count_hashes_differently_from_the_value_it_defaults_to()
    -> Result<(), Invalid> {
        let omitted = an_opening()?;
        let spelled_out = OpenAccount::new(
            "acme".to_owned(),
            "open-1".to_owned(),
            "customer_receivable".to_owned(),
            AccountOwner {
                owner_type: AccountOwnerType::Company,
                owner_id: Some("co_1".to_owned()),
            },
            "USD".to_owned(),
            Some(1),
            None,
        )?;

        let hashes_alike = omitted.idempotency_hash() == spelled_out.idempotency_hash();

        // The hash covers what the caller SAID: a retry that started spelling
        // out the default is a different request, and it is refused as key
        // reuse rather than replayed as the same one.
        assert!(!hashes_alike);
        Ok(())
    }

    #[test]
    fn metadata_hashes_the_same_whatever_order_its_keys_arrive_in() -> Result<(), Invalid> {
        let one_way = OpenAccount::new(
            "acme".to_owned(),
            "open-1".to_owned(),
            "customer_receivable".to_owned(),
            AccountOwner {
                owner_type: AccountOwnerType::Company,
                owner_id: Some("co_1".to_owned()),
            },
            "USD".to_owned(),
            None,
            Some(serde_json::json!({"a": 1, "b": 2})),
        )?;
        let the_other = OpenAccount::new(
            "acme".to_owned(),
            "open-1".to_owned(),
            "customer_receivable".to_owned(),
            AccountOwner {
                owner_type: AccountOwnerType::Company,
                owner_id: Some("co_1".to_owned()),
            },
            "USD".to_owned(),
            None,
            Some(serde_json::json!({"b": 2, "a": 1})),
        )?;

        let hashes_alike = one_way.idempotency_hash() == the_other.idempotency_hash();

        // Two spellings of one request, so one hash — a retry through a
        // client that re-serializes its JSON must replay, not be refused.
        assert!(hashes_alike);
        Ok(())
    }

    #[test]
    fn an_opening_hashes_the_owner_and_the_purpose_it_names() -> Result<(), Invalid> {
        let opening = an_opening()?;
        let another_owner = OpenAccount::new(
            "acme".to_owned(),
            "open-1".to_owned(),
            "customer_receivable".to_owned(),
            AccountOwner {
                owner_type: AccountOwnerType::Company,
                owner_id: Some("co_2".to_owned()),
            },
            "USD".to_owned(),
            None,
            None,
        )?;

        let hashes_alike = opening.idempotency_hash() == another_owner.idempotency_hash();

        assert!(!hashes_alike);
        Ok(())
    }

    #[test]
    fn the_payload_records_the_request_and_never_the_chart_triple() -> Result<(), Invalid> {
        let opening = an_opening()?;

        let payload = opening.payload();

        assert_eq!(
            payload,
            serde_json::json!({
                "version": 1,
                "tenant_id": "acme",
                "idempotency_key": "open-1",
                "purpose": "customer_receivable",
                "owner_type": "company",
                "owner_id": "co_1",
                "currency": "USD",
                "stripe_count": null,
                "metadata": null,
            })
        );
        Ok(())
    }
}
