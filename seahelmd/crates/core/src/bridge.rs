//! `seahelm-core hook [<source>]`: the agents' hook command, straight to
//! the core, for machines without the macOS app (Linux, Windows) or with it
//! closed. `seahelm-core install-hooks` wires agents to it.
//!
//! The bridge is `seahelm_core_hooks::wire::run`, the same one the
//! `seahelm-hook` binary runs: stdin to the core, the core's `stdout` (a
//! SessionStart's added context) back to the agent, nothing else, exit 0.

use crate::rpc;

pub fn run(args: &[String]) {
    seahelm_core_hooks::wire::run(&rpc::core_socket(), args.first().map(String::as_str));
}
