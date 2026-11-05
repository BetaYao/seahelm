//! A terminal pane: one seahelmd session, drawn from libghostty-vt's render
//! state.
//!
//! Each frame takes only the rows that changed out of the grid (`View::read`
//! into `rows`), then lays the whole viewport out as runs of same-styled
//! cells. GPUI caches a shaped line by its text and runs, so an unchanged row
//! costs a cache hit, not a shape.

use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant};

use futures::StreamExt;
use gpui::{
    div, fill, outline, point, prelude::*, px, size, App, BorderStyle, Bounds, Context, CursorStyle, DispatchPhase,
    Element, ElementId, ElementInputHandler, EntityInputHandler, ExternalPaths, FocusHandle, Focusable, Font, FontStyle, FontWeight, GlobalElementId, Hitbox, HitboxBehavior,
    Hsla, InspectorElementId, KeyDownEvent, LayoutId, MouseButton, MouseDownEvent, MouseMoveEvent, MouseUpEvent,
    Pixels, ScrollWheelEvent, ShapedLine, SharedString, Style, TextRun, UTF16Selection, UnderlineStyle, Window,
};
use keep_vt::render::{Cell, CursorShape, Frame, Row, View, Width};
use keep_vt::selection::{Autoscroll, Geometry, Pointer, Scroll, Scrollbar};
use keep_vt::input::{
    kitty, KeyAction, KeyEncoder, KeyInput, MouseAction, MouseButton as VtButton, MouseEncoder, MouseGeometry,
    MouseInput,
};
use keep_vt::Terminal;

use crate::keys;
use crate::session::Session;
use crate::theme;

/// Space between the pane's edge and the grid, as the macOS app's panes.
pub const PADDING: f32 = 8.0;

pub struct TerminalView {
    name: String,
    session: Option<Arc<Session>>,
    attach_error: Option<String>,
    view: Option<View>,
    generation: u64,
    rows: Vec<Row>,
    frame: Option<Frame>,
    focus: FocusHandle,
    pub font_family: SharedString,
    pub font_size: Pixels,
    stats: Stats,
    /// Where the grid was laid out last frame, for turning the pointer into
    /// cells.
    geom: Option<Geom>,
    /// Wheel travel not yet a whole row (trackpads send fractions).
    scroll_rows: f32,
    /// A left-button selection in progress: the last pointer, for
    /// autoscroll ticks.
    selecting: Option<Pointer>,
    rectangle: bool,
    autoscrolling: bool,
    scrollbar: Scrollbar,
    /// What an input method is composing, not yet the terminal's: drawn at
    /// the cursor, underlined, until committed or cancelled.
    marked: Option<String>,
    /// The cursor's cell last frame, where the IME's candidate window goes.
    ime_anchor: Option<Bounds<Pixels>>,
    /// libghostty-vt's encoders, which follow the program's modes (Kitty
    /// keyboard, modifyOtherKeys, mouse tracking and its format).
    key_encoder: Option<KeyEncoder>,
    mouse_encoder: Option<MouseEncoder>,
    /// A button whose press went to the program, so its release does too.
    reported_button: Option<VtButton>,
}

#[derive(Clone, Copy)]
struct Geom {
    bounds: Bounds<Pixels>,
    cell: gpui::Size<Pixels>,
    cols: u16,
    rows: u16,
}

/// `SEAHELM_GPUI_KEYS=1`: log each key, what it encodes to, and what the
/// input method commits.
fn debug_keys() -> bool {
    static ON: OnceLock<bool> = OnceLock::new();
    *ON.get_or_init(|| std::env::var_os("SEAHELM_GPUI_KEYS").is_some())
}

/// A monotonic clock for the gesture's double-click timing.
fn now_ns() -> u64 {
    static START: OnceLock<Instant> = OnceLock::new();
    START.get_or_init(Instant::now).elapsed().as_nanos() as u64
}

#[derive(Default)]
struct Stats {
    enabled: bool,
    since: Option<Instant>,
    frames: u32,
    total: Duration,
    worst: Duration,
    rows_read: usize,
    bytes_at_start: u64,
}

impl TerminalView {
    pub fn new(name: String, cx: &mut Context<Self>) -> Self {
        Self {
            name,
            session: None,
            attach_error: None,
            view: None,
            generation: u64::MAX,
            rows: Vec::new(),
            frame: None,
            focus: cx.focus_handle(),
            font_family: crate::fonts::terminal_family().into(),
            font_size: px(13.0),
            stats: Stats { enabled: std::env::var_os("SEAHELM_GPUI_STATS").is_some(), ..Stats::default() },
            geom: None,
            scroll_rows: 0.0,
            selecting: None,
            rectangle: false,
            autoscrolling: false,
            scrollbar: Scrollbar::default(),
            marked: None,
            ime_anchor: None,
            key_encoder: KeyEncoder::new().ok(),
            mouse_encoder: MouseEncoder::new().ok(),
            reported_button: None,
        }
    }

    pub fn title(&self) -> String {
        self.session
            .as_ref()
            .and_then(|s| s.grid.lock().ok().map(|g| g.title.clone()))
            .filter(|t| !t.is_empty())
            .unwrap_or_else(|| self.name.clone())
    }

    /// Attach on the first layout, when the size is known: a held session
    /// starts at the pane's size rather than 80x24 and a reflow.
    fn ensure_attached(&mut self, cols: u16, rows: u16, cx: &mut Context<Self>) {
        if let Some(session) = &self.session {
            session.resize(cols, rows);
            return;
        }
        if self.attach_error.is_some() {
            return;
        }
        let (tx, mut rx) = futures::channel::mpsc::unbounded();
        match Session::attach(&self.name, cols, rows, tx) {
            Ok(session) => {
                self.session = Some(session);
                cx.spawn(async move |this, cx| {
                    while rx.next().await.is_some() {
                        let alive = this.update(cx, |_, cx| cx.notify()).is_ok();
                        if !alive {
                            break;
                        }
                    }
                })
                .detach();
            }
            Err(e) => self.attach_error = Some(format!("{e:#}")),
        }
    }

    /// Repaint in the current theme: the grid takes the new colours and
    /// the row cache starts over, since its cells hold resolved colours.
    pub fn refresh_theme(&mut self, cx: &mut Context<Self>) {
        if let Some(session) = &self.session {
            session.apply_theme();
        }
        self.view = None;
        self.rows.clear();
        cx.notify();
    }

    /// Bring `rows` up to date with the grid.
    fn sync(&mut self) {
        let Some(session) = self.session.clone() else { return };
        session.take_wake();
        {
            let Ok(grid) = session.grid.lock() else { return };
            if grid.generation != self.generation || self.view.is_none() {
                self.view = View::new().ok();
                self.rows.clear();
                self.generation = grid.generation;
            }
            self.scrollbar = grid.terminal.scrollbar();
            let Some(view) = self.view.as_mut() else { return };
            if view.begin(&grid.terminal).is_err() {
                return;
            }
        }
        let Some(view) = self.view.as_mut() else { return };
        if view.finish().is_ok() {
            if let Ok(frame) = view.read(&mut self.rows) {
                self.stats.rows_read += frame.rows_changed;
                self.frame = Some(frame);
            }
        }
    }

    /// Run `f` on the grid's terminal, under its lock.
    fn with_terminal<R>(&self, f: impl FnOnce(&mut Terminal) -> R) -> Option<R> {
        let session = self.session.as_ref()?;
        let mut grid = session.grid.lock().ok()?;
        Some(f(&mut grid.terminal))
    }

    /// Encode a key under the terminal's modes.
    fn encode_key(&mut self, ks: &gpui::Keystroke, action: KeyAction) -> Vec<u8> {
        let Some(t) = keys::translate(ks) else { return Vec::new() };
        let Some(session) = self.session.clone() else { return Vec::new() };
        let Some(encoder) = self.key_encoder.as_mut() else { return Vec::new() };
        let Ok(grid) = session.grid.lock() else { return Vec::new() };
        encoder.encode(
            &grid.terminal,
            &KeyInput { key: t.key, mods: t.mods, action, text: t.text.as_deref(), unshifted: t.unshifted },
        )
    }

    fn kitty_flags(&self) -> u8 {
        self.with_terminal(|t| t.kitty_keyboard_flags()).unwrap_or(0)
    }

    fn on_key_down(&mut self, event: &KeyDownEvent, _window: &mut Window, cx: &mut Context<Self>) {
        let Some(session) = self.session.clone() else { return };
        let flags = self.kitty_flags();
        if debug_keys() {
            eprintln!("key_down {:?} text={} flags={flags}", event.keystroke, keys::is_text(&event.keystroke));
        }
        // Typed text is the input method's to deliver (`replace_text_in_range`),
        // unless the program asked for every key as an escape code and
        // nothing is being composed.
        if keys::is_text(&event.keystroke) && (flags & kitty::REPORT_ALL == 0 || self.marked.is_some()) {
            return;
        }
        if crate::platform::is_app_shortcut(&event.keystroke.modifiers) {
            match event.keystroke.key.as_str() {
                "v" => {
                    if let Some(text) = cx.read_from_clipboard().and_then(|c| c.text()) {
                        self.paste(&text);
                    }
                    cx.stop_propagation();
                    return;
                }
                "c" => {
                    if let Some(text) = self.with_terminal(|t| t.selection_text()).flatten().filter(|t| !t.is_empty()) {
                        cx.write_to_clipboard(gpui::ClipboardItem::new_string(text));
                    }
                    cx.stop_propagation();
                    return;
                }
                _ => {}
            }
        }
        let bytes = match keys::legacy_newline(&event.keystroke, flags) {
            Some(b) => b.to_vec(),
            None => {
                let action = if event.is_held { KeyAction::Repeat } else { KeyAction::Press };
                self.encode_key(&event.keystroke, action)
            }
        };
        if debug_keys() {
            eprintln!("  -> {bytes:?}");
        }
        if !bytes.is_empty() {
            self.to_live_screen();
            session.send(&bytes);
            cx.stop_propagation();
            cx.notify();
        }
    }

    /// Releases, for a program that asked for event types.
    fn on_key_up(&mut self, event: &gpui::KeyUpEvent, _window: &mut Window, cx: &mut Context<Self>) {
        if self.kitty_flags() & kitty::REPORT_EVENTS == 0 {
            return;
        }
        let bytes = self.encode_key(&event.keystroke, KeyAction::Release);
        if let (false, Some(session)) = (bytes.is_empty(), &self.session) {
            session.send(&bytes);
            cx.stop_propagation();
        }
    }

    /// What typing does first, as in Ghostty: back to the live screen, and
    /// the selection gone.
    fn to_live_screen(&mut self) {
        self.selecting = None;
        self.with_terminal(|t| {
            if t.has_selection() {
                t.clear_selection();
            }
            if !t.scrollbar().at_bottom() {
                t.scroll_viewport(Scroll::Bottom);
            }
        });
    }

    /// Bytes for the program, as typed: used for the Esc a fork sends to
    /// stop the original's turn.
    pub fn send_bytes(&self, bytes: &[u8]) {
        if let Some(session) = &self.session {
            session.send(bytes);
        }
    }

    /// Files dropped on the pane: their paths typed in, escaped, through
    /// the paste path (so a program in bracketed-paste mode reads them as
    /// pasted, and an agent takes an image path as an image).
    fn drop_paths(&mut self, paths: &ExternalPaths, window: &mut Window, cx: &mut Context<Self>) {
        let text = crate::terminal_text::drop_text(paths.paths(), cfg!(windows));
        if !text.is_empty() {
            window.focus(&self.focus);
            self.paste(&text);
            cx.notify();
        }
    }

    /// ⌘-click (Ctrl-click off macOS) on a URL opens it.
    fn link_at(&self, event: &MouseDownEvent) -> Option<String> {
        let opener = if crate::platform::MAC { event.modifiers.platform } else { event.modifiers.control };
        if !opener || event.button != MouseButton::Left {
            return None;
        }
        let at = self.pointer(event.position)?;
        let text = |row: &Row| row.cells.iter().map(|c| c.text.clone()).collect::<Vec<String>>();
        let row = self.rows.get(at.row as usize).map(text)?;
        let next = self.rows.get(at.row as usize + 1).map(text);
        crate::terminal_text::url_at(&row, at.col as usize, next.as_deref())
    }

    fn paste(&mut self, text: &str) {
        self.to_live_screen();
        let Some(session) = &self.session else { return };
        let bracketed = session.grid.lock().map(|g| g.terminal.dec_mode(2004)).unwrap_or(false);
        let body = text.replace("\r\n", "\r").replace('\n', "\r");
        let mut out = Vec::with_capacity(body.len() + 12);
        if bracketed {
            out.extend_from_slice(b"\x1b[200~");
        }
        out.extend_from_slice(body.as_bytes());
        if bracketed {
            out.extend_from_slice(b"\x1b[201~");
        }
        session.send(&out);
    }

    /// The wheel: history on the primary screen; arrow keys in a
    /// full-screen program (the alternate screen has no history), as most
    /// terminals do.
    fn on_scroll(&mut self, event: &ScrollWheelEvent, window: &mut Window, cx: &mut Context<Self>) {
        let Some(session) = self.session.clone() else { return };
        let row_h = self.geom.map(|g| g.cell.height).unwrap_or(window.line_height());
        let dy = event.delta.pixel_delta(row_h).y;
        self.scroll_rows += f32::from(dy) / f32::from(row_h).max(1.0);
        let rows = self.scroll_rows.trunc() as i32;
        if rows == 0 {
            return;
        }
        self.scroll_rows -= rows as f32;
        if !event.modifiers.shift && self.program_has_mouse() {
            let button = if rows > 0 { VtButton::WheelUp } else { VtButton::WheelDown };
            let mut out = Vec::new();
            for _ in 0..rows.unsigned_abs().min(10) {
                out.extend(self.encode_mouse(MouseAction::Press, Some(button), &event.modifiers, event.position, false));
            }
            if !out.is_empty() {
                session.send(&out);
            }
            return;
        }
        let alt = session.grid.lock().map(|g| g.terminal.alternate_screen().is_some()).unwrap_or(false);
        if alt {
            let key: &[u8] = if rows > 0 { b"\x1b[A" } else { b"\x1b[B" };
            for _ in 0..rows.unsigned_abs().min(10) {
                session.send(key);
            }
            return;
        }
        // Positive is towards the top of the content: up into history.
        self.with_terminal(|t| t.scroll_viewport(Scroll::Delta(-(rows as isize))));
        cx.notify();
    }

    /// The pointer as the gesture wants it: the cell under it, clamped to
    /// the grid, and its position in the pane.
    fn pointer(&self, position: gpui::Point<Pixels>) -> Option<Pointer> {
        let g = self.geom?;
        let x = f32::from(position.x - g.bounds.origin.x);
        let y = f32::from(position.y - g.bounds.origin.y);
        let cell = |v: f32, size: Pixels, n: u16| (((v - PADDING) / f32::from(size)).floor().max(0.0) as u16).min(n.saturating_sub(1));
        Some(Pointer { col: cell(x, g.cell.width, g.cols), row: cell(y, g.cell.height, g.rows), x: x as f64, y: y as f64 })
    }

    fn geometry(&self) -> Option<Geometry> {
        let g = self.geom?;
        Some(Geometry {
            columns: g.cols as u32,
            cell_width: f32::from(g.cell.width).round() as u32,
            padding_left: PADDING as u32,
            screen_height: f32::from(g.bounds.size.height) as u32,
        })
    }

    /// A program that asked for the mouse gets it; shift selects anyway.
    fn program_has_mouse(&self) -> bool {
        self.with_terminal(|t| t.mouse_tracking()).unwrap_or(false)
    }

    /// Encode a mouse event under the program's tracking mode and format.
    fn encode_mouse(
        &mut self,
        action: MouseAction,
        button: Option<VtButton>,
        modifiers: &gpui::Modifiers,
        position: gpui::Point<Pixels>,
        any_pressed: bool,
    ) -> Vec<u8> {
        let (Some(g), Some(session)) = (self.geom, self.session.clone()) else { return Vec::new() };
        let Some(encoder) = self.mouse_encoder.as_mut() else { return Vec::new() };
        let geometry = MouseGeometry {
            screen_width: f32::from(g.bounds.size.width) as u32,
            screen_height: f32::from(g.bounds.size.height) as u32,
            cell_width: f32::from(g.cell.width).round() as u32,
            cell_height: f32::from(g.cell.height).round() as u32,
            padding: PADDING as u32,
        };
        let input = MouseInput {
            action,
            button,
            mods: keys::mods(modifiers),
            x: f32::from(position.x - g.bounds.origin.x),
            y: f32::from(position.y - g.bounds.origin.y),
            any_pressed,
        };
        let Ok(grid) = session.grid.lock() else { return Vec::new() };
        encoder.encode(&grid.terminal, geometry, &input)
    }

    fn report_mouse(&mut self, bytes: Vec<u8>) {
        if let (false, Some(session)) = (bytes.is_empty(), &self.session) {
            session.send(&bytes);
        }
    }

    fn mouse_down(&mut self, event: &MouseDownEvent, window: &mut Window, cx: &mut Context<Self>) {
        window.focus(&self.focus);
        if let Some(url) = self.link_at(event) {
            cx.open_url(&url);
            return;
        }
        if !event.modifiers.shift && self.program_has_mouse() {
            if let Some(b) = vt_button(event.button) {
                let bytes = self.encode_mouse(MouseAction::Press, Some(b), &event.modifiers, event.position, true);
                self.reported_button = Some(b);
                self.report_mouse(bytes);
            }
            return;
        }
        if event.button != MouseButton::Left {
            return;
        }
        let Some(at) = self.pointer(event.position) else { return };
        self.rectangle = event.modifiers.alt;
        self.with_terminal(|t| t.select_press(at, now_ns()));
        self.selecting = Some(at);
        cx.notify();
    }

    fn mouse_move(&mut self, event: &MouseMoveEvent, hovered: bool, cx: &mut Context<Self>) {
        // Motion for the program: while a reported button is held (it may
        // leave the pane), or over the pane (any-event mode; the encoder
        // drops what the mode does not report).
        if self.selecting.is_none() && (self.reported_button.is_some() || hovered) && self.program_has_mouse() {
            let held = self.reported_button;
            let bytes = self.encode_mouse(MouseAction::Motion, held, &event.modifiers, event.position, held.is_some());
            self.report_mouse(bytes);
            return;
        }
        if self.selecting.is_none() || event.pressed_button != Some(MouseButton::Left) {
            return;
        }
        let (Some(at), Some(geometry)) = (self.pointer(event.position), self.geometry()) else { return };
        self.selecting = Some(at);
        let rectangle = self.rectangle || event.modifiers.alt;
        let autoscroll = self
            .with_terminal(|t| {
                let _ = t.select_drag(at, geometry, rectangle);
                t.select_autoscroll()
            })
            .unwrap_or(Autoscroll::None);
        if autoscroll != Autoscroll::None {
            self.start_autoscroll(cx);
        }
        cx.notify();
    }

    fn mouse_up(&mut self, event: &MouseUpEvent, cx: &mut Context<Self>) {
        if let Some(b) = self.reported_button.filter(|b| Some(*b) == vt_button(event.button)) {
            self.reported_button = None;
            let bytes = self.encode_mouse(MouseAction::Release, Some(b), &event.modifiers, event.position, false);
            self.report_mouse(bytes);
            return;
        }
        if event.button != MouseButton::Left {
            return;
        }
        let Some(at) = self.selecting.take() else { return };
        self.with_terminal(|t| t.select_release(Some((at.col, at.row))));
        cx.notify();
    }

    /// While a drag is held past the top or bottom edge, scroll and extend
    /// the selection every 50ms, as Ghostty does.
    fn start_autoscroll(&mut self, cx: &mut Context<Self>) {
        if self.autoscrolling {
            return;
        }
        self.autoscrolling = true;
        cx.spawn(async move |this, cx| loop {
            cx.background_executor().timer(Duration::from_millis(50)).await;
            let more = this
                .update(cx, |v, cx| {
                    let (Some(at), Some(geometry)) = (v.selecting, v.geometry()) else { return false };
                    let go = v
                        .with_terminal(|t| {
                            if t.select_autoscroll() == Autoscroll::None {
                                return false;
                            }
                            let _ = t.select_autoscroll_tick(at, geometry);
                            true
                        })
                        .unwrap_or(false);
                    cx.notify();
                    go
                })
                .unwrap_or(false);
            if !more {
                let _ = this.update(cx, |v, _| v.autoscrolling = false);
                break;
            }
        })
        .detach();
    }

    fn record(&mut self, spent: Duration) {
        if !self.stats.enabled {
            return;
        }
        let bytes = self.session.as_ref().map(|s| s.bytes_in.load(std::sync::atomic::Ordering::Relaxed)).unwrap_or(0);
        let repaints = self.session.as_ref().map(|s| s.repaints.load(std::sync::atomic::Ordering::Relaxed)).unwrap_or(0);
        let s = &mut self.stats;
        let since = *s.since.get_or_insert_with(|| {
            s.bytes_at_start = bytes;
            Instant::now()
        });
        s.frames += 1;
        s.total += spent;
        s.worst = s.worst.max(spent);
        let elapsed = since.elapsed();
        if elapsed >= Duration::from_secs(1) {
            let mb = (bytes - s.bytes_at_start) as f64 / elapsed.as_secs_f64() / (1 << 20) as f64;
            eprintln!(
                "frames {:>3}  avg {:>6.2}ms  worst {:>6.2}ms  rows read {:>5}  in {:>6.2} MB/s  repaints {}",
                s.frames,
                s.total.as_secs_f64() * 1e3 / s.frames as f64,
                s.worst.as_secs_f64() * 1e3,
                s.rows_read,
                mb,
                repaints
            );
            *s = Stats { enabled: true, ..Stats::default() };
        }
    }
}

impl Focusable for TerminalView {
    fn focus_handle(&self, _: &App) -> FocusHandle {
        self.focus.clone()
    }
}

impl Render for TerminalView {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let mut root = div()
            .id(ElementId::Name(format!("terminal-{}", self.name).into()))
            .track_focus(&self.focus)
            .key_context("Terminal")
            .on_key_down(cx.listener(Self::on_key_down))
            .on_key_up(cx.listener(Self::on_key_up))
            .on_scroll_wheel(cx.listener(Self::on_scroll))
            .on_drop(cx.listener(Self::drop_paths))
            .drag_over::<ExternalPaths>(|style, _, _, _| style.border_2().border_color(crate::tokens::accent()))
            .size_full()
            .bg(theme::rgb(theme::bg()));
        if let Some(e) = &self.attach_error {
            root = root.p(px(PADDING)).text_color(theme::rgb(theme::fg())).child(format!("cannot attach: {e}"));
            return root.into_any_element();
        }
        root.child(TerminalElement { view: cx.entity() }).into_any_element()
    }
}

/// The platform's input method talks to the terminal through this: it
/// composes in `marked` and commits text, which is typed into the session.
/// The terminal has no editable buffer of its own, so ranges are the
/// composition's.
impl EntityInputHandler for TerminalView {
    fn text_for_range(
        &mut self,
        range: std::ops::Range<usize>,
        adjusted: &mut Option<std::ops::Range<usize>>,
        _window: &mut Window,
        _cx: &mut Context<Self>,
    ) -> Option<String> {
        let marked = self.marked.as_deref().unwrap_or("");
        let utf16: Vec<u16> = marked.encode_utf16().collect();
        let range = range.start.min(utf16.len())..range.end.min(utf16.len());
        *adjusted = Some(range.clone());
        Some(String::from_utf16_lossy(&utf16[range]))
    }

    fn selected_text_range(&mut self, _: bool, _: &mut Window, _: &mut Context<Self>) -> Option<UTF16Selection> {
        let end = self.marked.as_deref().map_or(0, |m| m.encode_utf16().count());
        Some(UTF16Selection { range: end..end, reversed: false })
    }

    fn marked_text_range(&self, _: &mut Window, _: &mut Context<Self>) -> Option<std::ops::Range<usize>> {
        self.marked.as_deref().map(|m| 0..m.encode_utf16().count())
    }

    fn unmark_text(&mut self, _: &mut Window, cx: &mut Context<Self>) {
        self.marked = None;
        cx.notify();
    }

    fn replace_text_in_range(
        &mut self,
        _range: Option<std::ops::Range<usize>>,
        text: &str,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.marked = None;
        if debug_keys() {
            eprintln!("ime commit {text:?}");
        }
        if !text.is_empty() {
            self.to_live_screen();
            if let Some(session) = &self.session {
                session.send(text.replace('\n', "\r").as_bytes());
            }
        }
        cx.notify();
    }

    fn replace_and_mark_text_in_range(
        &mut self,
        _range: Option<std::ops::Range<usize>>,
        new_text: &str,
        _selected: Option<std::ops::Range<usize>>,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.marked = (!new_text.is_empty()).then(|| new_text.to_string());
        cx.notify();
    }

    fn bounds_for_range(
        &mut self,
        range: std::ops::Range<usize>,
        _element_bounds: Bounds<Pixels>,
        _window: &mut Window,
        _cx: &mut Context<Self>,
    ) -> Option<Bounds<Pixels>> {
        let anchor = self.ime_anchor?;
        let cell_w = self.geom.map(|g| g.cell.width).unwrap_or(anchor.size.width);
        Some(Bounds::new(point(anchor.origin.x + cell_w * range.start as f32, anchor.origin.y), anchor.size))
    }

    fn character_index_for_point(&mut self, _: gpui::Point<Pixels>, _: &mut Window, _: &mut Context<Self>) -> Option<usize> {
        None
    }
}

struct TerminalElement {
    view: gpui::Entity<TerminalView>,
}

struct Segment {
    origin: gpui::Point<Pixels>,
    line: ShapedLine,
}

pub struct Layout {
    cell: gpui::Size<Pixels>,
    backgrounds: Vec<gpui::PaintQuad>,
    segments: Vec<Segment>,
    cursor: Option<gpui::PaintQuad>,
    /// Shown while the viewport is back in history: where it is.
    thumb: Option<gpui::PaintQuad>,
    /// The IME's composition: a background over the cells it covers, and
    /// the text, underlined.
    preedit: Option<(gpui::PaintQuad, Segment)>,
    ime_anchor: Option<Bounds<Pixels>>,
    bounds: Bounds<Pixels>,
    hitbox: Option<Hitbox>,
    started: Instant,
}

impl IntoElement for TerminalElement {
    type Element = Self;
    fn into_element(self) -> Self {
        self
    }
}

impl Element for TerminalElement {
    type RequestLayoutState = ();
    type PrepaintState = Layout;

    fn id(&self) -> Option<ElementId> {
        None
    }

    fn source_location(&self) -> Option<&'static core::panic::Location<'static>> {
        None
    }

    fn request_layout(
        &mut self,
        _: Option<&GlobalElementId>,
        _: Option<&InspectorElementId>,
        window: &mut Window,
        cx: &mut App,
    ) -> (LayoutId, ()) {
        let mut style = Style::default();
        style.size.width = gpui::relative(1.).into();
        style.size.height = gpui::relative(1.).into();
        (window.request_layout(style, [], cx), ())
    }

    fn prepaint(
        &mut self,
        _: Option<&GlobalElementId>,
        _: Option<&InspectorElementId>,
        bounds: Bounds<Pixels>,
        _: &mut (),
        window: &mut Window,
        cx: &mut App,
    ) -> Layout {
        let started = Instant::now();
        let (family, font_size) = {
            let v = self.view.read(cx);
            (v.font_family.clone(), v.font_size)
        };
        let font = Font { family: family.clone(), ..gpui::font(family.clone()) };
        let text_system = window.text_system().clone();
        let font_id = text_system.resolve_font(&font);
        let cell_w = text_system.advance(font_id, font_size, 'M').map(|s| s.width).unwrap_or(px(8.));
        let ascent = text_system.ascent(font_id, font_size);
        let descent = text_system.descent(font_id, font_size);
        let cell_h = (ascent + descent.abs()).ceil().max(px(f32::from(font_size) * 1.2).round());
        let cell = size(cell_w, cell_h);

        let inner_w = (bounds.size.width - px(2. * PADDING)).max(px(0.));
        let inner_h = (bounds.size.height - px(2. * PADDING)).max(px(0.));
        let cols = ((f32::from(inner_w) / f32::from(cell_w)).floor() as u16).max(2);
        let rows = ((f32::from(inner_h) / f32::from(cell_h)).floor() as u16).max(1);

        let focused = self.view.update(cx, |v, cx| {
            v.geom = Some(Geom { bounds, cell, cols, rows });
            v.ensure_attached(cols, rows, cx);
            v.sync();
            v.focus.is_focused(window)
        });
        let hitbox = window.insert_hitbox(bounds, HitboxBehavior::Normal);

        let origin = point(bounds.origin.x + px(PADDING), bounds.origin.y + px(PADDING));
        let v = self.view.read(cx);
        let mut layout = Layout {
            cell,
            backgrounds: Vec::new(),
            segments: Vec::new(),
            cursor: None,
            thumb: scroll_thumb(v.scrollbar, bounds),
            preedit: None,
            ime_anchor: None,
            bounds,
            hitbox: Some(hitbox),
            started,
        };
        let Some(frame) = v.frame.clone() else { return layout };
        let default_fg = frame.foreground;
        let default_bg = frame.background;

        // Scrolled back, the cursor is not where it is drawn.
        let cursor_cell = frame.cursor.at.filter(|_| frame.cursor.visible && v.scrollbar.at_bottom());
        let cursor_colour = frame.cursor_colour.unwrap_or(theme::cursor());
        let block_cursor = focused && matches!(frame.cursor.shape, CursorShape::Block);

        let mut text = String::with_capacity(256);
        let mut runs: Vec<TextRun> = Vec::with_capacity(8);
        for (y, row) in v.rows.iter().enumerate() {
            let top = origin.y + cell_h * y as f32;
            // Backgrounds, merged across cells of one colour.
            let mut x = 0usize;
            while x < row.cells.len() {
                let bg = cell_bg(&row.cells[x], default_fg, default_bg, row.selection, x);
                let mut end = x + 1;
                while end < row.cells.len() && cell_bg(&row.cells[end], default_fg, default_bg, row.selection, end) == bg {
                    end += 1;
                }
                if let Some(bg) = bg {
                    layout.backgrounds.push(fill(
                        Bounds::new(point(origin.x + cell_w * x as f32, top), size(cell_w * (end - x) as f32, cell_h)),
                        theme::rgb(bg),
                    ));
                }
                x = end;
            }

            // Text, in runs of narrow cells; a wide character on its own so
            // it sits on its two columns.
            let mut x = 0usize;
            while x < row.cells.len() {
                let cell = &row.cells[x];
                if cell.width == Width::Tail || cell.width == Width::Head {
                    x += 1;
                    continue;
                }
                let on_cursor = |x: usize| block_cursor && cursor_cell == Some((x as u16, y as u16));
                if cell.width == Width::Wide || on_cursor(x) {
                    let colour = if on_cursor(x) { default_bg } else { cell_fg(cell, default_fg, default_bg) };
                    if !cell.text.is_empty() && !cell.invisible {
                        text.clear();
                        text.push_str(&cell.text);
                        runs.clear();
                        runs.push(run(&family, cell, text.len(), colour));
                        let line = text_system.shape_line(SharedString::from(text.clone()), font_size, &runs, None);
                        layout.segments.push(Segment { origin: point(origin.x + cell_w * x as f32, top), line });
                    }
                    x += if cell.width == Width::Wide { 2 } else { 1 };
                    continue;
                }
                // A run: narrow cells up to the next wide one or the cursor.
                let start = x;
                text.clear();
                runs.clear();
                while x < row.cells.len() {
                    let c = &row.cells[x];
                    if c.width != Width::Narrow || on_cursor(x) {
                        break;
                    }
                    let before = text.len();
                    if c.text.is_empty() || c.invisible {
                        text.push(' ');
                    } else {
                        text.push_str(&c.text);
                    }
                    let colour = cell_fg(c, default_fg, default_bg);
                    let len = text.len() - before;
                    match runs.last_mut() {
                        Some(last) if same_run(last, &family, c, colour) => last.len += len,
                        _ => runs.push(run(&family, c, len, colour)),
                    }
                    x += 1;
                }
                let trimmed = text.trim_end_matches(' ').len();
                if trimmed > 0 {
                    trim_runs(&mut runs, trimmed);
                    text.truncate(trimmed);
                    let line = text_system.shape_line(SharedString::from(text.clone()), font_size, &runs, Some(cell_w));
                    layout.segments.push(Segment { origin: point(origin.x + cell_w * start as f32, top), line });
                }
            }
        }

        if let Some((cx_, cy)) = frame.cursor.at {
            let at = point(origin.x + cell_w * cx_ as f32, origin.y + cell_h * cy as f32);
            layout.ime_anchor = Some(Bounds::new(at, cell));
            if let Some(marked) = v.marked.as_ref().filter(|m| !m.is_empty()) {
                let fg = Hsla::from(theme::rgb(default_fg));
                let runs = [TextRun {
                    len: marked.len(),
                    font: gpui::font(family.clone()),
                    color: fg,
                    background_color: None,
                    underline: Some(UnderlineStyle { color: Some(fg), thickness: px(1.), wavy: false }),
                    strikethrough: None,
                }];
                let line = text_system.shape_line(SharedString::from(marked.clone()), font_size, &runs, None);
                let bg = fill(Bounds::new(at, size(line.width, cell_h)), theme::rgb(default_bg));
                layout.preedit = Some((bg, Segment { origin: at, line }));
            }
        }
        if let Some((cx_, cy)) = cursor_cell.filter(|_| v.marked.is_none()) {
            let wide = v.rows.get(cy as usize).and_then(|r| r.cells.get(cx_ as usize)).is_some_and(|c| c.width == Width::Wide);
            let w = if wide { cell_w * 2. } else { cell_w };
            let at = point(origin.x + cell_w * cx_ as f32, origin.y + cell_h * cy as f32);
            let colour = theme::rgb(cursor_colour);
            layout.cursor = Some(match (focused, frame.cursor.shape) {
                (false, _) | (_, CursorShape::BlockHollow) => {
                    outline(Bounds::new(at, size(w, cell_h)), Hsla::from(colour), BorderStyle::Solid)
                }
                (true, CursorShape::Bar) => fill(Bounds::new(at, size(px(2.), cell_h)), colour),
                (true, CursorShape::Underline) => {
                    fill(Bounds::new(point(at.x, at.y + cell_h - px(2.)), size(w, px(2.))), colour)
                }
                (true, CursorShape::Block) => fill(Bounds::new(at, size(w, cell_h)), colour),
            });
        }
        layout
    }

    fn paint(
        &mut self,
        _: Option<&GlobalElementId>,
        _: Option<&InspectorElementId>,
        _bounds: Bounds<Pixels>,
        _: &mut (),
        layout: &mut Layout,
        window: &mut Window,
        cx: &mut App,
    ) {
        if let Some(hitbox) = layout.hitbox.take() {
            window.set_cursor_style(CursorStyle::IBeam, &hitbox);
            // Window-wide, not the element's: a drag goes on outside the
            // pane, and autoscroll needs to hear it there.
            let view = self.view.clone();
            let over = hitbox.clone();
            window.on_mouse_event(move |e: &MouseDownEvent, phase, window, cx| {
                if phase == DispatchPhase::Bubble && over.is_hovered(window) {
                    view.update(cx, |v, cx| v.mouse_down(e, window, cx));
                }
            });
            let view = self.view.clone();
            window.on_mouse_event(move |e: &MouseMoveEvent, phase, window, cx| {
                if phase == DispatchPhase::Bubble {
                    let hovered = hitbox.is_hovered(window);
                    view.update(cx, |v, cx| v.mouse_move(e, hovered, cx));
                }
            });
            let view = self.view.clone();
            window.on_mouse_event(move |e: &MouseUpEvent, phase, _window, cx| {
                if phase == DispatchPhase::Bubble {
                    view.update(cx, |v, cx| v.mouse_up(e, cx));
                }
            });
        }
        for quad in layout.backgrounds.drain(..) {
            window.paint_quad(quad);
        }
        // A block cursor goes under its character, which is drawn in the
        // background colour on top of it.
        let block = layout.cursor.as_ref().is_some_and(|c| c.border_widths.top == px(0.));
        if block {
            if let Some(c) = layout.cursor.take() {
                window.paint_quad(c);
            }
        }
        for seg in &layout.segments {
            let _ = seg.line.paint(seg.origin, layout.cell.height, window, cx);
        }
        if let Some(c) = layout.cursor.take() {
            window.paint_quad(c);
        }
        if let Some((bg, seg)) = layout.preedit.take() {
            window.paint_quad(bg);
            let _ = seg.line.paint(seg.origin, layout.cell.height, window, cx);
        }
        if let Some(t) = layout.thumb.take() {
            window.paint_quad(t);
        }
        let anchor = layout.ime_anchor;
        let focus = self.view.update(cx, |v, _| {
            v.ime_anchor = anchor;
            v.focus.clone()
        });
        window.handle_input(&focus, ElementInputHandler::new(layout.bounds, self.view.clone()), cx);
        let spent = layout.started.elapsed();
        self.view.update(cx, |v, _| v.record(spent));
    }
}

/// The buttons a program can be told about.
fn vt_button(b: MouseButton) -> Option<VtButton> {
    match b {
        MouseButton::Left => Some(VtButton::Left),
        MouseButton::Right => Some(VtButton::Right),
        MouseButton::Middle => Some(VtButton::Middle),
        _ => None,
    }
}

/// A 4pt overlay thumb at the right edge while the viewport is in history,
/// sized and placed as the viewport is in everything kept.
fn scroll_thumb(s: Scrollbar, bounds: Bounds<Pixels>) -> Option<gpui::PaintQuad> {
    if s.at_bottom() || s.total == 0 {
        return None;
    }
    let track = f32::from(bounds.size.height) - 4.0;
    let h = (track * s.len as f32 / s.total as f32).max(24.0);
    let top = (track - h) * s.offset as f32 / (s.total - s.len).max(1) as f32;
    Some(
        fill(
            Bounds::new(
                point(bounds.origin.x + bounds.size.width - px(6.), bounds.origin.y + px(2. + top)),
                size(px(4.), px(h)),
            ),
            crate::tokens::alpha(theme::rgb(theme::fg()), 0.35),
        )
        .corner_radii(px(2.)),
    )
}

fn cell_fg(c: &Cell, default_fg: [u8; 3], default_bg: [u8; 3]) -> [u8; 3] {
    let fg = c.fg.unwrap_or(default_fg);
    let colour = if c.inverse { c.bg.unwrap_or(default_bg) } else { fg };
    if c.faint {
        let mix = |a: u8, b: u8| ((a as u16 + b as u16) / 2) as u8;
        [mix(colour[0], default_bg[0]), mix(colour[1], default_bg[1]), mix(colour[2], default_bg[2])]
    } else {
        colour
    }
}

fn cell_bg(c: &Cell, default_fg: [u8; 3], default_bg: [u8; 3], selection: Option<(u16, u16)>, x: usize) -> Option<[u8; 3]> {
    if selection.is_some_and(|(a, b)| (a as usize..=b as usize).contains(&x)) {
        return Some(theme::selection_bg());
    }
    if c.inverse {
        return Some(c.fg.unwrap_or(default_fg));
    }
    c.bg.filter(|bg| *bg != default_bg)
}

fn run(family: &SharedString, c: &Cell, len: usize, colour: [u8; 3]) -> TextRun {
    let colour = Hsla::from(theme::rgb(colour));
    TextRun {
        len,
        font: Font {
            family: family.clone(),
            weight: if c.bold { FontWeight::BOLD } else { FontWeight::NORMAL },
            style: if c.italic { FontStyle::Italic } else { FontStyle::Normal },
            ..gpui::font(family.clone())
        },
        color: colour,
        background_color: None,
        underline: (c.underline != 0).then_some(UnderlineStyle { color: Some(colour), thickness: px(1.), wavy: c.underline == 3 }),
        strikethrough: c.strikethrough.then_some(gpui::StrikethroughStyle { color: Some(colour), thickness: px(1.) }),
    }
}

fn same_run(last: &TextRun, family: &SharedString, c: &Cell, colour: [u8; 3]) -> bool {
    let probe = run(family, c, 0, colour);
    last.font == probe.font
        && last.color == probe.color
        && last.underline == probe.underline
        && last.strikethrough == probe.strikethrough
}

/// Cut the runs back to the first `len` bytes.
fn trim_runs(runs: &mut Vec<TextRun>, len: usize) {
    let mut total = 0;
    let mut keep = 0;
    for r in runs.iter_mut() {
        if total >= len {
            break;
        }
        if total + r.len > len {
            r.len = len - total;
        }
        total += r.len;
        keep += 1;
    }
    runs.truncate(keep);
}
