//! Files and changes opened from the left column, or from a pane's Preview,
//! open in a *document pane*: a leaf of the worktree's split tree, split from
//! the focused pane the way the split shortcut (⌘D) splits it, with a tab
//! per file or change. One per worktree, reused by later opens; reopening an
//! item selects its tab and reads it again. It is never a terminal (no
//! session, no `pane.register`) and never saved with the layout.

use gpui::{div, prelude::*, px, ClickEvent, Context, FocusHandle, FontWeight, MouseButton, SharedString, Window};

use super::Workspace;
use crate::side_panel::{code_lines, OpenItem};
use crate::split::{Axis, LeafId};
use crate::theme;
use crate::tokens::{self, SYSTEM};
use crate::worktree_git::{self as wg, LineKind, Preview, Stage};

pub struct DocTab {
    /// What identifies it among the pane's tabs.
    key: String,
    title: String,
    detail: String,
    item: OpenItem,
    preview: Option<Preview>,
}

pub struct DocPane {
    /// Its leaf in the worktree's split tree.
    pub(super) leaf: LeafId,
    tabs: Tabs,
    pub(super) focus: FocusHandle,
}

impl DocPane {
    /// The title of the tab on screen, for the compact pane tabs.
    pub(super) fn title(&self) -> String {
        self.tabs.tabs.get(self.tabs.active).map_or_else(|| "Files".to_string(), |t| t.title.clone())
    }
}

#[derive(Default)]
struct Tabs {
    tabs: Vec<DocTab>,
    /// The tab on screen.
    active: usize,
}

impl Tabs {
    fn index(&self, key: &str) -> Option<usize> {
        self.tabs.iter().position(|t| t.key == key)
    }

    /// Close tab `at`. The one on screen stays on screen; closing it shows
    /// its left neighbour. False once no tab is left: the pane goes.
    fn close(&mut self, at: usize) -> bool {
        if at < self.tabs.len() {
            self.tabs.remove(at);
            if self.active > at || (self.active == at && at > 0) {
                self.active -= 1;
            }
        }
        if self.tabs.is_empty() {
            return false;
        }
        self.active = self.active.min(self.tabs.len() - 1);
        true
    }
}

/// The tab's key, title and second line for an item.
fn describe(item: &OpenItem) -> (String, String, String) {
    let base = |p: &str| p.rsplit('/').next().unwrap_or(p).to_string();
    match item {
        OpenItem::File { path, .. } => (format!("file:{path}"), base(path), path.clone()),
        OpenItem::Change { change, changes, .. } => {
            let detail = match (&change.old_path, change.stage) {
                (Some(old), _) => format!("{} · renamed from {old}", change.path),
                (None, Stage::Uncommitted) => format!("{} · uncommitted", change.path),
                (None, Stage::Committed) => {
                    let b = changes.base.as_deref().unwrap_or("the base");
                    format!("{} · not in {}", change.path, b.strip_prefix("origin/").unwrap_or(b))
                }
            };
            (format!("change:{:?}:{}", change.stage, change.path), format!("Δ {}", base(&change.path)), detail)
        }
    }
}

fn worktree_of(item: &OpenItem) -> &str {
    match item {
        OpenItem::File { worktree, .. } | OpenItem::Change { worktree, .. } => worktree,
    }
}

impl Workspace {
    /// The worktree's document pane, if it has one.
    pub(super) fn document(&self, row: &str) -> Option<&DocPane> {
        self.panes.get(row).and_then(|p| p.document.as_ref())
    }

    pub(super) fn is_document(&self, row: &str, leaf: LeafId) -> bool {
        self.document(row).is_some_and(|d| d.leaf == leaf)
    }

    /// Open `item` in its worktree's document pane (the fleet row whose path
    /// it is), splitting the focused pane for one when there is none, and
    /// put focus on it.
    pub(super) fn open_document(&mut self, item: OpenItem, cx: &mut Context<Self>) {
        let worktree_path = worktree_of(&item).to_string();
        let Some(row) = self.fleet.groups.iter().flat_map(|g| g.items.iter()).find(|i| i.worktree_path == worktree_path).map(|i| i.id.clone()) else {
            return;
        };
        let (key, title, detail) = describe(&item);
        let focus = cx.focus_handle();
        let panes = self.panes.entry(row.clone()).or_default();
        if !panes.document.as_ref().is_some_and(|d| panes.tree.leaves().contains(&d.leaf)) {
            let leaf = panes.tree.split(Axis::Horizontal);
            panes.document = Some(DocPane { leaf, tabs: Tabs::default(), focus });
        }
        let Some(doc) = panes.document.as_mut() else { return };
        let tabs = &mut doc.tabs;
        let at = match tabs.index(&key) {
            Some(i) => {
                tabs.tabs[i].item = item.clone();
                tabs.tabs[i].preview = None;
                i
            }
            None => {
                tabs.tabs.push(DocTab { key: key.clone(), title, detail, item: item.clone(), preview: None });
                tabs.tabs.len() - 1
            }
        };
        tabs.active = at;
        panes.tree.focused = doc.leaf;
        // A pane zoomed alone would hide the file just opened.
        if self.zoomed.as_ref().is_some_and(|(w, _)| *w == row) {
            self.zoomed = None;
        }
        self.needs_focus = true;
        crate::notify::log("document.open", serde_json::json!({"tab": key}));
        cx.spawn(async move |this, cx| {
            let preview = cx
                .background_executor()
                .spawn(async move {
                    match &item {
                        OpenItem::File { worktree, path } => wg::preview_file(worktree, path),
                        OpenItem::Change { worktree, change, changes } => wg::preview_change(worktree, change, changes),
                    }
                })
                .await;
            let _ = this.update(cx, |w, cx| {
                if let Some(t) = w.panes.get_mut(&row).and_then(|p| p.document.as_mut()).and_then(|d| d.tabs.tabs.iter_mut().find(|t| t.key == key)) {
                    t.preview = Some(preview);
                    cx.notify();
                }
            });
        })
        .detach();
        cx.notify();
    }

    fn select_document_tab(&mut self, row: &str, at: usize, cx: &mut Context<Self>) {
        if let Some(p) = self.panes.get_mut(row) {
            if let Some(d) = p.document.as_mut().filter(|d| at < d.tabs.tabs.len()) {
                d.tabs.active = at;
                p.tree.focused = d.leaf;
                self.needs_focus = true;
            }
        }
        cx.notify();
    }

    /// Close tab `at` of the worktree's document pane; the last tab takes the
    /// pane with it.
    pub(super) fn close_document_tab(&mut self, row: &str, at: usize, cx: &mut Context<Self>) {
        let Some(p) = self.panes.get_mut(row) else { return };
        let Some(d) = p.document.as_mut() else { return };
        if !d.tabs.close(at) {
            let leaf = d.leaf;
            p.document = None;
            p.tree.remove(leaf);
        }
        self.needs_focus = true;
        cx.notify();
    }

    /// The tab on screen of the focused document pane (⌘W on it).
    pub(super) fn close_active_document_tab(&mut self, row: &str, cx: &mut Context<Self>) {
        if let Some(at) = self.document(row).map(|d| d.tabs.active) {
            self.close_document_tab(row, at, cx);
        }
    }

    /// The document pane in its place in the panes body: its tabs, then the
    /// tab on screen. A click in it makes it the focused pane.
    pub(super) fn document_element(&self, row: &str, cx: &mut Context<Self>) -> Option<gpui::AnyElement> {
        let d = self.document(row)?;
        let mut strip = div()
            .id("document-strip")
            .flex_none()
            .h(px(super::STRIP_H))
            .px(px(8.))
            .flex()
            .flex_row()
            .items_end()
            .gap(px(2.))
            .overflow_x_scroll()
            .border_b_1()
            .border_color(tokens::hairline())
            .bg(tokens::sidebar_tint())
            .font_family(SYSTEM)
            .text_size(px(12.));
        for (i, t) in d.tabs.tabs.iter().enumerate() {
            let (r1, r2) = (row.to_string(), row.to_string());
            let close = div()
                .id(SharedString::from(format!("doc-close-{i}")))
                .ml(px(6.))
                .px(px(3.))
                .rounded(px(3.))
                .text_color(tokens::ink_faint())
                .hover(|s| s.bg(tokens::row_hover()).text_color(tokens::ink()))
                .on_click(cx.listener(move |w, _: &ClickEvent, _, cx| {
                    cx.stop_propagation();
                    w.close_document_tab(&r2, i, cx)
                }))
                .child("×");
            strip = strip.child(
                tab_chip(SharedString::from(format!("doc-tab-{i}")), &t.title, d.tabs.active == i, Some(close))
                    .on_click(cx.listener(move |w, _: &ClickEvent, _, cx| w.select_document_tab(&r1, i, cx))),
            );
        }
        let empty = |text: &str| {
            div().flex_1().flex().items_center().justify_center().font_family(SYSTEM).text_size(px(12.)).text_color(tokens::ink_faint()).child(text.to_string())
        };
        let tab = d.tabs.tabs.get(d.tabs.active);
        let body = match tab.and_then(|t| t.preview.as_ref()) {
            None => empty("Reading…").into_any_element(),
            Some(Preview::Note(text)) => empty(text).into_any_element(),
            Some(Preview::Text(lines)) => {
                code_lines("document-text", lines.iter().map(|l| (LineKind::Context, SharedString::from(l.clone()))).collect()).into_any_element()
            }
            Some(Preview::Diff(lines)) => code_lines("document-diff", lines.iter().map(|(k, l)| (*k, SharedString::from(l.clone()))).collect()).into_any_element(),
        };
        let (row_owned, leaf) = (row.to_string(), d.leaf);
        Some(
            div()
                .id("document-pane")
                .track_focus(&d.focus)
                .size_full()
                .flex()
                .flex_col()
                .bg(theme::rgb(theme::bg()))
                .on_mouse_down(
                    MouseButton::Left,
                    cx.listener(move |w, _, window: &mut Window, cx| {
                        if let Some(p) = w.panes.get_mut(&row_owned) {
                            if p.tree.leaves().contains(&leaf) {
                                p.tree.focused = leaf;
                            }
                        }
                        if let Some(d) = w.document(&row_owned) {
                            window.focus(&d.focus.clone());
                        }
                        cx.notify();
                    }),
                )
                .child(strip)
                .child(
                    div()
                        .flex_none()
                        .px(px(12.))
                        .py(px(5.))
                        .font_family(SYSTEM)
                        .text_size(px(11.))
                        .text_color(tokens::ink_faint())
                        .overflow_hidden()
                        .whitespace_nowrap()
                        .text_ellipsis()
                        .child(tab.map(|t| t.detail.clone()).unwrap_or_default()),
                )
                .child(div().flex_1().min_h_0().flex().flex_col().child(body))
                .into_any_element(),
        )
    }
}

pub(super) fn tab_chip(id: impl Into<SharedString>, title: &str, active: bool, close: Option<gpui::Stateful<gpui::Div>>) -> gpui::Stateful<gpui::Div> {
    div()
        .id(id.into())
        .h(px(26.))
        .px(px(10.))
        .rounded_t(px(6.))
        .flex()
        .flex_row()
        .items_center()
        .cursor_pointer()
        .text_color(if active { tokens::ink() } else { tokens::ink_dim() })
        .font_weight(if active { FontWeight::SEMIBOLD } else { FontWeight::NORMAL })
        .when(active, |d| d.bg(theme::rgb(theme::bg())))
        .when(!active, |d| d.hover(|s| s.bg(tokens::row_hover())))
        .child(title.to_string())
        .when_some(close, |d, c| d.child(c))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::worktree_git::{Change, Changes};

    fn change(stage: Stage) -> Change {
        Change { path: "src/a.rs".into(), old_path: None, status: 'M', stage, added: Some(1), removed: Some(0), conflicted: false }
    }

    #[test]
    fn tabs_are_named_and_told_apart() {
        let f = OpenItem::File { worktree: "/w".into(), path: "src/a.rs".into() };
        assert_eq!(describe(&f), ("file:src/a.rs".into(), "a.rs".into(), "src/a.rs".into()));
        let changes = Changes { base: Some("origin/main".into()), ..Changes::default() };
        let un = OpenItem::Change { worktree: "/w".into(), change: change(Stage::Uncommitted), changes: changes.clone() };
        let co = OpenItem::Change { worktree: "/w".into(), change: change(Stage::Committed), changes };
        let (k1, t1, d1) = describe(&un);
        let (k2, _, d2) = describe(&co);
        assert_ne!(k1, k2, "the same file uncommitted and committed is two tabs");
        assert_eq!(t1, "Δ a.rs");
        assert_eq!(d1, "src/a.rs · uncommitted");
        assert_eq!(d2, "src/a.rs · not in main");
    }

    #[test]
    fn closing_a_tab_keeps_the_right_one_on_screen() {
        let mk = |k: &str| DocTab { key: k.into(), title: k.into(), detail: String::new(), item: OpenItem::File { worktree: "/w".into(), path: k.into() }, preview: None };
        let mut d = Tabs { tabs: vec![mk("a"), mk("b"), mk("c")], active: 2 };
        assert_eq!(d.index("b"), Some(1));
        assert!(d.close(0));
        assert_eq!(d.active, 1, "c moved left and stays on screen");
        assert!(d.close(1));
        assert_eq!(d.active, 0, "closing the active one shows its left neighbour");
        assert!(d.close(5), "out of range: nothing");
        assert_eq!(d.tabs.len(), 1);
        assert!(!d.close(0), "no tabs left: the pane goes");
    }
}
