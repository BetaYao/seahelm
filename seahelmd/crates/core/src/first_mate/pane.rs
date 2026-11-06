//! Where First Mate lives (`FirstMatePane.swift`): one seahelmd session, one
//! directory, and the files seahelm keeps there. The same session name,
//! directory and files as the app's, so whichever owns First Mate finds the
//! other's state.

use std::path::{Path, PathBuf};

use serde_json::json;

use super::policy::SESSION;

pub const PROJECT: &str = "First Mate";

/// Bumped whenever the instructions or permissions change. Kept equal to
/// the app's while the text is the same, so the two never fight over the
/// files.
pub const VERSION: u32 = 4;

/// A digest of the instructions (FNV-1a, stable across builds). In the
/// managed files' marker and in the session stamp, so a change to
/// `instructions.md` reaches First Mate by itself: the files are rewritten
/// and its session replaced, without anyone remembering to bump `VERSION`
/// (phases 5–9 changed the instructions and the deployed copy stayed at
/// the one from before them).
pub fn instructions_digest() -> String {
    digest_of(INSTRUCTIONS)
}

fn digest_of(text: &str) -> String {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for b in text.bytes() {
        h ^= u64::from(b);
        h = h.wrapping_mul(0x0100_0000_01b3);
    }
    format!("{:08x}", h >> 32)
}

pub const INSTRUCTIONS: &str = include_str!("instructions.md");

/// The part of the managed files seahelm writes for this user: the language
/// to answer in (`first_mate_language`) and the standing orders. Claude Code
/// imports `standing-orders.md` itself (`@file`), so it is in First Mate's
/// context from the first turn; Codex has no imports and is told to read it.
/// Without this First Mate answered in English: the instructions said what
/// goes into the standing orders but never to read them, and the language
/// setting only reached the core's own lines.
pub fn user_section(name: &str, lang: super::lang::Lang) -> String {
    let language = lang.pick("English", "Chinese (中文)");
    let mut s = format!(
        "\n\n## Language and standing orders (written by seahelm)\n\n\
         Write every reply to the user, every event report and every summary in {language} \
         (`first_mate_language`). The user's own words in `standing-orders.md` win over this line.\n\n\
         Read `standing-orders.md` (in this directory) before acting on any event: it holds what the \
         user asked you to keep doing, or stop doing, everywhere.\n"
    );
    if name == "CLAUDE.md" {
        s += "\n@standing-orders.md\n";
    }
    s
}

/// The digest the managed files and the session are stamped with: the
/// instructions and the user's part, so changing the language rewrites the
/// files and replaces the session too.
pub fn managed_digest(lang: super::lang::Lang) -> String {
    digest_of(&format!("{INSTRUCTIONS}{}", user_section("CLAUDE.md", lang)))
}

pub fn dir() -> PathBuf {
    crate::rpc::config_dir().join("first-mate")
}

/// The agents First Mate can be: each has a way to be held to read-mostly
/// work (Claude Code's permission rules, Codex's sandbox).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Agent {
    Claude,
    Codex,
}

impl Agent {
    /// `config.json` `autopilot_agent`: the app's `AgentType` raw value.
    pub fn from_config(raw: &str) -> Self {
        if raw == "codex" {
            Agent::Codex
        } else {
            Agent::Claude
        }
    }

    pub fn raw(self) -> &'static str {
        match self {
            Agent::Claude => "claudeCode",
            Agent::Codex => "codex",
        }
    }

    /// Never the bypass flag. `--permission-mode default` because a
    /// user-level `bypassPermissions` would otherwise switch the gate off;
    /// Codex's sandbox with network on, or neither gh nor the socket works.
    pub fn launch(self) -> &'static str {
        match self {
            Agent::Claude => "claude --permission-mode default",
            Agent::Codex => "codex --sandbox workspace-write --ask-for-approval on-request -c sandbox_workspace_write.network_access=true",
        }
    }
}

/// Version, agent and owner: switching agent replaces the session as surely
/// as a new version does, and so does switching between the app and the
/// core — the app's session has no `seahelm` shim on its PATH, so its First
/// Mate would talk to an app that no longer runs it.
pub fn stamp(agent: Agent, lang: super::lang::Lang) -> String {
    format!("{VERSION}.{}:{}:core", managed_digest(lang), agent.raw())
}

pub fn session_is_current(dir: &Path, agent: Agent, lang: super::lang::Lang) -> bool {
    std::fs::read_to_string(dir.join(".session-version")).is_ok_and(|s| s.trim() == stamp(agent, lang))
}

pub fn mark_session_current(dir: &Path, agent: Agent, lang: super::lang::Lang) {
    let _ = std::fs::write(dir.join(".session-version"), stamp(agent, lang));
}

/// Claude Code's own gate for this directory: only reads and `seahelm`
/// itself run unasked, so an agent free to run any shell command cannot
/// step around seahelm's policy.
pub fn permissions() -> serde_json::Value {
    json!({"permissions": {
        "defaultMode": "default",
        "allow": [
            "Bash(seahelm:*)",
            "Bash(gh pr view:*)", "Bash(gh pr list:*)", "Bash(gh pr checks:*)", "Bash(gh pr diff:*)",
            "Bash(gh run view:*)", "Bash(gh run list:*)",
            "Bash(gh issue view:*)", "Bash(gh issue list:*)",
            "Bash(git -C:*)", "Bash(git status:*)", "Bash(git log:*)", "Bash(git diff:*)",
            "Read", "Grep", "Glob",
            "Edit(standing-orders.md)", "Write(standing-orders.md)",
        ],
        "deny": ["Bash(gh pr merge:*)", "Bash(git push:*)", "Bash(git worktree remove:*)", "Bash(rm:*)"],
    }})
}

/// Write the managed files (when stale), the standing orders (when absent),
/// and the `seahelm` command First Mate's instructions use: a shim onto
/// `seahelm-core cli`, first on its PATH, so the same words work on a
/// machine without the app.
pub fn provision(dir: &Path, core_exe: &Path, lang: super::lang::Lang) {
    let _ = std::fs::create_dir_all(dir.join(".claude"));
    let _ = std::fs::create_dir_all(dir.join("bin"));
    let marker = format!("<!-- seahelm-first-mate v{VERSION} {} -->", managed_digest(lang));
    for name in ["CLAUDE.md", "AGENTS.md"] {
        let path = dir.join(name);
        if !std::fs::read_to_string(&path).is_ok_and(|t| t.contains(&marker)) {
            let _ = std::fs::write(&path, format!("{marker}\n{INSTRUCTIONS}{}", user_section(name, lang)));
        }
    }
    let settings = dir.join(".claude/settings.json");
    if let Ok(text) = serde_json::to_string_pretty(&permissions()) {
        if std::fs::read_to_string(&settings).ok().and_then(|t| serde_json::from_str::<serde_json::Value>(&t).ok()) != Some(permissions()) {
            let _ = std::fs::write(&settings, text);
        }
    }
    let orders = dir.join("standing-orders.md");
    if !orders.exists() {
        let _ = std::fs::write(&orders, "# Standing orders\n\nWhat the user has asked First Mate to keep doing (or not doing).\n");
    }
    write_shim(&dir.join("bin"), core_exe);
}

#[cfg(unix)]
fn write_shim(bin: &Path, core_exe: &Path) {
    use std::os::unix::fs::PermissionsExt;
    let path = bin.join("seahelm");
    let body = format!("#!/bin/sh\nexec {} cli \"$@\"\n", crate::install::quote(&core_exe.to_string_lossy()));
    if std::fs::read_to_string(&path).ok().as_deref() != Some(body.as_str()) {
        let _ = std::fs::write(&path, body);
        let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755));
    }
}

#[cfg(windows)]
fn write_shim(bin: &Path, core_exe: &Path) {
    let path = bin.join("seahelm.cmd");
    let body = format!("@\"{}\" cli %*\r\n", core_exe.display());
    if std::fs::read_to_string(&path).ok().as_deref() != Some(body.as_str()) {
        let _ = std::fs::write(&path, body);
    }
}

/// The argv `seahelmd new` runs First Mate's agent with, in `dir`, with its
/// own `bin` first on PATH (set inside the shell: a login shell's profile
/// would otherwise put the app's `seahelm` in front of it).
pub fn session_argv(dir: &Path, agent: Agent) -> Vec<String> {
    #[cfg(unix)]
    {
        let shell = std::env::var("SHELL").ok().filter(|s| !s.is_empty()).unwrap_or_else(|| "/bin/sh".into());
        let q = |s: &str| crate::install::quote(s);
        let script = format!(
            "export PATH={}:\"$PATH\" SEAHELM_PANE_ID={SESSION}; cd {} && {}; exec {} -l",
            q(&dir.join("bin").to_string_lossy()),
            q(&dir.to_string_lossy()),
            agent.launch(),
            q(&shell)
        );
        vec![shell, "-lic".into(), script]
    }
    #[cfg(windows)]
    {
        let script = format!(
            "set \"PATH={};%PATH%\" && set SEAHELM_PANE_ID={SESSION} && cd /d \"{}\" && {}",
            dir.join("bin").display(),
            dir.display(),
            agent.launch()
        );
        vec!["cmd.exe".into(), "/k".into(), script]
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn provisions_once_and_keeps_standing_orders() {
        let d = tempfile::tempdir().unwrap();
        provision(d.path(), Path::new("/opt/seahelm-core"), super::super::lang::Lang::En);
        let claude = std::fs::read_to_string(d.path().join("CLAUDE.md")).unwrap();
        assert!(claude.starts_with(&format!("<!-- seahelm-first-mate v4 {} -->\n# You are First Mate", managed_digest(super::super::lang::Lang::En))));
        // A copy written before an instructions change is replaced.
        std::fs::write(d.path().join("CLAUDE.md"), "<!-- seahelm-first-mate v4 -->\n# old").unwrap();
        provision(d.path(), Path::new("/opt/seahelm-core"), super::super::lang::Lang::En);
        assert!(std::fs::read_to_string(d.path().join("CLAUDE.md")).unwrap().contains("# You are First Mate"));
        std::fs::write(d.path().join("standing-orders.md"), "mine").unwrap();
        provision(d.path(), Path::new("/opt/seahelm-core"), super::super::lang::Lang::En);
        assert_eq!(std::fs::read_to_string(d.path().join("standing-orders.md")).unwrap(), "mine");
        #[cfg(unix)]
        assert_eq!(std::fs::read_to_string(d.path().join("bin/seahelm")).unwrap(), "#!/bin/sh\nexec /opt/seahelm-core cli \"$@\"\n");
    }

    #[test]
    fn stamps_name_the_agent() {
        let d = tempfile::tempdir().unwrap();
        use super::super::lang::Lang;
        mark_session_current(d.path(), Agent::Claude, Lang::En);
        assert!(session_is_current(d.path(), Agent::Claude, Lang::En));
        assert!(!session_is_current(d.path(), Agent::Codex, Lang::En));
        // A language change replaces the session too.
        assert!(!session_is_current(d.path(), Agent::Claude, Lang::Zh));
    }

    #[test]
    fn the_files_carry_the_language_and_the_standing_orders() {
        use super::super::lang::Lang;
        let d = tempfile::tempdir().unwrap();
        provision(d.path(), Path::new("/opt/seahelm-core"), Lang::Zh);
        let claude = std::fs::read_to_string(d.path().join("CLAUDE.md")).unwrap();
        assert!(claude.contains("in Chinese (中文)") && claude.contains("\n@standing-orders.md\n"), "{claude}");
        let agents = std::fs::read_to_string(d.path().join("AGENTS.md")).unwrap();
        assert!(agents.contains("Read `standing-orders.md`") && !agents.contains("@standing-orders.md"));
        // Switching to English rewrites them.
        provision(d.path(), Path::new("/opt/seahelm-core"), Lang::En);
        assert!(std::fs::read_to_string(d.path().join("CLAUDE.md")).unwrap().contains("in English"));
    }
}
