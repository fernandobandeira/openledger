// BUG A-1, Rust: the match omits `ExpiryReversal`, exactly as the Go does.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AuthEventKind {
    Authorization, Incremental, Advice, Reversal, Clearing, Expiry, ExpiryReversal,
}

#[derive(Debug, Default, Clone, Copy)]
pub struct Effect { pub delta: i64, pub increase_side: bool, pub clears_expiry_flag: bool }

pub fn normalise(kind: AuthEventKind, wire: i64) -> Result<Effect, String> {
    use AuthEventKind::*;
    match kind {
        Authorization | Incremental => Ok(Effect { delta: wire, increase_side: true, ..Default::default() }),
        Clearing | Reversal => Ok(Effect { delta: wire, ..Default::default() }),
        Advice => Ok(Effect { delta: wire, ..Default::default() }),
        Expiry => Err("expiry is a flag".into()),
        // ExpiryReversal => <-- OMITTED
    }
}

fn main() {
    println!("{:?}", normalise(AuthEventKind::ExpiryReversal, 0));
}
