//! Files and changes opened from the left column, as tabs in the main area
//! above the terminals (the macOS app's edit mode, with its preview tab
//! strip): the first tab is the worktree's terminals, then one per file or
//! change opened, each closable. Kept per worktree; reopening an item
//! selects its tab (and reads it again).

use gpui::{div, prelude::*, px, ClickEvent, Context, FontWeight, SharedString};

use super::Workspace;
use crate::side_panel::{code_lines, OpenItem};
use crate::theme;
use crate::tokens::{self, SYSTEM};
use crate::worktree_git::{self as wg, LineKind, Preview, Stage};

pub struct PreviewTab {
    /// What identifies it among the worktree's tabs.
    key: String,
    title: String,
    detail: String,
    item: OpenItem,
    preview: Option<Preview>,
}

#[derive(Default)]
pub struct PreviewTabs {
    tabs: Vec<PreviewTab>,
    /// The tab on screen; None is the terminals.
    active: Option<usize>,
}

impl PreviewTabs {
    fn index(&self, key: &str) -> Option<usize> {
        self.tabs.iter().position(|t| t.key == key)
    }

    /// Close tab `at`. The one on screen stays on screen; closing it shows
    /// its left neighbour, and the last one the terminals.
    fn close(&mut self, at: usize) {
        if at >= self.tabs.len() {
            return;
        }
        self.tabs.remove(at);
        self.active = match self.active {
            Some(a) if a == at => (!self.tabs.is_empty()).then(|| at.saturating_sub(1).min(self.tabs.len() - 1)),
            Some(a) if a > at => Some(a - 1),
            other => other,
        };
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
    /// Open `item` as a tab of its worktree's (the fleet row whose path it
    /// is) and show it.
    pub(super) fn open_preview(&mut self, item: OpenItem, cx: &mut Context<Self>) {
        let worktree_path = worktree_of(&item).to_string();
        let Some(row) = self.fleet.groups.iter().flat_map(|g| g.items.iter()).find(|i| i.worktree_path == worktree_path).map(|i| i.id.clone()) else {
            return;
        };
        let (key, title, detail) = describe(&item);
        let tabs = self.preview_tabs.entry(row.clone()).or_default();
        let at = match tabs.index(&key) {
            Some(i) => {
                tabs.tabs[i].item = item.clone();
                tabs.tabs[i].preview = None;
                i
            }
            None => {
                tabs.tabs.push(PreviewTab { key: key.clone(), title, detail, item: item.clone(), preview: None });
                tabs.tabs.len() - 1
            }
        };
        tabs.active = Some(at);
        crate::notify::log("preview.open", serde_json::json!({"tab": key}));
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
                if let Some(t) = w.preview_tabs.get_mut(&row).and_then(|tabs| tabs.tabs.iter_mut().find(|t| t.key == key)) {
                    t.preview = Some(preview);
                    cx.notify();
                }
            });
        })
        .detach();
        cx.notify();
    }

    fn select_preview(&mut self, row: &str, at: Option<usize>, cx: &mut Context<Self>) {
        if let Some(tabs) = self.preview_tabs.get_mut(row) {
            tabs.active = at.filter(|i| *i < tabs.tabs.len());
            if tabs.active.is_none() {
                self.needs_focus = true;
            }
            cx.notify();
        }
    }

    fn close_preview(&mut self, row: &str, at: usize, cx: &mut Context<Self>) {
        let Some(tabs) = self.preview_tabs.get_mut(row) else { return };
        tabs.close(at);
        if tabs.active.is_none() {
            self.needs_focus = true;
        }
        cx.notify();
    }

    /// Whether worktree `row` shows a preview tab rather than its terminals.
    pub(super) fn preview_active(&self, row: &str) -> bool {
        self.preview_tabs.get(row).is_some_and(|t| t.active.is_some())
    }

    /// The strip of tabs above the main area, when the worktree has any
    /// besides its terminals.
    pub(super) fn preview_strip(&self, row: &str, cx: &mut Context<Self>) -> Option<gpui::AnyElement> {
        let tabs = self.preview_tabs.get(row).filter(|t| !t.tabs.is_empty())?;
        let mut strip = div()
            .id("preview-strip")
            .flex_none()
            .h(px(30.))
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
        let r = row.to_string();
        strip = strip.child(
            tab_chip("tab-terminals", "Terminals", tabs.active.is_none(), None)
                .on_click(cx.listener(move |w, _: &ClickEvent, _, cx| w.select_preview(&r, None, cx))),
        );
        for (i, t) in tabs.tabs.iter().enumerate() {
            let (r1, r2) = (row.to_string(), row.to_string());
            let close = div()
                .id(SharedString::from(format!("tab-close-{i}")))
                .ml(px(6.))
                .px(px(3.))
                .rounded(px(3.))
                .text_color(tokens::ink_faint())
                .hover(|s| s.bg(tokens::row_hover()).text_color(tokens::ink()))
                .on_click(cx.listener(move |w, _: &ClickEvent, _, cx| {
                    cx.stop_propagation();
                    w.close_preview(&r2, i, cx)
                }))
                .child("×");
            strip = strip.child(
                tab_chip(SharedString::from(format!("tab-{i}")), &t.title, tabs.active == Some(i), Some(close))
                    .on_click(cx.listener(move |w, _: &ClickEvent, _, cx| w.select_preview(&r1, Some(i), cx))),
            );
        }
        Some(strip.into_any_element())
    }

    /// The active preview tab, filling the main area.
    pub(super) fn preview_body(&self, row: &str) -> Option<gpui::AnyElement> {
        let tabs = self.preview_tabs.get(row)?;
        let t = tabs.tabs.get(tabs.active?)?;
        let empty = |text: &str| {
            div().flex_1().flex().items_center().justify_center().font_family(SYSTEM).text_size(px(12.)).text_color(tokens::ink_faint()).child(text.to_string())
        };
        let body = match &t.preview {
            None => empty("Reading…").into_any_element(),
            Some(Preview::Note(text)) => empty(text).into_any_element(),
            Some(Preview::Text(lines)) => {
                code_lines("preview-text", lines.iter().map(|l| (LineKind::Context, SharedString::from(l.clone()))).collect()).into_any_element()
            }
            Some(Preview::Diff(lines)) => code_lines("preview-diff", lines.iter().map(|(k, l)| (*k, SharedString::from(l.clone()))).collect()).into_any_element(),
        };
        Some(
            div()
                .flex_1()
                .min_h_0()
                .flex()
                .flex_col()
                .bg(theme::rgb(theme::bg()))
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
                        .child(t.detail.clone()),
                )
                .child(body)
                .into_any_element(),
        )
    }

    /// Tabs whose worktree is gone go with it.
    pub(super) fn forget_preview_tabs(&mut self, row: &str) {
        self.preview_tabs.remove(row);
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
        let mk = |k: &str| PreviewTab { key: k.into(), title: k.into(), detail: String::new(), item: OpenItem::File { worktree: "/w".into(), path: k.into() }, preview: None };
        let mut t = PreviewTabs { tabs: vec![mk("a"), mk("b"), mk("c")], active: Some(2) };
        assert_eq!(t.index("b"), Some(1));
        t.close(0);
        assert_eq!(t.active, Some(1), "c moved left and stays on screen");
        t.close(1);
        assert_eq!(t.active, Some(0), "closing the active one shows its left neighbour");
        t.close(5);
        assert_eq!(t.tabs.len(), 1, "out of range: nothing");
        t.close(0);
        assert_eq!(t.active, None, "no tabs left: the terminals");
    }
}
