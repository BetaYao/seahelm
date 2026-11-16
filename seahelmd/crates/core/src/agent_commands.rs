//! The slash commands a pane's agent understands, for a remote composer to
//! complete (`agent.commands`). Nothing here runs a command: a client sends
//! the text into the pane as it would any message.
//!
//! Two halves. The agent's built-ins are a table kept here, so they drift
//! with each agent's releases; a missing entry only means no completion for
//! it, and the text still goes through. Everything the user added is read
//! from where the agent itself reads it, at each call (a few dozen small
//! files): Claude Code's `commands/*.md` and `skills/*/SKILL.md`, user and
//! project, and those of its enabled plugins as `plugin:name`; Codex's
//! `$CODEX_HOME/prompts/*.md` as `prompts:name`.
//!
//! Each command says what sending it leads to (`kind`), so a client can tell
//! the user before they send it: `prompt` starts a model turn, whose answer
//! reaches the timeline like any other; `info` prints into the terminal only;
//! `interactive` opens a picker or dialog in the terminal; `session` clears,
//! replaces or ends the conversation.

use std::collections::HashSet;
use std::path::{Path, PathBuf};

use serde::Serialize;
use serde_json::Value;

use seahelm_core_types::AgentType;

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Command {
    /// Without the slash: `compact`, `code-review:code-review`.
    pub name: String,
    pub description: String,
    /// What follows the name, as the agent hints it (`[instructions]`).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub args: Option<String>,
    pub kind: &'static str,
    /// `builtin`, `user`, `project`, `skill` or `plugin`.
    pub source: &'static str,
}

const PROMPT: &str = "prompt";
const INFO: &str = "info";
const INTERACTIVE: &str = "interactive";
const SESSION: &str = "session";

type Builtin = (&'static str, &'static str, Option<&'static str>, &'static str);

const CLAUDE: &[Builtin] = &[
    ("add-dir", "Add a working directory", Some("<path>"), INFO),
    ("agents", "Manage subagents", None, INTERACTIVE),
    ("bashes", "List and manage background tasks", None, INTERACTIVE),
    ("clear", "Clear the conversation history", None, SESSION),
    ("compact", "Compact the conversation, keeping a summary", Some("[instructions]"), PROMPT),
    ("config", "Open settings", None, INTERACTIVE),
    ("context", "Show how the context window is used", None, INFO),
    ("cost", "Show this session's token cost and duration", None, INFO),
    ("doctor", "Check the Claude Code installation", None, INFO),
    ("exit", "Exit Claude Code", None, SESSION),
    ("export", "Export the conversation", Some("[file]"), INTERACTIVE),
    ("feedback", "Send feedback about Claude Code", None, INTERACTIVE),
    ("help", "Show help and available commands", None, INFO),
    ("hooks", "Manage hooks", None, INTERACTIVE),
    ("ide", "Manage IDE integrations", None, INTERACTIVE),
    ("init", "Write a CLAUDE.md for this project", None, PROMPT),
    ("login", "Sign in to your Anthropic account", None, SESSION),
    ("logout", "Sign out of your Anthropic account", None, SESSION),
    ("mcp", "Manage MCP servers", None, INTERACTIVE),
    ("memory", "Edit memory files", None, INTERACTIVE),
    ("model", "Choose the model", Some("[model]"), INTERACTIVE),
    ("output-style", "Choose the output style", None, INTERACTIVE),
    ("permissions", "View or change tool permissions", None, INTERACTIVE),
    ("plugin", "Manage plugins", None, INTERACTIVE),
    ("pr-comments", "Read the comments on this branch's pull request", None, PROMPT),
    ("release-notes", "Show the release notes", None, INFO),
    ("resume", "Resume another conversation", Some("[session]"), SESSION),
    ("review", "Review a pull request", Some("[PR]"), PROMPT),
    ("rewind", "Rewind the conversation and code to an earlier point", None, INTERACTIVE),
    ("security-review", "Review this branch's changes for security issues", None, PROMPT),
    ("status", "Show version, model and account status", None, INTERACTIVE),
    ("statusline", "Set up the status line", Some("[description]"), PROMPT),
    ("todos", "Show the current todo list", None, INFO),
    ("usage", "Show plan usage limits", None, INTERACTIVE),
    ("vim", "Toggle vim editing mode", None, INFO),
];

const CODEX: &[Builtin] = &[
    ("approvals", "Choose what Codex may do without asking", None, INTERACTIVE),
    ("compact", "Summarise the conversation to free context", None, PROMPT),
    ("diff", "Show the git diff, untracked files included", None, INFO),
    ("exit", "Exit Codex", None, SESSION),
    ("feedback", "Send logs to the Codex maintainers", None, INTERACTIVE),
    ("init", "Write an AGENTS.md for this project", None, PROMPT),
    ("logout", "Sign out of Codex", None, SESSION),
    ("mcp", "List the configured MCP tools", None, INFO),
    ("mention", "Mention a file", None, INTERACTIVE),
    ("model", "Choose the model and reasoning effort", None, INTERACTIVE),
    ("new", "Start a new conversation", None, SESSION),
    ("quit", "Exit Codex", None, SESSION),
    ("resume", "Resume an earlier conversation", None, SESSION),
    ("review", "Review the current changes", None, INTERACTIVE),
    ("status", "Show the session's configuration and token usage", None, INFO),
];

/// Every command the agent in a pane at `worktree` takes; empty for an agent
/// with no table and no files (a shell, too).
pub fn catalog(agent: AgentType, worktree: &str, home: &Path, codex_home: Option<&Path>) -> Vec<Command> {
    let (table, mut custom) = match agent {
        AgentType::ClaudeCode => (CLAUDE, claude_custom(home, Path::new(worktree))),
        AgentType::Codex => {
            let root = codex_home.map(Path::to_path_buf).unwrap_or_else(|| home.join(".codex"));
            (CODEX, markdown_commands(&root.join("prompts"), "prompts:", "user"))
        }
        _ => return Vec::new(),
    };
    let mut out: Vec<Command> = table
        .iter()
        .map(|&(name, description, args, kind)| Command {
            name: name.into(),
            description: description.into(),
            args: args.map(str::to_string),
            kind,
            source: "builtin",
        })
        .collect();
    // A built-in wins over a file of the same name, as in the agents; among
    // files the first found wins (project before user before plugin).
    let mut seen: HashSet<String> = out.iter().map(|c| c.name.clone()).collect();
    custom.retain(|c| seen.insert(c.name.clone()));
    out.extend(custom);
    out.sort_by(|a, b| a.name.cmp(&b.name));
    out
}

fn claude_custom(home: &Path, worktree: &Path) -> Vec<Command> {
    let user = home.join(".claude");
    let project = worktree.join(".claude");
    let mut out = Vec::new();
    if !worktree.as_os_str().is_empty() {
        out.extend(markdown_commands(&project.join("commands"), "", "project"));
        out.extend(skills(&project.join("skills"), ""));
    }
    out.extend(markdown_commands(&user.join("commands"), "", "user"));
    out.extend(skills(&user.join("skills"), ""));
    for (plugin, root) in claude_plugins(&user, &project) {
        let prefix = format!("{plugin}:");
        // The manifest may name its own paths instead of the default folders.
        let manifest = std::fs::read_to_string(root.join(".claude-plugin/plugin.json")).ok().and_then(|s| serde_json::from_str::<Value>(&s).ok());
        let paths = |key: &str| -> Vec<PathBuf> {
            match manifest.as_ref().and_then(|m| m.get(key)) {
                Some(Value::String(p)) => vec![root.join(p)],
                Some(Value::Array(ps)) => ps.iter().filter_map(Value::as_str).map(|p| root.join(p)).collect(),
                _ => vec![root.join(key)],
            }
        };
        for dir in paths("commands") {
            let found = if dir.is_file() { markdown_file(&dir, &prefix, "plugin").into_iter().collect() } else { markdown_commands(&dir, &prefix, "plugin") };
            out.extend(found);
        }
        for dir in paths("skills") {
            let found = if dir.join("SKILL.md").is_file() { skill(&dir, &prefix).into_iter().collect() } else { skills(&dir, &prefix) };
            out.extend(found.into_iter().map(|c| Command { source: "plugin", ..c }));
        }
    }
    out
}

/// Enabled plugins (user settings, then the project's) and where each is
/// installed: `(name before the @, install path)`.
fn claude_plugins(user: &Path, project: &Path) -> Vec<(String, PathBuf)> {
    let read = |p: PathBuf| std::fs::read_to_string(p).ok().and_then(|s| serde_json::from_str::<Value>(&s).ok());
    let mut enabled: Vec<(String, bool)> = Vec::new();
    for settings in [user.join("settings.json"), project.join("settings.json"), project.join("settings.local.json")] {
        if let Some(map) = read(settings).and_then(|v| v.get("enabledPlugins").and_then(Value::as_object).cloned()) {
            for (id, on) in map {
                let on = on.as_bool().unwrap_or(false);
                enabled.retain(|(e, _)| *e != id);
                enabled.push((id, on));
            }
        }
    }
    let Some(installed) = read(user.join("plugins").join("installed_plugins.json")) else { return Vec::new() };
    enabled
        .into_iter()
        .filter(|(_, on)| *on)
        .filter_map(|(id, _)| {
            let entry = installed.pointer(&format!("/plugins/{}", id.replace('~', "~0").replace('/', "~1")))?;
            let path = entry.as_array().and_then(|a| a.first()).unwrap_or(entry).get("installPath")?.as_str()?;
            Some((id.split('@').next().unwrap_or(&id).to_string(), PathBuf::from(path)))
        })
        .collect()
}

/// `<dir>/**/*.md`, each a command named after its file.
fn markdown_commands(dir: &Path, prefix: &str, source: &'static str) -> Vec<Command> {
    let mut files = Vec::new();
    collect_md(dir, 0, &mut files);
    files.sort();
    files.into_iter().filter_map(|path| markdown_file(&path, prefix, source)).collect()
}

fn markdown_file(path: &Path, prefix: &str, source: &'static str) -> Option<Command> {
    let stem = path.file_stem()?.to_str()?.to_string();
    let (front, body) = split_front_matter(&std::fs::read_to_string(path).ok()?);
    Some(Command {
        name: format!("{prefix}{stem}"),
        description: describe(&front, &body),
        args: field(&front, "argument-hint"),
        kind: PROMPT,
        source,
    })
}

fn collect_md(dir: &Path, depth: usize, out: &mut Vec<PathBuf>) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    for e in entries.flatten() {
        let path = e.path();
        if path.is_dir() && depth < 3 {
            collect_md(&path, depth + 1, out);
        } else if path.extension().is_some_and(|x| x == "md") {
            out.push(path);
        }
    }
}

/// `<dir>/<name>/SKILL.md`, each invocable as `/name` unless it says
/// `user-invocable: false`.
fn skills(dir: &Path, prefix: &str) -> Vec<Command> {
    let Ok(entries) = std::fs::read_dir(dir) else { return Vec::new() };
    let mut out: Vec<Command> = entries.flatten().filter_map(|e| skill(&e.path(), prefix)).collect();
    out.sort_by(|a, b| a.name.cmp(&b.name));
    out
}

/// One skill folder.
fn skill(dir: &Path, prefix: &str) -> Option<Command> {
    let text = std::fs::read_to_string(dir.join("SKILL.md")).ok()?;
    let (front, body) = split_front_matter(&text);
    if front.as_ref().and_then(|f| f.get("user-invocable")).and_then(serde_yaml::Value::as_bool) == Some(false) {
        return None;
    }
    let name = field(&front, "name").unwrap_or_else(|| dir.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default());
    Some(Command {
        name: format!("{prefix}{name}"),
        description: describe(&front, &body),
        args: field(&front, "argument-hint"),
        kind: PROMPT,
        source: "skill",
    })
}

fn split_front_matter(text: &str) -> (Option<serde_yaml::Mapping>, String) {
    let rest = text.strip_prefix("\u{feff}").unwrap_or(text);
    let Some(after) = rest.strip_prefix("---\n").or_else(|| rest.strip_prefix("---\r\n")) else {
        return (None, rest.to_string());
    };
    let Some(end) = after.find("\n---") else { return (None, rest.to_string()) };
    let front = serde_yaml::from_str::<serde_yaml::Mapping>(&after[..end]).ok();
    let body = after[end + 4..].split_once('\n').map(|(_, b)| b).unwrap_or("").to_string();
    (front, body)
}

fn field(front: &Option<serde_yaml::Mapping>, key: &str) -> Option<String> {
    let v = front.as_ref()?.get(key)?;
    let s = match v {
        serde_yaml::Value::String(s) => s.clone(),
        serde_yaml::Value::Sequence(items) => items.iter().filter_map(serde_yaml::Value::as_str).collect::<Vec<_>>().join(" "),
        _ => return None,
    };
    let s = s.split_whitespace().collect::<Vec<_>>().join(" ");
    (!s.is_empty()).then_some(s)
}

/// The front matter's description, else the body's first line of prose,
/// cut to a line a menu can show.
fn describe(front: &Option<serde_yaml::Mapping>, body: &str) -> String {
    let text = field(front, "description").unwrap_or_else(|| {
        body.lines()
            .map(|l| l.trim().trim_start_matches('#').trim())
            .find(|l| !l.is_empty())
            .unwrap_or("")
            .to_string()
    });
    const MAX: usize = 140;
    if text.chars().count() <= MAX {
        text
    } else {
        format!("{}…", text.chars().take(MAX - 1).collect::<String>().trim_end())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write(path: &Path, text: &str) {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, text).unwrap();
    }

    fn names(c: &[Command]) -> Vec<&str> {
        c.iter().map(|c| c.name.as_str()).collect()
    }

    #[test]
    fn claude_reads_commands_skills_and_enabled_plugins() {
        let home = tempfile::tempdir().unwrap();
        let wt = tempfile::tempdir().unwrap();
        let h = home.path();
        write(&h.join(".claude/commands/ship.md"), "---\ndescription: Ship it\nargument-hint: \"[branch]\"\n---\nbody");
        write(&h.join(".claude/commands/nested/tidy.md"), "# Tidy the repo\n\nMore.");
        write(&h.join(".claude/commands/compact.md"), "---\ndescription: mine\n---\n");
        write(&h.join(".claude/skills/drive/SKILL.md"), "---\nname: drive\ndescription: >-\n  Drive the\n  terminal\n---\n");
        write(&h.join(".claude/skills/hidden/SKILL.md"), "---\nname: hidden\nuser-invocable: false\n---\n");
        write(&wt.path().join(".claude/commands/ship.md"), "---\ndescription: Project ship\n---\n");
        let plugin = h.join("plugins/cache/cr/1.0");
        write(&plugin.join("commands/code-review.md"), "---\ndescription: Review a PR\n---\n");
        write(&plugin.join("skills/tdd/SKILL.md"), "---\nname: tdd\ndescription: Test first\n---\n");
        let listed = h.join("plugins/cache/mp/1.3");
        write(&listed.join(".claude-plugin/plugin.json"), r#"{"name": "mp", "skills": ["./skills/engineering/grill"]}"#);
        write(&listed.join("skills/engineering/grill/SKILL.md"), "---\nname: grilling\ndescription: Grill the plan\n---\n");
        write(&h.join(".claude/plugins/installed_plugins.json"), &serde_json::json!({"version": 2, "plugins": {
            "code-review@official": [{"installPath": plugin}], "off@official": [{"installPath": plugin}],
            "mp@official": [{"installPath": listed}]}}).to_string());
        write(&h.join(".claude/settings.json"), r#"{"enabledPlugins": {"code-review@official": true, "off@official": false, "mp@official": true}}"#);

        let c = catalog(AgentType::ClaudeCode, &wt.path().to_string_lossy(), h, None);
        let by = |n: &str| c.iter().find(|c| c.name == n).unwrap_or_else(|| panic!("{n} missing from {:?}", names(&c)));
        assert_eq!((by("ship").description.as_str(), by("ship").source), ("Project ship", "project"), "project before user");
        assert_eq!(by("compact").source, "builtin", "a built-in wins");
        assert_eq!(by("tidy").description, "Tidy the repo");
        assert_eq!(by("drive").description, "Drive the terminal");
        assert_eq!((by("code-review:code-review").source, by("code-review:tdd").kind), ("plugin", PROMPT));
        assert_eq!(by("model").kind, INTERACTIVE);
        assert_eq!(by("mp:grilling").description, "Grill the plan", "skills the manifest lists");
        assert!(!names(&c).contains(&"hidden") && !names(&c).iter().any(|n| n.starts_with("off:")));
        assert!(names(&c).windows(2).all(|w| w[0] <= w[1]), "sorted");
    }

    #[test]
    fn codex_reads_its_prompts_and_a_shell_has_none() {
        let home = tempfile::tempdir().unwrap();
        let codex = home.path().join("codex-home");
        write(&codex.join("prompts/deploy.md"), "---\ndescription: Deploy\nargument-hint: ENV=<env>\n---\n");
        let c = catalog(AgentType::Codex, "/nowhere", home.path(), Some(&codex));
        let deploy = c.iter().find(|c| c.name == "prompts:deploy").unwrap();
        assert_eq!(deploy.args.as_deref(), Some("ENV=<env>"));
        assert!(c.iter().any(|c| c.name == "model" && c.source == "builtin"));
        assert!(catalog(AgentType::ShellCommand, "/w", home.path(), None).is_empty());
    }
}
