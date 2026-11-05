//! Text and the fleet it can name into one line (`CommandParser.swift`). Pure.

use crate::fleet::{FleetIndex, NameError, PaneRef, RepoRef, WorktreeRef};

#[derive(Clone, Debug, PartialEq)]
pub enum Go {
    Pane(PaneRef),
    Worktree(WorktreeRef),
    FirstMate,
}

#[derive(Clone, Debug, PartialEq)]
pub enum Command {
    /// No leading slash: said to whoever the conversation talks to.
    Say(String),
    /// None: say who that is now.
    Go(Option<Go>),
    New { task: String, repo: Option<RepoRef> },
    Status,
    Memory { verb: String, repo: RepoRef },
    /// None: the pane the conversation talks to.
    Show(Option<PaneRef>),
    Help(Option<String>),
}

#[derive(Clone, Debug, PartialEq)]
pub enum Error {
    Empty,
    UnknownCommand(String),
    BadPaneRef(String),
    UnknownPane(u32),
    UnknownWorktree(String),
    AmbiguousWorktree(String, Vec<String>),
    RepoNotWorktree(String),
    UnknownRepo(String),
    WorktreeNotRepo(String),
    MissingArgument { verb: &'static str, what: &'static str },
    BadArgument { verb: &'static str, token: String },
}

pub fn parse(text: &str, index: &FleetIndex) -> Result<Command, Error> {
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return Err(Error::Empty);
    }
    // An absolute path starts with `/` too; only `/verb` is a command.
    if !is_slash_command(trimmed) {
        return Ok(Command::Say(trimmed.into()));
    }
    let body = &trimmed[1..];
    let (verb, rest) = split_first(body);
    let verb = verb.map(|v| v.split('@').next().unwrap_or(&v).to_lowercase()).unwrap_or_default();
    if verb.is_empty() {
        return Err(Error::UnknownCommand("/".into()));
    }
    parse_verb(&verb, &rest, index)
}

/// `/name` (letters, digits, underscore), optionally `@bot`. A filesystem
/// path is not one; a lone `/` is, so it can be answered "unknown".
pub fn is_slash_command(text: &str) -> bool {
    let t = text.trim();
    if !t.starts_with('/') {
        return false;
    }
    let token = t.split([' ', '\n']).next().unwrap_or(t);
    let name = token.split('@').next().unwrap_or(token);
    let rest = &name[1..];
    if rest.is_empty() {
        return name == "/";
    }
    rest.chars().all(|c| c.is_alphanumeric() || c == '_')
}

fn parse_verb(verb: &str, rest: &str, index: &FleetIndex) -> Result<Command, Error> {
    let first = split_first(rest).0;
    match verb {
        "go" => match first {
            None => Ok(Command::Go(None)),
            Some(t) if matches!(t.to_lowercase().as_str(), "mate" | "first-mate" | "firstmate") => Ok(Command::Go(Some(Go::FirstMate))),
            Some(t) => go_target(&t, index).map(|g| Command::Go(Some(g))),
        },
        "new" => parse_new(rest, index),
        // `/notes`, not `/memory`: Claude Code has a `/memory` of its own,
        // and the same word doing something else in a pane was a trap.
        "notes" => {
            let args: Vec<_> = rest.split_whitespace().collect();
            let (verb, repo) = match args.as_slice() {
                [repo] => ("show", *repo),
                [verb, repo] if matches!(*verb, "show" | "undo") => (*verb, *repo),
                _ => return Err(Error::BadArgument { verb:"notes", token:rest.into() }),
            };
            Ok(Command::Memory { verb:verb.into(), repo:repo_ref(repo,index)? })
        },
        "status" => match first {
            None => Ok(Command::Status),
            Some(t) => Err(Error::BadArgument { verb: "status", token: t }),
        },
        "show" => match first {
            None => Ok(Command::Show(None)),
            Some(t) => pane_ref(&t, index).map(|p| Command::Show(Some(p))),
        },
        "help" => Ok(Command::Help(first.map(|t| t.trim_start_matches('/').to_lowercase()))),
        other => Err(Error::UnknownCommand(other.into())),
    }
}

fn parse_new(rest: &str, index: &FleetIndex) -> Result<Command, Error> {
    if rest.is_empty() {
        return Err(Error::MissingArgument { verb: "new", what: "a task" });
    }
    let (mut repo, mut task) = (None, rest.to_string());
    if rest.starts_with('@') {
        let (head, tail) = split_first(rest);
        repo = Some(repo_ref(&head.unwrap_or_default(), index)?);
        task = tail;
    }
    if task.is_empty() {
        return Err(Error::MissingArgument { verb: "new", what: "a task" });
    }
    Ok(Command::New { task, repo })
}

/// `#7`, or a bare number.
pub fn pane_ref(token: &str, index: &FleetIndex) -> Result<PaneRef, Error> {
    let digits = token.strip_prefix('#').unwrap_or(token);
    let handle: u32 = digits.parse().ok().filter(|h| *h > 0).ok_or_else(|| Error::BadPaneRef(token.into()))?;
    index.pane(handle).cloned().ok_or(Error::UnknownPane(handle))
}

/// `@branch`, `@repo/branch`, or the bare name.
pub fn worktree_ref(token: &str, index: &FleetIndex) -> Result<WorktreeRef, Error> {
    let name = token.strip_prefix('@').unwrap_or(token);
    if name.is_empty() {
        return Err(Error::UnknownWorktree(token.into()));
    }
    index.worktree(name).cloned().map_err(|e| match e {
        NameError::Unknown(n) => Error::UnknownWorktree(n),
        NameError::Ambiguous(n, o) => Error::AmbiguousWorktree(n, o),
        NameError::RepoNotWorktree(n) => Error::RepoNotWorktree(n),
    })
}

/// `@repo` or the bare name.
pub fn repo_ref(token: &str, index: &FleetIndex) -> Result<RepoRef, Error> {
    let name = token.strip_prefix('@').unwrap_or(token);
    if name.is_empty() {
        return Err(Error::UnknownRepo(token.into()));
    }
    if let Some(r) = index.repo(name) {
        return Ok(r.clone());
    }
    if index.worktree(name).is_ok() {
        return Err(Error::WorktreeNotRepo(name.into()));
    }
    Err(Error::UnknownRepo(name.into()))
}

/// `/go` takes either kind: the sigil decides; a bare number is a pane, a
/// bare name a worktree.
fn go_target(token: &str, index: &FleetIndex) -> Result<Go, Error> {
    if token.starts_with('#') || token.parse::<u32>().is_ok() {
        pane_ref(token, index).map(Go::Pane)
    } else {
        worktree_ref(token, index).map(Go::Worktree)
    }
}

fn split_first(text: &str) -> (Option<String>, String) {
    let t = text.trim_start();
    match t.find(char::is_whitespace) {
        None if t.is_empty() => (None, String::new()),
        None => (Some(t.into()), String::new()),
        Some(i) => (Some(t[..i].into()), t[i..].trim().into()),
    }
}


#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use seahelm_core_types::AgentStatus;

    pub fn pane(handle: u32, key: &str, project: &str, branch: &str, path: &str) -> PaneRef {
        PaneRef {
            handle,
            key: key.into(),
            project: project.into(),
            branch: branch.into(),
            worktree_path: path.into(),
            kind: "Claude Code".into(),
            title: String::new(),
            status: AgentStatus::Idle,
            last_message: String::new(),
        }
    }

    pub fn fleet() -> FleetIndex {
        let wt = |repo: &str, branch: &str, path: &str, main: bool| WorktreeRef { repo: repo.into(), branch: branch.into(), path: path.into(), is_main: main };
        FleetIndex {
            panes: vec![pane(3, "s-a", "seahelm", "main", "/r/seahelm"), pane(7, "s-b", "seahelm", "fix/login", "/r/wt/fix-login"), pane(9, "s-c", "web", "fix/login", "/r/web-wt/fix")],
            worktrees: vec![
                wt("seahelm", "main", "/r/seahelm", true),
                wt("seahelm", "fix/login", "/r/wt/fix-login", false),
                wt("web", "fix/login", "/r/web-wt/fix", false),
                wt("web", "main", "/r/web", true),
                wt("seahelm", "", "/r/wt/integration", false),
                wt("seahelm", "task/only", "/r/wt/only", false),
            ],
            repos: vec![RepoRef { name: "seahelm".into(), path: "/r/seahelm".into() }, RepoRef { name: "web".into(), path: "/r/web".into() }],
        }
    }

    fn ok(text: &str) -> Command {
        parse(text, &fleet()).unwrap()
    }

    #[test]
    fn prose_and_paths_are_said() {
        assert_eq!(ok("fix the build"), Command::Say("fix the build".into()));
        assert_eq!(ok("#3 is flaky"), Command::Say("#3 is flaky".into()));
        assert_eq!(ok("/Users/me/shot.jpg"), Command::Say("/Users/me/shot.jpg".into()));
        assert_eq!(parse("  ", &fleet()), Err(Error::Empty));
    }

    #[test]
    fn go_takes_a_pane_a_worktree_or_first_mate() {
        assert!(matches!(ok("/go #7"), Command::Go(Some(Go::Pane(p))) if p.handle == 7));
        assert!(matches!(ok("/go 3"), Command::Go(Some(Go::Pane(p))) if p.handle == 3));
        assert_eq!(ok("/go mate"), Command::Go(Some(Go::FirstMate)));
        assert_eq!(ok("/go"), Command::Go(None));
        assert_eq!(parse("/go #42", &fleet()), Err(Error::UnknownPane(42)));
        assert_eq!(parse("/show #x", &fleet()), Err(Error::BadPaneRef("#x".into())));
    }

    #[test]
    fn worktrees_by_name_with_repo_when_ambiguous() {
        assert_eq!(parse("/go @fix/login", &fleet()), Err(Error::AmbiguousWorktree("fix/login".into(), vec!["seahelm/fix/login".into(), "web/fix/login".into()])));
        assert!(matches!(ok("/go @web/fix/login"), Command::Go(Some(Go::Worktree(w))) if w.repo == "web"));
        assert!(matches!(ok("/go @task/only"), Command::Go(Some(Go::Worktree(w))) if w.path == "/r/wt/only"));
        // A detached checkout answers to its directory.
        assert!(matches!(ok("/go @integration"), Command::Go(Some(Go::Worktree(w))) if w.path == "/r/wt/integration"));
        assert_eq!(parse("/go @seahelm", &fleet()), Err(Error::RepoNotWorktree("seahelm".into())));
    }

    #[test]
    fn new_with_and_without_a_repo() {
        assert!(matches!(ok("/new @web add a footer"), Command::New { task, repo: Some(r) } if task == "add a footer" && r.name == "web"));
        assert!(matches!(ok("/new add a footer"), Command::New { repo: None, .. }));
        assert_eq!(parse("/new @web", &fleet()), Err(Error::MissingArgument { verb: "new", what: "a task" }));
        assert_eq!(parse("/new @task/only fix", &fleet()), Err(Error::WorktreeNotRepo("task/only".into())));
    }

    #[test]
    fn the_rest() {
        assert_eq!(ok("/status"), Command::Status);
        assert_eq!(parse("/status worktrees", &fleet()), Err(Error::BadArgument { verb: "status", token: "worktrees".into() }));
        assert_eq!(ok("/help /go"), Command::Help(Some("go".into())));
        // A group chat addresses the bot: `/status@seahelm_bot`.
        assert_eq!(ok("/status@seahelm_bot"), Command::Status);
        for gone in ["/order #7 hi", "/yes", "/return @task/only", "/broadcast x", "/mate", "/panes"] {
            assert!(matches!(parse(gone, &fleet()), Err(Error::UnknownCommand(_))), "{gone}");
        }
    }
}
