//! One table of verbs: what the parser accepts and what `/help` prints come
//! from the same rows, so they cannot drift.
//!
//! The language was cut to this on 2026-11-04: prose goes to whoever the
//! conversation is talking to, `/go` changes that (a pane, a worktree, or
//! First Mate), `/new` starts work, `/status` and `/show` read. Anything
//! else — batch work, cleanup, repo management — is First Mate's or the
//! desktop's, not the command line's. Nothing asks for confirmation.

pub struct Spec {
    pub verb: &'static str,
    pub usage: &'static str,
    pub summary: &'static str,
    pub detail: &'static str,
}

pub const ALL: &[Spec] = &[
    Spec {
        verb: "go",
        usage: "/go #pane | @worktree | mate",
        summary: "Talk to a pane, a worktree's pane, or First Mate from now on",
        detail: "Changes who this conversation talks to: anything you say without a slash goes there. `/go mate` talks to First Mate. Bare `/go` says who it is now. Only this conversation changes.",
    },
    Spec {
        verb: "new",
        usage: "/new [@repo] <task>",
        summary: "Start a worktree with an agent on the task, and talk to it",
        detail: "Creates a worktree in the repo (the first one when `@repo` is left out), starts an agent on the task, and talks to it from now on.",
    },
    Spec {
        verb: "status",
        usage: "/status",
        summary: "The fleet, with handles",
        detail: "Every pane, grouped by repo and worktree, with its `#handle`, status and title; worktrees without a pane too. Marks the one you are talking to.",
    },
    Spec {
        verb: "show",
        usage: "/show [#pane]",
        summary: "What a pane is doing",
        detail: "The pane's latest turn and its reply. Read-only. Bare `/show` reads the pane you are talking to.",
    },
    Spec { verb:"memory",usage:"/memory show|undo @repo",summary:"Read or undo project memory",detail:"Runs directly in the core from the island, web or Telegram. Undo restores the previous core-written revision." },
    Spec { verb: "help", usage: "/help [command]", summary: "This list; with a command, its details", detail: "You are reading it." },
];

pub const ADDRESSING: &str = "`#7` is a pane. `@branch` (or `@repo/branch`) is a worktree; `@repo` is a repo.";
pub const PROSE_LINE: &str = "Anything without a slash goes to whoever you are talking to.";

pub fn find(verb: &str) -> Option<&'static Spec> {
    let v = verb.to_lowercase();
    ALL.iter().find(|s| s.verb == v)
}

pub fn help() -> String {
    let mut lines = vec!["**Commands**".to_string(), String::new(), format!("`<anything>` — {PROSE_LINE}")];
    lines.extend(ALL.iter().map(|s| format!("`{}` — {}", s.usage, s.summary)));
    lines.push(String::new());
    lines.push(ADDRESSING.into());
    lines.join("\n")
}

/// `/help <verb>`; None for a verb that does not exist.
pub fn help_for(verb: &str) -> Option<String> {
    find(verb).map(|s| format!("`{}`\n{}", s.usage, s.detail))
}
