//! A terminal pane: one seahelmd session, drawn from libghostty-vt's render
//! state.
//!
//! Each frame takes only the rows that changed out of the grid (`View::read`
//! into `rows`), then lays the whole viewport out as runs of same-styled
//! cells. GPUI caches a shaped line by its text and runs, so an unchanged row
//! costs a cache hit, not a shape.

use std::sync::Arc;
use std::time::{Duration, Instant};

use futures::StreamExt;
use gpui::{
    div, fill, outline, point, prelude::*, px, size, App, BorderStyle, Bounds, Context, Element, ElementId,
    FocusHandle, Focusable, Font, FontStyle, FontWeight, GlobalElementId, Hsla, InspectorElementId, KeyDownEvent,
    LayoutId, Pixels, ScrollWheelEvent, ShapedLine, SharedString, Style, TextRun, UnderlineStyle, Window,
};
use keep_vt::render::{Cell, CursorShape, Frame, Row, View, Width};

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

    fn on_key_down(&mut self, event: &KeyDownEvent, _window: &mut Window, cx: &mut Context<Self>) {
        let Some(session) = &self.session else { return };
        let app_cursor = session.grid.lock().map(|g| g.terminal.dec_mode(1)).unwrap_or(false);
        if event.keystroke.modifiers.platform && event.keystroke.key == "v" {
            if let Some(text) = cx.read_from_clipboard().and_then(|c| c.text()) {
                self.paste(&text);
            }
            cx.stop_propagation();
            return;
        }
        if let Some(bytes) = keys::encode(&event.keystroke, app_cursor) {
            session.send(&bytes);
            cx.stop_propagation();
        }
    }

    fn paste(&self, text: &str) {
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

    fn on_scroll(&mut self, event: &ScrollWheelEvent, window: &mut Window, _cx: &mut Context<Self>) {
        // Until scrollback is drawn: in a full-screen program the wheel is
        // arrow keys, as most terminals do on the alternate screen.
        let Some(session) = &self.session else { return };
        let alt = session.grid.lock().map(|g| g.terminal.alternate_screen().is_some()).unwrap_or(false);
        if !alt {
            return;
        }
        let dy = event.delta.pixel_delta(window.line_height()).y;
        let lines = (f32::from(dy) / 16.0).round() as i32;
        let key: &[u8] = if lines > 0 { b"\x1b[A" } else { b"\x1b[B" };
        for _ in 0..lines.unsigned_abs().min(10) {
            session.send(key);
        }
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
            .on_scroll_wheel(cx.listener(Self::on_scroll))
            .size_full()
            .bg(theme::rgb(theme::BG));
        if let Some(e) = &self.attach_error {
            root = root.p(px(PADDING)).text_color(theme::rgb(theme::FG)).child(format!("cannot attach: {e}"));
            return root.into_any_element();
        }
        root.child(TerminalElement { view: cx.entity() }).into_any_element()
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
            v.ensure_attached(cols, rows, cx);
            v.sync();
            v.focus.is_focused(window)
        });

        let origin = point(bounds.origin.x + px(PADDING), bounds.origin.y + px(PADDING));
        let v = self.view.read(cx);
        let mut layout = Layout { cell, backgrounds: Vec::new(), segments: Vec::new(), cursor: None, started };
        let Some(frame) = v.frame.clone() else { return layout };
        let default_fg = frame.foreground;
        let default_bg = frame.background;

        let cursor_cell = frame.cursor.at.filter(|_| frame.cursor.visible);
        let cursor_colour = frame.cursor_colour.unwrap_or(theme::CURSOR);
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

        if let Some((cx_, cy)) = cursor_cell {
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
        let spent = layout.started.elapsed();
        self.view.update(cx, |v, _| v.record(spent));
    }
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
        return Some(theme::SELECTION_BG);
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
