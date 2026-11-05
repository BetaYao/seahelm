//! The main window, laid out as the macOS app's dashboard: the fleet column
//! on the left as navigator, the selected worktree's terminal on the right.
//! Measurements and colours are the AppKit originals' (MACOS-SPEC.md).

use std::collections::HashMap;
use std::time::{Duration, Instant};

use gpui::{
    KeyDownEvent,
    actions, div, percentage, prelude::*, px, svg, App, ClickEvent, Context, Entity,
    FocusHandle, Focusable, FontWeight, MouseButton, MouseDownEvent, MouseMoveEvent, MouseUpEvent, PathPromptOptions,
    Rgba, SharedString, Subscription, Transformation, Window, WindowControlArea,
};

use crate::assets::icon;
use crate::core_client::{self, WorktreeState};
use crate::notify;
use crate::fleet::{self, Dot, GitStats, Group, Grouping, Item, Snapshot};
use crate::gateway_page::GatewayPage;
use crate::settings_page::SettingsPage;
use crate::platform;
use crate::session;
#[path = "worktree_menu.rs"]
mod worktree_menu;
#[path = "pane_extras.rs"]
mod pane_extras;
#[path = "preview_tabs.rs"]
mod preview_tabs;
use worktree_menu::{CancelSheet, NewWorktree, RowMenu};
use crate::side_panel::{self, SidePanel, Tab as SideTab};
use crate::split::{Axis, Direction, LeafId, Rect, SplitTree};
use crate::terminal_view::TerminalView;
use crate::theme;
use crate::tokens::{self, MONO, SYSTEM};

const SIDEBAR_DEFAULT: f32 = 300.0;
const SIDEBAR_MIN: f32 = 200.0;
const HEADER_H: f32 = 40.0;
/// A split divider's grab strip, centred on its 1pt line.
const DIVIDER_HIT: f32 = 16.0;

actions!(
    seahelm,
    [SplitRight, SplitDown, ClosePane, FocusPaneLeft, FocusPaneRight, FocusPaneUp, FocusPaneDown, ZoomPane]
);

/// The split shortcuts: the macOS app's on macOS; elsewhere ctrl+shift
/// (ctrl alone is the terminal's), Terminator's letters for the splits.
pub fn bind_keys(cx: &mut App) {
    use gpui::KeyBinding;
    if platform::MAC {
        cx.bind_keys([
            KeyBinding::new("cmd-d", SplitRight, None),
            KeyBinding::new("cmd-shift-d", SplitDown, None),
            KeyBinding::new("cmd-w", ClosePane, None),
            KeyBinding::new("cmd-alt-left", FocusPaneLeft, None),
            KeyBinding::new("cmd-alt-right", FocusPaneRight, None),
            KeyBinding::new("cmd-alt-up", FocusPaneUp, None),
            KeyBinding::new("cmd-alt-down", FocusPaneDown, None),
            KeyBinding::new("cmd-shift-enter", ZoomPane, None),
        ]);
    } else {
        cx.bind_keys([
            KeyBinding::new("ctrl-shift-e", SplitRight, None),
            KeyBinding::new("ctrl-shift-o", SplitDown, None),
            KeyBinding::new("ctrl-shift-w", ClosePane, None),
            KeyBinding::new("ctrl-alt-left", FocusPaneLeft, None),
            KeyBinding::new("ctrl-alt-right", FocusPaneRight, None),
            KeyBinding::new("ctrl-alt-up", FocusPaneUp, None),
            KeyBinding::new("ctrl-alt-down", FocusPaneDown, None),
            KeyBinding::new("ctrl-shift-enter", ZoomPane, None),
        ]);
    }
    cx.bind_keys([KeyBinding::new("escape", CancelSheet, Some("NewWorktreeSheet"))]);
}

/// A worktree's panes: the split tree, kept across launches, and a
/// terminal per leaf, each on a seahelmd session of its own.
#[derive(Default)]
struct Panes {
    tree: SplitTree,
    views: HashMap<LeafId, Entity<TerminalView>>,
    _subscriptions: Vec<Subscription>,
}

/// A divider being dragged.
struct SplitDrag {
    worktree: String,
    path: Vec<bool>,
    axis: Axis,
    area: Rect,
}

pub struct Workspace {
    fleet: Snapshot,
    git: HashMap<String, GitStats>,
    selected: Option<String>,
    panes: HashMap<String, Panes>,
    split_drag: Option<SplitDrag>,
    grouping: Grouping,
    /// Nothing has had the keyboard yet: the first frame with a terminal
    /// gives it the focused pane, so typing works without a click.
    needs_focus: bool,
    /// Whether the window's activation is being reported to the core yet.
    watching_activation: bool,
    /// When keys or the mouse in this window were last told to the core
    /// (`client.activity`, at most once a minute; only that, never what).
    activity_reported: Option<Instant>,
    sidebar_width: f32,
    sidebar_visible: bool,
    dragging_divider: bool,
    divider_hover: bool,
    focus: FocusHandle,
    memory: Option<u64>,
    /// seahelm-core's view of the worktrees it has panes in; where it has
    /// one, it decides the row's dot.
    core: HashMap<String, WorktreeState>,
    /// Each worktree's pull request, from the core (`pr.list`).
    prs: HashMap<String, core_client::Pr>,
    /// Claude's and Codex's rate limits (`usage.summary`), at the column's foot.
    usage: Vec<core_client::UsageReadout>,
    /// What waits on the user, from the core (`cards.changed`).
    cards: Vec<core_client::Card>,
    /// Per card, the `fresh_at` last announced, so a card pops once per ask.
    cards_announced: HashMap<String, f64>,
    cards_loaded: bool,
    window_active: bool,
    /// Cards being answered or dismissed, and the ones that failed (with
    /// why): a card is not done until the core takes it off the list.
    card_submits: HashMap<String, Submit>,
    /// The First Mate workbench is in the main area instead of a worktree.
    first_mate_open: bool,
    /// What the core says about First Mate; None while it does not answer.
    first_mate: Option<core_client::FirstMate>,
    first_mate_view: Option<Entity<TerminalView>>,
    /// The running spinner's step (see `SPIN_STEP`).
    spin_phase: u8,
    /// Remote access (seahelm-gateway's settings) is in the main area.
    gateway_open: bool,
    gateway_page: Entity<GatewayPage>,
    /// The left column shows Files or Changes in place of the fleet
    /// (None: the fleet), as the macOS app's column does.
    side_tab: Option<SideTab>,
    side_panel: Entity<SidePanel>,
    _side_closed: Subscription,
    /// The "New worktree" sheet, while open.
    new_worktree: Option<NewWorktree>,
    /// A row's right-click menu, while open.
    row_menu: Option<RowMenu>,
    /// Settings is in the main area.
    settings_open: bool,
    settings_page: Entity<SettingsPage>,
    /// What the core knows about each pane, by session (`pane_extras`).
    pane_facts: pane_extras::Facts,
    /// Who is at work on a pane through the core, by session.
    presence: HashMap<String, pane_extras::Presence>,
    /// Files and changes opened as tabs in the main area, by worktree.
    preview_tabs: HashMap<String, preview_tabs::PreviewTabs>,
    /// The worktree and leaf shown alone (zoomed), if any.
    zoomed: Option<(String, LeafId)>,
}


/// `client.activity` at most this often.
const ACTIVITY_EVERY: Duration = Duration::from_secs(60);
impl Workspace {
    pub fn new(cx: &mut Context<Self>) -> Self {
        let side_panel = cx.new(SidePanel::new);
        let side_closed = cx.subscribe(&side_panel, |w, _, _: &side_panel::CloseRequested, cx| w.set_side(None, cx));
        cx.subscribe(&side_panel, |w, _, e: &side_panel::OpenRequested, cx| w.open_preview(e.0.clone(), cx)).detach();
        let this = Self {
            fleet: Snapshot::default(),
            git: HashMap::new(),
            selected: None,
            panes: load_layouts()
                .into_iter()
                .map(|(id, tree)| (id, Panes { tree, ..Panes::default() }))
                .collect(),
            split_drag: None,
            grouping: Grouping::default(),
            needs_focus: true,
            watching_activation: false,
            activity_reported: None,
            sidebar_width: SIDEBAR_DEFAULT,
            sidebar_visible: true,
            dragging_divider: false,
            divider_hover: false,
            focus: cx.focus_handle(),
            memory: None,
            core: HashMap::new(),
            prs: HashMap::new(),
            usage: Vec::new(),
            cards: Vec::new(),
            cards_announced: HashMap::new(),
            cards_loaded: false,
            card_submits: HashMap::new(),
            first_mate_open: false,
            first_mate: None,
            first_mate_view: None,
            spin_phase: 0,
            window_active: true,
            gateway_open: false,
            gateway_page: cx.new(GatewayPage::new),
            side_tab: None,
            side_panel,
            _side_closed: side_closed,
            new_worktree: None,
            row_menu: None,
            settings_open: false,
            settings_page: cx.new(SettingsPage::new),
            pane_facts: HashMap::new(),
            presence: HashMap::new(),
            zoomed: None,
            preview_tabs: HashMap::new(),
        };
        Self::poll_pane_facts(cx);
        Self::poll_core(cx);
        Self::listen_core(cx);
        Self::poll_usage(cx);
        notify::log("launch", serde_json::json!({"version": env!("CARGO_PKG_VERSION")}));
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
        // The running spinner steps on this clock, and only while a row is
        // running. A GPUI animation instead asks for a frame every vsync and
        // repaints the whole window with it: ~20% CPU for one spinning dot.
        cx.spawn(async move |this, cx| loop {
            cx.background_executor().timer(SPIN_STEP).await;
            let alive = this.update(cx, |w, cx| {
                let running = w.display_groups(fleet::now()).iter().any(|g| g.items.iter().any(|i| i.dot() == Dot::Running));
                if running {
                    w.spin_phase = (w.spin_phase + 1) % SPIN_STEPS;
                    cx.notify();
                }
            });
            if alive.is_err() {
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
            // The core watches the PRs of every worktree listed, panes or not.
            let paths: Vec<String> =
                snap.groups.iter().flat_map(|g| g.items.iter().map(|i| i.worktree_path.clone())).collect();
            cx.background_executor().spawn(async move { core_client::set_worktrees(&paths) }).detach();
            let alive = this
                .update(cx, |w, cx| {
                    w.fleet = snap;
                    if w.selected.is_none() {
                        w.selected = w.fleet.groups.iter().flat_map(|g| g.items.first()).next().map(|i| i.id.clone());
                        w.side_follow(cx);
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
            let cards = cx.background_executor().spawn(async { core_client::cards() }).await;
            if this.update(cx, |w, cx| w.set_cards(cards, cx)).is_err() {
                return;
            }
            loop {
                let (states, prs, fm) = cx
                    .background_executor()
                    .spawn(async { (core_client::worktrees(), core_client::prs(), core_client::first_mate()) })
                    .await;
                let alive = this
                    .update(cx, |w, cx| {
                        if w.core != states || w.prs != prs || w.first_mate != fm {
                            w.core = states;
                            w.prs = prs;
                            // The session went away under an open view: let it go,
                            // so a new one is attached when it comes back.
                            if !fm.as_ref().is_some_and(|f| f.session_live) {
                                w.first_mate_view = None;
                            }
                            w.first_mate = fm;
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

    /// The core's events as they happen: a status change refreshes the rows
    /// at once rather than at the next poll, and a notice is shown as a
    /// banner. Both are logged for comparing with the macOS app.
    fn listen_core(cx: &mut Context<Self>) {
        let (tx, mut rx) = futures::channel::mpsc::unbounded();
        core_client::subscribe(&["pane.status_changed", "pane.notice", "cards.changed", "pane.presence"], tx);
        cx.spawn(async move |this, cx| {
            use futures::StreamExt;
            while let Some(ev) = rx.next().await {
                let kind = ev.get("type").and_then(serde_json::Value::as_str).unwrap_or_default().to_string();
                let get = |k: &str| ev.get(k).cloned().unwrap_or_default();
                match kind.as_str() {
                    // A core that restarted knows none of our panes and has
                    // its cards afresh: register them all again and reload.
                    core_client::CONNECTED => {
                        let Ok(regs) = this.update(cx, |w, _| w.registrations()) else { break };
                        let cards = cx
                            .background_executor()
                            .spawn(async move {
                                for reg in regs {
                                    if let Err(e) = core_client::call("pane.register", reg) {
                                        eprintln!("seahelm-gpui: core pane.register: {e}");
                                    }
                                }
                                core_client::cards()
                            })
                            .await;
                        if this.update(cx, |w, cx| w.set_cards(cards, cx)).is_err() {
                            break;
                        }
                    }
                    "pane.presence" => {
                        if this.update(cx, |w, cx| w.note_presence(&ev, cx)).is_err() {
                            break;
                        }
                    }
                    "cards.changed" => {
                        let cards = core_client::parse_cards(&ev);
                        if this.update(cx, |w, cx| w.set_cards(cards, cx)).is_err() {
                            break;
                        }
                    }
                    "pane.notice" => {
                        let shown = notify::text(&ev);
                        notify::log(
                            "notice",
                            serde_json::json!({"pane": get("pane_session_key"), "worktree": get("worktree_path"),
                                "status": get("new_status"), "shown": shown.is_some()}),
                        );
                        if let Some((title, body)) = shown {
                            cx.background_executor().spawn(async move { notify::deliver(&title, &body) }).detach();
                        }
                    }
                    _ => {
                        notify::log(
                            "status",
                            serde_json::json!({"pane": get("pane_session_key"), "worktree": get("worktree_path"),
                                "from": get("old_status"), "to": get("status")}),
                        );
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
                    }
                }
            }
        })
        .detach();
    }

    /// Usage, off the main thread: every 45 s, sooner while the core has
    /// nothing yet (it reads both providers just after it starts).
    fn poll_usage(cx: &mut Context<Self>) {
        cx.spawn(async move |this, cx| loop {
            cx.background_executor().timer(Duration::from_secs(5)).await;
            let usage = cx.background_executor().spawn(async { core_client::usage() }).await;
            let empty = usage.is_empty();
            let alive = this
                .update(cx, |w, cx| {
                    if w.usage != usage {
                        w.usage = usage;
                        cx.notify();
                    }
                })
                .is_ok();
            if !alive {
                break;
            }
            if !empty {
                cx.background_executor().timer(Duration::from_secs(40)).await;
            }
        })
        .detach();
    }

    /// What is on screen, for the core's unseen-completion and banner
    /// decisions: the selected worktree, and whether the window is the
    /// active one.
    /// A new card list. A card that is fresh (new, or asking something new)
    /// and not on screen gets a banner pointing at it; the core holds back
    /// its "needs you" notice while a card shows the question. Answering
    /// happens in the window, never in the banner.
    fn set_cards(&mut self, cards: Vec<core_client::Card>, cx: &mut Context<Self>) {
        let shown = self.selected_worktree();
        let mut announced = HashMap::new();
        for c in &cards {
            let last = self.cards_announced.get(&c.id).copied();
            let on_screen = self.window_active && shown.as_deref() == Some(c.worktree_path.as_str());
            if last.is_none_or(|t| c.fresh_at > t) {
                notify::log("card", serde_json::json!({"id": c.id, "kind": c.kind, "worktree": c.worktree_path, "on_screen": on_screen}));
                // The first list is what was already waiting at launch: shown,
                // not announced.
                if !on_screen && self.cards_loaded {
                    let title = format!("{} asks", short_name(&c.worktree_path));
                    let body = c.message.split_whitespace().collect::<Vec<_>>().join(" ");
                    cx.background_executor().spawn(async move { notify::deliver(&title, &body) }).detach();
                }
            }
            announced.insert(c.id.clone(), c.fresh_at);
        }
        self.cards_announced = announced;
        self.cards_loaded = true;
        self.card_submits.retain(|id, _| cards.iter().any(|c| &c.id == id));
        if self.cards != cards {
            self.cards = cards;
            cx.notify();
        }
    }

    fn selected_worktree(&self) -> Option<String> {
        self.selected.as_deref().and_then(|id| self.fleet.find(id)).map(|i| i.worktree_path.clone())
    }

    fn answer_card(&mut self, id: String, index: usize, cx: &mut Context<Self>) {
        notify::log("card.answer", serde_json::json!({"id": id, "index": index}));
        self.submit_card(id.clone(), cx, move || core_client::answer_card(&id, index));
    }

    /// Hand a card's answer to the core and show it as in flight until the
    /// core says how it went: done, it leaves the list (`cards.changed`);
    /// failed, it stays with the reason and can be tried again.
    fn submit_card(&mut self, id: String, cx: &mut Context<Self>, run: impl FnOnce() -> Result<(), String> + Send + 'static) {
        if matches!(self.card_submits.get(&id), Some(Submit::Sending)) {
            return;
        }
        self.card_submits.insert(id.clone(), Submit::Sending);
        cx.notify();
        cx.spawn(async move |this, cx| {
            let result = cx.background_executor().spawn(async move { run() }).await;
            let _ = this.update(cx, |w, cx| {
                match result {
                    // A card that stays (a multi-select tick) is ready again.
                    Ok(()) => {
                        w.card_submits.remove(&id);
                    }
                    Err(e) => {
                        eprintln!("seahelm-gpui: card {id}: {e}");
                        w.card_submits.insert(id, Submit::Failed(failure_text(&e)));
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// A card's button took the click; typing goes back to the terminal.
    fn refocus_terminal(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(view) = self.selected.clone().and_then(|id| self.terminal_for(&id, window, cx)) {
            window.focus(&view.focus_handle(cx));
        }
    }

    fn dismiss_card(&mut self, id: String, cx: &mut Context<Self>) {
        notify::log("card.dismiss", serde_json::json!({"id": id}));
        self.submit_card(id.clone(), cx, move || core_client::dismiss_card(&id));
    }

    /// The selected worktree's cards, above its terminals: what is asked,
    /// and a button per answer.
    fn card_strip(&self, worktree: &str, cx: &mut Context<Self>) -> Option<gpui::AnyElement> {
        let cards: Vec<&core_client::Card> = self.cards.iter().filter(|c| c.worktree_path == worktree).collect();
        if cards.is_empty() {
            return None;
        }
        let mut strip = div().flex_none().flex().flex_col().gap(px(6.)).px(px(12.)).py(px(8.)).bg(tokens::sidebar_tint());
        for card in cards {
            strip = strip.child(self.card_view(card, false, cx));
        }
        Some(strip.child(div().h(px(1.)).w_full().bg(tokens::hairline())).into_any_element())
    }

    /// One card: what kind, where (when `place`), what is asked, a button
    /// per answer from the card's own labels, and how its answer is going.
    /// Without a core, nothing can be answered.
    fn card_view(&self, card: &core_client::Card, place: bool, cx: &mut Context<Self>) -> gpui::AnyElement {
        let fg = theme::rgb(theme::fg());
        let tint = match card.kind.as_str() {
            "suggestion" => tokens::accent(),
            "approval" | "proposal" => tokens::attention(),
            _ => tokens::waiting(),
        };
        let what = match card.kind.as_str() {
            "question" | "choice" => "Needs an answer",
            "suggestion" => "Next",
            "approval" => "First Mate asks",
            "proposal" => "First Mate suggests",
            _ => "Report",
        };
        let submit = self.card_submits.get(&card.id);
        let live = self.first_mate.is_some() && !matches!(submit, Some(Submit::Sending));
        let mut options = div().flex().flex_row().flex_wrap().gap(px(6.));
        for (i, label) in card.labels.iter().enumerate() {
            let id = card.id.clone();
            let mut button = div()
                .id(SharedString::from(format!("card-{}-{i}{}", card.id, if place { "-wb" } else { "" })))
                .px(px(9.))
                .py(px(3.))
                .rounded(px(5.))
                .border_1()
                .border_color(tokens::alpha(tint, 0.45))
                .text_size(px(11.5))
                .line_height(px(16.))
                .text_color(fg)
                .child(label.clone());
            if live {
                button = button
                    .cursor_pointer()
                    .hover(|s| s.bg(tokens::alpha(tint, 0.14)))
                    .on_click(cx.listener(move |w, _: &ClickEvent, window, cx| {
                        w.answer_card(id.clone(), i, cx);
                        w.refocus_after_card(window, cx);
                    }));
            } else {
                button = button.opacity(0.45);
            }
            options = options.child(button);
        }
        let dismiss = card.id.clone();
        let mut head = div()
            .flex()
            .flex_row()
            .items_center()
            .gap(px(8.))
            .child(div().flex_none().text_size(px(10.5)).line_height(px(14.)).font_weight(FontWeight::SEMIBOLD).text_color(tint).child(what));
        // First Mate's own asks name no worktree: their kind says whose they are.
        let own = card.project == "First Mate";
        if place && !own {
            let wt = if card.branch.is_empty() { short_name(&card.worktree_path) } else { card.branch.clone() };
            let where_ = if card.project.is_empty() { wt } else { format!("{} · {wt}", card.project) };
            head = head.child(div().min_w_0().one_line().text_size(px(10.5)).line_height(px(14.)).text_color(tokens::ink_faint()).child(where_));
        }
        head = head.child(div().flex_1()).child(
            div()
                .id(SharedString::from(format!("card-x-{}{}", card.id, if place { "-wb" } else { "" })))
                .when(live, |d| {
                    d.cursor_pointer().hover(|s| s.text_color(tokens::ink())).on_click(cx.listener(move |w, _: &ClickEvent, window, cx| {
                        w.dismiss_card(dismiss.clone(), cx);
                        w.refocus_after_card(window, cx);
                    }))
                })
                .text_size(px(11.))
                .text_color(tokens::ink_faint())
                .child("×"),
        );
        let status = match submit {
            Some(Submit::Sending) => Some(("Sending…".to_string(), tokens::ink_faint())),
            Some(Submit::Failed(why)) => Some((format!("{why} — try again"), tokens::danger())),
            None => None,
        };
        div()
            .flex()
            .flex_col()
            .gap(px(5.))
            .pl(px(9.))
            .border_l_2()
            .border_color(tint)
            .child(head)
            .when(!card.message.trim().is_empty(), |d| {
                d.child(
                    div()
                        .max_h(px(if place { 120. } else { 64. }))
                        .overflow_hidden()
                        .font_family(SYSTEM)
                        .text_size(px(12.))
                        .line_height(px(16.))
                        .text_color(fg)
                        .child(card_body(card)),
                )
            })
            .child(options)
            .when_some(status, |d, (text, colour)| d.child(div().text_size(px(10.5)).line_height(px(14.)).text_color(colour).child(text)))
            .into_any_element()
    }

    /// After a card's click, typing goes back to the terminal that was in use.
    fn refocus_after_card(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.first_mate_open {
            if let Some(view) = self.first_mate_view.clone() {
                window.focus(&view.focus_handle(cx));
            }
        } else {
            self.refocus_terminal(window, cx);
        }
    }

    // MARK: First Mate

    /// The dock opens the workbench over the main area, or closes it.
    fn toggle_first_mate(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.first_mate_open = !self.first_mate_open;
        self.set_gateway_open(false, cx);
        self.settings_open = false;
        notify::log(if self.first_mate_open { "first_mate.open" } else { "first_mate.close" }, serde_json::json!({}));
        if self.first_mate_open {
            if let Some(view) = self.first_mate_terminal(cx) {
                window.focus(&view.focus_handle(cx));
            }
        } else {
            self.refocus_terminal(window, cx);
        }
        cx.notify();
    }

    /// The share button opens Remote access over the main area, or closes it.
    fn toggle_settings(&mut self, _: &ClickEvent, window: &mut Window, cx: &mut Context<Self>) {
        self.settings_open = !self.settings_open;
        if self.settings_open {
            self.first_mate_open = false;
            self.set_gateway_open(false, cx);
            self.settings_page.update(cx, |p, cx| {
                p.reload();
                cx.notify();
            });
        } else {
            self.refocus_terminal(window, cx);
        }
        cx.notify();
    }

    fn toggle_gateway(&mut self, _: &ClickEvent, window: &mut Window, cx: &mut Context<Self>) {
        let open = !self.gateway_open;
        if open {
            self.first_mate_open = false;
            self.settings_open = false;
        }
        self.set_gateway_open(open, cx);
        notify::log(if open { "gateway.open" } else { "gateway.close" }, serde_json::json!({}));
        if !open {
            self.refocus_terminal(window, cx);
        }
        cx.notify();
    }

    /// The header's folder (Files) and diff (Changes) buttons: open the side
    /// panel on that tab, or close it if it is already showing it.
    fn toggle_side(&mut self, tab: SideTab, cx: &mut Context<Self>) {
        let next = if self.side_tab == Some(tab) { None } else { Some(tab) };
        notify::log("side_panel", serde_json::json!({"tab": format!("{next:?}")}));
        self.set_side(next, cx);
    }

    fn set_side(&mut self, tab: Option<SideTab>, cx: &mut Context<Self>) {
        self.side_tab = tab;
        let wt = self.selected_worktree();
        self.side_panel.update(cx, |p, cx| match tab {
            Some(t) => p.show(wt, t, cx),
            None => p.hide(cx),
        });
        cx.notify();
    }

    /// The panel follows the selected worktree.
    fn side_follow(&mut self, cx: &mut Context<Self>) {
        let wt = self.selected_worktree();
        self.side_panel.update(cx, |p, cx| p.set_worktree(wt, cx));
    }

    fn set_gateway_open(&mut self, open: bool, cx: &mut Context<Self>) {
        if self.gateway_open != open {
            self.gateway_open = open;
            self.gateway_page.update(cx, |p, cx| p.set_visible(open, cx));
        }
    }

    /// First Mate's terminal, attached only once its session is up:
    /// attaching never creates it (a session under that name without the
    /// agent would be a bare shell posing as First Mate).
    fn first_mate_terminal(&mut self, cx: &mut Context<Self>) -> Option<Entity<TerminalView>> {
        if !self.first_mate.as_ref().is_some_and(|f| f.session_live) {
            return None;
        }
        if self.first_mate_view.is_none() {
            self.first_mate_view = Some(cx.new(|cx| {
                let mut v = TerminalView::new(core_client::FIRST_MATE_SESSION.into(), cx);
                v.font_size = px(crate::fonts::terminal_size());
                v
            }));
        }
        self.first_mate_view.clone()
    }

    /// The dock's two words about First Mate, and their colour.
    fn first_mate_status(&self) -> (String, Rgba) {
        match &self.first_mate {
            None => ("Core offline".into(), tokens::ink_faint()),
            Some(f) if !f.enabled && f.session_live => ("In the macOS app".into(), tokens::ink_dim()),
            Some(f) if !f.enabled => ("Off".into(), tokens::ink_faint()),
            Some(f) => match f.activity.as_str() {
                "thinking" => ("Working".into(), tokens::running()),
                "needs you" => ("Needs you".into(), tokens::attention()),
                "paused" => ("Paused".into(), tokens::ink_faint()),
                "starting" => ("Starting".into(), tokens::ink_dim()),
                _ => ("Watching".into(), tokens::waiting()),
            },
        }
    }

    /// The workbench: First Mate's real terminal on the left, every card
    /// waiting on the user on the right, each scrolling on its own.
    fn workbench(&mut self, cx: &mut Context<Self>) -> gpui::AnyElement {
        let bg = theme::rgb(theme::bg());
        let left = match self.first_mate_terminal(cx) {
            Some(view) => div().relative().flex_1().min_w_0().h_full().child(div().absolute().inset_0().child(view)),
            None => {
                let (title, body) = match &self.first_mate {
                    None => ("seahelm-core is not answering", "Cards and First Mate come back when it does."),
                    Some(f) if f.enabled => ("First Mate is starting", "Its session is being launched; the terminal appears here when it is up."),
                    Some(_) => ("First Mate is off", "Turn it on in the macOS app (Settings ▸ First Mate), or set autopilot_enabled in config.json."),
                };
                div()
                    .flex_1()
                    .min_w_0()
                    .h_full()
                    .flex()
                    .flex_col()
                    .items_center()
                    .justify_center()
                    .gap(px(6.))
                    .px(px(40.))
                    .font_family(SYSTEM)
                    .child(div().text_size(px(22.)).text_color(tokens::accent()).child("⎈"))
                    .child(div().text_size(px(13.)).font_weight(FontWeight::SEMIBOLD).text_color(tokens::ink()).child(title))
                    .child(div().max_w(px(420.)).text_size(px(12.)).line_height(px(17.)).text_color(tokens::ink_dim()).child(body))
            }
        };
        let n = self.cards.len();
        let mut list = div().id("workbench-cards").flex_1().min_h_0().overflow_y_scroll().px(px(12.)).py(px(12.)).flex().flex_col().gap(px(14.));
        if n == 0 {
            list = list.child(
                div()
                    .pt(px(36.))
                    .flex()
                    .flex_col()
                    .items_center()
                    .gap(px(6.))
                    .font_family(SYSTEM)
                    .child(div().text_size(px(20.)).text_color(tokens::running()).child("✓"))
                    .child(div().text_size(px(12.)).text_color(tokens::ink_dim()).child("Nothing waiting on you")),
            );
        } else {
            let cards = self.cards.clone();
            for card in cards.iter().rev() {
                list = list.child(self.card_view(card, true, cx));
            }
        }
        let header = div()
            .h(px(36.))
            .flex_none()
            .px(px(14.))
            .flex()
            .flex_row()
            .items_center()
            .gap(px(8.))
            .border_b_1()
            .border_color(tokens::hairline())
            .child(div().text_size(px(11.5)).font_weight(FontWeight::SEMIBOLD).text_color(tokens::ink()).child("Cards"))
            .child(div().text_size(px(11.)).text_color(tokens::ink_faint()).child(if n == 0 { String::new() } else { n.to_string() }))
            .child(div().flex_1())
            .when(self.first_mate.is_none(), |d| d.child(div().text_size(px(10.5)).text_color(tokens::danger()).child("not connected")));
        let right = div()
            .w(px(WORKBENCH_CARDS_W))
            .flex_none()
            .h_full()
            .flex()
            .flex_col()
            .bg(tokens::sidebar_tint())
            .border_l_1()
            .border_color(tokens::hairline())
            .child(header)
            .child(list);
        div().flex_1().min_h_0().flex().flex_row().bg(bg).child(left).child(right).into_any_element()
    }

    /// At the foot of the fleet: First Mate, its state, the usage it was
    /// given, and how many cards wait. Opens the workbench.
    fn first_mate_dock(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let (status, colour) = self.first_mate_status();
        let n = self.cards.len();
        let mut usage = div().flex().flex_row().items_center().gap(px(4.)).text_size(px(10.5)).line_height(px(14.));
        for (i, r) in self.usage.iter().enumerate() {
            if let Some(seg) = r.segments.first() {
                let tint = match seg.severity.as_str() {
                    "warn" => tokens::attention(),
                    "critical" => tokens::danger(),
                    _ => tokens::ink_dim(),
                };
                usage = usage
                    .when(i > 0, |d| d.child(div().ml(px(4.)).text_color(tokens::ink_faint()).child("·")))
                    .child(div().text_color(tokens::ink_faint()).child(format!("{} {}", r.name, seg.label)))
                    .child(div().font_weight(FontWeight::MEDIUM).text_color(tint).child(seg.percent.clone()));
            }
        }
        let open = self.first_mate_open;
        div()
            .id("first-mate-dock")
            .flex_none()
            .mt(px(10.))
            .mb(px(12.))
            .mx(px(12.))
            .px(px(11.))
            .py(px(10.))
            .rounded(px(10.))
            .border_1()
            .border_color(tokens::alpha(tokens::accent(), if open { 0.55 } else { 0.22 }))
            .bg(tokens::alpha(tokens::accent(), if open { 0.12 } else { 0.04 }))
            .hover(|s| s.bg(tokens::alpha(tokens::accent(), 0.09)))
            .cursor_pointer()
            .on_click(cx.listener(|w, _: &ClickEvent, window, cx| w.toggle_first_mate(window, cx)))
            .flex()
            .flex_col()
            .gap(px(7.))
            .child(
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap(px(8.))
                    .child(div().text_size(px(14.)).text_color(tokens::accent()).child("⎈"))
                    .child(div().text_size(px(12.)).font_weight(FontWeight::SEMIBOLD).text_color(tokens::ink()).child("First Mate"))
                    .child(div().flex_1())
                    .child(div().size(px(6.)).rounded_full().bg(colour))
                    .child(div().text_size(px(10.5)).text_color(colour).child(status)),
            )
            .when(!self.usage.is_empty(), |d| d.child(usage))
            .child(
                div()
                    .text_size(px(10.5))
                    .line_height(px(14.))
                    .text_color(if n > 0 { tokens::attention() } else { tokens::ink_faint() })
                    .child(match n {
                        0 => "Nothing waiting · standing by".to_string(),
                        1 => "1 card waiting for you".to_string(),
                        n => format!("{n} cards waiting for you"),
                    }),
            )
    }

    /// Keys or the mouse in this window: the user is here. Times First
    /// Mate's daily brief in the core.
    fn note_activity(&mut self) {
        if self.activity_reported.is_some_and(|t| t.elapsed() < ACTIVITY_EVERY) {
            return;
        }
        self.activity_reported = Some(Instant::now());
        std::thread::spawn(|| {
            let _ = core_client::call("client.activity", serde_json::json!({"client": "gpui"}));
        });
    }

    fn report_visible(&self, active: bool, cx: &mut Context<Self>) {
        let path = self.selected.as_deref().and_then(|id| self.fleet.find(id)).map(|i| i.worktree_path.clone());
        cx.background_executor()
            .spawn(async move {
                let worktrees: Vec<String> = path.into_iter().collect();
                let _ = core_client::call("client.visible", serde_json::json!({"client": "gpui", "worktrees": worktrees, "app_active": active}));
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
            let name = this.read_with(cx, |w, _| w.focused_session()).ok().flatten();
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
        // Picking a worktree is leaving First Mate (its session lives on)
        // and Remote access.
        self.first_mate_open = false;
        self.set_gateway_open(false, cx);
        self.settings_open = false;
        self.selected = Some(id.clone());
        self.side_follow(cx);
        // On screen in a frontmost window: a turn that ends here is seen.
        self.report_visible(window.is_window_active(), cx);
        notify::log("select", serde_json::json!({"worktree": id}));
        if let Some(term) = self.terminal_for(&id, window, cx) {
            window.focus(&term.focus_handle(cx));
        }
        cx.notify();
    }

    /// The session the focused pane of the selected worktree is on.
    fn focused_session(&self) -> Option<String> {
        let id = self.selected.as_deref()?;
        let leaf = self.panes.get(id).map_or(0, |p| p.tree.focused);
        Some(pane_session(id, leaf))
    }

    /// The worktree's focused terminal, its panes made on first use.
    fn terminal_for(&mut self, id: &str, window: &mut Window, cx: &mut Context<Self>) -> Option<Entity<TerminalView>> {
        let leaf = self.panes.entry(id.to_string()).or_default().tree.focused;
        self.view_for(id, leaf, window, cx)
    }

    /// Every pane with a terminal, as `pane.register` takes it.
    fn registrations(&self) -> Vec<serde_json::Value> {
        let mut out = Vec::new();
        for (id, pane) in &self.panes {
            let Some(item) = self.fleet.find(id) else { continue };
            for leaf in pane.views.keys() {
                out.push(registration(&pane_session(id, *leaf), item));
            }
        }
        out
    }

    /// One pane's terminal: its session started in the worktree on first
    /// use and registered with seahelm-core; focusing it (a click) makes it
    /// the tree's focused pane.
    fn view_for(&mut self, id: &str, leaf: LeafId, window: &mut Window, cx: &mut Context<Self>) -> Option<Entity<TerminalView>> {
        if let Some(t) = self.panes.get(id).and_then(|p| p.views.get(&leaf)) {
            return Some(t.clone());
        }
        let item = self.fleet.find(id)?.clone();
        let name = pane_session(id, leaf);
        if let Err(e) = session::ensure_in(&name, &[], Some(&item.worktree_path)) {
            eprintln!("seahelm-gpui: {e:#}");
        }
        let reg = registration(&name, &item);
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
        let handle = view.focus_handle(cx);
        let worktree = id.to_string();
        let sub = cx.on_focus(&handle, window, move |w, _, cx| {
            if let Some(p) = w.panes.get_mut(&worktree) {
                if p.tree.focused != leaf && p.tree.leaves().contains(&leaf) {
                    p.tree.focused = leaf;
                    w.save_layouts();
                    cx.notify();
                }
            }
        });
        let panes = self.panes.entry(id.to_string()).or_default();
        panes.views.insert(leaf, view.clone());
        panes._subscriptions.push(sub);
        Some(view)
    }

    fn save_layouts(&self) {
        let layouts: HashMap<&String, &SplitTree> =
            self.panes.iter().filter(|(_, p)| p.tree.len() > 1).map(|(id, p)| (id, &p.tree)).collect();
        if let Ok(text) = serde_json::to_string(&layouts) {
            let _ = std::fs::create_dir_all(platform::config_dir());
            let _ = std::fs::write(layout_file(), text);
        }
    }

    fn split(&mut self, axis: Axis, window: &mut Window, cx: &mut Context<Self>) {
        let Some(id) = self.selected.clone() else { return };
        let leaf = self.panes.entry(id.clone()).or_default().tree.split(axis);
        notify::log("split", serde_json::json!({"worktree": id, "axis": format!("{axis:?}")}));
        self.save_layouts();
        if let Some(v) = self.view_for(&id, leaf, window, cx) {
            window.focus(&v.focus_handle(cx));
        }
        cx.notify();
    }

    /// Close the focused pane: its session ends with it (the app's cmd+w on
    /// a split). The last pane of a worktree stays.
    fn close_pane(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(id) = self.selected.clone() else { return };
        let Some(panes) = self.panes.get_mut(&id) else { return };
        let leaf = panes.tree.focused;
        if !panes.tree.remove(leaf) {
            return;
        }
        panes.views.remove(&leaf);
        notify::log("close_pane", serde_json::json!({"worktree": id, "leaf": leaf}));
        let name = pane_session(&id, leaf);
        cx.background_executor()
            .spawn(async move {
                let _ = core_client::call("pane.unregister", serde_json::json!({"pane": name}));
                let _ = std::process::Command::new(session::daemon_binary()).args(["kill", &name]).output();
            })
            .detach();
        self.save_layouts();
        if let Some(v) = self.terminal_for(&id, window, cx) {
            window.focus(&v.focus_handle(cx));
        }
        cx.notify();
    }

    fn focus_pane(&mut self, dir: Direction, window: &mut Window, cx: &mut Context<Self>) {
        let Some(id) = self.selected.clone() else { return };
        let Some(next) = self.panes.get(&id).and_then(|p| p.tree.neighbour(dir)) else { return };
        if let Some(p) = self.panes.get_mut(&id) {
            p.tree.focused = next;
        }
        self.save_layouts();
        if let Some(v) = self.view_for(&id, next, window, cx) {
            window.focus(&v.focus_handle(cx));
        }
        cx.notify();
    }

    /// The terminal body's place in the window: right of the fleet column,
    /// under the header.
    fn body_bounds(&self, window: &Window) -> (f32, f32, f32, f32) {
        let size = window.viewport_size();
        let x = if self.sidebar_visible { self.sidebar_width } else { 0.0 };
        (x, HEADER_H, (f32::from(size.width) - x).max(1.0), (f32::from(size.height) - HEADER_H).max(1.0))
    }

    /// The selected worktree's panes, laid out from the tree's frames, with
    /// their dividers and, when there are several, a wash over all but the
    /// focused one.
    fn panes_body(&mut self, id: &str, window: &mut Window, cx: &mut Context<Self>) -> gpui::AnyElement {
        let (_, _, w, h) = self.body_bounds(window);
        let tree = self.panes.entry(id.to_string()).or_default().tree.clone();
        let zoomed = self.zoomed_leaf(id);
        let several = tree.len() > 1 && zoomed.is_none();
        let mut body = div().relative().flex_1().min_h_0().bg(theme::rgb(theme::bg()));
        let frames: Vec<(LeafId, Rect)> = match zoomed {
            Some(leaf) => vec![(leaf, Rect { x: 0.0, y: 0.0, w: 1.0, h: 1.0 })],
            None => tree.frames(),
        };
        for (leaf, r) in frames {
            let Some(view) = self.view_for(id, leaf, window, cx) else { continue };
            let mut pane = div()
                .absolute()
                .left(px(r.x * w))
                .top(px(r.y * h))
                .w(px(r.w * w))
                .h(px(r.h * h))
                .child(view);
            if several && leaf != tree.focused {
                pane = pane.child(div().absolute().inset_0().bg(tokens::inactive_wash()));
            }
            if let Some(corner) = self.pane_corner(id, leaf, cx) {
                pane = pane.child(corner);
            }
            body = body.child(pane);
        }
        for d in tree.dividers().into_iter().filter(|_| zoomed.is_none()) {
            let worktree = id.to_string();
            let path = d.path.clone();
            let path2 = d.path.clone();
            let (axis, area) = (d.axis, d.area);
            let line = div().bg(tokens::hairline());
            let strip = match d.axis {
                Axis::Horizontal => div()
                    .absolute()
                    .left(px(d.at * w - DIVIDER_HIT / 2.))
                    .top(px(d.area.y * h))
                    .w(px(DIVIDER_HIT))
                    .h(px(d.area.h * h))
                    .flex()
                    .justify_center()
                    .cursor_col_resize()
                    .child(line.w(px(1.)).h_full()),
                Axis::Vertical => div()
                    .absolute()
                    .top(px(d.at * h - DIVIDER_HIT / 2.))
                    .left(px(d.area.x * w))
                    .h(px(DIVIDER_HIT))
                    .w(px(d.area.w * w))
                    .flex()
                    .flex_col()
                    .justify_center()
                    .cursor_row_resize()
                    .child(line.h(px(1.)).w_full()),
            };
            let dragging = self.split_drag.as_ref().is_some_and(|s| s.worktree == id && s.path == d.path);
            body = body.child(
                strip
                    .id(SharedString::from(format!("split-{id}-{:?}", d.path)))
                    .occlude()
                    .when(dragging, |s| s.bg(tokens::alpha(tokens::accent(), 0.10)))
                    .hover(|s| s.bg(tokens::alpha(tokens::accent(), 0.10)))
                    .on_mouse_down(
                        MouseButton::Left,
                        cx.listener(move |w, _: &MouseDownEvent, _, cx| {
                            w.split_drag = Some(SplitDrag { worktree: worktree.clone(), path: path.clone(), axis, area });
                            cx.notify();
                        }),
                    )
                    .on_click(cx.listener(move |w, e: &ClickEvent, _, cx| {
                        if e.click_count() == 2 {
                            if let Some(id) = w.selected.clone() {
                                if let Some(p) = w.panes.get_mut(&id) {
                                    p.tree.equalize(&path2);
                                }
                                w.save_layouts();
                                cx.notify();
                            }
                        }
                    })),
            );
        }
        body.into_any_element()
    }

    /// The contrast button: dark ↔ light, the chrome and every pane.
    fn toggle_theme(&mut self, _: &ClickEvent, window: &mut Window, cx: &mut Context<Self>) {
        theme::set_dark(!theme::is_dark());
        notify::log("theme", serde_json::json!({"dark": theme::is_dark()}));
        for panes in self.panes.values() {
            for view in panes.views.values() {
                view.update(cx, |v, cx| v.refresh_theme(cx));
            }
        }
        window.refresh();
        cx.notify();
    }

    /// The group button: repository → status → activity.
    fn cycle_grouping(&mut self, _: &ClickEvent, _: &mut Window, cx: &mut Context<Self>) {
        self.grouping = self.grouping.next();
        cx.notify();
    }

    /// The fleet as the column shows it: seahelm-core's verdict laid over
    /// every worktree it watches, then grouped.
    fn display_groups(&self, now: f64) -> Vec<Group> {
        let mut groups = self.fleet.groups.clone();
        for item in groups.iter_mut().flat_map(|g| g.items.iter_mut()) {
            if let Some(c) = self.core.get(&item.worktree_path) {
                if let Some(title) = &c.title {
                    item.title = title.clone();
                }
                item.status = c.status.clone();
                item.unseen = c.unseen;
                item.running_since = c.running_since;
                item.last_activity_at = c.last_activity_at;
            }
        }
        fleet::regroup(&groups, self.grouping, now)
    }

    /// The folder button: pick a directory and add it as a project.
    fn add_project(&mut self, _: &ClickEvent, _: &mut Window, cx: &mut Context<Self>) {
        let picked = cx.prompt_for_paths(PathPromptOptions {
            files: false,
            directories: true,
            multiple: false,
            prompt: Some("Add Project".into()),
        });
        cx.spawn(async move |this, cx| {
            let Ok(Ok(Some(paths))) = picked.await else { return };
            let Some(path) = paths.first().map(|p| p.to_string_lossy().into_owned()) else { return };
            if let Err(e) = fleet::add_project(&path) {
                eprintln!("seahelm-gpui: add project: {e}");
                return;
            }
            let snap = cx.background_executor().spawn(async { fleet::read() }).await;
            let _ = this.update(cx, |w, cx| {
                w.fleet = snap;
                cx.notify();
            });
        })
        .detach();
    }

    fn on_divider_down(&mut self, _: &MouseDownEvent, _: &mut Window, cx: &mut Context<Self>) {
        self.dragging_divider = true;
        cx.notify();
    }

    fn on_mouse_move(&mut self, e: &MouseMoveEvent, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(drag) = &self.split_drag {
            let (x0, y0, w, h) = self.body_bounds(window);
            let ratio = match drag.axis {
                Axis::Horizontal => (f32::from(e.position.x) - x0 - drag.area.x * w) / (drag.area.w * w).max(1.0),
                Axis::Vertical => (f32::from(e.position.y) - y0 - drag.area.y * h) / (drag.area.h * h).max(1.0),
            };
            let (id, path) = (drag.worktree.clone(), drag.path.clone());
            if let Some(p) = self.panes.get_mut(&id) {
                p.tree.set_ratio(&path, ratio);
            }
            cx.notify();
            return;
        }
        if self.dragging_divider {
            let max = (f32::from(window.viewport_size().width) * 0.5).max(SIDEBAR_MIN);
            self.sidebar_width = f32::from(e.position.x).clamp(SIDEBAR_MIN, max);
            cx.notify();
        }
    }

    fn on_mouse_up(&mut self, _: &MouseUpEvent, _: &mut Window, cx: &mut Context<Self>) {
        if self.split_drag.take().is_some() {
            self.save_layouts();
            cx.notify();
        }
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

/// A pane's session: the worktree's own for its first pane, numbered after
/// it for the panes split from it.
pub fn pane_session(worktree_id: &str, leaf: LeafId) -> String {
    match leaf {
        0 => session_name(worktree_id),
        n => format!("{}-{n}", session_name(worktree_id)),
    }
}

fn layout_file() -> std::path::PathBuf {
    platform::config_dir().join("gpui-layout.json")
}

fn load_layouts() -> HashMap<String, SplitTree> {
    std::fs::read_to_string(layout_file()).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_default()
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
        let selected = self.selected.clone().filter(|id| self.fleet.find(id).is_some());
        let body = if self.settings_open {
            Some(div().flex_1().min_h_0().flex().child(self.settings_page.clone()).into_any_element())
        } else if self.gateway_open {
            Some(div().flex_1().min_h_0().flex().child(self.gateway_page.clone()).into_any_element())
        } else if self.first_mate_open {
            Some(self.workbench(cx))
        } else {
            selected.as_deref().map(|id| {
                let content = match self.preview_active(id).then(|| self.preview_body(id)).flatten() {
                    Some(p) => p,
                    None => self.panes_body(id, window, cx),
                };
                match self.preview_strip(id, cx) {
                    Some(strip) => div().flex_1().min_h_0().flex().flex_col().child(strip).child(content).into_any_element(),
                    None => content,
                }
            })
        };
        if !self.watching_activation {
            self.watching_activation = true;
            cx.observe_window_activation(window, |w, window, cx| {
                let active = window.is_window_active();
                notify::log(if active { "activate" } else { "deactivate" }, serde_json::json!({}));
                w.window_active = active;
                w.report_visible(active, cx);
            })
            .detach();
        }
        if self.needs_focus && !self.gateway_open && !self.settings_open && !selected.as_deref().is_some_and(|id| self.preview_active(id)) {
            if let Some(view) = selected.as_deref().and_then(|id| self.terminal_for(id, window, cx)) {
                window.focus(&view.focus_handle(cx));
                self.needs_focus = false;
            }
        }
        let title: SharedString = match selected.as_deref().and_then(|id| self.fleet.find(id)) {
            _ if self.settings_open => "Settings".into(),
            _ if self.gateway_open => "Remote access".into(),
            _ if self.first_mate_open => "First Mate".into(),
            Some(item) => item.title.clone().into(),
            None => "Seahelm".into(),
        };
        let width = self.sidebar_width;
        let cards = if self.first_mate_open || self.gateway_open || self.settings_open { None } else { self.selected_worktree().and_then(|wt| self.card_strip(&wt, cx)) };

        let mut root = div()
            .id("workspace")
            .track_focus(&self.focus)
            .size_full()
            .flex()
            .flex_row()
            .font_family(MONO)
            .on_action(cx.listener(|w, _: &SplitRight, window, cx| w.split(Axis::Horizontal, window, cx)))
            .on_action(cx.listener(|w, _: &SplitDown, window, cx| w.split(Axis::Vertical, window, cx)))
            .on_action(cx.listener(|w, _: &ClosePane, window, cx| w.close_pane(window, cx)))
            .on_action(cx.listener(|w, _: &FocusPaneLeft, window, cx| w.focus_pane(Direction::Left, window, cx)))
            .on_action(cx.listener(|w, _: &FocusPaneRight, window, cx| w.focus_pane(Direction::Right, window, cx)))
            .on_action(cx.listener(|w, _: &FocusPaneUp, window, cx| w.focus_pane(Direction::Up, window, cx)))
            .on_action(cx.listener(|w, _: &FocusPaneDown, window, cx| w.focus_pane(Direction::Down, window, cx)))
            .on_action(cx.listener(|w, _: &ZoomPane, _, cx| w.toggle_zoom(cx)))
            .capture_key_down(cx.listener(|w, _: &KeyDownEvent, _, _| w.note_activity()))
            .capture_any_mouse_down(cx.listener(|w, _: &MouseDownEvent, _, _| w.note_activity()));
        if self.dragging_divider || self.split_drag.as_ref().is_some_and(|d| d.axis == Axis::Horizontal) {
            root = root.cursor_col_resize();
        }

        if self.sidebar_visible {
            root = root.child(self.sidebar(width, window, cx));
        }
        if self.split_drag.as_ref().is_some_and(|d| d.axis == Axis::Vertical) {
            root = root.cursor_row_resize();
        }
        // While a divider is dragged, follow the pointer window-wide: the
        // dividers occlude what is under them (so a drag never starts a
        // selection), which also hides them from the root's own hover-bound
        // move and up listeners.
        if self.dragging_divider || self.split_drag.is_some() {
            let this = cx.entity();
            root = root.child(
                gpui::canvas(
                    |_, _, _| (),
                    move |_, _, window, _| {
                        let on_move = this.clone();
                        window.on_mouse_event(move |e: &MouseMoveEvent, phase, window, cx| {
                            if phase == gpui::DispatchPhase::Bubble {
                                on_move.update(cx, |w, cx| w.on_mouse_move(e, window, cx));
                            }
                        });
                        let on_up = this.clone();
                        window.on_mouse_event(move |e: &MouseUpEvent, phase, window, cx| {
                            if phase == gpui::DispatchPhase::Bubble {
                                on_up.update(cx, |w, cx| w.on_mouse_up(e, window, cx));
                            }
                        });
                    },
                )
                .absolute()
                .size_0(),
            );
        }
        root = root.child(self.terminal_column(title, cards, body, window.is_maximized(), cx));
        if self.sidebar_visible {
            root = root.child(self.divider(width, cx));
        }
        if let Some(overlay) = self.overlays(cx) {
            root = root.child(overlay);
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
            .when(self.side_tab.is_some(), |d| d.child(div().h(px(1.)).w_full().bg(tokens::hairline())).child(self.side_panel.clone()))
            .when(self.side_tab.is_none(), |d| {
                d.child(self.fleet_header(cx))
                    .child(div().mt(px(11.)).h(px(1.)).w_full().bg(tokens::hairline()))
                    .child(self.fleet_list(cx))
                    .child(self.first_mate_dock(cx))
            })
    }

    /// 40pt: the traffic lights' 70×14 slot on the left, the icon cluster on
    /// the right.
    fn sidebar_header(&self, cx: &mut Context<Self>) -> impl IntoElement {
        div()
            .h(px(HEADER_H))
            .flex_none()
            .relative()
            .child(drag_area())
            .flex()
            .flex_row()
            .items_center()
            .justify_end()
            .pr(px(8.))
            .gap(px(2.))
            .child(chrome_icon("contrast", !theme::is_dark()).id("toggle-theme").on_click(cx.listener(Self::toggle_theme)))
            .child(chrome_icon("share", self.gateway_open).id("toggle-gateway").on_click(cx.listener(Self::toggle_gateway)))
            .child(chrome_icon("settings", self.settings_open).id("toggle-settings").on_click(cx.listener(Self::toggle_settings)))
            .child(
                chrome_icon("folder", self.side_tab == Some(SideTab::Files))
                    .id("toggle-files")
                    .on_click(cx.listener(|w, _: &ClickEvent, _, cx| w.toggle_side(SideTab::Files, cx))),
            )
            .child(
                chrome_icon("diff", self.side_tab == Some(SideTab::Changes))
                    .id("toggle-changes")
                    .on_click(cx.listener(|w, _: &ClickEvent, _, cx| w.toggle_side(SideTab::Changes, cx))),
            )
            .child(chrome_icon("panel-left", false).id("toggle-sidebar").on_click(cx.listener(Self::toggle_sidebar)))
    }

    fn fleet_header(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let n = self.fleet.worktree_count();
        let running = self.core.values().filter(|c| c.status == "Running").count();
        let subtitle = if running > 0 { format!("{n} · {running} running") } else { format!("{n}") };
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
            .child(
                div()
                    .id("add-project")
                    .cursor_pointer()
                    .on_click(cx.listener(Self::add_project))
                    .child(glyph("folder-plus", 13., tokens::ink_dim())),
            )
            .child(
                div()
                    .id("grouping")
                    .cursor_pointer()
                    .on_click(cx.listener(Self::cycle_grouping))
                    .child(glyph("group", 13., if self.grouping == Grouping::Repository { tokens::ink_dim() } else { tokens::accent() })),
            )
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
        for (gi, group) in self.display_groups(now).iter().enumerate() {
            let project = (!group.path.is_empty()).then(|| (group.path.clone(), group.title.clone()));
            list = list.child(group_header(&group.title, gi == 0, group.items.len() >= 3, project, cx));
            let mut rows = div().flex().flex_col().gap(px(4.));
            for item in &group.items {
                rows = rows.child(self.row(item, now, cx));
            }
            list = list.child(rows);
        }
        list
    }

    fn row(&self, item: &Item, now: f64, cx: &mut Context<Self>) -> impl IntoElement {
        let selected = self.selected.as_deref() == Some(item.id.as_str());
        let panes = self.panes.get(&item.id).map_or(0, |p| p.views.len());
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
        if let Some(pr) = self.prs.get(&item.worktree_path) {
            line2 = line2.child(pr_badge(pr));
        }
        let waiting = self.cards.iter().filter(|c| c.worktree_path == item.worktree_path).count();
        if waiting > 0 {
            line2 = line2.child(
                div()
                    .flex_none()
                    .px(px(5.))
                    .rounded(px(4.))
                    .bg(tokens::alpha(tokens::waiting(), 0.18))
                    .text_size(px(10.))
                    .line_height(px(13.))
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(tokens::waiting())
                    .child(format!("? {waiting}")),
            );
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
            .on_click({
                let id = id.clone();
                cx.listener(move |w, _: &ClickEvent, window, cx| w.select(id.clone(), window, cx))
            })
            .on_mouse_down(MouseButton::Right, cx.listener(move |w, e: &MouseDownEvent, _, cx| w.open_row_menu(id.clone(), e, cx)))
            .child(div().w(px(5.5)).h(px(16.)).flex_none().flex().items_center().child(status_dot(item.dot(), self.spin_phase)))
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

    fn terminal_column(
        &self,
        title: SharedString,
        cards: Option<gpui::AnyElement>,
        body: Option<gpui::AnyElement>,
        maximized: bool,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let fg = theme::rgb(theme::fg());
        let memory = self.memory.map(format_memory).unwrap_or_default();
        let header = div()
            .h(px(HEADER_H))
            .flex_none()
            .relative()
            .flex()
            .flex_row()
            .items_center()
            .bg(theme::rgb(theme::bg()))
            .child(drag_area())
            .when(platform::MAC && !self.sidebar_visible, |d| d.pl(px(82.)))
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
            .when(self.gateway_open, |d| {
                d.child(
                    div()
                        .id("close-gateway")
                        .mr(px(12.))
                        .px(px(6.))
                        .cursor_pointer()
                        .text_size(px(14.))
                        .text_color(tokens::alpha(fg, 0.55))
                        .hover(|s| s.text_color(fg))
                        .child("×")
                        .on_click(cx.listener(Self::toggle_gateway)),
                )
            })
            .when(self.settings_open, |d| {
                d.child(
                    div()
                        .id("close-settings")
                        .mr(px(12.))
                        .px(px(6.))
                        .cursor_pointer()
                        .text_size(px(14.))
                        .text_color(tokens::alpha(fg, 0.55))
                        .hover(|s| s.text_color(fg))
                        .child("×")
                        .on_click(cx.listener(Self::toggle_settings)),
                )
            })
            .when(self.first_mate_open && !self.gateway_open, |d| {
                d.child(
                    div()
                        .id("close-first-mate")
                        .mr(px(12.))
                        .px(px(6.))
                        .cursor_pointer()
                        .text_size(px(14.))
                        .text_color(tokens::alpha(fg, 0.55))
                        .hover(|s| s.text_color(fg))
                        .child("×")
                        .on_click(cx.listener(|w, _: &ClickEvent, window, cx| w.toggle_first_mate(window, cx))),
                )
            })
            .when(!self.first_mate_open && !self.gateway_open && !self.settings_open, |d| {
                d.child(
                    div().mr(px(8.)).child(
                        icon_button("columns-2", tokens::alpha(fg, 0.55))
                            .id("split-right")
                            .on_click(cx.listener(|w, _: &ClickEvent, window, cx| w.split(Axis::Horizontal, window, cx))),
                    ),
                )
            })
            .when(!platform::MAC, |d| d.child(caption_buttons(maximized)));
        let body = match body {
            Some(b) => b,
            None => div().flex_1().bg(theme::rgb(theme::bg())).into_any_element(),
        };
        div()
            .flex_1()
            .min_w_0()
            .h_full()
            .flex()
            .flex_col()
            .bg(theme::rgb(theme::bg()))
            .child(header)
            .children(cards)
            .child(body)
    }

    /// No width of its own: a 16pt strip over the seam, a 1pt line in it.
    fn divider(&self, width: f32, cx: &mut Context<Self>) -> impl IntoElement {
        let active = self.divider_hover || self.dragging_divider;
        div()
            .id("column-divider")
            .occlude()
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

/// The workbench's card column.
const WORKBENCH_CARDS_W: f32 = 340.0;

/// A card's answer, on its way to the core or failed there.
#[derive(Clone, Debug, PartialEq)]
enum Submit {
    Sending,
    Failed(String),
}

/// What a card says under its kind label, without repeating the label
/// ("First Mate asks: …" under "First Mate asks").
fn card_body(card: &core_client::Card) -> String {
    let text = card.message.trim();
    ["First Mate asks: ", "First Mate suggests: "]
        .iter()
        .find_map(|p| text.strip_prefix(p))
        .unwrap_or(text)
        .to_string()
}

/// A core error in a few words for the card.
fn failure_text(e: &str) -> String {
    let message = serde_json::from_str::<serde_json::Value>(e)
        .ok()
        .and_then(|v| v.get("message").and_then(|m| m.as_str()).map(str::to_string))
        .unwrap_or_else(|| e.to_string());
    if message.contains("no such card") {
        "Already answered elsewhere".into()
    } else if message.contains("onnect") || message.contains("os error") {
        "seahelm-core did not answer".into()
    } else {
        message
    }
}

fn short_name(path: &str) -> String {
    std::path::Path::new(path).file_name().and_then(|n| n.to_str()).unwrap_or("Seahelm").to_string()
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

/// Off macOS the client draws the titlebar, so a header is where the window
/// is dragged from: a layer under the header's own controls (which occlude
/// it, so a click on one is still a click). On macOS the window server
/// drags from the transparent titlebar already.
fn drag_area() -> impl IntoElement {
    div().absolute().inset_0().when(!platform::MAC, |d| d.window_control_area(WindowControlArea::Drag))
}

/// Minimise, maximise / restore and close, Windows-sized (46×40), at the
/// header's right end. The clicks are the platform's: each button is a
/// window control area, answered in the window's hit test.
fn caption_buttons(maximized: bool) -> impl IntoElement {
    let fg = theme::rgb(theme::fg());
    let button = |id: &'static str, glyph: &'static str, area: WindowControlArea| {
        div()
            .id(id)
            .w(px(46.))
            .h_full()
            .flex()
            .items_center()
            .justify_center()
            .occlude()
            .window_control_area(area)
            .child(svg().path(icon(glyph)).size(px(10.)).flex_none().text_color(tokens::alpha(fg, 0.8)))
    };
    div()
        .h_full()
        .flex()
        .flex_row()
        .child(button("caption-min", "caption-min", WindowControlArea::Min).hover(|s| s.bg(tokens::row_hover())))
        .child(
            button("caption-max", if maximized { "caption-restore" } else { "caption-max" }, WindowControlArea::Max)
                .hover(|s| s.bg(tokens::row_hover())),
        )
        .child(button("caption-close", "caption-close", WindowControlArea::Close).hover(|s| s.bg(gpui::rgb(0xc42b1c))))
}

fn icon_button(name: &str, tint: Rgba) -> gpui::Div {
    div()
        .occlude()
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

/// `project` is the group's (main checkout, name) when the group is one
/// project: then `+` makes a worktree in it and `×` takes it off the list.
fn group_header(title: &str, first: bool, can_integrate: bool, project: Option<(String, String)>, cx: &mut Context<Workspace>) -> impl IntoElement {
    let buttons = project.map(|(path, name)| {
        let (p2, n2) = (path.clone(), name.clone());
        div()
            .flex()
            .flex_row()
            .gap(px(7.))
            .child(
                div()
                    .id(SharedString::from(format!("new-wt-{path}")))
                    .cursor_pointer()
                    .on_click(cx.listener(move |w, _: &ClickEvent, window, cx| w.open_new_worktree(path.clone(), name.clone(), window, cx)))
                    .child(glyph("plus", 11., tokens::ink_faint())),
            )
            .child(
                div()
                    .id(SharedString::from(format!("rm-project-{p2}")))
                    .cursor_pointer()
                    .on_click(cx.listener(move |w, _: &ClickEvent, window, cx| w.remove_project(p2.clone(), n2.clone(), window, cx)))
                    .child(glyph("x", 11., tokens::ink_faint())),
            )
    });
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
        .when_some(buttons, |d, b| d.child(b))
}

/// How often the running spinner steps, and in how many steps it turns.
const SPIN_STEP: Duration = Duration::from_millis(200);
const SPIN_STEPS: u8 = 8;

/// One pane as `pane.register` takes it.
fn registration(name: &str, item: &fleet::Item) -> serde_json::Value {
    serde_json::json!({
        "pane": name,
        "worktree_path": item.worktree_path,
        "project": item.repository,
        "branch": item.branch,
    })
}

fn status_dot(dot: Dot, spin_phase: u8) -> gpui::AnyElement {
    let text = |g: &'static str, c: Rgba| div().text_size(px(8.)).line_height(px(11.)).text_color(c).child(g).into_any_element();
    match dot {
        // A 9pt arc stepping round on the workspace's spin clock; every
        // spinner on one phase.
        Dot::Running => svg()
            .path(icon("spinner-arc"))
            .size(px(9.))
            .flex_none()
            .text_color(tokens::running())
            .with_transformation(Transformation::rotate(percentage(spin_phase as f32 / SPIN_STEPS as f32)))
            .into_any_element(),
        Dot::Waiting => text("●", tokens::attention()),
        Dot::Idle => text("○", tokens::idle()),
        Dot::Error => text("✕", tokens::danger()),
        Dot::Exited => text("◌", tokens::idle()),
        Dot::Unknown => text("◌", tokens::ink_faint()),
        Dot::Unseen => text("●", tokens::waiting()),
    }
}

/// What a PR badge says, piece by piece, as the app's row draws it
/// (`DashboardOverviewView.prAttributed`): `#12 ✓ approved`,
/// `#3 draft ✕`, `#4 merged`, `#5`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum PrTone {
    Dim,
    Faint,
    Merged,
    Good,
    Bad,
    Pending,
}

fn pr_badge_parts(pr: &core_client::Pr) -> Vec<(String, PrTone)> {
    let n = pr.number;
    let mut parts = match pr.state.as_str() {
        "merged" => return vec![(format!("#{n} merged"), PrTone::Merged)],
        "closed" => return vec![(format!("#{n} closed"), PrTone::Faint)],
        "draft" => vec![(format!("#{n} draft"), PrTone::Faint)],
        _ => vec![(format!("#{n}"), PrTone::Dim)],
    };
    match pr.checks.as_deref() {
        Some("passing") => parts.push((" \u{2713}".into(), PrTone::Good)),
        Some("failing") => parts.push((" \u{2715}".into(), PrTone::Bad)),
        Some("pending") => parts.push((" \u{25CF}".into(), PrTone::Pending)),
        _ => {}
    }
    match pr.review.as_deref() {
        Some("approved") => parts.push((" approved".into(), PrTone::Good)),
        Some("changes_requested") => parts.push((" changes".into(), PrTone::Bad)),
        _ => {}
    }
    parts
}

fn pr_badge(pr: &core_client::Pr) -> impl IntoElement {
    let mut d = div().flex_none().flex().flex_row().text_size(px(10.)).line_height(px(13.));
    for (text, tone) in pr_badge_parts(pr) {
        let colour = match tone {
            PrTone::Dim => tokens::ink_dim(),
            PrTone::Faint => tokens::ink_faint(),
            PrTone::Merged => tokens::merged(),
            PrTone::Good => tokens::running(),
            PrTone::Bad => tokens::danger(),
            PrTone::Pending => tokens::attention(),
        };
        d = d.child(div().text_color(colour).child(text));
    }
    d
}

#[cfg(test)]
mod pr_badge_tests {
    use super::*;

    fn text(state: &str, checks: Option<&str>, review: Option<&str>, n: u64) -> String {
        let pr = core_client::Pr {
            number: n,
            url: "u".into(),
            state: state.into(),
            checks: checks.map(Into::into),
            review: review.map(Into::into),
        };
        pr_badge_parts(&pr).into_iter().map(|(t, _)| t).collect()
    }

    /// The app's `testRowBadgeReadsLikeTheSummary`.
    #[test]
    fn row_badge_reads_like_the_summary() {
        assert_eq!(text("open", Some("passing"), Some("approved"), 12), "#12 \u{2713} approved");
        assert_eq!(text("draft", Some("failing"), None, 3), "#3 draft \u{2715}");
        assert_eq!(text("merged", None, None, 4), "#4 merged");
        assert_eq!(text("open", None, Some("review_required"), 5), "#5");
    }
}
