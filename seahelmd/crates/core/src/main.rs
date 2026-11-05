//! seahelm-core: what every seahelm client asks about its agents.
//!
//!   seahelm-core [serve]          run the service (one per user)
//!   seahelm-core ensure           start it unless it is running; exit once it answers
//!   seahelm-core call METHOD [JSON]   one JSON-RPC call, for scripts and debugging
//!   seahelm-core hook [SOURCE]    an agent's hook command: stdin JSON to the core
//!   seahelm-core install-hooks    wire Claude Code and Codex hooks to `hook`,
//!                                 and Claude's statusline to `statusline`
//!   seahelm-core statusline [-- CMD]  Claude's statusline: cache the payload, run CMD
//!   seahelm-core version
//!
//! The service reads each registered pane's screen from its seahelmd session,
//! takes the agents' lifecycle hooks, decides each pane's state, and serves it
//! over `~/.config/seahelm/core.sock` (see docs/status-core-port.md).

mod actions;
mod bridge;
mod cli;
mod command;
mod core;
mod first_mate;
mod install;
mod keys;
mod poller;
mod pr;
mod rpc;
mod statusline;
mod usage;

use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::{bail, Result};
use serde_json::Value;

fn main() {
    if let Err(e) = run() {
        eprintln!("seahelm-core: {e:#}");
        std::process::exit(1);
    }
}

fn run() -> Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let (verb, rest) = args.split_first().map(|(v, r)| (v.as_str(), r)).unwrap_or(("serve", &[]));
    match verb {
        "serve" => serve(),
        "ensure" => ensure(),
        "call" => {
            let (method, rest) = rest.split_first().ok_or_else(|| anyhow::anyhow!("usage: call METHOD [JSON]"))?;
            let params: Value = match rest.first() {
                Some(j) => serde_json::from_str(j)?,
                None => Value::Object(Default::default()),
            };
            let v = rpc::call(&rpc::core_socket(), method, params)?;
            println!("{}", serde_json::to_string_pretty(&v)?);
            Ok(())
        }
        // The `seahelm` words First Mate's instructions use, on the core.
        "cli" => std::process::exit(cli::run(rest)),
        // Never an error, never output: an agent runs this on every event.
        "hook" => {
            bridge::run(rest);
            Ok(())
        }
        "install-hooks" => install::run(rest),
        "statusline" => std::process::exit(statusline::run(rest)),
        "version" => {
            println!("seahelm-core {}", env!("CARGO_PKG_VERSION"));
            Ok(())
        }
        other => bail!("unknown command {other}"),
    }
}

fn serve() -> Result<()> {
    // Only here: `hook` and `cli` need the pane identity they were run with,
    // but the service starts sessions (First Mate, `/new`) that must not
    // inherit the identity of whatever pane launched it.
    seahelmd::inherited::scrub();
    let _ = core::STARTED_AT.set(seahelm_core_types::now());
    // An ignored signal survives exec, so a core started by a client that
    // ignores SIGTERM (a GUI toolkit may) could not be stopped by it.
    // A blocked mask survives exec too (the GPUI client's threads block
    // them), and a blocked SIGTERM never arrives whatever its handler.
    #[cfg(unix)]
    unsafe {
        libc::signal(libc::SIGTERM, libc::SIG_DFL);
        libc::signal(libc::SIGINT, libc::SIG_DFL);
        let mut set: libc::sigset_t = std::mem::zeroed();
        libc::sigemptyset(&mut set);
        libc::sigaddset(&mut set, libc::SIGTERM);
        libc::sigaddset(&mut set, libc::SIGINT);
        libc::pthread_sigmask(libc::SIG_UNBLOCK, &set, std::ptr::null_mut());
    }
    let path = rpc::core_socket();
    let listener = rpc::bind(&path)?;
    let core = core::Core::start()?;
    poller::spawn(Arc::clone(&core));
    // Beside a socket given by the environment (a scratch core), so a test
    // core never writes into the real log.
    let event_log = match std::env::var_os("SEAHELM_CORE_SOCKET") {
        Some(sock) => std::path::PathBuf::from(format!("{}.events.jsonl", sock.to_string_lossy())),
        None => rpc::config_dir().join("core-events.jsonl"),
    };
    core.spawn_event_log(event_log);
    core.spawn_titles();
    pr::spawn(Arc::clone(&core));
    usage::spawn();
    core.spawn_first_mate();
    eprintln!("seahelm-core listening on {}", path.display());
    rpc::serve(listener, core)
}

/// Start the service if nothing answers on its socket, detached from the
/// caller (its own session, like seahelmd's), and wait until it answers.
fn ensure() -> Result<()> {
    let path = rpc::core_socket();
    if rpc::call(&path, "core.ping", Value::Null).is_ok() {
        return Ok(());
    }
    let exe = std::env::current_exe()?;
    std::fs::create_dir_all(rpc::config_dir())?;
    let log = rpc::config_dir().join("core.log");
    let log = std::fs::OpenOptions::new().create(true).append(true).open(&log)?;
    let mut cmd = std::process::Command::new(exe);
    cmd.arg("serve").stdin(std::process::Stdio::null()).stdout(std::process::Stdio::null()).stderr(log);
    seahelmd::platform::spawn_detached(&mut cmd)?;
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline {
        if rpc::call(&path, "core.ping", Value::Null).is_ok() {
            return Ok(());
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    bail!("seahelm-core did not start; see {}", rpc::config_dir().join("core.log").display())
}
