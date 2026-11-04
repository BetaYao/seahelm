//! Scrolling the viewport through history, and selecting with the mouse:
//! what a client drawing the grid itself needs for scrollback and copy.
//!
//! The selection is libghostty-vt's own (Ghostty's click semantics: drag by
//! cell, double-click by word, triple-click by line, autoscroll past the
//! edges). The gesture state lives on the [`Terminal`], because the library
//! tracks its anchor inside the terminal's pages and frees it with them.

use std::ffi::c_void;
use std::os::raw::c_int;

use crate::{ffi, Error, Terminal};

mod raw {
    use std::ffi::c_void;
    use std::os::raw::c_int;

    pub type Gesture = *mut c_void;
    pub type Event = *mut c_void;

    /// `GhosttyTerminalScrollViewport`.
    #[repr(C)]
    pub struct ScrollViewport {
        pub tag: c_int,
        pub value: [u64; 2],
    }
    pub const SCROLL_TOP: c_int = 0;
    pub const SCROLL_BOTTOM: c_int = 1;
    pub const SCROLL_DELTA: c_int = 2;

    /// `GhosttyTerminalScrollbar`.
    #[repr(C)]
    #[derive(Default)]
    pub struct Scrollbar {
        pub total: u64,
        pub offset: u64,
        pub len: u64,
    }
    pub const DATA_SCROLLBAR: c_int = 9;
    pub const DATA_SELECTION: c_int = 31;
    pub const OPT_SELECTION: c_int = 21;

    pub const POINT_TAG_VIEWPORT: c_int = 1;

    /// `GhosttySurfacePosition`.
    #[repr(C)]
    pub struct SurfacePosition {
        pub x: f64,
        pub y: f64,
    }

    /// `GhosttySelectionGestureGeometry`.
    #[repr(C)]
    pub struct Geometry {
        pub columns: u32,
        pub cell_width: u32,
        pub padding_left: u32,
        pub screen_height: u32,
    }

    pub const EVENT_PRESS: c_int = 0;
    pub const EVENT_RELEASE: c_int = 1;
    pub const EVENT_DRAG: c_int = 2;
    pub const EVENT_AUTOSCROLL_TICK: c_int = 3;

    pub const EV_REF: c_int = 0;
    pub const EV_POSITION: c_int = 1;
    pub const EV_REPEAT_DISTANCE: c_int = 2;
    pub const EV_TIME_NS: c_int = 3;
    pub const EV_REPEAT_INTERVAL_NS: c_int = 4;
    pub const EV_RECTANGLE: c_int = 7;
    pub const EV_GEOMETRY: c_int = 8;
    pub const EV_VIEWPORT: c_int = 9;

    pub const GESTURE_DATA_AUTOSCROLL: c_int = 2;

    /// `GhosttyTerminalSelectionFormatOptions`.
    #[repr(C)]
    pub struct FormatOptions {
        pub size: usize,
        pub emit: c_int,
        pub unwrap: bool,
        pub trim: bool,
        pub selection: *const c_void,
    }

    extern "C" {
        pub fn ghostty_terminal_scroll_viewport(terminal: super::ffi::Terminal, behavior: ScrollViewport);
        pub fn ghostty_selection_gesture_new(allocator: *const c_void, out: *mut Gesture) -> c_int;
        pub fn ghostty_selection_gesture_free(gesture: Gesture, terminal: super::ffi::Terminal);
        pub fn ghostty_selection_gesture_reset(gesture: Gesture, terminal: super::ffi::Terminal);
        pub fn ghostty_selection_gesture_get(
            gesture: Gesture,
            terminal: super::ffi::Terminal,
            data: c_int,
            value: *mut c_void,
        ) -> c_int;
        pub fn ghostty_selection_gesture_event_new(allocator: *const c_void, out: *mut Event, kind: c_int) -> c_int;
        pub fn ghostty_selection_gesture_event_free(event: Event);
        pub fn ghostty_selection_gesture_event_set(event: Event, option: c_int, value: *const c_void) -> c_int;
        pub fn ghostty_selection_gesture_event(
            gesture: Gesture,
            terminal: super::ffi::Terminal,
            event: Event,
            out: *mut super::ffi::Selection,
        ) -> c_int;
        pub fn ghostty_terminal_selection_format_alloc(
            terminal: super::ffi::Terminal,
            allocator: *const c_void,
            options: FormatOptions,
            out_ptr: *mut *mut u8,
            out_len: *mut usize,
        ) -> c_int;
    }
}

pub(crate) use raw::Gesture as RawGesture;

/// Where to move the viewport.
#[derive(Clone, Copy, Debug)]
pub enum Scroll {
    /// The oldest line kept.
    Top,
    /// Back to the live screen.
    Bottom,
    /// Rows down (positive) or up into history (negative).
    Delta(isize),
}

/// The scrollable area, in rows: everything kept, where the viewport starts
/// in it, and how many rows the viewport shows.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Scrollbar {
    pub total: u64,
    pub offset: u64,
    pub len: u64,
}

impl Scrollbar {
    /// Whether the viewport shows the live screen.
    pub fn at_bottom(&self) -> bool {
        self.offset + self.len >= self.total
    }
}

/// The pointer, on the grid and on the surface.
#[derive(Clone, Copy, Debug)]
pub struct Pointer {
    /// The viewport cell under it (clamped to the grid by the caller).
    pub col: u16,
    pub row: u16,
    /// Surface pixels from the pane's top left, padding included: what the
    /// library uses to pick the side of a cell and to detect autoscroll.
    pub x: f64,
    pub y: f64,
}

/// How the grid sits on the surface, for drags.
#[derive(Clone, Copy, Debug)]
pub struct Geometry {
    pub columns: u32,
    pub cell_width: u32,
    pub padding_left: u32,
    pub screen_height: u32,
}

/// Which way a drag past an edge wants the viewport to go.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Autoscroll {
    None,
    Up,
    Down,
}

/// Double- and triple-click timing and slop, Ghostty's defaults.
const REPEAT_INTERVAL_NS: u64 = 500_000_000;
const REPEAT_DISTANCE: f64 = 4.0;

struct Event(raw::Event);

impl Event {
    fn new(kind: c_int) -> Result<Self, Error> {
        let mut e: raw::Event = std::ptr::null_mut();
        let rc = unsafe { raw::ghostty_selection_gesture_event_new(std::ptr::null(), &mut e, kind) };
        if rc != ffi::SUCCESS || e.is_null() {
            return Err(Error(rc));
        }
        Ok(Event(e))
    }

    fn set<T>(&self, option: c_int, value: &T) -> Result<(), Error> {
        let rc = unsafe { raw::ghostty_selection_gesture_event_set(self.0, option, value as *const T as *const c_void) };
        if rc != ffi::SUCCESS {
            return Err(Error(rc));
        }
        Ok(())
    }
}

impl Drop for Event {
    fn drop(&mut self) {
        unsafe { raw::ghostty_selection_gesture_event_free(self.0) };
    }
}

impl Terminal {
    pub fn scroll_viewport(&mut self, to: Scroll) {
        let (tag, value) = match to {
            Scroll::Top => (raw::SCROLL_TOP, [0, 0]),
            Scroll::Bottom => (raw::SCROLL_BOTTOM, [0, 0]),
            Scroll::Delta(d) => (raw::SCROLL_DELTA, [d as i64 as u64, 0]),
        };
        unsafe { raw::ghostty_terminal_scroll_viewport(self.raw, raw::ScrollViewport { tag, value }) };
    }

    pub fn scrollbar(&self) -> Scrollbar {
        let mut s = raw::Scrollbar::default();
        let rc = unsafe { ffi::ghostty_terminal_get(self.raw, raw::DATA_SCROLLBAR, &mut s as *mut _ as *mut c_void) };
        if rc != ffi::SUCCESS {
            return Scrollbar::default();
        }
        Scrollbar { total: s.total, offset: s.offset, len: s.len }
    }

    fn viewport_ref(&self, col: u16, row: u16) -> Option<ffi::GridRef> {
        let point = ffi::Point {
            tag: raw::POINT_TAG_VIEWPORT,
            value: ffi::PointValue { coordinate: ffi::PointCoordinate { x: col, y: row as u32 } },
        };
        let mut r = ffi::GridRef { size: std::mem::size_of::<ffi::GridRef>(), node: std::ptr::null_mut(), x: 0, y: 0 };
        let rc = unsafe { ffi::ghostty_terminal_grid_ref(self.raw, point, &mut r) };
        (rc == ffi::SUCCESS && !r.node.is_null()).then_some(r)
    }

    fn gesture(&mut self) -> Result<raw::Gesture, Error> {
        if let Some(g) = self.gesture {
            return Ok(g);
        }
        let mut g: raw::Gesture = std::ptr::null_mut();
        let rc = unsafe { raw::ghostty_selection_gesture_new(std::ptr::null(), &mut g) };
        if rc != ffi::SUCCESS || g.is_null() {
            return Err(Error(rc));
        }
        self.gesture = Some(g);
        Ok(g)
    }

    /// Install `selection`, or clear it.
    fn set_selection(&mut self, selection: Option<&ffi::Selection>) {
        let ptr = selection.map_or(std::ptr::null(), |s| s as *const ffi::Selection as *const c_void);
        unsafe { ffi::ghostty_terminal_set(self.raw, raw::OPT_SELECTION, ptr) };
    }

    /// Apply one gesture event; a selection it yields becomes the
    /// terminal's.
    fn apply(&mut self, event: &Event) -> Result<(), Error> {
        let g = self.gesture()?;
        let mut sel = ffi::Selection {
            size: std::mem::size_of::<ffi::Selection>(),
            start: empty_ref(),
            end: empty_ref(),
            rectangle: false,
        };
        let rc = unsafe { raw::ghostty_selection_gesture_event(g, self.raw, event.0, &mut sel) };
        match rc {
            ffi::SUCCESS => {
                self.set_selection(Some(&sel));
                Ok(())
            }
            NO_VALUE => Ok(()),
            rc => Err(Error(rc)),
        }
    }

    /// A left press: starts a selection, or picks a word / line on a double
    /// / triple click (`time_ns` is a monotonic clock, for telling them
    /// apart). A single press clears what was selected: the selection a
    /// press makes is empty until it drags.
    pub fn select_press(&mut self, at: Pointer, time_ns: u64) -> Result<(), Error> {
        let Some(cell) = self.viewport_ref(at.col, at.row) else { return Ok(()) };
        let e = Event::new(raw::EVENT_PRESS)?;
        e.set(raw::EV_REF, &cell)?;
        e.set(raw::EV_POSITION, &raw::SurfacePosition { x: at.x, y: at.y })?;
        e.set(raw::EV_TIME_NS, &time_ns)?;
        e.set(raw::EV_REPEAT_INTERVAL_NS, &REPEAT_INTERVAL_NS)?;
        e.set(raw::EV_REPEAT_DISTANCE, &REPEAT_DISTANCE)?;
        self.set_selection(None);
        self.apply(&e)
    }

    /// The pointer moved with the button down.
    pub fn select_drag(&mut self, at: Pointer, geometry: Geometry, rectangle: bool) -> Result<(), Error> {
        let Some(cell) = self.viewport_ref(at.col, at.row) else { return Ok(()) };
        let e = Event::new(raw::EVENT_DRAG)?;
        e.set(raw::EV_REF, &cell)?;
        e.set(raw::EV_POSITION, &raw::SurfacePosition { x: at.x, y: at.y })?;
        e.set(raw::EV_GEOMETRY, &raw_geometry(geometry))?;
        e.set(raw::EV_RECTANGLE, &rectangle)?;
        self.apply(&e)
    }

    /// The button came up.
    pub fn select_release(&mut self, at: Option<(u16, u16)>) -> Result<(), Error> {
        let e = Event::new(raw::EVENT_RELEASE)?;
        if let Some(cell) = at.and_then(|(c, r)| self.viewport_ref(c, r)) {
            e.set(raw::EV_REF, &cell)?;
        }
        self.apply(&e)
    }

    /// Whether a drag held past an edge wants the viewport moved.
    pub fn select_autoscroll(&mut self) -> Autoscroll {
        let Ok(g) = self.gesture() else { return Autoscroll::None };
        let mut v: c_int = 0;
        let rc = unsafe {
            raw::ghostty_selection_gesture_get(g, self.raw, raw::GESTURE_DATA_AUTOSCROLL, &mut v as *mut c_int as *mut c_void)
        };
        match (rc, v) {
            (ffi::SUCCESS, 1) => Autoscroll::Up,
            (ffi::SUCCESS, 2) => Autoscroll::Down,
            _ => Autoscroll::None,
        }
    }

    /// One autoscroll step while the pointer is held past an edge: the
    /// library scrolls and extends the selection to `at`.
    pub fn select_autoscroll_tick(&mut self, at: Pointer, geometry: Geometry) -> Result<(), Error> {
        let e = Event::new(raw::EVENT_AUTOSCROLL_TICK)?;
        e.set(raw::EV_VIEWPORT, &ffi::PointCoordinate { x: at.col, y: at.row as u32 })?;
        e.set(raw::EV_POSITION, &raw::SurfacePosition { x: at.x, y: at.y })?;
        e.set(raw::EV_GEOMETRY, &raw_geometry(geometry))?;
        self.apply(&e)
    }

    pub fn clear_selection(&mut self) {
        self.set_selection(None);
        if let Some(g) = self.gesture {
            unsafe { raw::ghostty_selection_gesture_reset(g, self.raw) };
        }
    }

    pub fn has_selection(&self) -> bool {
        let mut sel = ffi::Selection {
            size: std::mem::size_of::<ffi::Selection>(),
            start: empty_ref(),
            end: empty_ref(),
            rectangle: false,
        };
        let rc = unsafe { ffi::ghostty_terminal_get(self.raw, raw::DATA_SELECTION, &mut sel as *mut _ as *mut c_void) };
        rc == ffi::SUCCESS
    }

    /// The selection as text for the clipboard: soft wraps joined, trailing
    /// blanks trimmed (Ghostty's copy). None when nothing is selected.
    pub fn selection_text(&self) -> Option<String> {
        let options = raw::FormatOptions {
            size: std::mem::size_of::<raw::FormatOptions>(),
            emit: ffi::FORMAT_PLAIN,
            unwrap: true,
            trim: true,
            selection: std::ptr::null(),
        };
        let mut ptr: *mut u8 = std::ptr::null_mut();
        let mut len = 0usize;
        let rc = unsafe { raw::ghostty_terminal_selection_format_alloc(self.raw, std::ptr::null(), options, &mut ptr, &mut len) };
        if rc != ffi::SUCCESS {
            return None;
        }
        if ptr.is_null() || len == 0 {
            return Some(String::new());
        }
        let text = String::from_utf8_lossy(unsafe { std::slice::from_raw_parts(ptr, len) }).into_owned();
        unsafe { ffi::ghostty_free(std::ptr::null(), ptr, len) };
        Some(text)
    }

    /// Called from `Drop`: the gesture holds tracked references into the
    /// terminal's pages and must go first.
    pub(crate) fn free_gesture(&mut self) {
        if let Some(g) = self.gesture.take() {
            unsafe { raw::ghostty_selection_gesture_free(g, self.raw) };
        }
    }
}

const NO_VALUE: c_int = -4;

fn empty_ref() -> ffi::GridRef {
    ffi::GridRef { size: std::mem::size_of::<ffi::GridRef>(), node: std::ptr::null_mut(), x: 0, y: 0 }
}

fn raw_geometry(g: Geometry) -> raw::Geometry {
    raw::Geometry {
        columns: g.columns.max(1),
        cell_width: g.cell_width.max(1),
        padding_left: g.padding_left,
        screen_height: g.screen_height.max(1),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn term_with_history() -> Terminal {
        let mut t = Terminal::new(20, 5).unwrap();
        t.set_scrollback_limit(1 << 20).unwrap();
        for i in 0..30 {
            t.write(format!("line {i}\r\n").as_bytes());
        }
        t
    }

    /// Left of the cell's middle: a press there starts with the cell.
    fn at(col: u16, row: u16) -> Pointer {
        Pointer { col, row, x: col as f64 * 8.0 + 1.0, y: row as f64 * 16.0 + 8.0 }
    }

    /// Right of the cell's middle: a drag ending there takes the cell.
    fn to(col: u16, row: u16) -> Pointer {
        Pointer { x: col as f64 * 8.0 + 7.0, ..at(col, row) }
    }

    const GEO: Geometry = Geometry { columns: 20, cell_width: 8, padding_left: 0, screen_height: 80 };

    #[test]
    fn the_viewport_scrolls_into_history_and_back() {
        let mut t = term_with_history();
        assert!(t.scrollbar().at_bottom());
        t.scroll_viewport(Scroll::Delta(-10));
        let s = t.scrollbar();
        assert!(!s.at_bottom(), "{s:?}");
        assert_eq!(s.len, 5);
        t.scroll_viewport(Scroll::Top);
        assert_eq!(t.scrollbar().offset, 0);
        t.scroll_viewport(Scroll::Bottom);
        assert!(t.scrollbar().at_bottom());
    }

    #[test]
    fn a_drag_selects_and_copies() {
        let mut t = Terminal::new(20, 5).unwrap();
        t.write(b"hello world\r\nsecond line");
        t.select_press(at(0, 0), 1).unwrap();
        assert!(!t.has_selection(), "a press alone selects nothing");
        t.select_drag(to(4, 0), GEO, false).unwrap();
        t.select_release(Some((4, 0))).unwrap();
        assert_eq!(t.selection_text().as_deref(), Some("hello"));
        t.clear_selection();
        assert!(!t.has_selection());
        assert_eq!(t.selection_text(), None);
    }

    #[test]
    fn a_double_click_selects_a_word() {
        let mut t = Terminal::new(20, 5).unwrap();
        t.write(b"hello world");
        t.select_press(at(7, 0), 1_000).unwrap();
        t.select_release(Some((7, 0))).unwrap();
        t.select_press(at(7, 0), 2_000).unwrap();
        t.select_release(Some((7, 0))).unwrap();
        assert_eq!(t.selection_text().as_deref(), Some("world"));
    }

    #[test]
    fn a_selection_in_history_copies_what_was_scrolled_to() {
        let mut t = term_with_history();
        t.scroll_viewport(Scroll::Top);
        t.select_press(at(0, 0), 1).unwrap();
        t.select_drag(to(5, 0), GEO, false).unwrap();
        assert_eq!(t.selection_text().as_deref(), Some("line 0"));
    }

    fn row_text(row: &crate::render::Row) -> String {
        row.cells.iter().map(|c| if c.text.is_empty() { " " } else { c.text.as_str() }).collect::<String>().trim_end().to_string()
    }

    #[test]
    fn the_render_state_draws_the_scrolled_viewport_and_its_selection() {
        let mut t = term_with_history();
        let mut view = crate::render::View::new().unwrap();
        let mut rows = Vec::new();
        view.update(&t).unwrap();
        view.read(&mut rows).unwrap();
        assert_ne!(row_text(&rows[0]), "line 0");

        t.scroll_viewport(Scroll::Top);
        t.select_press(at(0, 1), 1).unwrap();
        t.select_drag(to(3, 1), GEO, false).unwrap();
        view.update(&t).unwrap();
        let frame = view.read(&mut rows).unwrap();
        assert!(frame.rows_changed > 0, "scrolling marks the rows redrawn");
        assert_eq!(row_text(&rows[0]), "line 0");
        assert_eq!(rows[1].selection, Some((0, 3)));
        assert_eq!(rows[0].selection, None);
    }
}
