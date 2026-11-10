//! What a pane's corner shows and does, from what seahelm-core knows about
//! it (`core_client::pane_facts`, every two seconds):
//!
//! - its `#n`, the handle every surface and chat names it by;
//! - who is at work on it: `pane.presence` from a `seahelm` CLI call on
//!   it, as "Claude Code #7 · note", for a few seconds after the last one;
//! - where its agent went: when the core puts a pane's Claude in another
//!   worktree the fleet tracks, "Fork there" copies its session into a new
//!   pane in that worktree (`claude --resume <id> --fork-session`, named
//!   after the destination's branch) and stops the original's turn with
//!   Esc, as the macOS app's fork does.
//!
//! - its name: one the user gave it (`pane.rename`, kept by the core and
//!   shown by every client) beside the `#n`; clicking the `#n` names it.
//!
//! Zoom shows the focused pane alone, until zoomed out or the tree changes.

use std::collections::HashMap;
use std::time::{Duration, Instant};

use gpui::{deferred, div, prelude::*, px, ClickEvent, Context, Entity, Focusable, FontWeight, MouseButton, SharedString, Subscription, Window};

use super::{pane_session, session_name, Workspace};
use crate::core_client::{self, PaneFacts};
use crate::session;
use crate::split::{Axis, LeafId};
use crate::text_input::{Submitted, TextInput};
use super::worktree_menu::CancelSheet;
use crate::tokens::{self, SYSTEM};

/// How long a call keeps its caller on the pane (the macOS app's 6 s).
const PRESENCE_FOR: Duration = Duration::from_secs(6);

/// The "Rename pane" sheet: one field, Enter or Rename to keep it.
pub struct RenamePane {
    key: String,
    input: Entity<TextInput>,
    busy: bool,
    error: Option<String>,
    _submit: Subscription,
}

pub struct Presence {
    actor: String,
    note: String,
    until: Instant,
}

/// "Claude Code #7", "Codex", "Pane #3".
pub fn actor_name(agent: &str, handle: Option<u64>) -> String {
    let name = match agent {
        "claudeCode" => "Claude Code",
        "codex" => "Codex",
        "cursor" => "Cursor",
        "opencode" => "OpenCode",
        _ => "Pane",
    };
    match handle {
        Some(n) => format!("{name} #{n}"),
        None => name.to_string(),
    }
}

/// The command a fork runs: Claude resuming `id` as a new session, named
/// after where it is going, without permission prompts when the user set
/// `agent_yolo`. Quoted for `sh`, or for `cmd.exe` on Windows.
pub fn fork_command(id: &str, branch: &str, yolo: bool, windows: bool) -> String {
    let q = |s: &str| if windows { format!("\"{}\"", s.replace('"', "")) } else { format!("'{}'", s.replace('\'', r"'\''")) };
    let mut line = format!("claude --resume {} --fork-session", q(id));
    if !branch.is_empty() {
        line += &format!(" --name {}", q(branch));
    }
    if yolo {
        line += " --dangerously-skip-permissions";
    }
    line
}

impl Workspace {
    pub(super) fn poll_pane_facts(cx: &mut Context<Self>) {
        cx.spawn(async move |this, cx| loop {
            let facts = cx.background_executor().spawn(async { core_client::pane_facts() }).await;
            let alive = this.update(cx, |w, cx| {
                if w.pane_facts != facts {
                    w.pane_facts = facts;
                    cx.notify();
                }
                // A presence that ran out leaves the corner.
                let before = w.presence.len();
                w.presence.retain(|_, p| p.until > Instant::now());
                if w.presence.len() != before {
                    cx.notify();
                }
            });
            if alive.is_err() {
                break;
            }
            cx.background_executor().timer(Duration::from_secs(2)).await;
        })
        .detach();
    }

    /// `pane.presence {caller, pane_id, note}` from the core.
    pub(super) fn note_presence(&mut self, ev: &serde_json::Value, cx: &mut Context<Self>) {
        let s = |k: &str| ev.get(k).and_then(serde_json::Value::as_str).unwrap_or_default().to_string();
        let (caller, target) = (s("caller"), s("pane_id"));
        if target.is_empty() || caller == target {
            return;
        }
        let facts = self.pane_facts.get(&caller).cloned().unwrap_or_default();
        self.presence.insert(target, Presence { actor: actor_name(&facts.agent, facts.handle), note: s("note"), until: Instant::now() + PRESENCE_FOR });
        cx.notify();
    }

    pub(super) fn toggle_zoom(&mut self, cx: &mut Context<Self>) {
        let Some(id) = self.selected.clone() else { return };
        let Some(panes) = self.panes.get(&id) else { return };
        let focused = panes.tree.focused;
        self.zoomed = match &self.zoomed {
            Some((w, l)) if *w == id && *l == focused => None,
            _ if panes.tree.len() > 1 => Some((id, focused)),
            _ => None,
        };
        cx.notify();
    }

    /// The leaf zoomed in worktree `id`, while that leaf still exists.
    pub(super) fn zoomed_leaf(&self, id: &str) -> Option<LeafId> {
        let (w, leaf) = self.zoomed.as_ref()?;
        (w == id && self.panes.get(id).is_some_and(|p| p.tree.leaves().contains(leaf))).then_some(*leaf)
    }

    /// The worktree (fleet row id and branch) a pane's agent is working in,
    /// when that is not the pane's own and the fleet tracks it.
    fn away_in(&self, id: &str, facts: &PaneFacts) -> Option<(String, String, String)> {
        let there = facts.location_worktree.as_deref()?;
        let own = self.fleet.find(id).map(|i| i.worktree_path.as_str())?;
        if there == own {
            return None;
        }
        self.fleet.groups.iter().flat_map(|g| g.items.iter()).find(|i| i.worktree_path == there).map(|i| (i.id.clone(), i.branch.clone(), i.subtitle.clone()))
    }

    /// Fork the pane's Claude session into a new pane in `dest`, stop the
    /// original's turn, and go there.
    fn fork_into(&mut self, id: String, leaf: LeafId, dest: String, branch: String, session_id: String, cx: &mut Context<Self>) {
        let yolo = crate::user_config::flag("agent_yolo");
        let line = fork_command(&session_id, &branch, yolo, cfg!(windows));
        let Some(dest_item) = self.fleet.find(&dest).cloned() else { return };
        // A leaf whose session name is free: the destination's first if it
        // has no panes and nothing holds that name, else a new split.
        let panes = self.panes.entry(dest.clone()).or_default();
        let mut new_leaf = 0;
        let first_free = panes.views.is_empty() && panes.tree.len() == 1 && seahelmd::client::connect(&session_name(&dest)).is_err();
        if !first_free {
            for _ in 0..8 {
                new_leaf = panes.tree.split(Axis::Horizontal);
                if seahelmd::client::connect(&pane_session(&dest, new_leaf)).is_err() {
                    break;
                }
            }
        }
        let name = pane_session(&dest, new_leaf);
        let cmd: Vec<String> = if cfg!(windows) {
            vec!["cmd.exe".into(), "/k".into(), line.clone()]
        } else {
            let shell = std::env::var("SHELL").ok().filter(|s| !s.is_empty()).unwrap_or_else(|| "/bin/sh".into());
            vec![shell.clone(), "-lic".into(), format!("{line}; exec {shell} -l")]
        };
        if let Err(e) = session::ensure_in(&name, &cmd, Some(&dest_item.worktree_path)) {
            eprintln!("seahelm-gpui: fork: {e:#}");
            return;
        }
        crate::notify::log("pane.fork", serde_json::json!({"from": pane_session(&id, leaf), "to": name}));
        // The original's turn stops; its session and transcript stay.
        if let Some(view) = self.panes.get(&id).and_then(|p| p.views.get(&leaf)) {
            view.read(cx).send_bytes(b"\x1b");
        }
        self.save_layouts();
        self.selected = Some(dest);
        self.needs_focus = true;
        self.side_follow(cx);
        cx.notify();
    }

    fn open_rename(&mut self, key: String, window: &mut Window, cx: &mut Context<Self>) {
        let facts = self.pane_facts.get(&key).cloned().unwrap_or_default();
        let current = facts.custom_title.or(facts.display_title).unwrap_or_default();
        let input = cx.new(|cx| {
            let mut t = TextInput::new("Pane name (empty: its own title)", cx);
            t.set_text(&current, cx);
            t
        });
        let submit = cx.subscribe(&input, |w, _, _: &Submitted, cx| w.submit_rename(cx));
        window.focus(&input.focus_handle(cx));
        self.rename_pane = Some(RenamePane { key, input, busy: false, error: None, _submit: submit });
        cx.notify();
    }

    fn close_rename(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.rename_pane.take().is_some() {
            self.refocus_terminal(window, cx);
            cx.notify();
        }
    }

    fn submit_rename(&mut self, cx: &mut Context<Self>) {
        let Some(sheet) = self.rename_pane.as_mut() else { return };
        if sheet.busy {
            return;
        }
        sheet.busy = true;
        let (key, title) = (sheet.key.clone(), sheet.input.read(cx).text().trim().to_string());
        cx.spawn(async move |this, cx| {
            let k = key.clone();
            let r = cx.background_executor().spawn(async move { core_client::rename_pane(&k, &title) }).await;
            let _ = this.update(cx, |w, cx| {
                match r {
                    Ok(name) => {
                        let f = w.pane_facts.entry(key).or_default();
                        f.custom_title = name.clone();
                        if name.is_some() {
                            f.display_title = name;
                        }
                        w.rename_pane = None;
                        w.needs_focus = true;
                    }
                    Err(e) => {
                        if let Some(s) = w.rename_pane.as_mut() {
                            s.busy = false;
                            s.error = Some(e);
                        }
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    pub(super) fn rename_sheet(&self, cx: &mut Context<Self>) -> Option<gpui::AnyElement> {
        let s = self.rename_pane.as_ref()?;
        let card = div()
            .w(px(380.))
            .p(px(18.))
            .rounded(px(12.))
            .bg(tokens::sidebar_tint())
            .border_1()
            .border_color(tokens::separator())
            .shadow_lg()
            .flex()
            .flex_col()
            .gap(px(12.))
            .font_family(SYSTEM)
            .text_size(px(12.5))
            .key_context("RenamePaneSheet")
            .on_action(cx.listener(|w, _: &CancelSheet, window, cx| w.close_rename(window, cx)))
            .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
            .child(div().text_size(px(15.)).font_weight(FontWeight::SEMIBOLD).text_color(tokens::ink()).child("Rename pane"))
            .child(div().text_color(tokens::ink_dim()).child("Shown here, in the macOS app and on seahelm-web. Leave it empty to go back to the pane's own title."))
            .child(s.input.clone())
            .when_some(s.error.clone(), |d, e| d.child(div().text_color(tokens::danger()).child(e)))
            .child(
                div()
                    .flex()
                    .flex_row()
                    .justify_end()
                    .gap(px(8.))
                    .child(super::worktree_menu::sheet_button("rename-cancel", "Cancel", false, s.busy).on_click(cx.listener(|w, _: &ClickEvent, window, cx| w.close_rename(window, cx))))
                    .child(super::worktree_menu::sheet_button("rename-ok", "Rename", true, s.busy).on_click(cx.listener(|w, _: &ClickEvent, _, cx| w.submit_rename(cx)))),
            );
        Some(
            deferred(
                div()
                    .id("rename-backdrop")
                    .occlude()
                    .absolute()
                    .inset_0()
                    .bg(tokens::alpha(gpui::rgb(0x000000), 0.35))
                    .flex()
                    .items_start()
                    .justify_center()
                    .pt(px(90.))
                    .on_mouse_down(MouseButton::Left, cx.listener(|w, _, window, cx| w.close_rename(window, cx)))
                    .child(card),
            )
            .with_priority(2)
            .into_any_element(),
        )
    }

    /// The pane's corner: presence, the fork offer, its `#n` and name.
    pub(super) fn pane_corner(&self, id: &str, leaf: LeafId, cx: &mut Context<Self>) -> Option<gpui::AnyElement> {
        let key = pane_session(id, leaf);
        let facts = self.pane_facts.get(&key);
        let presence = self.presence.get(&key).filter(|p| p.until > Instant::now());
        let away = facts.filter(|f| f.claude_session.is_some()).and_then(|f| self.away_in(id, f));
        let handle = facts.and_then(|f| f.handle);
        let name = facts.and_then(|f| f.custom_title.clone());
        if presence.is_none() && away.is_none() && handle.is_none() && name.is_none() {
            return None;
        }
        let mut row = div().absolute().top(px(6.)).right(px(10.)).flex().flex_row().items_center().gap(px(6.)).font_family(SYSTEM).text_size(px(11.));
        if let Some(p) = presence {
            let text = if p.note.is_empty() { p.actor.clone() } else { format!("{} · {}", p.actor, p.note) };
            row = row.child(pill(tokens::accent()).child(text));
        }
        if let (Some((dest, branch, label)), Some(sid)) = (away, facts.and_then(|f| f.claude_session.clone())) {
            let id = id.to_string();
            row = row.child(
                pill(tokens::attention())
                    .id(SharedString::from(format!("fork-{key}")))
                    .cursor_pointer()
                    .on_click(cx.listener(move |w, _: &ClickEvent, _: &mut Window, cx| {
                        w.fork_into(id.clone(), leaf, dest.clone(), branch.clone(), sid.clone(), cx)
                    }))
                    .child(format!("Agent in {label}"))
                    .child(div().font_weight(FontWeight::SEMIBOLD).child("Fork there")),
            );
        }
        if handle.is_some() || name.is_some() {
            let label = match (handle, &name) {
                (Some(n), Some(t)) => format!("#{n} · {t}"),
                (Some(n), None) => format!("#{n}"),
                (None, Some(t)) => t.clone(),
                (None, None) => String::new(),
            };
            let rename_key = key.clone();
            row = row.child(
                div()
                    .id(SharedString::from(format!("name-{key}")))
                    .px(px(5.))
                    .rounded(px(4.))
                    .bg(tokens::alpha(tokens::sidebar_tint(), 0.85))
                    .text_color(if name.is_some() { tokens::ink_dim() } else { tokens::ink_faint() })
                    .cursor_pointer()
                    .hover(|s| s.text_color(tokens::ink()))
                    .on_click(cx.listener(move |w, _: &ClickEvent, window: &mut Window, cx| w.open_rename(rename_key.clone(), window, cx)))
                    .child(label),
            );
        }
        Some(row.into_any_element())
    }
}

fn pill(colour: gpui::Rgba) -> gpui::Div {
    div()
        .flex()
        .flex_row()
        .gap(px(6.))
        .px(px(8.))
        .py(px(2.))
        .rounded(px(10.))
        .bg(tokens::alpha(tokens::sidebar_tint(), 0.95))
        .border_1()
        .border_color(colour)
        .text_color(tokens::ink())
}

/// Facts by session, as `poll_pane_facts` keeps them.
pub type Facts = HashMap<String, PaneFacts>;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn actors_read_as_the_macos_pill() {
        assert_eq!(actor_name("claudeCode", Some(7)), "Claude Code #7");
        assert_eq!(actor_name("unknown", Some(3)), "Pane #3");
        assert_eq!(actor_name("codex", None), "Codex");
    }

    #[test]
    fn fork_commands_quote_and_name() {
        assert_eq!(fork_command("abc-1", "task/x", false, false), "claude --resume 'abc-1' --fork-session --name 'task/x'");
        assert_eq!(fork_command("id", "", true, false), "claude --resume 'id' --fork-session --dangerously-skip-permissions");
        assert_eq!(fork_command("a'b", "b", false, false), r"claude --resume 'a'\''b' --fork-session --name 'b'");
        assert_eq!(fork_command("id", "task/x", false, true), r#"claude --resume "id" --fork-session --name "task/x""#);
    }
}
