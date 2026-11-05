//! Making and removing worktrees from the fleet column, through seahelm-core
//! (`worktree.create` / `worktree.delete`):
//!
//! - a group's `+` (and a row's "New Worktree…") opens a sheet: what the
//!   agent should do, which agent; the core cuts a branch from the task,
//!   adds the worktree from the trunk and starts the agent in a session this
//!   client attaches when the worktree is opened, which it is at once;
//! - a row's right-click menu: open its pull request, new worktree, copy
//!   the path, show it in the file manager, delete it (asked first; the
//!   branch stays, and the core refuses while there is uncommitted work,
//!   before ending any session);
//! - a group's `×` takes the project off this client's list (asked first;
//!   nothing on disk changes).

use gpui::{
    anchored, deferred, div, point, prelude::*, px, ClickEvent, Context, Entity, Focusable, FontWeight, MouseButton, MouseDownEvent,
    Pixels, Point, PromptLevel, Subscription, Window,
};

use super::Workspace;
use crate::core_client;
use crate::fleet;
use crate::notify;
use crate::text_input::{Submitted, TextInput};
use crate::tokens::{self, SYSTEM};
use crate::worktree_git;

gpui::actions!(seahelm, [CancelSheet]);

/// The agents the core can start in a new worktree (`worktree.options`).
const AGENTS: &[(&str, &str)] = &[("claudeCode", "Claude Code"), ("codex", "Codex")];

pub struct NewWorktree {
    project: String,
    project_name: String,
    input: Entity<TextInput>,
    agent: &'static str,
    busy: bool,
    error: Option<String>,
    _submit: Subscription,
}

pub struct RowMenu {
    item: String,
    at: Point<Pixels>,
}

impl Workspace {
    /// The project a worktree belongs to: its group's main checkout.
    fn project_of(&self, item: &str) -> Option<(String, String)> {
        self.fleet
            .groups
            .iter()
            .find(|g| g.items.iter().any(|i| i.id == item))
            .filter(|g| !g.path.is_empty())
            .map(|g| (g.path.clone(), g.title.clone()))
    }

    pub(super) fn open_new_worktree(&mut self, project: String, project_name: String, window: &mut Window, cx: &mut Context<Self>) {
        self.row_menu = None;
        let input = cx.new(|cx| TextInput::new("What should the agent do?", cx));
        let submit = cx.subscribe(&input, |w, _, _: &Submitted, cx| w.create_worktree(cx));
        window.focus(&input.focus_handle(cx));
        notify::log("worktree.new.open", serde_json::json!({"project": project}));
        self.new_worktree = Some(NewWorktree { project, project_name, input, agent: AGENTS[0].0, busy: false, error: None, _submit: submit });
        cx.notify();
    }

    fn close_sheet(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.new_worktree.as_ref().is_some_and(|s| s.busy) {
            return;
        }
        self.new_worktree = None;
        self.refocus_terminal(window, cx);
        cx.notify();
    }

    fn create_worktree(&mut self, cx: &mut Context<Self>) {
        let Some(sheet) = self.new_worktree.as_mut() else { return };
        if sheet.busy {
            return;
        }
        let task = sheet.input.read(cx).text().trim().to_string();
        if task.is_empty() {
            sheet.error = Some("Say what the agent should do: it names the branch and is the agent's first message.".into());
            cx.notify();
            return;
        }
        sheet.busy = true;
        sheet.error = None;
        let (project, agent) = (sheet.project.clone(), sheet.agent);
        notify::log("worktree.new.create", serde_json::json!({"project": project, "agent": agent}));
        cx.spawn(async move |this, cx| {
            let made = cx.background_executor().spawn(async move { core_client::create_worktree(&project, &task, agent) }).await;
            let snap = match &made {
                Ok(_) => Some(cx.background_executor().spawn(async { fleet::read() }).await),
                Err(_) => None,
            };
            let _ = this.update(cx, |w, cx| {
                match made {
                    Ok(path) => {
                        if let Some(snap) = snap {
                            w.fleet = snap;
                        }
                        w.new_worktree = None;
                        // Opened at once: its first pane attaches the session
                        // the core is holding, and the agent starts at its size.
                        w.selected = Some(path);
                        w.needs_focus = true;
                        w.side_follow(cx);
                    }
                    Err(e) => {
                        if let Some(s) = w.new_worktree.as_mut() {
                            s.busy = false;
                            s.error = Some(e);
                        }
                    }
                }
                cx.notify();
            });
        })
        .detach();
        cx.notify();
    }

    pub(super) fn open_row_menu(&mut self, item: String, e: &MouseDownEvent, cx: &mut Context<Self>) {
        self.row_menu = Some(RowMenu { item, at: e.position });
        cx.notify();
    }

    fn close_row_menu(&mut self, cx: &mut Context<Self>) {
        if self.row_menu.take().is_some() {
            cx.notify();
        }
    }

    /// Asked first, with what the worktree holds: git refuses to remove one
    /// with uncommitted work, and its panes' sessions end.
    fn delete_worktree(&mut self, item: String, window: &mut Window, cx: &mut Context<Self>) {
        self.row_menu = None;
        let Some(it) = self.fleet.find(&item).cloned() else { return };
        if it.is_main {
            return;
        }
        let panes = self.panes.get(&item).map_or(0, |p| p.views.len());
        cx.spawn_in(window, async move |this, cx| {
            let path = it.worktree_path.clone();
            let changes = cx.background_executor().spawn(async move { worktree_git::changes(&path) }).await;
            let detail = delete_detail(&it.branch, changes.uncommitted().count(), changes.committed().count(), panes);
            let answer = this.update_in(cx, |_, window, cx| {
                window.prompt(PromptLevel::Warning, &format!("Delete the worktree {}?", it.subtitle), Some(&detail), &["Delete", "Cancel"], cx)
            });
            let Ok(answer) = answer else { return };
            if answer.await != Ok(0) {
                return;
            }
            notify::log("worktree.delete", serde_json::json!({"path": it.worktree_path}));
            let path = it.worktree_path.clone();
            let done = cx.background_executor().spawn(async move { core_client::delete_worktree(&path) }).await;
            let snap = cx.background_executor().spawn(async { fleet::read() }).await;
            let _ = this.update_in(cx, |w, window, cx| {
                match done {
                    Ok(()) => {
                        w.forget_worktree(&item);
                        w.fleet = snap;
                    }
                    Err(e) => {
                        // Shown, not waited on: there is nothing to decide.
                        drop(window.prompt(PromptLevel::Critical, "The worktree was not deleted", Some(&e), &["OK"], cx));
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// A deleted worktree's panes and layout go; the selection moves to the
    /// first row left.
    fn forget_worktree(&mut self, item: &str) {
        self.panes.remove(item);
        self.forget_preview_tabs(item);
        self.save_layouts();
        if self.selected.as_deref() == Some(item) {
            self.selected = self.fleet.groups.iter().flat_map(|g| g.items.iter()).find(|i| i.id != item).map(|i| i.id.clone());
            self.needs_focus = true;
        }
    }

    pub(super) fn remove_project(&mut self, project: String, name: String, window: &mut Window, cx: &mut Context<Self>) {
        let answer = window.prompt(
            PromptLevel::Info,
            &format!("Remove {name} from the fleet?"),
            Some("Its worktrees and their sessions stay as they are; add the folder again to bring it back."),
            &["Remove", "Cancel"],
            cx,
        );
        cx.spawn(async move |this, cx| {
            if answer.await != Ok(0) {
                return;
            }
            if let Err(e) = fleet::remove_project(&project) {
                eprintln!("seahelm-gpui: remove project: {e}");
                return;
            }
            let snap = cx.background_executor().spawn(async { fleet::read() }).await;
            let _ = this.update(cx, |w, cx| {
                w.fleet = snap;
                if w.selected.as_deref().is_some_and(|s| w.fleet.find(s).is_none()) {
                    w.selected = None;
                }
                cx.notify();
            });
        })
        .detach();
    }

    // MARK: - drawing

    /// The sheet and the menu, over everything else.
    pub(super) fn overlays(&self, cx: &mut Context<Self>) -> Option<gpui::AnyElement> {
        if self.new_worktree.is_some() {
            return Some(self.new_worktree_sheet(cx).into_any_element());
        }
        self.row_menu.as_ref().map(|m| self.row_menu_view(m, cx).into_any_element())
    }

    fn new_worktree_sheet(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let Some(s) = &self.new_worktree else { return div().into_any_element() };
        let mut agents = div().flex().flex_row().gap(px(6.));
        for (id, label) in AGENTS {
            let on = s.agent == *id;
            let id = *id;
            agents = agents.child(
                div()
                    .id(gpui::SharedString::from(format!("agent-{id}")))
                    .px(px(10.))
                    .h(px(26.))
                    .rounded(px(6.))
                    .flex()
                    .items_center()
                    .border_1()
                    .border_color(if on { tokens::accent() } else { tokens::hairline() })
                    .text_color(if on { tokens::ink() } else { tokens::ink_dim() })
                    .cursor_pointer()
                    .on_click(cx.listener(move |w, _: &ClickEvent, _, cx| {
                        if let Some(s) = w.new_worktree.as_mut() {
                            s.agent = id;
                            cx.notify();
                        }
                    }))
                    .child(label.to_string()),
            );
        }
        let card = div()
            .w(px(460.))
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
            .key_context("NewWorktreeSheet")
            .on_action(cx.listener(|w, _: &CancelSheet, window, cx| w.close_sheet(window, cx)))
            // Clicks inside the card stay inside it.
            .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
            .child(div().text_size(px(15.)).font_weight(FontWeight::SEMIBOLD).text_color(tokens::ink()).child(format!("New worktree in {}", s.project_name)))
            .child(
                div()
                    .text_color(tokens::ink_dim())
                    .child("A branch named after the task, off the project's trunk, with the agent started on it."),
            )
            .child(s.input.clone())
            .child(div().flex().flex_row().items_center().gap(px(10.)).child(div().text_color(tokens::ink_dim()).child("Agent")).child(agents))
            .when_some(s.error.clone(), |d, e| d.child(div().text_color(tokens::danger()).child(e)))
            .child(
                div()
                    .flex()
                    .flex_row()
                    .justify_end()
                    .gap(px(8.))
                    .child(sheet_button("sheet-cancel", "Cancel", false, s.busy).on_click(cx.listener(|w, _: &ClickEvent, window, cx| w.close_sheet(window, cx))))
                    .child(
                        sheet_button("sheet-create", if s.busy { "Creating…" } else { "Create" }, true, s.busy)
                            .on_click(cx.listener(|w, _: &ClickEvent, _, cx| w.create_worktree(cx))),
                    ),
            );
        deferred(
            div()
                .id("sheet-backdrop")
                .occlude()
                .absolute()
                .inset_0()
                .bg(tokens::alpha(gpui::rgb(0x000000), 0.35))
                .flex()
                .items_start()
                .justify_center()
                .pt(px(90.))
                .on_mouse_down(MouseButton::Left, cx.listener(|w, _, window, cx| w.close_sheet(window, cx)))
                .child(card),
        )
        .with_priority(2)
        .into_any_element()
    }

    fn row_menu_view(&self, m: &RowMenu, cx: &mut Context<Self>) -> impl IntoElement {
        let item = self.fleet.find(&m.item).cloned();
        let pr_url = item.as_ref().and_then(|i| self.prs.get(&i.worktree_path)).map(|p| p.url.clone()).filter(|u| !u.is_empty());
        let project = self.project_of(&m.item);
        let mut menu = div()
            .min_w(px(210.))
            .py(px(5.))
            .rounded(px(8.))
            .bg(tokens::sidebar_tint())
            .border_1()
            .border_color(tokens::separator())
            .shadow_lg()
            .flex()
            .flex_col()
            .font_family(SYSTEM)
            .text_size(px(12.5))
            .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation());
        if let Some(it) = item.clone() {
            if let Some(url) = pr_url {
                menu = menu.child(menu_item("menu-pr", "Open Pull Request", false).on_click(cx.listener(move |w, _: &ClickEvent, _, cx| {
                    cx.open_url(&url);
                    w.close_row_menu(cx);
                })));
            }
            if let Some((path, name)) = project {
                menu = menu.child(menu_item("menu-new", "New Worktree…", false).on_click(cx.listener(move |w, _: &ClickEvent, window, cx| {
                    w.open_new_worktree(path.clone(), name.clone(), window, cx)
                })));
            }
            let copy = it.worktree_path.clone();
            menu = menu.child(menu_item("menu-copy", "Copy Path", false).on_click(cx.listener(move |w, _: &ClickEvent, _, cx| {
                cx.write_to_clipboard(gpui::ClipboardItem::new_string(copy.clone()));
                w.close_row_menu(cx);
            })));
            let reveal = it.worktree_path.clone();
            menu = menu.child(menu_item("menu-reveal", reveal_label(), false).on_click(cx.listener(move |w, _: &ClickEvent, _, cx| {
                cx.reveal_path(std::path::Path::new(&reveal));
                w.close_row_menu(cx);
            })));
            menu = menu.child(div().my(px(4.)).h(px(1.)).bg(tokens::hairline()));
            if it.is_main {
                menu = menu.child(menu_item("menu-delete", "Delete Worktree…", false).opacity(0.4).child(
                    div().ml(px(6.)).text_size(px(11.)).text_color(tokens::ink_faint()).child("main checkout"),
                ));
            } else {
                let id = it.id.clone();
                menu = menu.child(menu_item("menu-delete", "Delete Worktree…", true).on_click(cx.listener(move |w, _: &ClickEvent, window, cx| {
                    w.delete_worktree(id.clone(), window, cx)
                })));
            }
        }
        deferred(
            div()
                .id("menu-backdrop")
                .absolute()
                .inset_0()
                .on_mouse_down(MouseButton::Left, cx.listener(|w, _, _, cx| w.close_row_menu(cx)))
                .on_mouse_down(MouseButton::Right, cx.listener(|w, _, _, cx| w.close_row_menu(cx)))
                .child(anchored().position(point(m.at.x, m.at.y)).snap_to_window().child(menu)),
        )
        .with_priority(1)
    }
}

/// What the delete prompt says: what goes, what stays, what git will refuse.
fn delete_detail(branch: &str, uncommitted: usize, committed: usize, panes: usize) -> String {
    let mut lines = Vec::new();
    if uncommitted > 0 {
        lines.push(format!(
            "{uncommitted} uncommitted file{}: it will not be deleted until they are committed or discarded.",
            if uncommitted == 1 { "" } else { "s" }
        ));
    }
    if panes > 0 {
        lines.push(format!("Its {panes} pane{} and their sessions end.", if panes == 1 { "" } else { "s" }));
    }
    let keep = if branch.is_empty() || branch == "detached" { "Its commits stay in the repository.".to_string() } else { format!("The branch {branch} stays.") };
    lines.push(if committed > 0 {
        format!("{keep} It has work the trunk lacks ({committed} file{}).", if committed == 1 { "" } else { "s" })
    } else {
        keep
    });
    lines.join("\n")
}

fn reveal_label() -> &'static str {
    if cfg!(target_os = "macos") {
        "Show in Finder"
    } else if cfg!(windows) {
        "Show in Explorer"
    } else {
        "Open Folder"
    }
}

fn menu_item(id: &'static str, label: &str, danger: bool) -> gpui::Stateful<gpui::Div> {
    div()
        .id(id)
        .mx(px(5.))
        .px(px(9.))
        .h(px(24.))
        .rounded(px(5.))
        .flex()
        .flex_row()
        .items_center()
        .cursor_pointer()
        .text_color(if danger { tokens::danger() } else { tokens::ink() })
        .hover(|s| s.bg(tokens::row_hover()))
        .child(label.to_string())
}

fn sheet_button(id: &'static str, label: &str, primary: bool, busy: bool) -> gpui::Stateful<gpui::Div> {
    div()
        .id(id)
        .px(px(14.))
        .h(px(28.))
        .rounded(px(7.))
        .flex()
        .items_center()
        .cursor_pointer()
        .when(primary, |d| d.bg(tokens::accent()).text_color(gpui::rgb(0xffffff)).font_weight(FontWeight::SEMIBOLD))
        .when(!primary, |d| d.border_1().border_color(tokens::hairline()).text_color(tokens::ink()))
        .when(busy, |d| d.opacity(0.6))
        .child(label.to_string())
}

#[cfg(test)]
mod tests {
    use super::delete_detail;

    #[test]
    fn the_delete_prompt_says_what_goes_and_what_stays() {
        assert_eq!(delete_detail("task/x", 0, 0, 0), "The branch task/x stays.");
        let d = delete_detail("task/x", 2, 3, 1);
        assert!(d.starts_with("2 uncommitted files: it will not be deleted"));
        assert!(d.contains("Its 1 pane and their sessions end."));
        assert!(d.ends_with("The branch task/x stays. It has work the trunk lacks (3 files)."));
        assert_eq!(delete_detail("detached", 1, 0, 2).lines().count(), 3);
    }
}
