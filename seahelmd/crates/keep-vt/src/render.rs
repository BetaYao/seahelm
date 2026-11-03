//! What a renderer draws: libghostty-vt's render state, read row by row.
//!
//! A [`View`] is kept beside a [`Terminal`] for as long as something draws
//! it. Each frame, [`View::begin`] takes what changed from the terminal (the
//! only step that needs the terminal, so the only one under its lock),
//! [`View::finish`] does the rest, and [`View::read`] copies the rows that
//! changed into the caller's cache and marks them drawn. A row that did not
//! change is not touched, which is what keeps a frame of a quiet screen cheap.

use std::ffi::c_void;
use std::os::raw::c_int;

use crate::{ffi, Error, Terminal};

mod sys {
    use std::ffi::c_void;
    use std::os::raw::c_int;

    #[repr(C)]
    pub struct RowIteratorImpl {
        _private: [u8; 0],
    }
    pub type RowIterator = *mut RowIteratorImpl;

    #[repr(C)]
    pub struct RowCellsImpl {
        _private: [u8; 0],
    }
    pub type RowCells = *mut RowCellsImpl;

    pub const DATA_COLS: c_int = 1;
    pub const DATA_ROWS: c_int = 2;
    pub const DATA_DIRTY: c_int = 3;
    pub const DATA_ROW_ITERATOR: c_int = 4;
    pub const DATA_CURSOR: c_int = 18;
    pub const DATA_COLORS: c_int = 19;

    pub const ROW_DATA_CELLS: c_int = 3;
    pub const ROW_DATA_SELECTION: c_int = 4;

    pub const CELLS_DATA_RAW: c_int = 1;
    pub const CELLS_DATA_STYLE: c_int = 2;
    pub const CELLS_DATA_GRAPHEMES_LEN: c_int = 3;
    pub const CELLS_DATA_GRAPHEMES_BUF: c_int = 4;
    pub const CELLS_DATA_BG_COLOR: c_int = 5;
    pub const CELLS_DATA_FG_COLOR: c_int = 6;
    pub const CELLS_DATA_HAS_STYLING: c_int = 8;

    #[repr(C)]
    pub struct Cursor {
        pub size: usize,
        pub viewport_has_value: bool,
        pub viewport_x: u16,
        pub viewport_y: u16,
        pub wide_tail: bool,
        pub visible: bool,
        pub blinking: bool,
        pub password_input: bool,
        pub visual_style: c_int,
    }

    #[repr(C)]
    pub struct Colors {
        pub size: usize,
        pub background: super::ffi::ColorRgb,
        pub foreground: super::ffi::ColorRgb,
        pub cursor: super::ffi::ColorRgb,
        pub cursor_has_value: bool,
        pub palette: [super::ffi::ColorRgb; 256],
    }

    #[repr(C)]
    pub struct RowSelection {
        pub size: usize,
        pub start_x: u16,
        pub end_x: u16,
    }

    extern "C" {
        pub fn ghostty_render_state_begin_update(
            state: super::ffi::RenderState,
            terminal: super::ffi::Terminal,
        ) -> c_int;
        pub fn ghostty_render_state_end_update(state: super::ffi::RenderState) -> c_int;
        pub fn ghostty_render_state_clean(state: super::ffi::RenderState) -> c_int;
        pub fn ghostty_render_state_row_iterator_new(allocator: *const c_void, out: *mut RowIterator) -> c_int;
        pub fn ghostty_render_state_row_iterator_free(iterator: RowIterator);
        pub fn ghostty_render_state_row_iterator_next(iterator: RowIterator) -> bool;
        pub fn ghostty_render_state_row_iterator_next_dirty(iterator: RowIterator, out_y: *mut u16) -> bool;
        pub fn ghostty_render_state_row_get(iterator: RowIterator, data: c_int, out: *mut c_void) -> c_int;
        pub fn ghostty_render_state_row_cells_new(allocator: *const c_void, out: *mut RowCells) -> c_int;
        pub fn ghostty_render_state_row_cells_free(cells: RowCells);
        pub fn ghostty_render_state_row_cells_next(cells: RowCells) -> bool;
        pub fn ghostty_render_state_row_cells_get(cells: RowCells, data: c_int, out: *mut c_void) -> c_int;
    }
}

/// How a cell sits in a row of wide characters.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Width {
    #[default]
    Narrow,
    /// The first of the two columns a wide character takes.
    Wide,
    /// The second column of a wide character: drawn by the cell before it.
    Tail,
    /// The last column of a row whose wide character wrapped to the next.
    Head,
}

/// One cell, as it is to be drawn.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Cell {
    /// The grapheme cluster, or empty.
    pub text: String,
    /// The colours the program gave it; None means the terminal's default.
    pub fg: Option<[u8; 3]>,
    pub bg: Option<[u8; 3]>,
    pub width: Width,
    pub bold: bool,
    pub italic: bool,
    pub faint: bool,
    pub inverse: bool,
    pub invisible: bool,
    pub strikethrough: bool,
    /// 0 none, 1 single, 2 double, 3 curly, 4 dotted, 5 dashed.
    pub underline: u8,
}

/// The cursor's shape.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum CursorShape {
    Bar,
    #[default]
    Block,
    Underline,
    BlockHollow,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Cursor {
    /// Column and row in the viewport, when the cursor is in it.
    pub at: Option<(u16, u16)>,
    pub visible: bool,
    pub blinking: bool,
    pub shape: CursorShape,
}

/// Everything about a frame that is not its rows.
#[derive(Clone, Debug)]
pub struct Frame {
    pub cols: u16,
    pub rows: u16,
    pub background: [u8; 3],
    pub foreground: [u8; 3],
    pub cursor_colour: Option<[u8; 3]>,
    pub cursor: Cursor,
    /// Rows rewritten in the caller's cache by this read.
    pub rows_changed: usize,
}

/// A row in the caller's cache: its cells, and the columns selected.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Row {
    pub cells: Vec<Cell>,
    pub selection: Option<(u16, u16)>,
}

/// The render state kept for one terminal. Not shared between terminals: its
/// dirty tracking is relative to the one it is updated from.
pub struct View {
    state: ffi::RenderState,
    rows: sys::RowIterator,
    cells: sys::RowCells,
    codepoints: Vec<u32>,
}

// The handles are owned exclusively.
unsafe impl Send for View {}

impl View {
    pub fn new() -> Result<Self, Error> {
        let mut state: ffi::RenderState = std::ptr::null_mut();
        let rc = unsafe { ffi::ghostty_render_state_new(std::ptr::null(), &mut state) };
        if rc != ffi::SUCCESS {
            return Err(Error(rc));
        }
        let mut rows: sys::RowIterator = std::ptr::null_mut();
        let rc = unsafe { sys::ghostty_render_state_row_iterator_new(std::ptr::null(), &mut rows) };
        if rc != ffi::SUCCESS {
            unsafe { ffi::ghostty_render_state_free(state) };
            return Err(Error(rc));
        }
        let mut cells: sys::RowCells = std::ptr::null_mut();
        let rc = unsafe { sys::ghostty_render_state_row_cells_new(std::ptr::null(), &mut cells) };
        if rc != ffi::SUCCESS {
            unsafe {
                sys::ghostty_render_state_row_iterator_free(rows);
                ffi::ghostty_render_state_free(state);
            }
            return Err(Error(rc));
        }
        Ok(Self { state, rows, cells, codepoints: Vec::with_capacity(8) })
    }

    /// Take what changed from the terminal. The only step that needs it: hold
    /// the terminal's lock for this and let go before [`View::finish`].
    pub fn begin(&mut self, terminal: &Terminal) -> Result<(), Error> {
        check(unsafe { sys::ghostty_render_state_begin_update(self.state, terminal.raw) })
    }

    /// Complete the update; needs nothing but the view.
    pub fn finish(&mut self) -> Result<(), Error> {
        check(unsafe { sys::ghostty_render_state_end_update(self.state) })
    }

    /// Both halves at once, for a caller that holds the terminal anyway.
    pub fn update(&mut self, terminal: &Terminal) -> Result<(), Error> {
        self.begin(terminal)?;
        self.finish()
    }

    /// Bring `cache` up to date — resized to the viewport, the rows that
    /// changed rewritten — mark everything drawn, and say what else the frame
    /// holds.
    pub fn read(&mut self, cache: &mut Vec<Row>) -> Result<Frame, Error> {
        let mut cols: u16 = 0;
        let mut rows: u16 = 0;
        let mut dirty: c_int = 0;
        unsafe {
            check(ffi::ghostty_render_state_get(self.state, sys::DATA_COLS, out(&mut cols)))?;
            check(ffi::ghostty_render_state_get(self.state, sys::DATA_ROWS, out(&mut rows)))?;
            check(ffi::ghostty_render_state_get(self.state, sys::DATA_DIRTY, out(&mut dirty)))?;
        }
        // A cache of another shape is a full redraw whatever the state says.
        let reshaped = cache.len() != rows as usize || cache.first().is_some_and(|r| r.cells.len() != cols as usize);
        if reshaped {
            cache.clear();
            cache.resize_with(rows as usize, Row::default);
        }

        let mut rows_changed = 0;
        if dirty != 0 || reshaped {
            unsafe {
                check(ffi::ghostty_render_state_get(self.state, sys::DATA_ROW_ITERATOR, out(&mut self.rows)))?;
            }
            let mut y: u16 = 0;
            while unsafe { sys::ghostty_render_state_row_iterator_next_dirty(self.rows, &mut y) } {
                let Some(row) = cache.get_mut(y as usize) else { continue };
                self.read_row(row, cols)?;
                rows_changed += 1;
            }
            // Dirty FALSE skips every row, so a reshaped cache with a clean
            // state is filled from a full pass instead.
            if reshaped && rows_changed == 0 && rows > 0 {
                unsafe {
                    check(ffi::ghostty_render_state_get(self.state, sys::DATA_ROW_ITERATOR, out(&mut self.rows)))?;
                }
                let mut y = 0usize;
                while unsafe { sys::ghostty_render_state_row_iterator_next(self.rows) } {
                    if let Some(row) = cache.get_mut(y) {
                        self.read_row(row, cols)?;
                        rows_changed += 1;
                    }
                    y += 1;
                }
            }
        }

        let mut colors = sys::Colors {
            size: std::mem::size_of::<sys::Colors>(),
            background: ffi::ColorRgb::default(),
            foreground: ffi::ColorRgb::default(),
            cursor: ffi::ColorRgb::default(),
            cursor_has_value: false,
            palette: [ffi::ColorRgb::default(); 256],
        };
        let mut cursor = sys::Cursor {
            size: std::mem::size_of::<sys::Cursor>(),
            viewport_has_value: false,
            viewport_x: 0,
            viewport_y: 0,
            wide_tail: false,
            visible: false,
            blinking: false,
            password_input: false,
            visual_style: 1,
        };
        unsafe {
            check(ffi::ghostty_render_state_get(self.state, sys::DATA_COLORS, out(&mut colors)))?;
            check(ffi::ghostty_render_state_get(self.state, sys::DATA_CURSOR, out(&mut cursor)))?;
            check(sys::ghostty_render_state_clean(self.state))?;
        }
        let rgb = |c: ffi::ColorRgb| [c.r, c.g, c.b];
        Ok(Frame {
            cols,
            rows,
            background: rgb(colors.background),
            foreground: rgb(colors.foreground),
            cursor_colour: colors.cursor_has_value.then(|| rgb(colors.cursor)),
            cursor: Cursor {
                at: cursor.viewport_has_value.then_some((cursor.viewport_x, cursor.viewport_y)),
                visible: cursor.visible,
                blinking: cursor.blinking,
                shape: match cursor.visual_style {
                    0 => CursorShape::Bar,
                    2 => CursorShape::Underline,
                    3 => CursorShape::BlockHollow,
                    _ => CursorShape::Block,
                },
            },
            rows_changed,
        })
    }

    fn read_row(&mut self, row: &mut Row, cols: u16) -> Result<(), Error> {
        let mut selection = sys::RowSelection { size: std::mem::size_of::<sys::RowSelection>(), start_x: 0, end_x: 0 };
        row.selection = (unsafe {
            sys::ghostty_render_state_row_get(self.rows, sys::ROW_DATA_SELECTION, out(&mut selection))
        } == ffi::SUCCESS)
            .then_some((selection.start_x, selection.end_x));

        unsafe {
            check(sys::ghostty_render_state_row_get(self.rows, sys::ROW_DATA_CELLS, out(&mut self.cells)))?;
        }
        row.cells.resize_with(cols as usize, Cell::default);
        let mut x = 0usize;
        while x < row.cells.len() && unsafe { sys::ghostty_render_state_row_cells_next(self.cells) } {
            let cell = &mut row.cells[x];
            self.read_cell(cell);
            x += 1;
        }
        for cell in &mut row.cells[x..] {
            *cell = Cell::default();
        }
        Ok(())
    }

    fn read_cell(&mut self, cell: &mut Cell) {
        let c = self.cells;
        let mut raw: ffi::Cell = 0;
        let mut wide: c_int = 0;
        let mut len: u32 = 0;
        let mut has_styling = false;
        let mut fg = ffi::ColorRgb::default();
        let mut bg = ffi::ColorRgb::default();
        unsafe {
            sys::ghostty_render_state_row_cells_get(c, sys::CELLS_DATA_RAW, out(&mut raw));
            ffi::ghostty_cell_get(raw, ffi::CELL_DATA_WIDE, out(&mut wide));
            sys::ghostty_render_state_row_cells_get(c, sys::CELLS_DATA_GRAPHEMES_LEN, out(&mut len));
            sys::ghostty_render_state_row_cells_get(c, sys::CELLS_DATA_HAS_STYLING, out(&mut has_styling));
        }
        cell.width = match wide {
            1 => Width::Wide,
            2 => Width::Tail,
            3 => Width::Head,
            _ => Width::Narrow,
        };

        cell.text.clear();
        if len > 0 {
            self.codepoints.resize(len as usize, 0);
            unsafe {
                sys::ghostty_render_state_row_cells_get(
                    c,
                    sys::CELLS_DATA_GRAPHEMES_BUF,
                    self.codepoints.as_mut_ptr() as *mut c_void,
                );
            }
            cell.text.extend(self.codepoints.iter().filter_map(|&cp| char::from_u32(cp)));
        }

        // The colours resolve palette indices and background-only cells
        // alike; an unset one is the caller's default.
        cell.fg = (unsafe { sys::ghostty_render_state_row_cells_get(c, sys::CELLS_DATA_FG_COLOR, out(&mut fg)) }
            == ffi::SUCCESS)
            .then_some([fg.r, fg.g, fg.b]);
        cell.bg = (unsafe { sys::ghostty_render_state_row_cells_get(c, sys::CELLS_DATA_BG_COLOR, out(&mut bg)) }
            == ffi::SUCCESS)
            .then_some([bg.r, bg.g, bg.b]);

        if has_styling {
            let mut style = blank_style();
            unsafe { sys::ghostty_render_state_row_cells_get(c, sys::CELLS_DATA_STYLE, out(&mut style)) };
            cell.bold = style.bold;
            cell.italic = style.italic;
            cell.faint = style.faint;
            cell.inverse = style.inverse;
            cell.invisible = style.invisible;
            cell.strikethrough = style.strikethrough;
            cell.underline = style.underline.clamp(0, 5) as u8;
        } else {
            cell.bold = false;
            cell.italic = false;
            cell.faint = false;
            cell.inverse = false;
            cell.invisible = false;
            cell.strikethrough = false;
            cell.underline = 0;
        }
    }
}

impl Drop for View {
    fn drop(&mut self) {
        unsafe {
            sys::ghostty_render_state_row_cells_free(self.cells);
            sys::ghostty_render_state_row_iterator_free(self.rows);
            ffi::ghostty_render_state_free(self.state);
        }
    }
}

fn out<T>(value: &mut T) -> *mut c_void {
    value as *mut T as *mut c_void
}

fn check(rc: c_int) -> Result<(), Error> {
    if rc == ffi::SUCCESS {
        Ok(())
    } else {
        Err(Error(rc))
    }
}

fn blank_style() -> ffi::Style {
    let none = ffi::StyleColor { tag: 0, value: ffi::StyleColorValue { padding: 0 } };
    ffi::Style {
        size: std::mem::size_of::<ffi::Style>(),
        fg: none,
        bg: none,
        underline_color: none,
        bold: false,
        italic: false,
        faint: false,
        blink: false,
        inverse: false,
        invisible: false,
        strikethrough: false,
        overline: false,
        underline: 0,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn struct_sizes_match_c_headers() {
        assert_eq!(std::mem::size_of::<sys::Cursor>(), 24, "Cursor");
        assert_eq!(std::mem::size_of::<sys::Colors>(), 792, "Colors");
        assert_eq!(std::mem::size_of::<sys::RowSelection>(), 16, "RowSelection");
    }

    #[test]
    fn rows_text_colours_and_cursor_come_through() {
        let mut t = Terminal::new(10, 3).unwrap();
        t.write(b"hi \x1b[31mred\x1b[0m\r\n\xe4\xb8\xad!");
        let mut view = View::new().unwrap();
        let mut cache = Vec::new();
        view.update(&t).unwrap();
        let frame = view.read(&mut cache).unwrap();
        assert_eq!((frame.cols, frame.rows), (10, 3));
        assert_eq!(frame.rows_changed, 3);
        assert_eq!(cache[0].cells[0].text, "h");
        assert_eq!(cache[0].cells[3].text, "r");
        assert!(cache[0].cells[3].fg.is_some(), "red is a colour");
        assert!(cache[0].cells[0].fg.is_none(), "default stays default");
        assert_eq!(cache[1].cells[0].text, "中");
        assert_eq!(cache[1].cells[0].width, Width::Wide);
        assert_eq!(cache[1].cells[1].width, Width::Tail);
        assert_eq!(cache[1].cells[2].text, "!");
        assert_eq!(frame.cursor.at, Some((3, 1)));
    }

    #[test]
    fn only_changed_rows_are_read_again() {
        let mut t = Terminal::new(10, 3).unwrap();
        t.write(b"one\r\ntwo\r\nthree");
        let mut view = View::new().unwrap();
        let mut cache = Vec::new();
        view.update(&t).unwrap();
        view.read(&mut cache).unwrap();

        view.update(&t).unwrap();
        assert_eq!(view.read(&mut cache).unwrap().rows_changed, 0, "nothing new");

        t.write(b"\x1b[1;1Hzzz");
        view.update(&t).unwrap();
        let frame = view.read(&mut cache).unwrap();
        // The row written, and the row the cursor left.
        assert_eq!(frame.rows_changed, 2);
        assert_eq!(cache[0].cells[0].text, "z");
        assert_eq!(cache[1].cells[0].text, "t");
    }
}
