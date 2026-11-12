//! A pane's right-click menu, as the macOS app's terminal has it
//! (`GhosttyNSView.makePaneContextMenu`): split, the link under the pointer,
//! copy and paste, rename, close.

use gpui::{anchored, deferred, div, point, prelude::*, px, ClickEvent, Context, Focusable, MouseButton, Pixels, Point};

use super::Workspace;
use crate::split::{Axis, LeafId};
use crate::terminal_view::ContextMenuRequested;
use crate::tokens::{self, SYSTEM};

pub struct PaneMenu {
    worktree: String,
    leaf: LeafId,
    at: Point<Pixels>,
    link: Option<String>,
    has_selection: bool,
}

impl Workspace {
    /// The terminal asked for its menu: that pane takes the focus, as a
    /// click would, so split and close act on it.
    pub(super) fn open_pane_menu(&mut self, worktree: String, leaf: LeafId, e: &ContextMenuRequested, cx: &mut Context<Self>) {
        if let Some(p) = self.panes.get_mut(&worktree) {
            if p.tree.focused != leaf && p.tree.leaves().contains(&leaf) {
                p.tree.focused = leaf;
                self.save_layouts();
            }
        }
        self.row_menu = None;
        self.pane_menu = Some(PaneMenu { worktree, leaf, at: e.at, link: e.link.clone(), has_selection: e.has_selection });
        cx.notify();
    }

    fn close_pane_menu(&mut self, cx: &mut Context<Self>) {
        if self.pane_menu.take().is_some() {
            cx.notify();
        }
    }

    pub(super) fn pane_menu_view(&self, cx: &mut Context<Self>) -> Option<gpui::AnyElement> {
        let m = self.pane_menu.as_ref()?;
        let view = self.panes.get(&m.worktree).and_then(|p| p.views.get(&m.leaf)).cloned();
        let key = super::pane_session(&m.worktree, m.leaf);
        let can_close = self.panes.get(&m.worktree).is_some_and(|p| p.tree.len() > 1);
        let mut menu = div()
            .min_w(px(200.))
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
        menu = menu
            .child(item("pm-split-h", "Split Horizontally", true).on_click(cx.listener(|w, _: &ClickEvent, window, cx| {
                w.pane_menu = None;
                w.split(Axis::Horizontal, window, cx);
            })))
            .child(item("pm-split-v", "Split Vertically", true).on_click(cx.listener(|w, _: &ClickEvent, window, cx| {
                w.pane_menu = None;
                w.split(Axis::Vertical, window, cx);
            })))
            .child(separator());
        if let Some(link) = m.link.clone() {
            let copy = link.clone();
            menu = menu
                .child(item("pm-open-link", "Open Link in Browser", true).on_click(cx.listener(move |w, _: &ClickEvent, _, cx| {
                    cx.open_url(&link);
                    w.close_pane_menu(cx);
                })))
                .child(item("pm-copy-link", "Copy Link", true).on_click(cx.listener(move |w, _: &ClickEvent, _, cx| {
                    cx.write_to_clipboard(gpui::ClipboardItem::new_string(copy.clone()));
                    w.close_pane_menu(cx);
                })))
                .child(separator());
        }
        let (copy_view, paste_view) = (view.clone(), view.clone());
        let can_paste = cx.read_from_clipboard().and_then(|c| c.text()).is_some_and(|t| !t.is_empty());
        menu = menu
            .child(item("pm-copy", "Copy", m.has_selection).when(m.has_selection, |d| {
                d.on_click(cx.listener(move |w, _: &ClickEvent, _, cx| {
                    if let Some(v) = &copy_view {
                        v.update(cx, |v, cx| v.copy_selection(cx));
                    }
                    w.close_pane_menu(cx);
                }))
            }))
            .child(item("pm-paste", "Paste", can_paste).when(can_paste, |d| {
                d.on_click(cx.listener(move |w, _: &ClickEvent, window, cx| {
                    w.close_pane_menu(cx);
                    if let Some(v) = &paste_view {
                        window.focus(&v.focus_handle(cx));
                        v.update(cx, |v, cx| v.paste_clipboard(cx));
                    }
                }))
            }))
            .child(separator())
            .child(item("pm-rename", "Rename Pane…", true).on_click(cx.listener(move |w, _: &ClickEvent, window, cx| {
                w.pane_menu = None;
                w.open_rename(key.clone(), window, cx);
            })))
            .child(item("pm-close", "Close Pane", can_close).when(can_close, |d| {
                d.on_click(cx.listener(|w, _: &ClickEvent, window, cx| {
                    w.pane_menu = None;
                    w.close_pane(window, cx);
                }))
            }));
        Some(
            deferred(
                div()
                    .id("pane-menu-backdrop")
                    .occlude()
                    .absolute()
                    .inset_0()
                    .on_mouse_down(MouseButton::Left, cx.listener(|w, _, _, cx| w.close_pane_menu(cx)))
                    .on_mouse_down(MouseButton::Right, cx.listener(|w, _, _, cx| w.close_pane_menu(cx)))
                    .child(anchored().position(point(m.at.x, m.at.y)).snap_to_window().child(menu)),
            )
            .with_priority(1)
            .into_any_element(),
        )
    }
}

fn item(id: &'static str, label: &str, enabled: bool) -> gpui::Stateful<gpui::Div> {
    div()
        .id(id)
        .mx(px(5.))
        .px(px(9.))
        .h(px(24.))
        .rounded(px(5.))
        .flex()
        .flex_row()
        .items_center()
        .text_color(tokens::ink())
        .when(enabled, |d| d.cursor_pointer().hover(|s| s.bg(tokens::row_hover())))
        .when(!enabled, |d| d.opacity(0.4))
        .child(label.to_string())
}

fn separator() -> gpui::Div {
    div().my(px(4.)).h(px(1.)).bg(tokens::hairline())
}
