//! The `seahelm-hook` binary end to end (SeahelmHookInstallerTests,
//! adapted from the shell script to the binary that replaced it).

#![cfg(unix)]

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixListener;
use std::path::Path;
use std::process::{Command, Output, Stdio};
use std::time::{Duration, Instant};

use serde_json::Value;

const HOOK: &str = env!("CARGO_BIN_EXE_seahelm-hook");

fn run_hook(sock: &Path, args: &[&str], payload: &str) -> Output {
    let mut child = Command::new(HOOK)
        .args(args)
        .env_clear()
        .env("SEAHELM_SOCKET_PATH", sock)
        .env("SEAHELM_PANE_ID", "seahelm-repo-main")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(payload.as_bytes()).unwrap();
    child.wait_with_output().unwrap()
}

/// Accept `n` connections, answer each like the control socket does, and
/// return the request lines.
fn serve(listener: UnixListener, n: usize) -> std::thread::JoinHandle<Vec<Value>> {
    std::thread::spawn(move || {
        (0..n)
            .map(|_| {
                let (stream, _) = listener.accept().unwrap();
                let mut reader = BufReader::new(stream.try_clone().unwrap());
                let mut line = String::new();
                reader.read_line(&mut line).unwrap();
                (&stream).write_all(b"{\"jsonrpc\":\"2.0\",\"id\":\"h\",\"result\":{}}\n").unwrap();
                serde_json::from_str(&line).unwrap()
            })
            .collect()
    })
}

#[test]
fn test_script_stamps_source_on_the_wire() {
    let dir = tempfile::tempdir().unwrap();
    let sock = dir.path().join("s.sock");
    let server = serve(UnixListener::bind(&sock).unwrap(), 2);

    let payload = r#"{"hook_event_name":"Stop","session_id":"s","cwd":"/wt"}"#;
    let tagged = run_hook(&sock, &["claude-code"], payload);
    let untagged = run_hook(&sock, &[], payload);
    let captured = server.join().unwrap();

    for out in [&tagged, &untagged] {
        assert!(out.status.success());
        assert!(out.stdout.is_empty(), "the hook must never write to stdout");
    }
    assert_eq!(captured.len(), 2, "both hook invocations should reach the socket");
    let first = &captured[0];
    assert_eq!(first["method"], "hook");
    assert_eq!(first["jsonrpc"], "2.0");
    assert_eq!(first["params"]["seahelm_source"], "claude-code");
    assert_eq!(first["params"]["seahelm_pane_id"], "seahelm-repo-main");
    assert_eq!(first["params"]["hook_event_name"], "Stop");
    assert!(captured[1]["params"].get("seahelm_source").is_none(), "untagged call must not emit an empty source");
    assert_eq!(captured[1]["params"]["seahelm_pane_id"], "seahelm-repo-main");
}

/// Nobody listening is not the agent's problem: exit 0, silently, at once.
#[test]
fn test_missing_socket_exits_zero_quietly() {
    let dir = tempfile::tempdir().unwrap();
    let start = Instant::now();
    let out = run_hook(&dir.path().join("absent.sock"), &["codex"], r#"{"hook_event_name":"Stop"}"#);
    assert!(out.status.success());
    assert!(out.stdout.is_empty() && out.stderr.is_empty());
    assert!(start.elapsed() < Duration::from_secs(2));
}

#[test]
fn test_empty_payload_sends_nothing() {
    let dir = tempfile::tempdir().unwrap();
    let sock = dir.path().join("s.sock");
    let listener = UnixListener::bind(&sock).unwrap();
    listener.set_nonblocking(true).unwrap();
    let out = run_hook(&sock, &["claude-code"], "");
    assert!(out.status.success());
    assert!(listener.accept().is_err(), "an empty payload must not be forwarded");
}

/// A server that accepts and never answers must not hold the agent up past
/// the two-second budget.
#[test]
fn test_a_silent_server_cannot_hang_the_agent() {
    let dir = tempfile::tempdir().unwrap();
    let sock = dir.path().join("s.sock");
    let listener = UnixListener::bind(&sock).unwrap();
    let holder = std::thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        std::thread::sleep(Duration::from_secs(4));
        drop(stream);
    });
    let start = Instant::now();
    let out = run_hook(&sock, &["claude-code"], r#"{"a":1}"#);
    assert!(out.status.success());
    assert!(start.elapsed() < Duration::from_millis(3500), "took {:?}", start.elapsed());
    holder.join().unwrap();
}
