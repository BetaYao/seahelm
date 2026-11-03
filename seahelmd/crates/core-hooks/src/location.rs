//! Where an agent is working, which is not always its hook `cwd`
//! (`AgentWorkLocation.swift`).
//!
//! Claude Code puts the shell back in the project directory after any
//! command that leaves it, so an agent working in a sibling worktree
//! (`../repo-feature`) reports the main checkout as its cwd on every event
//! and spells the move out in each tool call instead: `cd <worktree> && …`,
//! or an absolute path to edit. This reads those tool calls.
//!
//! `home` resolves `~`; it is an argument so nothing here reads the
//! environment.

use std::sync::OnceLock;

use regex::Regex;
use serde_json::Value;

use crate::event::WebhookEventType;
use crate::{paths, Map};

/// What a tool call says about where the agent is working.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Signal {
    /// The call works in this directory (a `cd` target, a file tool's
    /// parent directory).
    Directory(String),
    /// A shell command with no leading `cd`: it runs in the hook cwd.
    Cwd,
}

/// Tools whose input names a file the agent is changing, and the key that
/// holds it. Reads are left out: looking at another worktree is a visit,
/// not working there.
const FILE_TOOLS: [(&str, &str); 4] =
    [("Edit", "file_path"), ("MultiEdit", "file_path"), ("Write", "file_path"), ("NotebookEdit", "notebook_path")];

fn tool_call(event: WebhookEventType, data: &Map) -> Option<(&str, &Map)> {
    if event != WebhookEventType::ToolUseStart {
        return None;
    }
    let tool = data.get("tool_name")?.as_str()?;
    let input = data.get("tool_input")?.as_object()?;
    Some((tool, input))
}

/// None when the event says nothing about place: not a tool start, or a
/// tool (Read, Grep, …) whose input names nowhere it works. `cwd` resolves
/// a relative `cd`.
pub fn signal(event: WebhookEventType, data: &Map, cwd: &str, home: &str) -> Option<Signal> {
    let (tool, input) = tool_call(event, data)?;
    if tool == "Bash" {
        if let Some(command) = input.get("command").and_then(Value::as_str) {
            return Some(leading_cd(command, cwd, home).map(Signal::Directory).unwrap_or(Signal::Cwd));
        }
    }
    let key = FILE_TOOLS.iter().find(|(t, _)| *t == tool).map(|(_, k)| *k)?;
    let path = input.get(key)?.as_str().filter(|p| paths::is_absolute(p))?;
    Some(Signal::Directory(paths::parent(path)))
}

/// The directory a command `cd`s into before doing anything else:
/// `cd <dir> && …`, `cd <dir>; …`, or a bare `cd <dir>`. Quoted paths and
/// `~` are understood; anything fancier (`cd $(…)`, `cd -`) is None.
pub fn leading_cd(command: &str, cwd: &str, home: &str) -> Option<String> {
    static CD: OnceLock<Regex> = OnceLock::new();
    let re = CD.get_or_init(|| {
        Regex::new(r#"^\s*cd\s+(?:"([^"$`]+)"|'([^']+)'|([^\s;&|"'$`()]+))\s*(?:&&|;|\n|$)"#).unwrap()
    });
    let caps = re.captures(command)?;
    let dir = (1..=3).find_map(|i| caps.get(i)).map(|m| m.as_str())?;
    if dir == "-" {
        return None;
    }
    Some(paths::resolve(dir, cwd, home))
}

/// The worktree a tool call creates, when it creates one: `git worktree add
/// [options] <path> …` anywhere in a shell command (a `cd` or `git -C`
/// before it resolves a relative path), or Claude's EnterWorktree with a
/// name (`<cwd>/.claude/worktrees/<name>`). Not canonicalized: the
/// directory does not exist yet when the tool starts.
pub fn created_worktree(event: WebhookEventType, data: &Map, cwd: &str, home: &str) -> Option<String> {
    let (tool, input) = tool_call(event, data)?;
    if tool == "EnterWorktree" {
        if let Some(name) = input.get("name").and_then(Value::as_str).filter(|n| !n.is_empty() && !n.contains('/')) {
            return Some(paths::join(cwd, &format!(".claude/worktrees/{name}")));
        }
    }
    if tool != "Bash" {
        return None;
    }
    let command = input.get("command")?.as_str()?;
    let mut dir = cwd.to_string();
    for segment in command.split([';', '&', '|', '\n']) {
        let mut words = shell_words(segment);
        if words.first().map(String::as_str) == Some("cd") && words.len() == 2 {
            dir = paths::resolve(&words[1], &dir, home);
            continue;
        }
        if words.first().map(String::as_str) != Some("git") {
            continue;
        }
        words.remove(0);
        let mut base = dir.clone();
        while words.len() > 1 && words[0] == "-C" {
            base = paths::resolve(&words[1], &base, home);
            words.drain(..2);
        }
        if words.len() <= 2 || words[0] != "worktree" || words[1] != "add" {
            continue;
        }
        let mut args = words[2..].iter();
        let mut path = None;
        while let Some(arg) = args.next() {
            if !arg.starts_with('-') {
                path = Some(arg);
                break;
            }
            if ["-b", "-B", "--reason"].contains(&arg.as_str()) {
                args.next();
            }
        }
        if let Some(path) = path {
            return Some(paths::resolve(path, &base, home));
        }
    }
    None
}

/// Whitespace-split words, with single- and double-quoted runs kept whole.
fn shell_words(text: &str) -> Vec<String> {
    static WORDS: OnceLock<Regex> = OnceLock::new();
    let re = WORDS.get_or_init(|| Regex::new(r#""([^"]*)"|'([^']*)'|(\S+)"#).unwrap());
    re.captures_iter(text)
        .filter_map(|c| (1..=3).find_map(|i| c.get(i)).map(|m| m.as_str().to_string()))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const HOME: &str = "/home/me";

    fn data(v: Value) -> Map {
        v.as_object().unwrap().clone()
    }

    fn bash(command: &str) -> Option<Signal> {
        signal(WebhookEventType::ToolUseStart, &data(json!({"tool_name": "Bash", "tool_input": {"command": command}})), "/r/repo", HOME)
    }

    fn dir(s: &str) -> Option<Signal> {
        Some(Signal::Directory(s.into()))
    }

    #[test]
    fn test_leading_cd_forms() {
        assert_eq!(bash("cd /r/repo-feature && git status"), dir("/r/repo-feature"));
        assert_eq!(bash("  cd /r/repo-feature; ls"), dir("/r/repo-feature"));
        assert_eq!(bash("cd \"/r/with space\" && ls"), dir("/r/with space"));
        assert_eq!(bash("cd '/r/q' && ls"), dir("/r/q"));
        assert_eq!(bash("cd ../repo-feature && ls"), dir("/r/repo-feature"));
        assert_eq!(bash("cd /r/repo-feature"), dir("/r/repo-feature"));
        assert_eq!(bash("cd ~/x && ls"), dir("/home/me/x"));
    }

    #[test]
    fn test_commands_without_a_plain_leading_cd_run_in_the_cwd() {
        assert_eq!(bash("git status"), Some(Signal::Cwd));
        assert_eq!(bash("echo hi && cd /r/repo-feature"), Some(Signal::Cwd));
        assert_eq!(bash("cd $(git rev-parse --show-toplevel) && ls"), Some(Signal::Cwd));
        assert_eq!(bash("cd - && ls"), Some(Signal::Cwd));
        assert_eq!(bash("cd /r/a | cat"), Some(Signal::Cwd));
    }

    #[test]
    fn test_file_writes_name_their_directory_and_reads_name_nothing() {
        let edit = signal(
            WebhookEventType::ToolUseStart,
            &data(json!({"tool_name": "Edit", "tool_input": {"file_path": "/r/wt/src/a.swift"}})),
            "/r/repo",
            HOME,
        );
        assert_eq!(edit, dir("/r/wt/src"));
        let read = signal(
            WebhookEventType::ToolUseStart,
            &data(json!({"tool_name": "Read", "tool_input": {"file_path": "/r/wt/src/a.swift"}})),
            "/r/repo",
            HOME,
        );
        assert_eq!(read, None);
    }

    #[test]
    fn test_only_tool_starts_count() {
        let s = signal(
            WebhookEventType::ToolUseEnd,
            &data(json!({"tool_name": "Bash", "tool_input": {"command": "cd /r/wt"}})),
            "/r/repo",
            HOME,
        );
        assert_eq!(s, None);
    }

    fn created(command: &str) -> Option<String> {
        created_worktree(
            WebhookEventType::ToolUseStart,
            &data(json!({"tool_name": "Bash", "tool_input": {"command": command}})),
            "/r/repo",
            HOME,
        )
    }

    #[test]
    fn test_git_worktree_add_names_the_worktree_it_creates() {
        assert_eq!(created("git worktree add ../repo-x").as_deref(), Some("/r/repo-x"));
        assert_eq!(
            created("git fetch -q origin main && git worktree add -q -b chore/x ../repo-x origin/main").as_deref(),
            Some("/r/repo-x")
        );
        assert_eq!(created("git worktree add --detach -B b \"/w/with space\" HEAD").as_deref(), Some("/w/with space"));
        assert_eq!(created("cd /r/other && git worktree add wt").as_deref(), Some("/r/other/wt"));
        assert_eq!(created("git -C /r/other worktree add ../wt").as_deref(), Some("/r/wt"));
    }

    #[test]
    fn test_other_commands_create_nothing() {
        assert_eq!(created("git worktree list"), None);
        assert_eq!(created("git worktree remove ../repo-x"), None);
        assert_eq!(created("echo git worktree add ../x"), None);
        assert_eq!(created("git worktree add"), None);
    }

    #[test]
    fn test_enter_worktree_creates_under_claude_worktrees() {
        let path = created_worktree(
            WebhookEventType::ToolUseStart,
            &data(json!({"tool_name": "EnterWorktree", "tool_input": {"name": "fix"}})),
            "/r/repo",
            HOME,
        );
        assert_eq!(path.as_deref(), Some("/r/repo/.claude/worktrees/fix"));
    }
}
