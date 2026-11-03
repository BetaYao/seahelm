//! The main window, laid out as the macOS app's dashboard: the fleet column
//! on the left as navigator, the selected worktree's terminal on the right.
//! Measurements and colours are the AppKit originals' (MACOS-SPEC.md).

use std::collections::HashMap;
use std::time::Duration;

use gpui::{
    div, percentage, prelude::*, px, svg, Animation, AnimationExt, App, ClickEvent, Context, Entity, FocusHandle,
    Focusable, FontWeight, MouseButton, MouseDownEvent, MouseMoveEvent, MouseUpEvent, Rgba, SharedString,
    Transformation, Window,
};

use crate::assets::icon;
use crate::core_client::{self, WorktreeState};
use crate::fleet::{self, Dot, GitStats, Item, Snapshot};
use crate::session;
use crate::terminal_view::TerminalView;
use crate::theme;
use crate::tokens::{self, MONO, SYSTEM};

const SIDEBAR_DEFAULT: f32 = 300.0;
const SIDEBAR_MIN: f32 = 200.0;
const HEADER_H: f32 = 40.0;

pub struct Workspace {
    fleet: Snapshot,
    git: HashMap<String, GitStats>,
    selected: Option<String>,
    terminals: HashMap<String, Entity<TerminalView>>,
    sidebar_width: f32,
    sidebar_visible: bool,
    dragging_divider: bool,
    divider_hover: bool,
    dock_hover: bool,
    focus: FocusHandle,
    memory: Option<u64>,
    /// seahelm-core's view of the worktrees it has panes in; where it has
    /// one, it decides the row's dot over the app's.
    core: HashMap<String, WorktreeState>,
}

impl Workspace {
    pub fn new(cx: &mut Context<Self>) -> Self {
        let this = Self {
            fleet: Snapshot::default(),
            git: HashMap::new(),
            selected: None,
            terminals: HashMap::new(),
            sidebar_width: SIDEBAR_DEFAULT,
            sidebar_visible: true,
            dragging_divider: false,
            divider_hover: false,
            dock_hover: false,
            focus: cx.focus_handle(),
            memory: None,
            core: HashMap::new(),
        };
        Self::poll_core(cx);
        Self::poll_fleet(cx);
        Self::poll_git(cx);
        Self::poll_memory(cx);
        // The time labels move on their own.
        cx.spawn(async move |this, cx| loop {
            cx.background_executor().timer(Duration::from_secs(1)).await;
            if this.update(cx, |_, cx| cx.notify()).is_err() {
                break;
            }
        })
        .detach();
        this
    }

    /// The fleet, every two seconds, read off the main thread.
    fn poll_fleet(cx: &mut Context<Self>) {
        cx.spawn(async move |this, cx| loop {
            let snap = cx.background_executor().spawn(async { fleet::read() }).await;
            let alive = this
                .update(cx, |w, cx| {
                    w.fleet = snap;
                    if w.selected.is_none() {
                        w.selected = w.fleet.groups.iter().flat_map(|g| g.items.first()).next().map(|i| i.id.clone());
                    }
                    cx.notify();
                })
                .is_ok();
            if !alive {
                break;
            }
            cx.background_executor().timer(Duration::from_secs(2)).await;
        })
        .detach();
    }

    /// seahelm-core: started if needed, then read every two seconds.
    fn poll_core(cx: &mut Context<Self>) {
        cx.spawn(async move |this, cx| {
            cx.background_executor().spawn(async { core_client::ensure() }).await;
            loop {
                let states = cx.background_executor().spawn(async { core_client::worktrees() }).await;
                let alive = this
                    .update(cx, |w, cx| {
                        if w.core != states {
                            w.core = states;
                            cx.notify();
                        }
                    })
                    .is_ok();
                if !alive {
                    break;
                }
                cx.background_executor().timer(Duration::from_secs(2)).await;
            }
        })
        .detach();
    }

    /// Diff stats for every worktree, every fifteen seconds.
    fn poll_git(cx: &mut Context<Self>) {
        cx.spawn(async move |this, cx| loop {
            let paths: Vec<String> = this
                .read_with(cx, |w, _| {
                    w.fleet.groups.iter().flat_map(|g| g.items.iter().map(|i| i.worktree_path.clone())).collect()
                })
                .unwrap_or_default();
            let stats = cx
                .background_executor()
                .spawn(async move { paths.into_iter().filter_map(|p| fleet::git_stats(&p).map(|s| (p, s))).collect() })
                .await;
            if this
                .update(cx, |w, cx| {
                    w.git = stats;
                    cx.notify();
                })
                .is_err()
            {
                break;
            }
            let wait = if this.read_with(cx, |w, _| w.git.is_empty()).unwrap_or(true) { 1 } else { 15 };
            cx.background_executor().timer(Duration::from_secs(wait)).await;
        })
        .detach();
    }

    /// The header's memory readout: the focused session's process tree.
    fn poll_memory(cx: &mut Context<Self>) {
        cx.spawn(async move |this, cx| loop {
            let name = this.read_with(cx, |w, _| w.selected.as_deref().map(session_name)).ok().flatten();
            let bytes = match name {
                Some(n) => cx.background_executor().spawn(async move { session::memory(&n) }).await,
                None => None,
            };
            if this
                .update(cx, |w, cx| {
                    if w.memory != bytes {
                        w.memory = bytes;
                        cx.notify();
                    }
                })
                .is_err()
            {
                break;
            }
            cx.background_executor().timer(Duration::from_secs(3)).await;
        })
        .detach();
    }

    fn select(&mut self, id: String, window: &mut Window, cx: &mut Context<Self>) {
        self.selected = Some(id.clone());
        // On screen in a frontmost window: a turn that ends here is seen.
        if let Some(path) = self.fleet.find(&id).map(|i| i.worktree_path.clone()) {
            cx.background_executor()
                .spawn(async move {
                    let _ = core_client::call("client.visible", serde_json::json!({"worktrees": [path], "app_active": true}));
                })
                .detach();
        }
        if let Some(term) = self.terminal_for(&id, cx) {
            window.focus(&term.focus_handle(cx));
        }
        cx.notify();
    }

    /// The selected worktree's terminal, its session started in that
    /// worktree on first use.
    fn terminal_for(&mut self, id: &str, cx: &mut Context<Self>) -> Option<Entity<TerminalView>> {
        if let Some(t) = self.terminals.get(id) {
            return Some(t.clone());
        }
        let item = self.fleet.find(id)?.clone();
        let name = session_name(id);
        if let Err(e) = session::ensure_in(&name, &[], Some(&item.worktree_path)) {
            eprintln!("seahelm-gpui: {e:#}");
        }
        let reg = serde_json::json!({
            "pane": name,
            "worktree_path": item.worktree_path,
            "project": item.repository,
            "branch": item.subtitle,
        });
        cx.background_executor()
            .spawn(async move {
                if let Err(e) = core_client::call("pane.register", reg) {
                    eprintln!("seahelm-gpui: core pane.register: {e}");
                }
            })
            .detach();
        let view = cx.new(|cx| {
            let mut v = TerminalView::new(name, cx);
            v.font_size = px(crate::fonts::terminal_size());
            v
        });
        self.terminals.insert(id.to_string(), view.clone());
        Some(view)
    }

    fn on_divider_down(&mut self, _: &MouseDownEvent, _: &mut Window, cx: &mut Context<Self>) {
        self.dragging_divider = true;
        cx.notify();
    }

    fn on_mouse_move(&mut self, e: &MouseMoveEvent, window: &mut Window, cx: &mut Context<Self>) {
        if self.dragging_divider {
            let max = (f32::from(window.viewport_size().width) * 0.5).max(SIDEBAR_MIN);
            self.sidebar_width = f32::from(e.position.x).clamp(SIDEBAR_MIN, max);
            cx.notify();
        }
    }

    fn on_mouse_up(&mut self, _: &MouseUpEvent, _: &mut Window, cx: &mut Context<Self>) {
        if self.dragging_divider {
            self.dragging_divider = false;
            cx.notify();
        }
    }

    fn toggle_sidebar(&mut self, _: &ClickEvent, _: &mut Window, cx: &mut Context<Self>) {
        self.sidebar_visible = !self.sidebar_visible;
        cx.notify();
    }
}

/// Our own session per worktree, in our own daemon directory: attaching to
/// the app's live sessions would shrink its panes to our window.
pub fn session_name(worktree_id: &str) -> String {
    let base = std::path::Path::new(worktree_id).file_name().and_then(|n| n.to_str()).unwrap_or("worktree");
    let mut h: u32 = 2166136261;
    for b in worktree_id.bytes() {
        h = (h ^ b as u32).wrapping_mul(16777619);
    }
    let clean: String = base.chars().map(|c| if c.is_ascii_alphanumeric() || c == '-' { c } else { '_' }).take(40).collect();
    format!("gpui-{clean}-{h:08x}")
}

impl Focusable for Workspace {
    fn focus_handle(&self, _: &App) -> FocusHandle {
        self.focus.clone()
    }
}

impl Render for Workspace {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let terminal = self.selected.clone().and_then(|id| self.terminal_for(&id, cx));
        let title: SharedString = match (&terminal, self.selected.as_deref().and_then(|id| self.fleet.find(id))) {
            (_, Some(item)) => item.title.clone().into(),
            _ => "Seahelm".into(),
        };
        let width = self.sidebar_width;

        let mut root = div()
            .id("workspace")
            .track_focus(&self.focus)
            .size_full()
            .flex()
            .flex_row()
            .font_family(MONO)
            .on_mouse_move(cx.listener(Self::on_mouse_move))
            .on_mouse_up(MouseButton::Left, cx.listener(Self::on_mouse_up));
        if self.dragging_divider {
            root = root.cursor_col_resize();
        }

        if self.sidebar_visible {
            root = root.child(self.sidebar(width, window, cx));
        }
        root = root.child(self.terminal_column(title, terminal, cx));
        if self.sidebar_visible {
            root = root.child(self.divider(width, cx));
        }
        root
    }
}

impl Workspace {
    fn sidebar(&mut self, width: f32, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        div()
            .w(px(width))
            .h_full()
            .flex_none()
            .flex()
            .flex_col()
            .bg(tokens::sidebar_tint())
            .child(self.sidebar_header(cx))
            .child(self.fleet_header())
            .child(div().mt(px(11.)).h(px(1.)).w_full().bg(tokens::hairline()))
            .child(self.fleet_list(cx))
            .child(self.dock(cx))
    }

    /// 40pt: the traffic lights' 70×14 slot on the left, the icon cluster on
    /// the right.
    fn sidebar_header(&self, cx: &mut Context<Self>) -> impl IntoElement {
        div()
            .h(px(HEADER_H))
            .flex_none()
            .flex()
            .flex_row()
            .items_center()
            .justify_end()
            .pr(px(8.))
            .gap(px(2.))
            .child(chrome_icon("contrast", false))
            .child(chrome_icon("sailboat", false))
            .child(chrome_icon("folder", false))
            .child(chrome_icon("diff", false))
            .child(chrome_icon("panel-left", false).id("toggle-sidebar").on_click(cx.listener(Self::toggle_sidebar)))
    }

    fn fleet_header(&self) -> impl IntoElement {
        let n = self.fleet.worktree_count();
        let subtitle = if self.fleet.running > 0 { format!("{n} · {} running", self.fleet.running) } else { format!("{n}") };
        div()
            .mt(px(13.))
            .px(px(15.))
            .flex()
            .flex_row()
            .items_center()
            .gap(px(10.))
            .child(div().text_size(px(13.)).line_height(px(17.)).text_color(tokens::accent()).child("◍"))
            .child(div().text_size(px(12.5)).line_height(px(16.)).font_weight(FontWeight::BOLD).text_color(tokens::ink()).child("Fleet"))
            .child(div().text_size(px(11.)).line_height(px(15.)).text_color(tokens::ink_faint()).child(subtitle))
            .child(div().flex_1())
            .child(glyph("folder-plus", 13., tokens::ink_dim()))
            .child(glyph("group", 13., tokens::ink_dim()))
    }

    fn fleet_list(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let mut list = div()
            .id("fleet-list")
            .flex_1()
            .overflow_y_scroll()
            .mt(px(14.))
            .pt(px(2.))
            .pb(px(12.))
            .px(px(15.))
            .flex()
            .flex_col()
            .gap(px(2.));
        if let Some(err) = &self.fleet.error {
            list = list.child(div().text_size(px(11.)).line_height(px(15.)).text_color(tokens::ink_faint()).child(err.clone()));
        }
        let now = fleet::now();
        for (gi, group) in self.fleet.groups.iter().enumerate() {
            list = list.child(group_header(&group.title, gi == 0, group.items.len() >= 3));
            let mut rows = div().flex().flex_col().gap(px(4.));
            for item in &group.items {
                rows = rows.child(self.row(item, now, cx));
            }
            list = list.child(rows);
        }
        list
    }

    fn row(&self, item: &Item, now: f64, cx: &mut Context<Self>) -> impl IntoElement {
        // Where the core watches this worktree, its verdict is the row's.
        let mut item = item.clone();
        if let Some(c) = self.core.get(&item.worktree_path) {
            item.status = c.status.clone();
            item.unseen = c.unseen;
            item.running_since = c.running_since.or(item.running_since);
            item.last_activity_at = c.last_activity_at.or(item.last_activity_at);
        }
        let item = &item;
        let selected = self.selected.as_deref() == Some(item.id.as_str());
        let panes = self.fleet.panes.get(&item.worktree_path).copied().unwrap_or(0);
        let stats = self.git.get(&item.worktree_path);
        let id = item.id.clone();

        let mut line2 = div()
            .flex()
            .flex_row()
            .items_baseline()
            .gap(px(8.))
            .child(div().text_size(px(11.)).line_height(px(15.)).text_color(tokens::ink_dim()).one_line().child(item.subtitle.clone()));
        if let Some(s) = stats.filter(|s| s.added + s.removed + s.ahead + s.behind > 0) {
            let mut g = div().flex().flex_row().text_size(px(10.)).line_height(px(13.));
            if s.added + s.removed > 0 {
                g = g
                    .child(div().text_color(tokens::diff_add()).child(format!("+{}", s.added)))
                    .child(div().text_color(tokens::diff_del()).child(format!(" \u{2212}{}", s.removed)));
            }
            let mut sync = String::new();
            if s.ahead > 0 {
                sync += &format!("↑{}", s.ahead);
            }
            if s.behind > 0 {
                sync += &format!("↓{}", s.behind);
            }
            if !sync.is_empty() {
                g = g.child(div().text_color(tokens::ink_faint()).child(format!("  {sync}")));
            }
            line2 = line2.child(g);
        }
        if let Some(pr) = &item.pr {
            line2 = line2.child(pr_badge(pr));
        }
        line2 = line2.child(div().flex_1()).child(
            div()
                .flex_none()
                .text_size(px(10.)).line_height(px(13.))
                .text_color(tokens::ink_faint())
                .child(if panes == 0 { "—".to_string() } else { format!("{panes} panes") }),
        );

        div()
            .id(SharedString::from(format!("row-{}", item.id)))
            .rounded(px(8.))
            .flex()
            .flex_row()
            .pl(px(10.))
            .pr(px(10.))
            .py(px(8.))
            .gap(px(7.))
            .when(selected, |d| d.bg(tokens::row_selected()))
            .when(!selected, |d| d.hover(|s| s.bg(tokens::row_hover())))
            .on_click(cx.listener(move |w, _: &ClickEvent, window, cx| w.select(id.clone(), window, cx)))
            .child(div().w(px(5.5)).h(px(16.)).flex_none().flex().items_center().child(status_dot(item.dot(), &item.id)))
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .overflow_hidden()
                    .flex()
                    .flex_col()
                    .gap(px(3.))
                    .child(
                        div()
                            .w_full()
                            .flex()
                            .flex_row()
                            .items_center()
                            .gap(px(7.))
                            .child(div().flex_1().min_w_0().one_line().text_size(px(12.)).line_height(px(16.)).text_color(tokens::ink()).child(item.title.clone()))
                            .child(div().flex_none().text_size(px(10.)).line_height(px(13.)).text_color(tokens::ink_faint()).child(item.time_label(now))),
                    )
                    .child(line2),
            )
    }

    /// `─ ⎈ First Mate · state ──── ›` at the foot of the column.
    fn dock(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let hover = self.dock_hover;
        let rule = || div().h(px(1.)).bg(tokens::dock_rule());
        div()
            .id("first-mate-dock")
            .flex_none()
            .mt(px(10.))
            .mb(px(12.))
            .mr(px(12.))
            .ml(px(6.))
            .px(px(6.))
            .py(px(6.))
            .rounded(px(8.))
            .when(hover, |d| d.bg(tokens::dock_hover()))
            .on_hover(cx.listener(|w, h: &bool, _, cx| {
                w.dock_hover = *h;
                cx.notify();
            }))
            .flex()
            .flex_row()
            .items_center()
            .gap(px(6.))
            .child(rule().w(px(14.)))
            .child(glyph("ship-wheel", 11., tokens::ink_dim()))
            .child(
                div()
                    .flex()
                    .flex_row()
                    .text_size(px(11.)).line_height(px(15.))
                    .child(
                        div()
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(if hover { tokens::ink() } else { tokens::ink_dim() })
                            .child("First Mate"),
                    )
                    .child(div().text_color(tokens::ink_faint()).child(" · "))
                    .child(div().font_weight(FontWeight::MEDIUM).text_color(tokens::ink_faint()).child("off")),
            )
            .child(rule().flex_1())
            .child(glyph("chevron-right", 10., if hover { tokens::ink() } else { tokens::ink_faint() }))
    }

    fn terminal_column(&self, title: SharedString, terminal: Option<Entity<TerminalView>>, _cx: &mut Context<Self>) -> impl IntoElement {
        let fg = theme::rgb(theme::FG);
        let memory = self.memory.map(format_memory).unwrap_or_default();
        let header = div()
            .h(px(HEADER_H))
            .flex_none()
            .relative()
            .flex()
            .flex_row()
            .items_center()
            .bg(theme::rgb(theme::BG))
            .when(!self.sidebar_visible, |d| d.pl(px(82.)))
            .child(div().ml(px(12.)).child(chrome_icon("share", false)))
            .child(div().ml(px(6.)).font_family(SYSTEM).text_size(px(11.)).line_height(px(15.)).text_color(tokens::ink_dim()).child(memory))
            .child(
                // Truly centred, over the whole header.
                div()
                    .absolute()
                    .inset_0()
                    .flex()
                    .items_center()
                    .justify_center()
                    .child(
                        div()
                            .max_w(px(520.))
                            .one_line()
                            .font_family(SYSTEM)
                            .text_size(px(12.)).line_height(px(16.))
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(fg)
                            .child(title),
                    ),
            )
            .child(div().flex_1())
            .child(div().mr(px(8.)).child(icon_button("columns-2", tokens::alpha(fg, 0.55))));
        let body = match terminal {
            Some(t) => div().flex_1().min_h_0().child(t),
            None => div().flex_1().bg(theme::rgb(theme::BG)),
        };
        div().flex_1().min_w_0().h_full().flex().flex_col().bg(theme::rgb(theme::BG)).child(header).child(body)
    }

    /// No width of its own: a 16pt strip over the seam, a 1pt line in it.
    fn divider(&self, width: f32, cx: &mut Context<Self>) -> impl IntoElement {
        let active = self.divider_hover || self.dragging_divider;
        div()
            .id("column-divider")
            .absolute()
            .top_0()
            .bottom_0()
            .left(px(width - 8.))
            .w(px(16.))
            .cursor_col_resize()
            .flex()
            .justify_center()
            .when(active, |d| d.bg(tokens::alpha(tokens::accent(), 0.10)))
            .on_hover(cx.listener(|w, h: &bool, _, cx| {
                w.divider_hover = *h;
                cx.notify();
            }))
            .on_mouse_down(MouseButton::Left, cx.listener(Self::on_divider_down))
            .child(div().h_full().w(px(if active { 2. } else { 1. })).bg(if active { tokens::accent() } else { tokens::separator() }))
    }
}

fn format_memory(bytes: u64) -> String {
    let mb = bytes as f64 / (1024.0 * 1024.0);
    if mb < 1.0 {
        "<1 MB".into()
    } else if mb < 1024.0 {
        format!("{mb:.0} MB")
    } else {
        format!("{:.1} GB", mb / 1024.0)
    }
}

/// One line, cut with an ellipsis. GPUI's `truncate()` (nowrap) measures
/// once, before flex has given the text its width, and caches that; a
/// wrapping line clamped to one is measured again at every width.
trait OneLine: gpui::Styled + Sized {
    fn one_line(self) -> Self {
        self.overflow_hidden().text_ellipsis().line_clamp(1)
    }
}
impl<T: gpui::Styled> OneLine for T {}

fn glyph(name: &str, size: f32, colour: Rgba) -> gpui::Svg {
    // Lucide draws inside a 2/24 margin where an SF Symbol fills its size.
    svg().path(icon(name)).size(px(size * 1.2)).flex_none().text_color(colour)
}

fn icon_button(name: &str, tint: Rgba) -> gpui::Div {
    div()
        .size(px(26.))
        .rounded(px(7.))
        .flex()
        .items_center()
        .justify_center()
        .hover(|s| s.bg(tokens::row_hover()))
        .child(glyph(name, 12., tint))
}

/// A 26×26 toolbar button with a 12pt glyph in the chrome grey.
fn chrome_icon(name: &str, active: bool) -> gpui::Div {
    icon_button(name, if active { tokens::accent() } else { tokens::chrome_icon() })
}

fn group_header(title: &str, first: bool, can_integrate: bool) -> impl IntoElement {
    div()
        // The spec's 13/7 come out tighter in AppKit's stack; these are
        // measured off the live window.
        .pt(px(if first { 0. } else { 6. }))
        .pb(px(1.))
        .flex()
        .flex_row()
        .items_center()
        .gap(px(7.))
        .child(div().text_size(px(11.)).line_height(px(15.)).font_weight(FontWeight::SEMIBOLD).text_color(tokens::ink_dim()).child(title.to_string()))
        .child(div().flex_1())
        .when(can_integrate, |d| d.child(glyph("merge", 11., tokens::ink_faint())))
        .child(glyph("plus", 11., tokens::ink_faint()))
        .child(glyph("x", 11., tokens::ink_faint()))
}

fn status_dot(dot: Dot, id: &str) -> gpui::AnyElement {
    let text = |g: &'static str, c: Rgba| div().text_size(px(8.)).line_height(px(11.)).text_color(c).child(g).into_any_element();
    match dot {
        // A 9pt arc, one turn a second; every spinner on one phase.
        Dot::Running => svg()
            .path(icon("spinner-arc"))
            .size(px(9.))
            .flex_none()
            .text_color(tokens::running())
            .with_animation(
                SharedString::from(format!("spin-{id}")),
                Animation::new(Duration::from_secs(1)).repeat(),
                |svg, delta| svg.with_transformation(Transformation::rotate(percentage(delta))),
            )
            .into_any_element(),
        Dot::Waiting => text("●", tokens::attention()),
        Dot::Idle => text("○", tokens::idle()),
        Dot::Error => text("✕", tokens::danger()),
        Dot::Exited => text("◌", tokens::idle()),
        Dot::Unknown => text("◌", tokens::ink_faint()),
        Dot::Unseen => text("●", tokens::waiting()),
    }
}

fn pr_badge(pr: &fleet::Pr) -> impl IntoElement {
    let mut d = div().flex().flex_row().text_size(px(10.)).line_height(px(13.)).child(div().text_color(tokens::ink_dim()).child(format!("#{}", pr.number)));
    match pr.state.to_ascii_uppercase().as_str() {
        "MERGED" => d = d.child(div().text_color(tokens::merged()).child(" merged")),
        "CLOSED" => d = d.child(div().text_color(tokens::ink_faint()).child(" closed")),
        _ => {
            match pr.checks.as_deref().map(str::to_ascii_uppercase).as_deref() {
                Some("SUCCESS") => d = d.child(div().text_color(tokens::diff_add()).child(" ✓")),
                Some("FAILURE") | Some("ERROR") => d = d.child(div().text_color(tokens::diff_del()).child(" ✕")),
                Some(_) => d = d.child(div().text_color(tokens::attention()).child(" ●")),
                None => {}
            }
            match pr.review.as_deref().map(str::to_ascii_uppercase).as_deref() {
                Some("APPROVED") => d = d.child(div().text_color(tokens::ink_dim()).child(" approved")),
                Some("CHANGES_REQUESTED") => d = d.child(div().text_color(tokens::ink_dim()).child(" changes")),
                _ => {}
            }
        }
    }
    d
}
