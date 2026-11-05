//! Who may answer a card (docs/first-mate-autonomy.md, "Who may answer a
//! card").
//!
//! A card is the user's: an approval First Mate waits on, a habit promotion,
//! an agent's question. Every caller on `core.sock` runs as the user, and
//! what a call says about itself (`_meta.caller`) is the caller's word, so
//! the core asks the kernel instead: the connection's peer pid
//! (`rpc::Peer`), then that process's ancestry and environment. A process
//! inside a seahelm pane — an agent, First Mate, a script either of them
//! started — is refused; the clients the user answers through (the macOS
//! app, the GPUI client, seahelm-gateway for the web and Telegram) are
//! recognised by their executable, wherever they were launched from.
//!
//! This is not a sandbox. Everything runs as one uid, and a process set on
//! it can always get round this (copy a client's binary name, detach from
//! its session). What it stops is an agent answering a card by accident or
//! by a straightforward call, and what it refuses is written down where the
//! user sees it (an audit line and a note in First Mate's timeline).

use std::path::Path;

/// One process in the peer's ancestry, peer first.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Proc {
    pub pid: u32,
    pub ppid: u32,
    /// The executable's path; empty when it could not be read.
    pub exe: String,
    pub argv: Vec<String>,
}

/// What was read about a peer: the inputs to [`classify`].
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Facts {
    /// The peer, then its parent, and so on up to the first process with no
    /// parent the system will name. Empty when the peer could not be read
    /// (gone already, or the platform gave no pid).
    pub chain: Vec<Proc>,
    /// The peer's environment as it was exec'd (`KERN_PROCARGS2`,
    /// `/proc/<pid>/environ`): `NAME=value` pairs. None when unreadable.
    pub env: Option<Vec<(String, String)>>,
}

/// Which of the clients a peer is.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Client {
    MacApp,
    Gpui,
    Gateway,
}

impl Client {
    pub fn as_str(self) -> &'static str {
        match self {
            Client::MacApp => "the macOS app",
            Client::Gpui => "the GPUI client",
            Client::Gateway => "seahelm-gateway",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Verdict {
    /// One of the clients the user answers through. `in_pane` says why it
    /// would otherwise have been refused (the app relaunched from a pane by
    /// `run.sh`): allowed, but written in the audit log.
    Client { client: Client, in_pane: Option<String> },
    /// Not in a pane: the user's own terminal, a launchd job.
    Outside,
    /// Inside a seahelm pane, and why.
    InPane(String),
    /// Could not tell. Refused: a guard that opens when it cannot look is no
    /// guard.
    Unknown(String),
}

impl Verdict {
    #[cfg(test)]
    pub fn allowed(&self) -> bool {
        matches!(self, Verdict::Client { .. } | Verdict::Outside)
    }
}

/// The variables seahelm puts in every pane: `SessionManager` exports
/// `SEAHELM_PANE_ID`, and seahelmd sets `SEAHELMD_SESSION` for whatever it
/// runs.
pub const PANE_ENV: [&str; 2] = ["SEAHELM_PANE_ID", "SEAHELMD_SESSION"];

/// The verdict on a peer, from what was read about it. Pure, so every path
/// is tested without a process to look at.
pub fn classify(f: &Facts) -> Verdict {
    let Some(peer) = f.chain.first() else {
        return Verdict::Unknown("its process could not be identified".into());
    };
    let in_pane = in_pane(f);
    if let Some(client) = client_of(peer) {
        return Verdict::Client { client, in_pane };
    }
    match in_pane {
        Some(why) => Verdict::InPane(why),
        None if f.env.is_none() && peer.exe.is_empty() => {
            Verdict::Unknown(format!("pid {} could not be read", peer.pid))
        }
        None => Verdict::Outside,
    }
}

/// Why a peer counts as inside a pane, if it does: a pane variable in its
/// environment, or a seahelmd session process among its ancestors.
fn in_pane(f: &Facts) -> Option<String> {
    if let Some(env) = &f.env {
        if let Some((k, v)) = env.iter().find(|(k, v)| PANE_ENV.contains(&k.as_str()) && !v.is_empty()) {
            return Some(format!("its environment carries {k}={v}"));
        }
    }
    f.chain.iter().find_map(|p| session_of(p).map(|name| format!("it runs under seahelmd session {name} (pid {})", p.pid)))
}

/// The session a seahelmd session process serves: `seahelmd __serve
/// [--hold N] <name> -- <program…>` (`client::spawn_daemon`).
pub fn session_of(p: &Proc) -> Option<String> {
    let exe = p.argv.first().map(String::as_str).filter(|a| !a.is_empty()).unwrap_or(&p.exe);
    if stem(exe) != "seahelmd" || p.argv.get(1).map(String::as_str) != Some("__serve") {
        return None;
    }
    let before_program = p.argv.iter().position(|a| a == "--").unwrap_or(p.argv.len());
    let name = p.argv[2..before_program.max(2)].iter().rev().find(|a| !a.starts_with('-') && a.parse::<u64>().is_err());
    Some(name.cloned().unwrap_or_else(|| "?".into()))
}

/// The executable's name without directory or `.exe`, lowercased.
fn stem(path: &str) -> String {
    let base = path.rsplit(['/', '\\']).next().unwrap_or(path).to_lowercase();
    base.strip_suffix(".exe").map(str::to_string).unwrap_or(base)
}

/// A client by its executable. The app is `…/Seahelm.app/Contents/MacOS/Seahelm`
/// (any bundle name: dev builds, /Applications); the `seahelm` CLI shares
/// its name but lives in `Contents/Resources/bin` or `~/.local/bin`, and is
/// not a client.
pub fn client_of(p: &Proc) -> Option<Client> {
    let exe = if p.exe.is_empty() { p.argv.first().cloned().unwrap_or_default() } else { p.exe.clone() };
    match stem(&exe).as_str() {
        "seahelm-gateway" => Some(Client::Gateway),
        "seahelm-gpui" => Some(Client::Gpui),
        "seahelm" if is_app_executable(&exe) => Some(Client::MacApp),
        _ => None,
    }
}

fn is_app_executable(exe: &str) -> bool {
    let path = Path::new(exe);
    let parent = |p: &Path, name: &str| p.parent().filter(|d| d.file_name().is_some_and(|n| n == name)).map(Path::to_path_buf);
    parent(path, "MacOS")
        .and_then(|macos| parent(&macos, "Contents"))
        .and_then(|contents| contents.parent().map(Path::to_path_buf))
        .is_some_and(|bundle| bundle.extension().is_some_and(|e| e.eq_ignore_ascii_case("app")))
}

/// Read a live peer: its ancestry (argv and executable for each) and its
/// environment. Same uid only — the socket admits no one else.
pub fn gather(pid: u32) -> Facts {
    use sysinfo::{Pid, ProcessRefreshKind, ProcessesToUpdate, System, UpdateKind};
    let mut sys = System::new();
    // Parents for everyone (cheap), then argv/exe along the chain only.
    sys.refresh_processes_specifics(ProcessesToUpdate::All, true, ProcessRefreshKind::nothing());
    let mut pids = Vec::new();
    let mut at = Some(Pid::from_u32(pid));
    while let Some(p) = at {
        if pids.contains(&p) || pids.len() >= 64 {
            break;
        }
        let Some(proc_) = sys.process(p) else { break };
        pids.push(p);
        at = proc_.parent().filter(|pp| pp.as_u32() != 0);
    }
    if pids.is_empty() {
        return Facts::default();
    }
    let kind = ProcessRefreshKind::nothing().with_cmd(UpdateKind::Always).with_exe(UpdateKind::Always).with_environ(UpdateKind::Always);
    sys.refresh_processes_specifics(ProcessesToUpdate::Some(&pids), false, kind);
    let chain: Vec<Proc> = pids
        .iter()
        .filter_map(|p| sys.process(*p))
        .map(|p| Proc {
            pid: p.pid().as_u32(),
            ppid: p.parent().map(|pp| pp.as_u32()).unwrap_or(0),
            exe: p.exe().map(|e| e.to_string_lossy().into_owned()).unwrap_or_default(),
            argv: p.cmd().iter().map(|a| a.to_string_lossy().into_owned()).collect(),
        })
        .collect();
    let env = sys.process(Pid::from_u32(pid)).map(|p| p.environ()).filter(|e| !e.is_empty()).map(|e| {
        e.iter()
            .map(|kv| {
                let kv = kv.to_string_lossy();
                match kv.split_once('=') {
                    Some((k, v)) => (k.to_string(), v.to_string()),
                    None => (kv.into_owned(), String::new()),
                }
            })
            .collect()
    });
    Facts { chain, env }
}

/// The verdict on a connection.
pub fn identify(peer: &crate::rpc::Peer) -> Verdict {
    if peer.foreign_user {
        return Verdict::Unknown("it runs as another user".into());
    }
    let Some(pid) = peer.pid else {
        // TODO(platform): a unix without LOCAL_PEERPID / SO_PEERCRED lands
        // here and refuses every guarded call.
        return Verdict::Unknown("the system did not say which process connected".into());
    };
    classify(&gather(pid))
}

/// The calls that answer for the user: answering or dismissing a card, and
/// raising one (a raised card's answer goes back to whoever raised it, so a
/// raised card that copies First Mate's could carry the user's yes to it).
pub fn guarded(method: &str) -> bool {
    is_card_call(method) || speaks_as_user(method)
}

/// A call checked with its params: the guarded methods, and starting the
/// inventory (`habits.inventory` without `preview`), which puts cards in
/// front of the user in First Mate's name. The read-only preview is not.
pub fn guarded_call(method: &str, params: &serde_json::Value) -> bool {
    method.starts_with("task-source.") || guarded(method) || starts_inventory(method, params) || matches!(method, "memory.note" | "memory.undo" | "memory.confirm" | "schedule.add" | "schedule.remove" | "schedule.run_now")
}

pub fn starts_inventory(method: &str, params: &serde_json::Value) -> bool {
    method == "habits.inventory" && params.get("preview").and_then(serde_json::Value::as_bool) != Some(true)
}

pub fn is_card_call(method: &str) -> bool {
    matches!(method, "cards.answer" | "cards.dismiss" | "cards.clear" | "cards.raise" | "autopilot.answer")
}

/// The calls that speak to First Mate in the user's voice: `autopilot.say`,
/// and `command.run`, whose prose goes to First Mate when the conversation
/// is bound to it. What the user says sets `user_spoke` and lets First Mate
/// act at the user's default levels, so a pane may not say it for them.
pub fn speaks_as_user(method: &str) -> bool {
    matches!(method, "autopilot.say" | "command.run")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn proc_(pid: u32, ppid: u32, exe: &str, argv: &[&str]) -> Proc {
        Proc { pid, ppid, exe: exe.into(), argv: argv.iter().map(|s| s.to_string()).collect() }
    }

    const APP: &str = "/Volumes/w/seahelm/.build/Build/Products/Debug/Seahelm.app/Contents/MacOS/Seahelm";
    const BIN: &str = "/Applications/Seahelm.app/Contents/Resources/bin";

    fn session(pid: u32, name: &str) -> Proc {
        proc_(pid, 1, &format!("{BIN}/seahelmd"), &[&format!("{BIN}/seahelmd"), "__serve", "--hold", "10", name, "--", "/bin/zsh", "-lic", "claude"])
    }

    fn launchd() -> Proc {
        proc_(1, 0, "/sbin/launchd", &["/sbin/launchd"])
    }

    fn env(pairs: &[(&str, &str)]) -> Option<Vec<(String, String)>> {
        Some(pairs.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect())
    }

    #[test]
    fn an_agent_in_a_pane_is_refused_by_its_ancestry() {
        // claude → zsh → seahelmd __serve, with the environment scrubbed.
        let f = Facts {
            chain: vec![proc_(300, 200, "/usr/local/bin/node", &["claude"]), proc_(200, 100, "/bin/zsh", &["-zsh"]), session(100, "seahelm-task-x"), launchd()],
            env: env(&[("PATH", "/usr/bin")]),
        };
        assert_eq!(classify(&f), Verdict::InPane("it runs under seahelmd session seahelm-task-x (pid 100)".into()));
    }

    #[test]
    fn a_pane_variable_is_enough() {
        // Detached from its session (setsid, reparented to launchd), but it
        // still carries the pane's id.
        let f = Facts { chain: vec![proc_(300, 1, "/usr/bin/python3", &["python3", "answer.py"]), launchd()], env: env(&[("SEAHELM_PANE_ID", "seahelm-first-mate")]) };
        assert_eq!(classify(&f), Verdict::InPane("its environment carries SEAHELM_PANE_ID=seahelm-first-mate".into()));
        let f = Facts { chain: vec![proc_(300, 1, "/bin/sh", &["sh"]), launchd()], env: env(&[("SEAHELMD_SESSION", "s1")]) };
        assert!(matches!(classify(&f), Verdict::InPane(w) if w.contains("SEAHELMD_SESSION=s1")));
        // An empty value names no pane.
        let f = Facts { chain: vec![proc_(300, 1, "/bin/sh", &["sh"]), launchd()], env: env(&[("SEAHELM_PANE_ID", "")]) };
        assert_eq!(classify(&f), Verdict::Outside);
    }

    #[test]
    fn first_mate_through_its_cli_shim_is_in_a_pane() {
        let f = Facts {
            chain: vec![
                proc_(400, 300, &format!("{BIN}/seahelm-core"), &["seahelm-core", "cli", "cards"]),
                proc_(300, 200, "/usr/local/bin/node", &["claude"]),
                session(200, "seahelm-first-mate"),
                launchd(),
            ],
            env: env(&[("SEAHELM_PANE_ID", "seahelm-first-mate")]),
        };
        assert!(!classify(&f).allowed());
    }

    #[test]
    fn the_clients_are_recognised_wherever_they_were_started() {
        // The app as run.sh starts it: from a shell inside a pane, with the
        // pane's variables in its exec-time environment (main.swift scrubs
        // them only from what its children inherit).
        let f = Facts {
            chain: vec![proc_(500, 450, APP, &[APP]), proc_(450, 200, "/bin/bash", &["bash", "./run.sh"]), proc_(200, 100, "/bin/zsh", &["-zsh"]), session(100, "seahelm-task-x"), launchd()],
            env: env(&[("SEAHELM_PANE_ID", "seahelm-task-x")]),
        };
        let v = classify(&f);
        assert!(v.allowed());
        assert!(matches!(v, Verdict::Client { client: Client::MacApp, in_pane: Some(_) }));
        // Installed, launched by launchd.
        let f = Facts { chain: vec![proc_(5, 1, "/Applications/Seahelm.app/Contents/MacOS/Seahelm", &[]), launchd()], env: env(&[]) };
        assert_eq!(classify(&f), Verdict::Client { client: Client::MacApp, in_pane: None });
        // The gateway, started by the app and detached.
        let f = Facts { chain: vec![proc_(6, 1, &format!("{BIN}/seahelm-gateway"), &["seahelm-gateway", "serve"]), launchd()], env: env(&[]) };
        assert_eq!(classify(&f), Verdict::Client { client: Client::Gateway, in_pane: None });
        // The gateway still a child of an app launched from a pane.
        let f = Facts {
            chain: vec![proc_(7, 500, &format!("{BIN}/seahelm-gateway"), &["seahelm-gateway"]), proc_(500, 200, APP, &[APP]), session(200, "seahelm-task-x"), launchd()],
            env: env(&[]),
        };
        assert!(matches!(classify(&f), Verdict::Client { client: Client::Gateway, in_pane: Some(_) }));
        // The GPUI client on Windows.
        let f = Facts { chain: vec![proc_(8, 4, r"C:\Program Files\seahelm\seahelm-gpui.exe", &[])], env: env(&[]) };
        assert_eq!(classify(&f), Verdict::Client { client: Client::Gpui, in_pane: None });
    }

    #[test]
    fn the_cli_is_not_the_app() {
        for exe in [format!("{BIN}/seahelm"), "/Users/u/.local/bin/seahelm".to_string()] {
            let f = Facts { chain: vec![proc_(9, 1, &exe, &["seahelm", "cards"]), launchd()], env: env(&[("SEAHELM_PANE_ID", "p")]) };
            assert!(matches!(classify(&f), Verdict::InPane(_)), "{exe}");
        }
        // Nor a binary merely named Seahelm outside a bundle.
        let f = Facts { chain: vec![proc_(9, 1, "/tmp/MacOS/Seahelm", &[]), session(2, "s")], env: env(&[]) };
        assert!(matches!(classify(&f), Verdict::InPane(_)));
    }

    #[test]
    fn outside_a_pane_is_allowed_and_unreadable_is_not() {
        let f = Facts { chain: vec![proc_(10, 9, "/usr/bin/python3", &["python3"]), proc_(9, 1, "/bin/zsh", &["-zsh"]), launchd()], env: env(&[("TERM_PROGRAM", "Apple_Terminal")]) };
        assert_eq!(classify(&f), Verdict::Outside);
        assert!(matches!(classify(&Facts::default()), Verdict::Unknown(_)));
        let f = Facts { chain: vec![proc_(10, 1, "", &[])], env: None };
        assert!(matches!(classify(&f), Verdict::Unknown(_)));
    }

    #[test]
    fn session_names() {
        assert_eq!(session_of(&session(1, "seahelm-a-b")), Some("seahelm-a-b".into()));
        let bare = proc_(1, 1, "/x/seahelmd", &["/x/seahelmd", "__serve", "n1", "--", "zsh"]);
        assert_eq!(session_of(&bare), Some("n1".into()));
        let attach = proc_(1, 1, "/x/seahelmd", &["/x/seahelmd", "attach", "n1"]);
        assert_eq!(session_of(&attach), None, "an attach client is the app's side of a pane");
        let win = proc_(1, 1, r"C:\s\seahelmd.exe", &[r"C:\s\seahelmd.exe", "__serve", "w", "--", "pwsh"]);
        assert_eq!(session_of(&win), Some("w".into()));
    }

    #[test]
    fn guarded_methods() {
        for m in ["cards.answer", "cards.dismiss", "cards.clear", "cards.raise", "autopilot.answer", "autopilot.say", "command.run"] {
            assert!(guarded(m), "{m}");
        }
        for m in ["cards.list", "pane.list", "hook", "autopilot.state", "message.snapshot"] {
            assert!(!guarded(m), "{m}");
        }
        // Starting the inventory is checked; its preview, and listing habits, are not.
        let j = |v: &str| serde_json::from_str::<serde_json::Value>(v).unwrap();
        assert!(guarded_call("habits.inventory", &j("{}")) && guarded_call("habits.inventory", &j(r#"{"preview": false}"#)));
        assert!(!guarded_call("habits.inventory", &j(r#"{"preview": true}"#)));
        assert!(!guarded_call("habits.list", &j("{}")));
        assert!(guarded_call("cards.answer", &j("{}")));
    }

    /// This test process, read live: the chain starts at it, and the
    /// environment read from the kernel agrees with its own.
    #[cfg(any(target_os = "macos", target_os = "linux"))]
    #[test]
    fn reads_a_live_process() {
        let me = std::process::id();
        let f = gather(me);
        assert_eq!(f.chain.first().map(|p| p.pid), Some(me));
        let exe = std::env::current_exe().unwrap();
        assert_eq!(Path::new(&f.chain[0].exe).file_name(), exe.file_name());
        let env = f.env.expect("own environment is readable");
        let has_pane = std::env::var("SEAHELM_PANE_ID").is_ok_and(|v| !v.is_empty());
        assert_eq!(env.iter().any(|(k, v)| k == "SEAHELM_PANE_ID" && !v.is_empty()), has_pane);
        // Run from a seahelm pane (as during development), this process is refused.
        if has_pane {
            assert!(matches!(classify(&gather(me)), Verdict::InPane(_)));
        }
    }

    /// A manual check against live processes, read-only (nothing is sent to
    /// them): `SEAHELM_PEER_CHECK_PIDS="<app pid> <gateway pid> $$" cargo
    /// test -p seahelm-core peer::tests::verdicts_for_live_pids -- --ignored --nocapture`.
    #[test]
    #[ignore]
    fn verdicts_for_live_pids() {
        let pids = std::env::var("SEAHELM_PEER_CHECK_PIDS").unwrap_or_default();
        for pid in pids.split_whitespace().filter_map(|p| p.parse::<u32>().ok()) {
            let f = gather(pid);
            let exe = f.chain.first().map(|p| p.exe.clone()).unwrap_or_default();
            println!("{pid} {exe}\n    → {:?}", classify(&f));
        }
    }
}

/// Only the kernel-observed First Mate session gets the note exception; undo belongs to the user.
pub fn first_mate_memory(method: &str, pid: Option<u32>) -> bool {
    method == "memory.note" && pid.is_some_and(|pid| gather(pid).chain.iter().any(|p| session_of(p).as_deref() == Some(crate::first_mate::policy::SESSION)))
}

#[cfg(test)]
mod research_checks {
    #[test] fn every_schedule_rpc_is_user_only() { for m in ["schedule.add", "schedule.remove", "schedule.run_now"] { assert!(super::guarded_call(m, &serde_json::json!({}))); } }
}

/// Environment claims cannot establish First Mate's identity.
pub fn real_first_mate(f: &Facts) -> bool {
    f.chain.iter().filter_map(session_of).next().as_deref() == Some(crate::first_mate::policy::SESSION)
}
pub fn first_mate_peer(peer: &crate::rpc::Peer) -> bool {
    peer.pid.is_some_and(|pid| real_first_mate(&gather(pid))) && !matches!(identify(peer), Verdict::Unknown(_))
}

#[cfg(test)] mod research_identity_tests {
    use super::*;
    #[test] fn ignores_spoofed_environment_and_requires_the_nearest_session() {
        let mut f = Facts { env: Some(vec![("SEAHELM_PANE_ID".into(), "seahelm-first-mate".into())]), ..Default::default() };
        assert!(!real_first_mate(&f));
        f.chain.push(Proc { exe: "seahelmd".into(), argv: vec!["seahelmd".into(), "__serve".into(), "other".into(), "--".into()], ..Default::default() });
        assert!(!real_first_mate(&f));
        f.chain[0].argv[2] = "seahelm-first-mate".into(); assert!(real_first_mate(&f));
        assert!(!guarded_call("schedule.list", &serde_json::json!({})));
    }
}
