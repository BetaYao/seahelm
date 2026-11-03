//! Which agent runs in a pane, from its process tree rather than from the
//! agent's name on screen.
//!
//! Ported from `ProcessProbe.swift`, on `sysinfo` instead of `sysctl`
//! (`KERN_PROC_ALL`, `KERN_PROCARGS2`) and a `ps` fork, so it works on macOS,
//! Linux and Windows. The session's root pid (the session's shell or program)
//! comes from the daemon; from there the descendants are matched against
//! each manifest's `process` block, looking through generic runtimes
//! (node → codex). Screen text is a poor substitute: scrollback names the
//! agent long after it exited, and some agents clear their name off screen.

use std::collections::HashMap;

use seahelm_core_types::AgentType;
use sysinfo::{Pid, ProcessRefreshKind, ProcessesToUpdate, System, UpdateKind};

use crate::manifest::{AgentManifest, ManifestStore};

/// One process, as identification needs it.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Proc {
    pub pid: u32,
    /// 0 when the process has no parent the system will name.
    pub ppid: u32,
    /// Empty until read: argv is read only for the few processes under a
    /// session, never for the whole machine.
    pub argv: Vec<String>,
    pub resident_bytes: Option<u64>,
}

impl Proc {
    pub fn new(pid: u32, ppid: u32, argv: &[&str]) -> Proc {
        Proc { pid, ppid, argv: argv.iter().map(|s| s.to_string()).collect(), resident_bytes: None }
    }

    /// argv0's basename, lowercased. Both separators are honoured so a
    /// Windows path reads the same as a Unix one.
    pub fn exec_basename(&self) -> String {
        self.argv.first().map(|a| basename(a).to_lowercase()).unwrap_or_default()
    }
}

fn basename(path: &str) -> &str {
    path.rsplit(['/', '\\']).next().unwrap_or(path)
}

/// The machine's process tree, captured once per poll cycle and shared by
/// every pane: pid, parent and resident memory for every process, argv for
/// none (it is read per session in [`probe`]). Paying for the walk per pane
/// was what pinned a core in the Swift app.
#[derive(Clone, Debug, Default)]
pub struct ProcessTable {
    procs: Vec<Proc>,
    /// Captured from the system, so argv can be read for the pids a probe
    /// needs. A table built from given processes (tests) uses their argv.
    live: bool,
}

impl ProcessTable {
    /// Walk the system's process table.
    pub fn capture() -> Self {
        let mut sys = System::new();
        sys.refresh_processes_specifics(ProcessesToUpdate::All, true, ProcessRefreshKind::nothing().with_memory());
        let mut procs: Vec<Proc> = sys
            .processes()
            .values()
            .map(|p| Proc {
                pid: p.pid().as_u32(),
                ppid: p.parent().map(|pp| pp.as_u32()).unwrap_or(0),
                argv: Vec::new(),
                resident_bytes: Some(p.memory()),
            })
            .collect();
        // HashMap order would make "the first process that matches" vary
        // between captures.
        procs.sort_by_key(|p| p.pid);
        ProcessTable { procs, live: true }
    }

    /// A table of known processes, argv included (tests, or a caller with
    /// its own source).
    pub fn from_procs(procs: Vec<Proc>) -> Self {
        ProcessTable { procs, live: false }
    }

    pub fn procs(&self) -> &[Proc] {
        &self.procs
    }

    pub fn contains(&self, pid: u32) -> bool {
        self.procs.iter().any(|p| p.pid == pid)
    }

    /// `procs` with argv filled in (read from the system for a live table).
    fn with_argv(&self, procs: Vec<Proc>) -> Vec<Proc> {
        if !self.live || procs.is_empty() {
            return procs;
        }
        let argv = read_argv(&procs.iter().map(|p| p.pid).collect::<Vec<_>>());
        procs
            .into_iter()
            .map(|mut p| {
                p.argv = argv.get(&p.pid).cloned().unwrap_or_default();
                p
            })
            .collect()
    }
}

/// argv for a few pids, read fresh.
pub fn read_argv(pids: &[u32]) -> HashMap<u32, Vec<String>> {
    let pids: Vec<Pid> = pids.iter().map(|&p| Pid::from_u32(p)).collect();
    let mut sys = System::new();
    sys.refresh_processes_specifics(ProcessesToUpdate::Some(&pids), false, ProcessRefreshKind::nothing().with_cmd(UpdateKind::Always));
    sys.processes()
        .values()
        .map(|p| (p.pid().as_u32(), p.cmd().iter().map(|a| a.to_string_lossy().into_owned()).collect()))
        .collect()
}

/// What one probe of a session found.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Probe {
    pub agent: Option<AgentType>,
    /// The session's root process is alive and was looked at. Only then does
    /// `agent: None` mean "no agent running" rather than "could not look".
    pub saw_session: bool,
    /// The foreground job for the pane title (`brew update`).
    pub foreground_command_line: Option<String>,
    /// Resident bytes of the session's whole tree, root included.
    pub memory_bytes: u64,
}

impl Probe {
    /// Could not look: says nothing about the agent.
    pub fn miss() -> Probe {
        Probe::default()
    }
}

/// Probe the session rooted at `root_pid`.
pub fn probe(table: &ProcessTable, root_pid: u32, store: &ManifestStore) -> Probe {
    let Some(root) = table.procs.iter().find(|p| p.pid == root_pid) else {
        return Probe::miss();
    };
    let tree = descendants(root_pid, &table.procs);
    let memory_bytes = unique_memory_bytes(std::iter::once(root).chain(tree.iter()));
    // The root is usually the session's shell (the app launches agents as
    // `zsh -lic '… && claude; exec zsh -l'`), but a session can also run the
    // agent as its own program (`seahelmd new NAME -- claude`), and then the
    // root *is* the agent. So the root is read too, and set aside only when
    // it is a shell.
    let mut procs = table.with_argv(std::iter::once(root.clone()).chain(tree).collect());
    let root_is_shell = procs[0].argv.is_empty() || is_shell(&procs[0].exec_basename());
    if root_is_shell {
        procs.remove(0);
        // A bare shell has no descendants: the plainest "no agent".
        if procs.is_empty() {
            return Probe { saw_session: true, memory_bytes, ..Probe::default() };
        }
    }
    let agent = identify(&procs, store.all().map(|c| &c.manifest))
        .map(|id| AgentType::from_manifest_id(&id))
        .filter(|t| *t != AgentType::Unknown);
    // A program run as the session root is the foreground job, whatever
    // helpers it has started (an agent's MCP servers are not the title).
    let foreground_command_line =
        if root_is_shell { foreground_command_line(&procs) } else { foreground_command_line(&procs[..1]) };
    Probe { agent, saw_session: true, foreground_command_line, memory_bytes }
}

/// The manifest id of the agent among `procs`, or None. Pass 1: argv0's
/// basename in a manifest's `exec_names` (most specific). Pass 2:
/// `argv_contains`, for processes whose argv0 is one of the manifest's
/// generic runtimes, or any process when it names none.
pub fn identify<'a>(procs: &[Proc], manifests: impl IntoIterator<Item = &'a AgentManifest>) -> Option<String> {
    let manifests: Vec<&AgentManifest> = manifests.into_iter().collect();
    for p in procs {
        if let Some(m) = manifests.iter().find(|m| directly_matches(p, m)) {
            return Some(m.id.clone());
        }
    }
    for p in procs {
        for m in &manifests {
            let Some(pm) = &m.process else { continue };
            if pm.argv_contains.is_empty() {
                continue;
            }
            let exec = p.exec_basename();
            let generic = pm.generic_runtimes.contains(&exec);
            if argv_matches(p, m) && (generic || pm.generic_runtimes.is_empty()) {
                return Some(m.id.clone());
            }
        }
    }
    None
}

/// Whether a probe could see this agent at all (its manifest names
/// processes). Looked up by exact manifest id.
pub fn can_identify<'a>(manifest_id: &str, manifests: impl IntoIterator<Item = &'a AgentManifest>) -> bool {
    manifests
        .into_iter()
        .find(|m| m.id == manifest_id)
        .and_then(|m| m.process.as_ref())
        .is_some_and(|pm| !pm.exec_names.is_empty() || !pm.argv_contains.is_empty())
}

fn directly_matches(p: &Proc, m: &AgentManifest) -> bool {
    let exec = p.exec_basename();
    m.process.as_ref().is_some_and(|pm| pm.exec_names.contains(&exec))
}

fn argv_matches(p: &Proc, m: &AgentManifest) -> bool {
    let Some(pm) = &m.process else { return false };
    if pm.argv_contains.is_empty() {
        return false;
    }
    p.argv.iter().any(|token| {
        let t = token.to_lowercase();
        pm.argv_contains.iter().any(|c| t.contains(c.as_str()))
    })
}

/// The descendants of `root` (not `root` itself), depth-first in the order
/// the Swift walked them: children kept in table order, taken from the end
/// of a stack.
pub fn descendants(root: u32, all: &[Proc]) -> Vec<Proc> {
    let mut children: HashMap<u32, Vec<&Proc>> = HashMap::new();
    for p in all {
        children.entry(p.ppid).or_default().push(p);
    }
    let mut out = Vec::new();
    let mut stack: Vec<&Proc> = children.get(&root).cloned().unwrap_or_default();
    while let Some(p) = stack.pop() {
        out.push(p.clone());
        // A pid that is its own parent (pid 0 on some systems) must not loop.
        if p.pid == p.ppid || out.len() > all.len() {
            continue;
        }
        if let Some(kids) = children.get(&p.pid) {
            stack.extend(kids.iter().copied());
        }
    }
    out
}

const SHELLS: &[&str] = &["zsh", "bash", "sh", "fish", "dash", "tcsh", "csh", "login", "pwsh", "powershell", "cmd"];

fn is_shell(basename: &str) -> bool {
    // A login shell's argv0 is `-zsh`.
    let name = basename.strip_prefix('-').unwrap_or(basename);
    let name = name.strip_suffix(".exe").unwrap_or(name);
    SHELLS.contains(&name)
}

/// The command for the pane title: a non-shell leaf under the session shell
/// (`brew update` over a `bash -c` wrapper), argv0 reduced to its basename.
pub fn foreground_command_line(procs: &[Proc]) -> Option<String> {
    let candidates: Vec<&Proc> = procs.iter().filter(|p| !is_shell(&p.exec_basename()) && !p.argv.is_empty()).collect();
    let leaves: Vec<&&Proc> = candidates.iter().filter(|c| !candidates.iter().any(|o| o.ppid == c.pid)).collect();
    let pick = leaves.last().map(|p| **p).or_else(|| candidates.last().copied())?;
    let head = basename(&pick.argv[0]);
    let mut parts = vec![head.to_string()];
    parts.extend(pick.argv[1..].iter().cloned());
    Some(parts.join(" "))
}

/// Memory under a session root.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SessionMemory {
    /// The root and all its descendants.
    pub total_bytes: u64,
    /// Every recognised agent process and its children, so Claude Code's
    /// node helpers count with the agent, not only its thin launcher.
    pub agent_bytes: u64,
    pub process_name: Option<String>,
}

pub fn memory<'a>(root_pid: u32, all: &[Proc], manifests: impl IntoIterator<Item = &'a AgentManifest>) -> SessionMemory {
    let manifests: Vec<&AgentManifest> = manifests.into_iter().collect();
    let tree = descendants(root_pid, all);
    let root = all.iter().find(|p| p.pid == root_pid);
    let total_bytes = unique_memory_bytes(root.into_iter().chain(tree.iter()));

    let mut children: HashMap<u32, Vec<u32>> = HashMap::new();
    for p in all {
        children.entry(p.ppid).or_default().push(p.pid);
    }
    let mut agent_pids = std::collections::HashSet::new();
    for agent_root in tree.iter().filter(|p| manifests.iter().any(|m| directly_matches(p, m) || argv_matches(p, m))) {
        let mut stack = vec![agent_root.pid];
        while let Some(pid) = stack.pop() {
            if agent_pids.insert(pid) {
                stack.extend(children.get(&pid).into_iter().flatten().copied());
            }
        }
    }
    let agent_bytes = all.iter().filter(|p| agent_pids.contains(&p.pid)).map(|p| p.resident_bytes.unwrap_or(0)).sum();
    SessionMemory { total_bytes, agent_bytes, process_name: foreground_command_line(&tree) }
}

fn unique_memory_bytes<'a>(procs: impl Iterator<Item = &'a Proc>) -> u64 {
    let mut seen = std::collections::HashSet::new();
    procs.filter(|p| seen.insert(p.pid)).map(|p| p.resident_bytes.unwrap_or(0)).sum()
}

/// `pid=<N>` of the session named `name` in `seahelmd list` output
/// (`name=… pid=… clients=…`). The core gets the pid from the daemon's
/// `Info` instead; this stays for tools that only have the list.
pub fn session_pid(name: &str, list_output: &str) -> Option<u32> {
    list_output
        .lines()
        .filter(|l| field(l, "name=") == Some(name))
        .find_map(|l| field(l, "pid=").and_then(|p| p.parse().ok()))
}

fn field<'a>(line: &'a str, key: &str) -> Option<&'a str> {
    let start = line.find(key)? + key.len();
    let rest = &line[start..];
    let end = rest.find(char::is_whitespace).unwrap_or(rest.len());
    let v = &rest[..end];
    (!v.is_empty()).then_some(v)
}

