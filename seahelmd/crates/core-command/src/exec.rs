//! What a line does: the one place a command's meaning lives. The side
//! effects go through a `Host` (the core); who the conversation talks to
//! comes in with the line and goes back out when it changes, and the caller
//! keeps it (per the core/gateway boundary).

use seahelm_core_messages::Message;
use serde_json::{json, Value};

use crate::fleet::{FleetIndex, PaneRef};
use crate::format;
use crate::parse::{self, Command, Go};
use crate::spec;

pub trait Host {
    fn fleet(&self) -> FleetIndex;
    /// Type into the pane and press Enter.
    fn send_text(&self, pane_key: &str, text: &str) -> bool;
    /// A worktree with an agent on the task; its path.
    fn create_worktree(&self, repo_path: &str, task: &str) -> Result<String, String>;
    fn transcript(&self, pane_key: &str) -> Option<String>;
    fn messages(&self, pane_key: &str) -> Vec<Message>;
    fn activity(&self, pane_key: &str) -> Vec<String>;
    fn project_memory(&self, _repo: &str, _verb: &str) -> Result<String,String> { Err("Project memory unavailable".into()) }
    fn first_mate_available(&self) -> bool;
    fn say_to_first_mate(&self, text: &str) -> bool;
}

/// Who is talking: what their surface can do, and who they talk to.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Context {
    /// The desktop: its binding is its selection.
    pub desktop: bool,
    pub binding: Option<Binding>,
    /// First Mate runs on the caller's side (the macOS app still owns it):
    /// what is for First Mate comes back in `Outcome::first_mate` for the
    /// caller to hand over, instead of going to the core's.
    pub first_mate_here: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub enum Binding {
    /// A pane, by its handle key (seahelmd session name).
    Pane { key: String, worktree_path: String },
    /// A worktree whose first pane takes the conversation when it appears.
    Worktree { path: String },
    FirstMate,
}

impl Binding {
    pub fn to_json(&self) -> Value {
        match self {
            Binding::Pane { key, worktree_path } => json!({"pane": key, "worktree_path": worktree_path}),
            Binding::Worktree { path } => json!({"worktree_path": path}),
            Binding::FirstMate => json!({"first_mate": true}),
        }
    }

    pub fn from_json(v: &Value) -> Option<Self> {
        let s = |k: &str| v.get(k).and_then(Value::as_str).map(str::to_string);
        if v.get("first_mate").and_then(Value::as_bool) == Some(true) {
            return Some(Binding::FirstMate);
        }
        match (s("pane"), s("worktree_path")) {
            (Some(key), wt) => Some(Binding::Pane { key, worktree_path: wt.unwrap_or_default() }),
            (None, Some(path)) => Some(Binding::Worktree { path }),
            _ => None,
        }
    }
}

/// A shortcut beside a reply: the line it runs, as if typed. A surface that
/// cannot draw buttons loses nothing, the text says how to type it.
#[derive(Clone, Debug, PartialEq)]
pub struct Button {
    pub label: String,
    pub line: String,
}

impl Button {
    pub fn line(label: &str, line: &str) -> Self {
        Button { label: label.into(), line: line.into() }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Reply {
    pub text: String,
    pub is_error: bool,
    pub buttons: Vec<Button>,
}

impl Reply {
    fn ok(text: impl Into<String>) -> Self {
        Reply { text: text.into(), is_error: false, buttons: vec![] }
    }

    fn err(text: impl Into<String>) -> Self {
        Reply { text: text.into(), is_error: true, buttons: vec![] }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Outcome {
    pub reply: Reply,
    /// Who the conversation talks to from now on; unchanged when None.
    pub binding: Option<Binding>,
    /// Text for First Mate, when it runs on the caller's side.
    pub first_mate: Option<String>,
}

impl Outcome {
    fn just(reply: Reply) -> Self {
        Outcome { reply, binding: None, first_mate: None }
    }

    fn bind(reply: Reply, binding: Binding) -> Self {
        Outcome { reply, binding: Some(binding), first_mate: None }
    }

    pub fn to_json(&self) -> Value {
        let mut v = json!({
            "text": self.reply.text,
            "is_error": self.reply.is_error,
            "buttons": self.reply.buttons.iter().map(|b| json!({"label": b.label, "line": b.line})).collect::<Vec<_>>(),
        });
        if let Some(b) = &self.binding {
            v["binding"] = b.to_json();
        }
        if let Some(t) = &self.first_mate {
            v["first_mate"] = json!(t);
        }
        v
    }
}

pub const NOT_BOUND: &str = "Not talking to anyone yet. `/status` to see the panes, then `/go #n` — or `/new <task>` to start one.";

/// Run one line for one conversation.
/// First Mate is there to talk to: the core's, or the caller's.
fn mate_available(ctx: &Context, host: &dyn Host) -> bool {
    host.first_mate_available() || ctx.first_mate_here
}

/// Say `text` to First Mate: to the core's when it runs, else back to the
/// caller in `out`. False when there is none.
fn mate_say(ctx: &Context, host: &dyn Host, text: &str, out: &mut Option<String>) -> bool {
    if host.first_mate_available() {
        return host.say_to_first_mate(text);
    }
    if ctx.first_mate_here {
        *out = Some(text.to_string());
        return true;
    }
    false
}

pub fn run(text: &str, ctx: &Context, host: &dyn Host) -> Outcome {
    let index = host.fleet();
    let command = match parse::parse(text, &index) {
        Ok(c) => c,
        Err(e) => return Outcome::just(Reply::err(format::describe(&e))),
    };
    match command {
        Command::Memory {verb,repo} => Outcome::just(match host.project_memory(&repo.path,&verb) { Ok(text)=>Reply::ok(text), Err(e)=>Reply::err(e) }),
        Command::Say(text) => say(&text, &index, ctx, host),
        Command::Go(None) => Outcome::just(Reply::ok(match &ctx.binding {
            Some(Binding::FirstMate) => "Talking to First Mate.".to_string(),
            _ => match bound_pane(ctx, &index).0 {
                Some(p) => format!("Talking to {} — {} {}.", format::target(&p), format::icon(p.status), format::label(p.status)),
                None => NOT_BOUND.to_string(),
            },
        })),
        Command::Go(Some(Go::FirstMate)) => {
            if !mate_available(ctx, host) {
                return Outcome::just(Reply::err("First Mate is off. Turn it on in Settings ▸ First Mate."));
            }
            Outcome::bind(Reply::ok("Talking to First Mate. `/go #n` talks to a pane again."), Binding::FirstMate)
        }
        Command::Go(Some(Go::Pane(p))) => Outcome::bind(
            Reply::ok(format!("Talking to {} — {} {}. Say anything to send it.", format::target(&p), format::icon(p.status), format::label(p.status))),
            Binding::Pane { key: p.key.clone(), worktree_path: p.worktree_path.clone() },
        ),
        Command::Go(Some(Go::Worktree(w))) => match index.panes_in(&w.path).first() {
            Some(p) => Outcome::bind(
                Reply::ok(format!("Talking to {} — {} {}.", format::target(p), format::icon(p.status), format::label(p.status))),
                Binding::Pane { key: p.key.clone(), worktree_path: w.path.clone() },
            ),
            None => Outcome::bind(
                Reply::ok(format!("Now on {} — no pane there yet. `/new <task>` to start one.", index.label(&w))),
                Binding::Worktree { path: w.path.clone() },
            ),
        },
        Command::New { task, repo } => {
            let Some(repo_path) = repo.map(|r| r.path).or_else(|| index.repos.first().map(|r| r.path.clone())) else {
                return Outcome::just(Reply::err("No repo configured. Add one on the desktop."));
            };
            let name = std::path::Path::new(&repo_path).file_name().and_then(|n| n.to_str()).unwrap_or("repo").to_string();
            match host.create_worktree(&repo_path, &task) {
                Err(e) => Outcome::just(Reply::err(format!("Couldn't start a worktree in **{name}**: {e}"))),
                Ok(path) => {
                    let fresh = host.fleet();
                    match fresh.panes_in(&path).first() {
                        Some(p) => Outcome::bind(
                            Reply::ok(format!("Started {}. Talking to it from now on.", format::target(p))),
                            Binding::Pane { key: p.key.clone(), worktree_path: path.clone() },
                        ),
                        None => {
                            let label = fresh.worktree_at(&path).map(|w| fresh.label(w)).unwrap_or(path.clone());
                            Outcome::bind(Reply::ok(format!("Started {label}. Talking to it as soon as its agent is up.")), Binding::Worktree { path })
                        }
                    }
                }
            }
        }
        Command::Status => {
            let (bound, rebind) = bound_pane(ctx, &index);
            let reply = Reply { text: format::status(&index, bound.as_ref()), is_error: false, buttons: format::pane_buttons(&index, bound.as_ref()) };
            Outcome { reply, binding: rebind, first_mate: None }
        }
        Command::Show(named) => {
            let (pane, rebind) = match named {
                Some(p) => (Some(p), None),
                None => bound_pane(ctx, &index),
            };
            let Some(p) = pane else {
                return Outcome::just(Reply::err(if ctx.binding == Some(Binding::FirstMate) { "Talking to First Mate: `/show #n` reads a pane." } else { NOT_BOUND }));
            };
            let text = format::pane_detail(&p, &host.activity(&p.key), host.transcript(&p.key).as_deref(), &host.messages(&p.key));
            Outcome { reply: Reply::ok(text), binding: rebind, first_mate: None }
        }
        Command::Help(None) => Outcome::just(Reply::ok(spec::help())),
        Command::Help(Some(v)) => match spec::help_for(&v) {
            Some(t) => Outcome::just(Reply::ok(t)),
            None => Outcome::just(Reply::err(format::describe(&parse::Error::UnknownCommand(v)))),
        },
    }
}

/// Prose for whoever the conversation talks to. A binding to a pane that is
/// gone sends nothing: guessing another is how an order lands in the wrong
/// agent.
fn say(text: &str, index: &FleetIndex, ctx: &Context, host: &dyn Host) -> Outcome {
    let mut forward = None;
    if ctx.binding == Some(Binding::FirstMate) {
        let reply = if mate_say(ctx, host, text, &mut forward) { Reply::ok("→ First Mate") } else { Reply::err("First Mate is off. `/go #n` talks to a pane.") };
        return Outcome { reply, binding: None, first_mate: forward };
    }
    let (pane, rebind) = bound_pane(ctx, index);
    if let Some(p) = pane {
        return Outcome { reply: deliver(text, &p, host), binding: rebind, first_mate: None };
    }
    if matches!(ctx.binding, Some(Binding::Pane { .. })) {
        return Outcome::just(Reply::err("The pane this conversation was talking to isn't running — nothing sent. `/status` lists what is, `/go #n` picks one."));
    }
    if ctx.desktop {
        return Outcome::just(Reply::err("No pane selected. Pick one on the dashboard, or `/new <task>`."));
    }
    // Nothing chosen: First Mate, when it is on, is who a chat talks to.
    if mate_say(ctx, host, text, &mut forward) {
        return Outcome { reply: Reply::ok("→ First Mate"), binding: None, first_mate: forward };
    }
    // One pane is no choice at all: talk to it, and say so once.
    if index.panes.len() == 1 {
        let p = &index.panes[0];
        let sent = deliver(text, p, host);
        let reply = Reply { text: format!("{} — talking to it from now on.", sent.text), is_error: sent.is_error, buttons: vec![] };
        return Outcome::bind(reply, Binding::Pane { key: p.key.clone(), worktree_path: p.worktree_path.clone() });
    }
    Outcome::just(Reply::err(NOT_BOUND))
}

fn deliver(text: &str, p: &PaneRef, host: &dyn Host) -> Reply {
    if host.send_text(&p.key, text) {
        Reply::ok(format!("→ {}", format::target(p)))
    } else {
        Reply::err(format!("Couldn't reach {} — its terminal is gone. `/status` to see what's left.", format::target(p)))
    }
}

/// The pane the conversation talks to, and the binding to keep from now on
/// when a worktree binding just resolved to its first pane. A pane binding
/// whose pane is gone resolves to nothing, never to a neighbour.
fn bound_pane(ctx: &Context, index: &FleetIndex) -> (Option<PaneRef>, Option<Binding>) {
    match &ctx.binding {
        Some(Binding::Pane { key, .. }) => (index.pane_by_key(key).cloned(), None),
        Some(Binding::Worktree { path }) => match index.panes_in(path).first() {
            Some(p) => (Some((*p).clone()), Some(Binding::Pane { key: p.key.clone(), worktree_path: path.clone() })),
            None => (None, None),
        },
        _ => (None, None),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parse::tests::{fleet, pane};
    use std::cell::RefCell;

    #[derive(Default)]
    struct Fake {
        sent: RefCell<Vec<(String, String)>>,
        mate: RefCell<Vec<String>>,
        mate_on: bool,
        fleet: Option<FleetIndex>,
    }

    impl Host for Fake {
        fn fleet(&self) -> FleetIndex {
            self.fleet.clone().unwrap_or_else(fleet)
        }
        fn send_text(&self, pane: &str, text: &str) -> bool {
            self.sent.borrow_mut().push((pane.into(), text.into()));
            true
        }
        fn create_worktree(&self, _: &str, _: &str) -> Result<String, String> {
            Ok("/r/wt/new".into())
        }
        fn transcript(&self, _: &str) -> Option<String> {
            None
        }
        fn messages(&self, _: &str) -> Vec<Message> {
            vec![]
        }
        fn activity(&self, _: &str) -> Vec<String> {
            vec![]
        }
        fn project_memory(&self, repo: &str, verb: &str) -> Result<String,String> { Ok(format!("{verb} {repo}")) }
        fn first_mate_available(&self) -> bool {
            self.mate_on
        }
        fn say_to_first_mate(&self, text: &str) -> bool {
            if self.mate_on {
                self.mate.borrow_mut().push(text.into());
            }
            self.mate_on
        }
    }

    fn chat(binding: Option<Binding>) -> Context {
        Context { desktop: false, binding, first_mate_here: false }
    }

    fn on(key: &str) -> Context {
        chat(Some(Binding::Pane { key: key.into(), worktree_path: String::new() }))
    }

    #[test]
    fn go_binds_and_prose_follows() {
        let host = Fake::default();
        let o = run("/go #7", &chat(None), &host);
        assert_eq!(o.binding, Some(Binding::Pane { key: "s-b".into(), worktree_path: "/r/wt/fix-login".into() }));
        assert_eq!(run("run the tests", &on("s-b"), &host).reply.text, "→ #7 seahelm/fix/login");
        assert_eq!(host.sent.borrow()[0], ("s-b".into(), "run the tests".into()));
        assert_eq!(run("/go", &on("s-b"), &host).reply.text, "Talking to #7 seahelm/fix/login — ○ Idle.");
    }

    #[test]
    fn a_binding_to_a_gone_pane_sends_nothing() {
        let host = Fake::default();
        assert!(run("hello", &on("s-gone"), &host).reply.text.starts_with("The pane this conversation was talking to isn't running"));
        assert!(host.sent.borrow().is_empty());
    }

    #[test]
    fn first_mate_is_one_of_the_places_to_go() {
        let host = Fake { mate_on: true, ..Fake::default() };
        assert_eq!(run("/go mate", &chat(None), &host).binding, Some(Binding::FirstMate));
        assert_eq!(run("check CI", &chat(Some(Binding::FirstMate)), &host).reply.text, "→ First Mate");
        // Nothing chosen in a chat: First Mate, when it is on.
        assert_eq!(run("what's red?", &chat(None), &host).reply.text, "→ First Mate");
        assert_eq!(*host.mate.borrow(), ["check CI", "what's red?"]);
        assert!(run("/go mate", &chat(None), &Fake::default()).reply.is_error);
        assert_eq!(run("hi", &chat(None), &Fake::default()).reply.text, NOT_BOUND);
    }

    #[test]
    fn first_mate_on_the_callers_side_is_handed_back() {
        let host = Fake::default();
        let ctx = Context { first_mate_here: true, ..chat(None) };
        assert_eq!(run("/go mate", &ctx, &host).binding, Some(Binding::FirstMate));
        let o = run("what's red?", &Context { binding: Some(Binding::FirstMate), ..ctx.clone() }, &host);
        assert_eq!((o.reply.text.as_str(), o.first_mate.as_deref()), ("→ First Mate", Some("what's red?")));
        assert_eq!(o.to_json()["first_mate"], "what's red?");
        assert_eq!(run("unbound", &ctx, &host).first_mate.as_deref(), Some("unbound"));
    }

    #[test]
    fn a_worktree_binding_resolves_to_its_first_pane_and_sticks() {
        let o = run("go on", &chat(Some(Binding::Worktree { path: "/r/web-wt/fix".into() })), &Fake::default());
        assert_eq!(o.reply.text, "→ #9 web/fix/login");
        assert_eq!(o.binding, Some(Binding::Pane { key: "s-c".into(), worktree_path: "/r/web-wt/fix".into() }));
    }

    #[test]
    fn new_talks_to_the_new_pane() {
        let mut f = fleet();
        f.panes.push(pane(10, "s-new", "seahelm", "task/x", "/r/wt/new"));
        let host = Fake { fleet: Some(f), ..Fake::default() };
        let o = run("/new add a readme", &chat(None), &host);
        assert_eq!(o.reply.text, "Started #10 seahelm/task/x. Talking to it from now on.");
        assert!(matches!(o.binding, Some(Binding::Pane { ref key, .. }) if key == "s-new"));
    }

    #[test]
    fn memory_runs_from_the_island_or_telegram_without_a_model_turn() {
        let host=Fake::default();
        for ctx in [chat(None),on("s-b")] {
            for verb in ["show","undo"] {
                let out=run(&format!("/notes {verb} @seahelm"),&ctx,&host);
                assert!(!out.reply.is_error,"{}",out.reply.text); assert!(out.reply.text.starts_with(verb));
                assert!(out.first_mate.is_none()); assert!(host.mate.borrow().is_empty());
            }
        }
        assert!(run("/notes confirm @seahelm",&chat(None),&host).reply.is_error);
        assert!(run("/memory show @seahelm",&chat(None),&host).reply.is_error, "/memory is Claude Code's, not ours");
    }

    #[test]
    fn status_and_show_read() {
        let o = run("/status", &on("s-b"), &Fake::default());
        assert!(o.reply.text.contains("#7 ○ Claude Code  ← talking to this one"));
        assert_eq!(o.reply.buttons[0].line, "/go #9");
        assert!(run("/show #3", &chat(None), &Fake::default()).reply.text.starts_with("**#3 seahelm/main**"));
        assert_eq!(run("/show", &chat(None), &Fake::default()).reply.text, NOT_BOUND);
        assert_eq!(o.to_json()["buttons"][0]["line"], "/go #9");
    }
}
