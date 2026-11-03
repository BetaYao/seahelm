//! Port of Tests/ProcessProbeTests.swift. The live tests read through
//! `sysinfo` instead of `sysctl`, so the buffer-reuse case becomes "argv of
//! two processes read in one batch do not bleed into each other", and the
//! table carries memory (sysinfo reads it with the tree; there is no `ps`
//! fork to avoid).

use seahelm_core_scan::manifest::AgentManifest;
use seahelm_core_scan::process::{self, descendants, foreground_command_line, identify, session_pid, Proc, ProcessTable};
use seahelm_core_scan::ManifestStore;
use seahelm_core_types::AgentType;

fn manifest(id: &str, exec: &[&str], argv: &[&str], generic: &[&str]) -> AgentManifest {
    let json = serde_json::json!({
        "id": id,
        "process": { "exec_names": exec, "argv_contains": argv, "generic_runtimes": generic },
        "rules": []
    });
    AgentManifest::from_json(&json.to_string()).unwrap()
}

fn p(pid: u32, ppid: u32, argv: &[&str]) -> Proc {
    Proc::new(pid, ppid, argv)
}

fn pm(pid: u32, ppid: u32, argv: &[&str], mb: u64) -> Proc {
    Proc { resident_bytes: Some(mb * 1_048_576), ..Proc::new(pid, ppid, argv) }
}

#[test]
fn session_pid_parse() {
    let out = "  name=seahelm-repo-feat\tpid=4242\tclients=1\tstart_dir=/x\n  name=other\tpid=99\tclients=0\tstart_dir=/y";
    assert_eq!(session_pid("seahelm-repo-feat", out), Some(4242));
    assert_eq!(session_pid("missing", out), None);
}

#[test]
fn direct_exec_match() {
    let ms = [manifest("claude", &["claude"], &[], &[]), manifest("codex", &["codex"], &[], &[])];
    let procs = [p(2, 1, &["/bin/zsh"]), p(3, 2, &["/opt/homebrew/bin/claude", "--foo"])];
    assert_eq!(identify(&procs, &ms).as_deref(), Some("claude"));
}

#[test]
fn wrapper_penetration_node_to_codex() {
    let ms = [manifest("codex", &["codex"], &["codex"], &["node"])];
    let procs = [p(5, 1, &["node", "/usr/local/lib/codex/bin/codex.js"])];
    assert_eq!(identify(&procs, &ms).as_deref(), Some("codex"));
}

#[test]
fn generic_runtime_alone_does_not_match() {
    let ms = [manifest("codex", &["codex"], &["codex"], &["node"])];
    let procs = [p(5, 1, &["node", "/some/other/app.js"])];
    assert_eq!(identify(&procs, &ms), None);
}

#[test]
fn exec_names_wins_over_argv() {
    let ms = [manifest("claude", &["claude"], &[], &[]), manifest("codex", &["codex"], &["codex"], &["node"])];
    let procs = [p(9, 1, &["/bin/claude"])];
    assert_eq!(identify(&procs, &ms).as_deref(), Some("claude"));
}

#[test]
fn bundled_manifests_all_load_and_identify() {
    let store = ManifestStore::bundled();
    for id in ["claude", "codex", "opencode", "gemini", "cline", "goose", "amp", "aider", "cursor", "kiro"] {
        let cm = store.get(id).unwrap_or_else(|| panic!("missing manifest {id}"));
        assert!(cm.manifest.process.is_some(), "{id} has no process block");
        assert_ne!(AgentType::from_manifest_id(id), AgentType::Unknown, "{id} has no AgentType");
    }
}

#[test]
fn identify_opencode_from_process() {
    let store = ManifestStore::bundled();
    let procs = [p(7, 1, &["node", "/opt/opencode/bin/opencode"])];
    assert_eq!(identify(&procs, store.all().map(|c| &c.manifest)).as_deref(), Some("opencode"));
}

/// Cursor's CLI entrypoint is `agent`; its install path still says
/// `cursor-agent`.
#[test]
fn identify_cursor_agent_cli_entrypoint() {
    let store = ManifestStore::bundled();
    let via_agent = [p(
        7,
        1,
        &["/Users/me/.local/bin/agent", "--use-system-ca", "/Users/me/.local/share/cursor-agent/versions/2026.07.17/index.js"],
    )];
    assert_eq!(identify(&via_agent, store.all().map(|c| &c.manifest)).as_deref(), Some("cursor"));
    let via_alias = [p(8, 1, &["/Users/me/.local/bin/cursor-agent"])];
    assert_eq!(identify(&via_alias, store.all().map(|c| &c.manifest)).as_deref(), Some("cursor"));
}

#[test]
fn descendants_walk() {
    let all = [p(2, 1, &["zsh"]), p(3, 2, &["node"]), p(4, 3, &["codex"]), p(5, 1, &["unrelated"])];
    let mut d: Vec<u32> = descendants(2, &all).iter().map(|p| p.pid).collect();
    d.sort();
    assert_eq!(d, [3, 4]);
}

#[test]
fn session_memory_includes_agent_subtree() {
    let ms = [manifest("claude", &["claude"], &["claude-code"], &["node"])];
    let all = [
        pm(2, 1, &["/bin/zsh"], 1),
        pm(3, 2, &["/opt/homebrew/bin/claude"], 20),
        pm(4, 3, &["node", "/Users/me/.claude/helper.js"], 300),
        pm(5, 2, &["/usr/bin/git", "status"], 9),
    ];
    let mem = process::memory(2, &all, &ms);
    assert_eq!(mem.total_bytes, 330 * 1_048_576);
    assert_eq!(mem.agent_bytes, 320 * 1_048_576);
    assert!(mem.process_name.is_some());
}

#[test]
fn session_memory_counts_claude_code_node_wrapper_and_children() {
    let ms = [manifest("claude", &[], &["claude-code"], &["node"])];
    let all = [
        pm(2, 1, &["/bin/zsh"], 1),
        pm(3, 2, &["node", "/Users/me/.local/bin/claude-code"], 120),
        pm(4, 3, &["/usr/bin/python3", "worker.py"], 80),
    ];
    let mem = process::memory(2, &all, &ms);
    assert_eq!(mem.total_bytes, 201 * 1_048_576);
    assert_eq!(mem.agent_bytes, 200 * 1_048_576);
}

#[test]
fn foreground_command_line_prefers_leaf_job() {
    let procs = [p(3, 2, &["node", "/opt/tool/bin/wrapper.js"]), p(4, 3, &["/opt/homebrew/bin/brew", "update"])];
    assert_eq!(foreground_command_line(&procs).as_deref(), Some("brew update"));
}

#[test]
fn foreground_command_line_skips_nested_shells() {
    let procs = [p(3, 2, &["/bin/bash", "-c", "sleep 1"]), p(4, 3, &["/bin/sleep", "1"])];
    assert_eq!(foreground_command_line(&procs).as_deref(), Some("sleep 1"));
}

#[test]
fn foreground_command_line_nil_when_only_shells() {
    let procs = [p(3, 2, &["/bin/zsh"]), p(4, 3, &["bash"])];
    assert_eq!(foreground_command_line(&procs), None);
}

// MARK: - Live reads (this test process and its children)

#[test]
fn argv_reads_own_process() {
    let pid = std::process::id();
    let argv = process::read_argv(&[pid]).remove(&pid).unwrap_or_default();
    assert!(!argv.is_empty(), "argv for the running test process must parse");
    assert!(!argv[0].is_empty(), "argv0 must not be blank");
    assert_eq!(Some(argv), process::read_argv(&[pid]).remove(&pid), "parse must be stable across calls");
}

#[cfg(unix)]
#[test]
fn argv_is_stable_when_a_buffer_is_reused_across_processes() {
    use std::process::Command;
    let padding = "Z".repeat(4096);
    let mut long = Command::new("/bin/sh").args(["-c", &format!("sleep 5 # {padding}")]).spawn().unwrap();
    let mut short = Command::new("sleep").arg("5").spawn().unwrap();
    let (lp, sp) = (long.id(), short.id());
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    let mut argv = process::read_argv(&[lp, sp]);
    while std::time::Instant::now() < deadline
        && !(argv.get(&sp).is_some_and(|a| a.len() == 2) && argv.get(&lp).is_some_and(|a| a.len() == 3))
    {
        std::thread::sleep(std::time::Duration::from_millis(20));
        argv = process::read_argv(&[lp, sp]);
    }
    let _ = long.kill();
    let _ = short.kill();
    let _ = long.wait();
    let _ = short.wait();
    let l = argv.get(&lp).cloned().unwrap_or_default();
    let s = argv.get(&sp).cloned().unwrap_or_default();
    assert!(l.join(" ").contains(&padding), "the long argv must really be long, or the short read proves nothing");
    assert_eq!(s.len(), 2, "short argv came back as {s:?}");
    assert!(s[0].ends_with("sleep"));
    assert_eq!(s[1], "5");
    assert!(!s.join("").contains('Z'), "the previous process's argv bled into the next");
}

#[test]
fn process_table_carries_tree_shape_without_argv() {
    let table = ProcessTable::capture();
    let own = table.procs().iter().find(|p| p.pid == std::process::id()).expect("own pid missing from the process table");
    #[cfg(unix)]
    assert_eq!(own.ppid, std::os::unix::process::parent_id());
    assert!(own.argv.is_empty(), "the table must not pay for argv");
    assert!(own.resident_bytes.is_some_and(|b| b > 0));
}

/// Beyond the Swift: a probe of a live session tree, rooted at a child shell.
#[cfg(unix)]
#[test]
fn probe_finds_the_foreground_job_of_a_live_session() {
    use std::process::Command;
    let mut sh = Command::new("/bin/sh").args(["-c", "sleep 5; true"]).spawn().unwrap();
    let store = ManifestStore::bundled();
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    let mut probe = process::probe(&ProcessTable::capture(), sh.id(), &store);
    while std::time::Instant::now() < deadline && probe.foreground_command_line.is_none() {
        std::thread::sleep(std::time::Duration::from_millis(20));
        probe = process::probe(&ProcessTable::capture(), sh.id(), &store);
    }
    let _ = sh.kill();
    let _ = sh.wait();
    assert!(probe.saw_session);
    assert_eq!(probe.agent, None);
    assert_eq!(probe.foreground_command_line.as_deref(), Some("sleep 5"));
    assert!(probe.memory_bytes > 0);

    assert_eq!(process::probe(&ProcessTable::capture(), u32::MAX - 1, &store), process::Probe::miss());
}

/// Beyond the Swift: identification through a table of given processes.
#[test]
fn probe_identifies_through_a_given_table() {
    let store = ManifestStore::bundled();
    let table = ProcessTable::from_procs(vec![p(2, 1, &["/bin/zsh"]), p(3, 2, &["node", "/x/codex/bin/codex.js"])]);
    let probe = process::probe(&table, 2, &store);
    assert_eq!(probe.agent, Some(AgentType::Codex));
    assert!(probe.saw_session);
    let bare = ProcessTable::from_procs(vec![p(2, 1, &["/bin/zsh"])]);
    let probe = process::probe(&bare, 2, &store);
    assert!(probe.saw_session && probe.agent.is_none());
}

#[test]
fn an_agent_run_as_the_session_root_is_identified() {
    // `seahelmd new NAME -- claude`: the root is the agent, its children are
    // helpers (an MCP server), and the title is the agent's own command.
    let table = ProcessTable::from_procs(vec![
        Proc::new(100, 1, &["/Users/x/.local/bin/claude", "--resume", "abc"]),
        Proc::new(101, 100, &["node", "/tmp/mcp-server.js"]),
    ]);
    let p = process::probe(&table, 100, &ManifestStore::bundled());
    assert_eq!(p.agent, Some(AgentType::ClaudeCode));
    assert!(p.saw_session);
    assert_eq!(p.foreground_command_line.as_deref(), Some("claude --resume abc"));
}

#[test]
fn a_shell_root_is_still_set_aside() {
    let table = ProcessTable::from_procs(vec![
        Proc::new(100, 1, &["-zsh"]),
        Proc::new(101, 100, &["brew", "update"]),
    ]);
    let p = process::probe(&table, 100, &ManifestStore::bundled());
    assert_eq!(p.agent, None);
    assert_eq!(p.foreground_command_line.as_deref(), Some("brew update"));
}
