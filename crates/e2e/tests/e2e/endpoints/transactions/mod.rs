//! `/v1/transactions` — one file per verb, split when one verb's contract
//! outgrows a single read: `post` is the posting-and-idempotency contract,
//! `pending` the pending → posted half, `reverse` the reversal-and-void half
//! (ADR-0016), `striping` which physical balance row a posting lands on
//! (ADR-0013 §4, ADR-0018 §1), and `batched` what a caller gets when its
//! posting shares one statement with other callers' (ADR-0018 §§2–3). The
//! last two are invisible on the wire, so they are the same endpoint seen
//! from underneath. `read_back` is the other VERB — GET, the transaction a
//! caller reads back — which ADR-0019 argued into scope precisely because
//! ADR-0016 made `status`, `resolves_id` and `reverses_id` wire concepts
//! nothing could read.

pub mod batched;
pub mod pending;
pub mod post;
pub mod read_back;
pub mod reverse;
pub mod striping;
