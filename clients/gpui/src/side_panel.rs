//! The selected worktree's side panel, opened from the header's folder and
//! diff buttons (the macOS app's `WorktreeSidePanelViewController`):
//!
//! - Files: the worktree's files as git sees them (tracked, and untracked
//!   but not ignored), as a tree; a file opens read-only below the header.
//! - Changes: what still has to go in a PR — uncommitted work, then
//!   committed work the base lacks (`worktree_git::changes`); a change opens
//!   as its diff.
//!
//! Reads run off the UI thread. Changes are read again every few seconds
//! while that tab is on screen; files when the panel opens or on ↻.

use std::collections::BTreeSet;
use std::time::Duration;

use gpui::{
    div, prelude::*, px, svg, uniform_list, ClickEvent, Context, EventEmitter, FontWeight, Rgba, SharedString, Window,
};

use crate::assets::icon;
use crate::tokens::{self, MONO, SYSTEM};
use crate::worktree_git::{self as wg, Change, Changes, LineKind, Preview, Stage, TreeRow};

const WIDTH: f32 = 340.0;
const HEADER_H: f32 = 40.0;
const ROW_H: f32 = 22.0;
const LINE_H: f32 = 17.0;
const CHANGES_EVERY: Duration = Duration::from_secs(4);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Tab {
    Files,
    Changes,
}

/// The panel asks its owner to close it (its ×).
pub struct CloseRequested;

/// What is open below the header instead of the list.
struct Opened {
    title: String,
    detail: String,
    preview: Option<Preview>,
}

pub struct SidePanel {
    worktree: Option<String>,
    tab: Tab,
    visible: bool,
    files: Vec<String>,
    files_for: Option<String>,
    expanded: BTreeSet<String>,
    rows: Vec<TreeRow>,
    changes: Changes,
    changes_for: Option<String>,
    opened: Option<Opened>,
    /// Bumped whenever the worktree changes, so a read that finishes for the
    /// old one is dropped.
    generation: u64,
    polling: bool,
}

impl EventEmitter<CloseRequested> for SidePanel {}

impl SidePanel {
    pub fn new(_cx: &mut Context<Self>) -> Self {
        Self {
            worktree: None,
            tab: Tab::Files,
            visible: false,
            files: Vec::new(),
            files_for: None,
            expanded: BTreeSet::new(),
            rows: Vec::new(),
            changes: Changes::default(),
            changes_for: None,
            opened: None,
            generation: 0,
            polling: false,
        }
    }

    /// On screen with `tab`, for `worktree`.
    pub fn show(&mut self, worktree: Option<String>, tab: Tab, cx: &mut Context<Self>) {
        self.visible = true;
        if self.tab != tab {
            self.tab = tab;
            self.opened = None;
        }
        self.set_worktree(worktree, cx);
        self.load(cx);
        self.poll(cx);
        cx.notify();
    }

    pub fn hide(&mut self, cx: &mut Context<Self>) {
        self.visible = false;
        cx.notify();
    }

    /// Follow the selection; nothing to do while hidden beyond noting it.
    pub fn set_worktree(&mut self, worktree: Option<String>, cx: &mut Context<Self>) {
        if self.worktree == worktree {
            return;
        }
        self.worktree = worktree;
        self.generation += 1;
        self.opened = None;
        self.expanded.clear();
        self.files.clear();
        self.rows.clear();
        self.files_for = None;
        self.changes = Changes::default();
        self.changes_for = None;
        if self.visible {
            self.load(cx);
        }
        cx.notify();
    }

    fn load(&mut self, cx: &mut Context<Self>) {
        match self.tab {
            Tab::Files => self.load_files(cx),
            Tab::Changes => self.load_changes(cx),
        }
    }

    fn load_files(&mut self, cx: &mut Context<Self>) {
        let Some(wt) = self.worktree.clone() else { return };
        let generation = self.generation;
        cx.spawn(async move |this, cx| {
            let path = wt.clone();
            let files = cx.background_executor().spawn(async move { wg::files(&path) }).await;
            let _ = this.update(cx, |p, cx| {
                if p.generation == generation {
                    p.files = files;
                    p.files_for = Some(wt);
                    p.rebuild_rows();
                    cx.notify();
                }
            });
        })
        .detach();
    }

    fn load_changes(&mut self, cx: &mut Context<Self>) {
        let Some(wt) = self.worktree.clone() else { return };
        let generation = self.generation;
        cx.spawn(async move |this, cx| {
            let path = wt.clone();
            let changes = cx.background_executor().spawn(async move { wg::changes(&path) }).await;
            let _ = this.update(cx, |p, cx| {
                if p.generation == generation && p.changes != changes {
                    p.changes = changes;
                    cx.notify();
                }
                if p.generation == generation {
                    p.changes_for = Some(wt);
                }
            });
        })
        .detach();
    }

    /// Changes again every few seconds while that tab is on screen: an agent
    /// is usually writing in the worktree beside it.
    fn poll(&mut self, cx: &mut Context<Self>) {
        if self.polling {
            return;
        }
        self.polling = true;
        cx.spawn(async move |this, cx| loop {
            cx.background_executor().timer(CHANGES_EVERY).await;
            let go = this.update(cx, |p, cx| {
                if !p.visible {
                    p.polling = false;
                    return false;
                }
                if p.tab == Tab::Changes && p.opened.is_none() {
                    p.load_changes(cx);
                }
                true
            })
            .unwrap_or_default();
            if !go {
                break;
            }
        })
        .detach();
    }

    fn rebuild_rows(&mut self) {
        self.rows = wg::tree_rows(&self.files, &self.expanded);
    }

    fn set_tab(&mut self, tab: Tab, cx: &mut Context<Self>) {
        if self.tab != tab {
            self.tab = tab;
            self.opened = None;
            self.load(cx);
            cx.notify();
        }
    }

    fn refresh(&mut self, _: &ClickEvent, _: &mut Window, cx: &mut Context<Self>) {
        self.opened = None;
        self.load(cx);
        cx.notify();
    }

    fn toggle_dir(&mut self, path: String, cx: &mut Context<Self>) {
        if !self.expanded.remove(&path) {
            self.expanded.insert(path);
        }
        self.rebuild_rows();
        cx.notify();
    }

    fn open_file(&mut self, rel: String, cx: &mut Context<Self>) {
        let Some(wt) = self.worktree.clone() else { return };
        self.opened = Some(Opened { title: rel.clone(), detail: String::new(), preview: None });
        let generation = self.generation;
        cx.spawn(async move |this, cx| {
            let r = rel.clone();
            let preview = cx.background_executor().spawn(async move { wg::preview_file(&wt, &r) }).await;
            let _ = this.update(cx, |p, cx| {
                if p.generation == generation {
                    if let Some(o) = p.opened.as_mut().filter(|o| o.title == rel) {
                        o.preview = Some(preview);
                        cx.notify();
                    }
                }
            });
        })
        .detach();
        cx.notify();
    }

    fn open_change(&mut self, change: Change, cx: &mut Context<Self>) {
        let Some(wt) = self.worktree.clone() else { return };
        let detail = match (&change.old_path, change.stage) {
            (Some(old), _) => format!("renamed from {old}"),
            (None, Stage::Uncommitted) => "uncommitted".into(),
            (None, Stage::Committed) => format!("not in {}", self.base_label()),
        };
        self.opened = Some(Opened { title: change.path.clone(), detail, preview: None });
        let changes = self.changes.clone();
        let generation = self.generation;
        cx.spawn(async move |this, cx| {
            let c = change.clone();
            let preview = cx.background_executor().spawn(async move { wg::preview_change(&wt, &c, &changes) }).await;
            let _ = this.update(cx, |p, cx| {
                if p.generation == generation {
                    if let Some(o) = p.opened.as_mut().filter(|o| o.title == change.path) {
                        o.preview = Some(preview);
                        cx.notify();
                    }
                }
            });
        })
        .detach();
        cx.notify();
    }

    fn back(&mut self, _: &ClickEvent, _: &mut Window, cx: &mut Context<Self>) {
        self.opened = None;
        if self.tab == Tab::Changes {
            self.load_changes(cx);
        }
        cx.notify();
    }

    /// "main" for `origin/main`.
    fn base_label(&self) -> String {
        let b = self.changes.base.as_deref().unwrap_or("the base");
        b.strip_prefix("origin/").unwrap_or(b).to_string()
    }
}

impl Render for SidePanel {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let body = match (&self.opened, self.worktree.is_some()) {
            (_, false) => self.empty("Pick a worktree").into_any_element(),
            (Some(_), true) => self.opened_view(cx).into_any_element(),
            (None, true) => match self.tab {
                Tab::Files => self.files_view(cx).into_any_element(),
                Tab::Changes => self.changes_view(cx).into_any_element(),
            },
        };
        div()
            .w(px(WIDTH))
            .h_full()
            .flex_none()
            .flex()
            .flex_col()
            .border_l_1()
            .border_color(tokens::hairline())
            .bg(tokens::sidebar_tint())
            .child(self.header(cx))
            .child(div().h(px(1.)).w_full().bg(tokens::hairline()))
            .child(div().flex_1().min_h_0().flex().flex_col().child(body))
    }
}

impl SidePanel {
    fn header(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let n = self.changes.files.len();
        let changes_label = if self.changes_for.is_some() && n > 0 { format!("Changes {n}") } else { "Changes".into() };
        div()
            .h(px(HEADER_H))
            .flex_none()
            .px(px(10.))
            .flex()
            .flex_row()
            .items_center()
            .gap(px(4.))
            .child(self.tab_button("side-tab-files", "Files", self.tab == Tab::Files, cx.listener(|p, _: &ClickEvent, _, cx| p.set_tab(Tab::Files, cx))))
            .child(self.tab_button("side-tab-changes", &changes_label, self.tab == Tab::Changes, cx.listener(|p, _: &ClickEvent, _, cx| p.set_tab(Tab::Changes, cx))))
            .child(div().flex_1())
            .child(small_icon("refresh-cw", "side-refresh").on_click(cx.listener(Self::refresh)))
            .child(small_icon("x", "side-close").on_click(cx.listener(|_, _: &ClickEvent, _, cx| cx.emit(CloseRequested))))
    }

    fn tab_button(
        &self,
        id: &'static str,
        label: &str,
        active: bool,
        on_click: impl Fn(&ClickEvent, &mut Window, &mut gpui::App) + 'static,
    ) -> impl IntoElement {
        div()
            .id(id)
            .occlude()
            .px(px(9.))
            .h(px(24.))
            .rounded(px(6.))
            .flex()
            .items_center()
            .font_family(SYSTEM)
            .text_size(px(12.))
            .font_weight(if active { FontWeight::SEMIBOLD } else { FontWeight::NORMAL })
            .text_color(if active { tokens::ink() } else { tokens::ink_dim() })
            .when(active, |d| d.bg(tokens::row_selected()))
            .when(!active, |d| d.hover(|s| s.bg(tokens::row_hover())))
            .cursor_pointer()
            .on_click(on_click)
            .child(label.to_string())
    }

    fn empty(&self, text: &str) -> impl IntoElement {
        div()
            .flex_1()
            .flex()
            .items_center()
            .justify_center()
            .font_family(SYSTEM)
            .text_size(px(12.))
            .text_color(tokens::ink_faint())
            .child(text.to_string())
    }

    fn files_view(&self, cx: &mut Context<Self>) -> impl IntoElement {
        if self.files_for.is_none() {
            return self.empty("Reading files…").into_any_element();
        }
        if self.rows.is_empty() {
            return self.empty("No files").into_any_element();
        }
        uniform_list(
            "side-files",
            self.rows.len(),
            cx.processor(|p: &mut Self, range: std::ops::Range<usize>, _window, cx| {
                range
                    .filter_map(|ix| p.rows.get(ix).cloned().map(|r| (ix, r)))
                    .map(|(ix, r)| {
                        let path = r.path.clone();
                        let is_dir = r.is_dir;
                        div()
                            .id(("side-file", ix))
                            .h(px(ROW_H))
                            .pl(px(10. + r.depth as f32 * 14.))
                            .pr(px(10.))
                            .flex()
                            .flex_row()
                            .items_center()
                            .gap(px(5.))
                            .cursor_pointer()
                            .hover(|s| s.bg(tokens::row_hover()))
                            .on_click(cx.listener(move |p, _: &ClickEvent, _, cx| {
                                if is_dir {
                                    p.toggle_dir(path.clone(), cx)
                                } else {
                                    p.open_file(path.clone(), cx)
                                }
                            }))
                            .child(if r.is_dir {
                                glyph(if r.expanded { "chevron-down" } else { "chevron-right" }, 10., tokens::ink_faint()).into_any_element()
                            } else {
                                div().w(px(12.)).flex_none().into_any_element()
                            })
                            .child(
                                div()
                                    .flex_1()
                                    .min_w_0()
                                    .overflow_hidden()
                                    .whitespace_nowrap()
                                    .text_ellipsis()
                                    .font_family(SYSTEM)
                                    .text_size(px(12.))
                                    .text_color(if r.is_dir { tokens::ink() } else { tokens::ink_dim() })
                                    .child(r.name.clone()),
                            )
                    })
                    .collect()
            }),
        )
        .flex_1()
        .into_any_element()
    }

    fn changes_view(&self, cx: &mut Context<Self>) -> impl IntoElement {
        if self.changes_for.is_none() {
            return self.empty("Reading changes…").into_any_element();
        }
        if self.changes.files.is_empty() {
            let text = match &self.changes.base {
                Some(_) => format!("Nothing to commit, and nothing {} lacks", self.base_label()),
                None => "Nothing to commit".into(),
            };
            return self.empty(&text).into_any_element();
        }
        let uncommitted: Vec<Change> = self.changes.uncommitted().cloned().collect();
        let committed: Vec<Change> = self.changes.committed().cloned().collect();
        let mut list = div().id("side-changes").flex_1().min_h_0().overflow_y_scroll().flex().flex_col().pb(px(8.));
        if !uncommitted.is_empty() {
            list = list.child(section_title(format!("Uncommitted · {}", uncommitted.len())));
            for (i, c) in uncommitted.into_iter().enumerate() {
                list = list.child(self.change_row(("side-un", i), c, cx));
            }
        }
        if !committed.is_empty() {
            list = list.child(section_title(format!("Not in {} · {}", self.base_label(), committed.len())));
            for (i, c) in committed.into_iter().enumerate() {
                list = list.child(self.change_row(("side-co", i), c, cx));
            }
        }
        list.into_any_element()
    }

    fn change_row(&self, id: (&'static str, usize), c: Change, cx: &mut Context<Self>) -> impl IntoElement {
        let (dir, name) = match c.path.rsplit_once('/') {
            Some((d, n)) => (format!("{d}/"), n.to_string()),
            None => (String::new(), c.path.clone()),
        };
        let status_colour = match c.status {
            'A' | '?' => tokens::diff_add(),
            'D' => tokens::diff_del(),
            'R' => tokens::waiting(),
            _ => tokens::attention(),
        };
        let conflicted = c.conflicted;
        let counts = match (c.added, c.removed) {
            (Some(a), Some(r)) => Some((a, r)),
            _ => None,
        };
        let open = c.clone();
        div()
            .id(id)
            .h(px(ROW_H))
            .px(px(10.))
            .flex()
            .flex_row()
            .items_center()
            .gap(px(7.))
            .cursor_pointer()
            .hover(|s| s.bg(tokens::row_hover()))
            .on_click(cx.listener(move |p, _: &ClickEvent, _, cx| p.open_change(open.clone(), cx)))
            .child(
                div()
                    .w(px(12.))
                    .flex_none()
                    .font_family(MONO)
                    .text_size(px(11.))
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(status_colour)
                    .child(if c.status == '?' { "U".to_string() } else { c.status.to_string() }),
            )
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .overflow_hidden()
                    .whitespace_nowrap()
                    .text_ellipsis()
                    .font_family(SYSTEM)
                    .text_size(px(12.))
                    .child(div().flex().flex_row().child(div().text_color(tokens::ink()).child(name)).child(
                        div().ml(px(6.)).text_color(tokens::ink_faint()).child(dir),
                    )),
            )
            .when(conflicted, |d| {
                d.child(div().flex_none().font_family(SYSTEM).text_size(px(10.5)).text_color(tokens::danger()).child("conflicts"))
            })
            .when_some(counts, |d, (a, r)| {
                d.child(
                    div()
                        .flex_none()
                        .flex()
                        .flex_row()
                        .font_family(MONO)
                        .text_size(px(10.5))
                        .child(div().text_color(tokens::diff_add()).child(format!("+{a}")))
                        .child(div().ml(px(4.)).text_color(tokens::diff_del()).child(format!("\u{2212}{r}"))),
                )
            })
    }

    fn opened_view(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let Some(o) = &self.opened else { return div().into_any_element() };
        let head = div()
            .flex_none()
            .px(px(6.))
            .py(px(6.))
            .flex()
            .flex_row()
            .items_center()
            .gap(px(4.))
            .child(small_icon("chevron-left", "side-back").on_click(cx.listener(Self::back)))
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .flex()
                    .flex_col()
                    .child(
                        div()
                            .overflow_hidden()
                            .whitespace_nowrap()
                            .text_ellipsis()
                            .font_family(SYSTEM)
                            .text_size(px(12.))
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(tokens::ink())
                            .child(o.title.clone()),
                    )
                    .when(!o.detail.is_empty(), |d| {
                        d.child(div().font_family(SYSTEM).text_size(px(10.5)).text_color(tokens::ink_faint()).child(o.detail.clone()))
                    }),
            );
        let body = match &o.preview {
            None => self.empty("Reading…").into_any_element(),
            Some(Preview::Note(text)) => self.empty(text).into_any_element(),
            Some(Preview::Text(lines)) => {
                let lines: Vec<(LineKind, SharedString)> = lines.iter().map(|l| (LineKind::Context, SharedString::from(l.clone()))).collect();
                code_lines("side-text", lines).into_any_element()
            }
            Some(Preview::Diff(lines)) => {
                let lines: Vec<(LineKind, SharedString)> = lines.iter().map(|(k, l)| (*k, SharedString::from(l.clone()))).collect();
                code_lines("side-diff", lines).into_any_element()
            }
        };
        div()
            .flex_1()
            .min_h_0()
            .flex()
            .flex_col()
            .child(head)
            .child(div().h(px(1.)).w_full().bg(tokens::hairline()))
            .child(body)
            .into_any_element()
    }
}

/// A file's lines or a diff's, drawn only where on screen; long lines are
/// cut at the panel's edge.
fn code_lines(id: &'static str, lines: Vec<(LineKind, SharedString)>) -> impl IntoElement {
    uniform_list(id, lines.len(), move |range, _window, _cx| {
        range
            .filter_map(|ix| lines.get(ix).cloned())
            .map(|(kind, text)| {
                let (fg, bg): (Rgba, Option<Rgba>) = match kind {
                    LineKind::Added => (tokens::diff_add(), Some(tokens::alpha(tokens::diff_add(), 0.10))),
                    LineKind::Removed => (tokens::diff_del(), Some(tokens::alpha(tokens::diff_del(), 0.10))),
                    LineKind::Meta => (tokens::waiting(), None),
                    LineKind::Context => (tokens::ink_dim(), None),
                };
                div()
                    .h(px(LINE_H))
                    .px(px(10.))
                    .whitespace_nowrap()
                    .overflow_hidden()
                    .font_family(MONO)
                    .text_size(px(11.))
                    .text_color(fg)
                    .when_some(bg, |d, bg| d.bg(bg))
                    .child(if text.is_empty() { SharedString::from(" ") } else { text })
            })
            .collect()
    })
    .flex_1()
    .py(px(4.))
}

fn section_title(text: String) -> impl IntoElement {
    div()
        .px(px(10.))
        .pt(px(10.))
        .pb(px(3.))
        .font_family(SYSTEM)
        .text_size(px(11.))
        .font_weight(FontWeight::SEMIBOLD)
        .text_color(tokens::ink_dim())
        .child(text)
}

fn glyph(name: &str, size: f32, colour: Rgba) -> gpui::Svg {
    svg().path(icon(name)).size(px(size * 1.2)).flex_none().text_color(colour)
}

fn small_icon(name: &str, id: &'static str) -> gpui::Stateful<gpui::Div> {
    div()
        .id(id)
        .occlude()
        .size(px(24.))
        .rounded(px(6.))
        .flex()
        .items_center()
        .justify_center()
        .cursor_pointer()
        .hover(|s| s.bg(tokens::row_hover()))
        .child(glyph(name, 12., tokens::chrome_icon()))
}
