//! The committed `crates/api/openapi.json` is an artifact with a drift
//! refusal, the same instinct as the schema snapshot (ADR-0007 §2): the spec
//! is generated from the annotations, committed, and this test regenerates it
//! and compares bytes. The e2e conformance test holds the other half — that
//! the committed document matches the running router.

/// To regenerate the committed spec after changing the annotations:
///
/// ```text
/// OPENLEDGER_WRITE_SPEC=1 cargo test -p api --test spec
/// ```
///
/// then commit the rewritten `crates/api/openapi.json`. The env var is an
/// explicit opt-in so a normal test run can only ever FAIL on drift, never
/// paper over it by rewriting the file it was about to compare.
#[test]
fn the_committed_spec_matches_the_code() -> Result<(), Box<dyn std::error::Error>> {
    // Emission must be deterministic for a byte-diff to mean anything:
    // generate twice, compare bytes. (Cross-process and cross-rebuild
    // stability was measured in spike 021; every CI run of this test on a
    // fresh build re-checks it against the committed bytes for real.)
    let generated = api::openapi_json()?;
    assert_eq!(
        generated,
        api::openapi_json()?,
        "spec emission is not deterministic — two generations in one process disagree"
    );

    let committed_at = concat!(env!("CARGO_MANIFEST_DIR"), "/openapi.json");
    if std::env::var_os("OPENLEDGER_WRITE_SPEC").is_some() {
        std::fs::write(committed_at, &generated)?;
        return Ok(());
    }

    let committed = std::fs::read_to_string(committed_at)
        .map_err(|e| format!("could not read {committed_at}: {e} — regenerate it with OPENLEDGER_WRITE_SPEC=1 cargo test -p api --test spec"))?;
    assert_eq!(
        committed, generated,
        "crates/api/openapi.json no longer matches the annotations; \
         regenerate it with OPENLEDGER_WRITE_SPEC=1 cargo test -p api --test spec \
         and commit the diff"
    );
    Ok(())
}
