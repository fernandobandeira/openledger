//! Binding and serving: everything between "the composition root handed us a
//! `Ledger`" and "axum is answering on a socket".

use std::io::Write;
use std::net::SocketAddr;

use ledger::Ledger;

/// Binding or serving failed — the binary's exit 1. The `Usage` half of the
/// old split is gone on purpose: `--bind` reaches [`run`] as an
/// already-parsed [`SocketAddr`], because clap owns the usage error (exit 2,
/// the flag named in clap's own message) at the command line.
pub struct ServeError(pub String);

/// `println!` panics on a broken pipe, and this workspace denies `panic`. The
/// announce line below must not be able to kill a server that would otherwise
/// serve.
fn say(message: &str) {
    let _ = writeln!(std::io::stdout(), "{message}");
}

pub async fn run<L>(ledger: L, bind: SocketAddr) -> Result<(), ServeError>
where
    L: Ledger + Clone + 'static,
{
    let listener = tokio::net::TcpListener::bind(bind)
        .await
        .map_err(|e| ServeError(format!("could not bind {bind}: {e}")))?;
    let bound = listener
        .local_addr()
        .map_err(|e| ServeError(format!("could not read the bound address: {e}")))?;
    // The first line of output is a contract: the e2e suite binds port 0 and
    // reads the address from here.
    say(&format!("listening on http://{bound}"));

    axum::serve(listener, crate::router(ledger))
        .await
        .map_err(|e| ServeError(format!("server error: {e}")))
}
