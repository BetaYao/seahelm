//! Listings, details and errors in words (`CommandFormatter.swift`). Pure,
//! so the wording is the same on every surface and testable.

use seahelm_core_messages::{Kind, Message};
use seahelm_core_types::AgentStatus;

use crate::exec::Button;
use crate::fleet::{worktree_name, FleetIndex, PaneRef};
use crate::parse::Error;
use crate::spec;

pub fn icon(s: AgentStatus) -> &'static str {
    match s {
        AgentStatus::Running => "●",
        AgentStatus::Idle => "○",
        AgentStatus::Waiting => "◐",
        AgentStatus::Error => "✕",
        AgentStatus::Exited => "◻",
        AgentStatus::Unknown => "?",
    }
}

pub fn label(s: AgentStatus) -> &'static str {
    match s {
        AgentStatus::Running => "Running",
        AgentStatus::Waiting => "Needs input",
        AgentStatus::Idle => "Idle",
        AgentStatus::Error => "Error",
        AgentStatus::Exited => "Dormant",
        AgentStatus::Unknown => "Unknown",
    }
}

/// `#7 seahelm/main`: how every reply names a pane.
pub fn target(p: &PaneRef) -> String {
    format!("#{} {}/{}", p.handle, p.project, p.branch)
}

pub fn truncated(s: &str, limit: usize) -> String {
    if s.chars().count() <= limit {
        s.to_string()
    } else {
        s.chars().take(limit - 1).collect::<String>() + "…"
    }
}

/// `/status`: every worktree under its repo, each with its panes and their
/// handles; a worktree without a pane says so.
pub fn status(index: &FleetIndex, bound: Option<&PaneRef>) -> String {
    if index.panes.is_empty() && index.worktrees.is_empty() {
        return "Nothing here yet. `/new <task>` to start one.".into();
    }
    // (repo, path, name, is main) for every worktree, plus any pane's
    // worktree the list does not know.
    let mut places: Vec<(String, String, String, bool)> = index.worktrees.iter().map(|w| (w.repo.clone(), w.path.clone(), w.name(), w.is_main)).collect();
    for p in &index.panes {
        if !places.iter().any(|(_, path, _, _)| *path == p.worktree_path) {
            places.push((p.project.clone(), p.worktree_path.clone(), worktree_name(&p.branch, &p.worktree_path), false));
        }
    }
    places.sort_by_key(|(repo, _, name, main)| (repo.to_lowercase(), !*main, name.to_lowercase()));
    let n = index.panes.len();
    let mut out = vec![format!("**Fleet** — {n} pane{} in {} worktree{}", if n == 1 { "" } else { "s" }, places.len(), if places.len() == 1 { "" } else { "s" }), String::new()];
    let mut repo: Option<String> = None;
    for (r, path, name, _) in &places {
        if repo.as_deref() != Some(r.as_str()) {
            out.push(format!("**{r}**"));
            repo = Some(r.clone());
        }
        let label = index.worktree_at(path).map(|w| index.label(w)).unwrap_or_else(|| format!("@{name}"));
        let panes = index.panes_in(path);
        if panes.is_empty() {
            out.push(format!("  {label}  ·  no panes"));
            continue;
        }
        out.push(format!("  {label}"));
        for p in panes {
            let title = if p.title.is_empty() || p.title == *name { String::new() } else { format!(" — {}", truncated(&p.title, 60)) };
            let here = if bound.is_some_and(|b| b.key == p.key) { "  ← talking to this one" } else { "" };
            out.push(format!("    #{} {} {}{title}{here}", p.handle, icon(p.status), p.kind));
        }
    }
    out.push(String::new());
    out.push("`/go #n` to talk to one · `/show #n` to read it.".into());
    out.join("\n")
}

/// How many shortcuts a listing offers; the text is complete either way.
pub const BUTTON_LIMIT: usize = 8;

/// `/go` for each pane but the bound one, newest handles first.
pub fn pane_buttons(index: &FleetIndex, bound: Option<&PaneRef>) -> Vec<Button> {
    let mut v: Vec<&PaneRef> = index.panes.iter().filter(|p| bound.is_none_or(|b| b.key != p.key)).collect();
    v.sort_by_key(|p| std::cmp::Reverse(p.handle));
    v.into_iter().take(BUTTON_LIMIT).map(|p| Button::line(&format!("{} #{} {}", icon(p.status), p.handle, p.branch), &format!("/go #{}", p.handle))).collect()
}

/// Lines that look like secrets or diffs are left out, then the text is cut
/// (`MailContentRedactor.summary`).
pub fn redacted(text: &str, limit: usize) -> String {
    const UNSAFE: [&str; 7] = ["token", "password", "secret", "api_key", "authorization:", "export ", "diff --git"];
    let safe: Vec<&str> = text.split('\n').filter(|l| !UNSAFE.iter().any(|u| l.to_lowercase().contains(u))).collect();
    safe.join("\n").chars().take(limit).collect::<String>().trim().to_string()
}

/// What `last_message` falls back to before an agent has said anything:
/// under **Latest** it would only repeat the status line.
pub const LIFECYCLE_LABELS: [&str; 4] = ["Session started", "Creating worktree", "Subagent started", "Processing prompt"];

/// One pane in full. From its timeline when it has one: the latest turn,
/// short, then its reply whole. Otherwise its screen's tail and activity.
pub fn pane_detail(p: &PaneRef, activity: &[String], transcript: Option<&str>, stream: &[Message]) -> String {
    let title = if p.title.eq_ignore_ascii_case(&p.kind) { "" } else { &p.title };
    let mut out = vec![
        format!("**{}** · {}{}", target(p), p.kind, if title.is_empty() { String::new() } else { format!(" — {}", truncated(title, 90)) }),
        format!("{} {}", icon(p.status), label(p.status)),
        String::new(),
    ];
    let turn = latest_turn(stream);
    if !turn.is_empty() {
        let reply = turn.iter().rev().find(|m| m.kind == Kind::Assistant);
        let rest: Vec<Message> = turn.iter().filter(|m| reply.is_none_or(|r| r.seq != m.seq)).cloned().collect();
        let session = redacted(&session_lines(&rest).join("\n"), 2_000);
        if !session.is_empty() {
            out.extend(["**Session**".to_string(), session, String::new()]);
        }
        let latest = redacted(reply.and_then(|r| r.text.as_deref()).unwrap_or(&p.last_message), 3_500);
        if !latest.is_empty() && !LIFECYCLE_LABELS.contains(&latest.as_str()) {
            out.extend(["**Latest**".to_string(), latest, String::new()]);
        }
        return out.join("\n").trim_matches('\n').to_string();
    }
    if let Some(t) = transcript.map(transcript_tail).filter(|t| !t.is_empty()) {
        out.extend(["**Session**".to_string(), "```".to_string(), t, "```".to_string(), String::new()]);
    }
    let message = redacted(&p.last_message, 1_500);
    if !message.is_empty() && !LIFECYCLE_LABELS.contains(&message.as_str()) {
        out.extend(["**Latest**".to_string(), message, String::new()]);
    }
    if !activity.is_empty() {
        out.push("**Recent activity**".into());
        out.extend(activity.iter().take(8).map(|a| format!("· {a}")));
        out.push(String::new());
    }
    out.join("\n").trim_matches('\n').to_string()
}

/// A screen's recent end, redacted, safe inside a code fence, starting on a
/// whole line.
pub fn transcript_tail(text: &str) -> String {
    const LIMIT: usize = 3_000;
    let r = redacted(text, usize::MAX).replace("```", "'''");
    let n = r.chars().count();
    if n <= LIMIT {
        return r;
    }
    let tail: String = r.chars().skip(n - LIMIT).collect();
    let start = tail.find('\n').map_or(0, |i| i + 1);
    format!("…\n{}", &tail[start..])
}

/// The timeline from the latest prompt on (all of it when that scrolled out).
pub fn latest_turn(stream: &[Message]) -> &[Message] {
    match stream.iter().rposition(|m| m.kind == Kind::User) {
        Some(i) => &stream[i..],
        None => stream,
    }
}

/// Characters the session part may take, so the reply under it still fits.
pub const SESSION_BUDGET: usize = 800;

/// A turn as a few lines: what was asked, what the agent said, its tool
/// calls folded into one line per run. Past the budget the oldest lines go,
/// never the prompt.
pub fn session_lines(turn: &[Message]) -> Vec<String> {
    let mut prompt: Option<String> = None;
    let mut lines: Vec<String> = Vec::new();
    let mut run: Vec<(String, u32)> = Vec::new();
    let close = |run: &mut Vec<(String, u32)>, lines: &mut Vec<String>| {
        if !run.is_empty() {
            lines.push(format!("› {}", run.iter().map(|(t, n)| if *n > 1 { format!("{t} ×{n}") } else { t.clone() }).collect::<Vec<_>>().join(" · ")));
            run.clear();
        }
    };
    for m in turn {
        let text = m.text.as_deref().unwrap_or_default().split_whitespace().collect::<Vec<_>>().join(" ");
        match m.kind {
            Kind::User if !text.is_empty() => prompt = Some(format!("❯ {}", truncated(&text, 120))),
            Kind::Assistant | Kind::Thinking if !text.is_empty() => {
                close(&mut run, &mut lines);
                lines.push(truncated(&text, 160));
            }
            Kind::Tool => {
                let Some(tool) = m.tool.as_deref().filter(|t| !t.is_empty()) else { continue };
                match run.last_mut() {
                    Some((t, n)) if t == tool => *n += 1,
                    _ => run.push((tool.into(), 1)),
                }
            }
            _ => {}
        }
    }
    close(&mut run, &mut lines);
    let mut used = prompt.as_ref().map_or(0, |p| p.chars().count() + 1);
    let mut kept: Vec<String> = Vec::new();
    for line in lines.iter().rev() {
        let n = line.chars().count() + 1;
        if used + n > SESSION_BUDGET {
            kept.insert(0, "…".into());
            break;
        }
        used += n;
        kept.insert(0, line.clone());
    }
    prompt.into_iter().chain(kept).collect()
}

pub fn describe(e: &Error) -> String {
    match e {
        Error::Empty => "Nothing to do.".into(),
        Error::UnknownCommand(v) => format!("Unknown command `/{v}`. `/help` lists them."),
        Error::BadPaneRef(t) => format!("`{t}` is not a pane. Panes are `#` and a number — `/status` lists them."),
        Error::UnknownPane(h) => format!("No pane #{h}. `/status` to see what's running."),
        Error::UnknownWorktree(n) => format!("No worktree `@{n}`. `/status` lists them."),
        Error::AmbiguousWorktree(n, o) => {
            format!("`@{n}` is in several repos: {}. Say which.", o.iter().map(|x| format!("`@{x}`")).collect::<Vec<_>>().join(", "))
        }
        Error::RepoNotWorktree(n) => format!("`@{n}` is a repo, not a worktree. `/new @{n} <task>` starts one there."),
        Error::UnknownRepo(n) => format!("No repo `@{n}`. `/status` lists them."),
        Error::WorktreeNotRepo(n) => format!("`@{n}` is a worktree, not a repo. `/go @{n}` talks to it."),
        Error::MissingArgument { verb, what } => format!("`/{verb}` needs {what}.{}", usage_hint(verb)),
        Error::BadArgument { verb, token } => format!("`/{verb}` doesn't take `{token}`.{}", usage_hint(verb)),
    }
}

fn usage_hint(verb: &str) -> String {
    spec::find(verb).map(|s| format!(" Usage: `{}`", s.usage)).unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parse::tests::{fleet, pane};

    #[test]
    fn status_lists_every_worktree_with_its_panes() {
        let f = fleet();
        let text = status(&f, f.pane(7));
        assert!(text.starts_with("**Fleet** — 3 panes in 6 worktrees\n\n**seahelm**\n  @seahelm/main\n    #3 ○ Claude Code\n"), "{text}");
        assert!(text.contains("  @seahelm/fix/login\n    #7 ○ Claude Code  ← talking to this one"), "{text}");
        assert!(text.contains("  @integration  ·  no panes"), "{text}");
        assert_eq!(pane_buttons(&f, f.pane(7)).iter().map(|b| b.label.clone()).collect::<Vec<_>>(), ["○ #9 fix/login", "○ #3 main"]);
    }

    #[test]
    fn detail_reads_the_latest_turn() {
        let p = pane(7, "s-b", "seahelm", "fix/login", "/r/wt/fix-login");
        let m = |kind, text: &str| Message::new("p", "s-b", kind, 0.0).with_text(text);
        let mut tool = Message::new("p", "s-b", Kind::Tool, 0.0);
        tool.tool = Some("Bash".into());
        let stream = vec![m(Kind::User, "old"), m(Kind::User, "fix the login"), m(Kind::Assistant, "Looking."), tool.clone(), tool, m(Kind::Assistant, "Fixed it.")];
        let mut stream = stream;
        for (i, x) in stream.iter_mut().enumerate() {
            x.seq = i as u64 + 1;
        }
        let d = pane_detail(&p, &[], None, &stream);
        assert_eq!(d, "**#7 seahelm/fix/login** · Claude Code\n○ Idle\n\n**Session**\n❯ fix the login\nLooking.\n› Bash ×2\n\n**Latest**\nFixed it.");
    }

    #[test]
    fn secrets_and_lifecycle_labels_stay_out() {
        assert_eq!(redacted("ok\nexport TOKEN=abc\nfine", 100), "ok\nfine");
        let mut p = pane(7, "s-b", "seahelm", "fix/login", "/r/wt/fix-login");
        p.last_message = "Session started".into();
        assert!(!pane_detail(&p, &[], None, &[]).contains("Latest"));
    }

    #[test]
    fn errors_name_the_usage() {
        assert_eq!(describe(&Error::MissingArgument { verb: "new", what: "a task" }), "`/new` needs a task. Usage: `/new [@repo] <task>`");
    }
}
