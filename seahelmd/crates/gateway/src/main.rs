//! seahelm-gateway: seahelm's network face (docs/seahelm-gateway-plan.md).
//! Web access — pairing, auth, WebSocket, the terminal relay — and the
//! Telegram adapter, as a client of seahelm-core. It is the only seahelm
//! component that listens on a network.
//!
//! Commands:
//!   serve              run in the foreground
//!   ensure             start detached unless one already answers
//!   status             print `gateway.status`
//!   pair               print the pairing code and where to enter it
//!   share <pane> [--hours N] [--to NAME]   mint a share link for one pane
//!   call METHOD [JSON] one `gateway.sock` call
//!   version

mod admin;
mod auth;
mod core;
mod gateway;
mod paths;
mod rpc;
mod store;
mod telegram;
mod web;

use std::time::{Duration, Instant};

use anyhow::{bail, Result};
use serde_json::{json, Value};

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if let Err(e) = run(&args) {
        eprintln!("seahelm-gateway: {e:#}");
        std::process::exit(1);
    }
}

fn run(args: &[String]) -> Result<()> {
    let (cmd, rest) = args.split_first().map(|(c, r)| (c.as_str(), r)).unwrap_or(("serve", &[]));
    match cmd {
        "serve" => serve(),
        "ensure" => ensure(),
        "status" => print(admin_call("gateway.status", json!({}))?),
        "pair" => {
            let r = admin_call("pairing.code.get", json!({}))?;
            println!("Open {} and enter {}", r["pair_url"].as_str().unwrap_or(""), r["code"].as_str().unwrap_or(""));
            Ok(())
        }
        "share" => {
            let Some(pane) = rest.first() else { bail!("usage: share <pane session key> [--hours N] [--to NAME]") };
            let mut params = json!({"pane_session_key": pane, "lifetime_seconds": 86400.0});
            let mut i = 1;
            while i < rest.len() {
                match rest[i].as_str() {
                    "--hours" => {
                        let h: f64 = rest.get(i + 1).and_then(|v| v.parse().ok()).ok_or_else(|| anyhow::anyhow!("--hours N"))?;
                        params["lifetime_seconds"] = if h > 0.0 { json!(h * 3600.0) } else { Value::Null };
                        i += 2;
                    }
                    "--to" => {
                        params["recipient"] = json!(rest.get(i + 1).cloned().unwrap_or_default());
                        i += 2;
                    }
                    other => bail!("unknown option {other}"),
                }
            }
            let r = admin_call("share.create", params)?;
            println!("{}", r["url"].as_str().unwrap_or(""));
            Ok(())
        }
        "call" => {
            let (method, rest) = rest.split_first().ok_or_else(|| anyhow::anyhow!("usage: call METHOD [JSON]"))?;
            let params: Value = match rest.first() {
                Some(j) => serde_json::from_str(j)?,
                None => json!({}),
            };
            print(admin_call(method, params)?)
        }
        "version" => {
            println!("seahelm-gateway {}", env!("CARGO_PKG_VERSION"));
            Ok(())
        }
        other => bail!("unknown command {other}"),
    }
}

fn print(v: Value) -> Result<()> {
    println!("{}", serde_json::to_string_pretty(&v)?);
    Ok(())
}

fn admin_call(method: &str, params: Value) -> Result<Value> {
    rpc::call(&paths::gateway_socket(), method, params, Duration::from_secs(30))?.map_err(|e| anyhow::anyhow!("{method}: {e}"))
}

fn serve() -> Result<()> {
    // A gateway started from inside a pane must not pass that pane's
    // identity on (it starts nothing today, but its children would).
    seahelmd::inherited::scrub();
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
    let store = store::Store::open(&paths::gateway_dir())?;
    let rt = tokio::runtime::Builder::new_multi_thread().enable_all().thread_name("gateway").build()?;
    let core = core::Core::new(paths::core_socket());
    let gw = gateway::Gateway::new(core.clone(), store, rt.handle().clone());
    // Bind first: a second gateway stops here, before it touches the core.
    admin::spawn(gw.clone())?;
    core.start();
    eprintln!("seahelm-gateway {}: serving (pid {})", env!("CARGO_PKG_VERSION"), std::process::id());
    rt.block_on(async move {
        telegram::spawn(gw.clone());
        web::run(gw).await;
    });
    Ok(())
}

fn ensure() -> Result<()> {
    let path = paths::gateway_socket();
    let ping = || matches!(rpc::call(&path, "gateway.ping", json!({}), Duration::from_secs(2)), Ok(Ok(_)));
    if ping() {
        return Ok(());
    }
    let exe = std::env::current_exe()?;
    let dir = paths::gateway_dir();
    std::fs::create_dir_all(&dir)?;
    let log = std::fs::OpenOptions::new().create(true).append(true).open(dir.join("gateway.log"))?;
    let mut cmd = std::process::Command::new(exe);
    cmd.arg("serve").stdin(std::process::Stdio::null()).stdout(std::process::Stdio::null()).stderr(log);
    seahelmd::platform::spawn_detached(&mut cmd)?;
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline {
        if ping() {
            return Ok(());
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    bail!("seahelm-gateway did not start; see {}", dir.join("gateway.log").display())
}
