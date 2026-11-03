//! A session's life on Windows, end to end through the CLI: a named pipe, a
//! pseudoconsole, the cursor-position handshake ConPTY opens with, and the
//! process tree going when the session is killed.

#![cfg(windows)]

use std::process::{Command, Output};
use std::time::{Duration, Instant};

/// Sessions for one test, kept apart from any real ones by a namespace of
/// their own (`SEAHELMD_DIR` names the pipes' prefix on Windows).
struct Space(String);

impl Space {
    fn new(tag: &str) -> Self {
        Space(format!("seahelmd-test-{tag}-{}", std::process::id()))
    }

    fn cli(&self, args: &[&str]) -> Output {
        Command::new(env!("CARGO_BIN_EXE_seahelmd"))
            .args(args)
            .env("SEAHELMD_DIR", &self.0)
            .output()
            .expect("run seahelmd")
    }

    fn text(&self, args: &[&str]) -> String {
        String::from_utf8_lossy(&self.cli(args).stdout).into_owned()
    }

    fn wait_for(&self, verb: &str, name: &str, needle: &str) -> String {
        let deadline = Instant::now() + Duration::from_secs(20);
        loop {
            let out = self.text(&[verb, name]);
            if out.contains(needle) {
                return out;
            }
            assert!(Instant::now() < deadline, "{verb} never had {needle:?}:\n{out}");
            std::thread::sleep(Duration::from_millis(100));
        }
    }
}

#[test]
fn a_session_runs_reports_and_ends() {
    let s = Space::new("life");
    let out = s.cli(&["new", "w1", "--", "cmd", "/c", "echo hello-windows & ping -n 60 127.0.0.1 >nul"]);
    assert!(out.status.success(), "new: {}", String::from_utf8_lossy(&out.stderr));

    // Output arriving at all means ConPTY's opening cursor query was answered.
    s.wait_for("history", "w1", "hello-windows");
    let snap = s.wait_for("snapshot", "w1", "hello-windows");
    assert!(snap.contains("\"generation\":"), "{snap}");

    let list = s.text(&["list"]);
    assert!(list.contains("name=w1"), "{list}");
    assert!(list.contains("pid="), "{list}");

    let out = s.cli(&["kill", "w1"]);
    assert!(out.status.success(), "kill: {}", String::from_utf8_lossy(&out.stderr));
    let deadline = Instant::now() + Duration::from_secs(10);
    while s.text(&["list"]).contains("name=w1") {
        assert!(Instant::now() < deadline, "the session outlived its kill");
        std::thread::sleep(Duration::from_millis(100));
    }
}

#[test]
fn a_session_ends_when_its_program_does() {
    // The pseudoconsole has to be closed for the output to end; without that
    // the daemon would wait for ever on a program long gone.
    let s = Space::new("end");
    let out = s.cli(&["new", "w2", "--", "cmd", "/c", "echo brief"]);
    assert!(out.status.success(), "new: {}", String::from_utf8_lossy(&out.stderr));
    let deadline = Instant::now() + Duration::from_secs(20);
    while s.text(&["list"]).contains("name=w2") {
        assert!(Instant::now() < deadline, "the session did not end with its program");
        std::thread::sleep(Duration::from_millis(100));
    }
}

#[test]
fn run_types_into_a_shell_session() {
    let s = Space::new("run");
    let out = s.cli(&["new", "w3", "--", "cmd"]);
    assert!(out.status.success(), "new: {}", String::from_utf8_lossy(&out.stderr));
    std::thread::sleep(Duration::from_millis(500));
    let out = s.cli(&["send", "w3", "echo typed-in\r"]);
    assert!(out.status.success(), "send: {}", String::from_utf8_lossy(&out.stderr));
    s.wait_for("history", "w3", "typed-in");
    let _ = s.cli(&["kill", "w3"]);
}
