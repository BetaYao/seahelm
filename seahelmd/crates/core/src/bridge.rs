//! `seahelm-core hook [<source>]`: the agents' hook command, straight to
//! the core, for machines without the macOS app (Linux, Windows) or with it
//! closed. `seahelm-core install-hooks` wires agents to it.
//!
//! The same contract as the `seahelm-hook` shim (`seahelm_core_hooks::wire`,
//! whose payload splicing it uses): read the hook JSON on stdin, tag it with
//! the pane (`SEAHELM_PANE_ID`, else `SEAHELMD_SESSION`) and the declared
//! source, send one `hook` line, wait briefly for the acknowledgement.
//! Fire-and-forget: never a byte on stdout (Claude Code reads a command
//! hook's stdout as a decision), always exit 0, never starts the core, and
//! a watchdog ends it after `wire::TIMEOUT` whatever is stuck.

use std::io::{BufRead, BufReader, Read};

use seahelm_core_hooks::wire;

use crate::rpc;

pub fn run(args: &[String]) {
    std::thread::spawn(|| {
        std::thread::sleep(wire::TIMEOUT);
        std::process::exit(0);
    });
    let source = args.first().cloned();
    let _ = std::panic::catch_unwind(move || deliver(source.as_deref()));
}

fn deliver(source: Option<&str>) {
    let mut payload = Vec::new();
    if std::io::stdin().read_to_end(&mut payload).is_err() {
        return;
    }
    let payload = String::from_utf8_lossy(&payload);
    let pane = wire::pane_id(
        std::env::var("SEAHELM_PANE_ID").ok().as_deref(),
        std::env::var("SEAHELMD_SESSION").ok().as_deref(),
    );
    let Some(params) = wire::splice(&payload, pane.as_deref(), source) else { return };
    let socket = rpc::core_socket();
    #[cfg(unix)]
    if !socket.exists() {
        return;
    }
    let Ok(mut stream) = seahelmd::platform::Stream::connect(&socket) else { return };
    let _ = stream.set_write_timeout(Some(wire::TIMEOUT));
    let _ = stream.set_read_timeout(Some(wire::TIMEOUT));
    if std::io::Write::write_all(&mut stream, wire::request_line(params).as_bytes()).is_err() {
        return;
    }
    // The acknowledgement, so the event is taken before we go.
    let mut reply = String::new();
    let _ = BufReader::new(stream).read_line(&mut reply);
}
