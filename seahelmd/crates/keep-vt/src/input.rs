//! Keys and the mouse to the bytes a program reads: libghostty-vt's own
//! encoders, set from the terminal's modes on every event, so the Kitty
//! keyboard protocol, modifyOtherKeys, application cursor keys and every
//! mouse-reporting mode and format come out as Ghostty writes them.

use std::ffi::c_void;
use std::os::raw::{c_char, c_int};

use crate::{ffi, Error, Terminal};

mod raw {
    use std::ffi::c_void;
    use std::os::raw::{c_char, c_int};

    pub type KeyEncoder = *mut c_void;
    pub type KeyEvent = *mut c_void;
    pub type MouseEncoder = *mut c_void;
    pub type MouseEvent = *mut c_void;

    pub const KEY_OPT_MACOS_OPTION_AS_ALT: c_int = 6;
    pub const OPTION_AS_ALT_TRUE: c_int = 1;

    pub const MOUSE_OPT_SIZE: c_int = 2;
    pub const MOUSE_OPT_ANY_BUTTON_PRESSED: c_int = 3;
    pub const MOUSE_OPT_TRACK_LAST_CELL: c_int = 4;

    /// `GhosttyMouseEncoderSize` (40 bytes).
    #[repr(C)]
    pub struct MouseSize {
        pub size: usize,
        pub screen_width: u32,
        pub screen_height: u32,
        pub cell_width: u32,
        pub cell_height: u32,
        pub padding_top: u32,
        pub padding_bottom: u32,
        pub padding_right: u32,
        pub padding_left: u32,
    }

    /// `GhosttyMousePosition`.
    #[repr(C)]
    pub struct MousePosition {
        pub x: f32,
        pub y: f32,
    }

    extern "C" {
        pub fn ghostty_key_encoder_new(allocator: *const c_void, out: *mut KeyEncoder) -> c_int;
        pub fn ghostty_key_encoder_free(encoder: KeyEncoder);
        pub fn ghostty_key_encoder_setopt(encoder: KeyEncoder, option: c_int, value: *const c_void);
        pub fn ghostty_key_encoder_setopt_from_terminal(encoder: KeyEncoder, terminal: super::ffi::Terminal);
        pub fn ghostty_key_encoder_encode(
            encoder: KeyEncoder,
            event: KeyEvent,
            out: *mut c_char,
            out_size: usize,
            out_len: *mut usize,
        ) -> c_int;

        pub fn ghostty_key_event_new(allocator: *const c_void, out: *mut KeyEvent) -> c_int;
        pub fn ghostty_key_event_free(event: KeyEvent);
        pub fn ghostty_key_event_set_action(event: KeyEvent, action: c_int);
        pub fn ghostty_key_event_set_key(event: KeyEvent, key: c_int);
        pub fn ghostty_key_event_set_mods(event: KeyEvent, mods: u16);
        pub fn ghostty_key_event_set_consumed_mods(event: KeyEvent, mods: u16);
        pub fn ghostty_key_event_set_utf8(event: KeyEvent, utf8: *const c_char, len: usize);
        pub fn ghostty_key_event_set_unshifted_codepoint(event: KeyEvent, codepoint: u32);

        pub fn ghostty_mouse_encoder_new(allocator: *const c_void, out: *mut MouseEncoder) -> c_int;
        pub fn ghostty_mouse_encoder_free(encoder: MouseEncoder);
        pub fn ghostty_mouse_encoder_setopt(encoder: MouseEncoder, option: c_int, value: *const c_void);
        pub fn ghostty_mouse_encoder_setopt_from_terminal(encoder: MouseEncoder, terminal: super::ffi::Terminal);
        pub fn ghostty_mouse_encoder_encode(
            encoder: MouseEncoder,
            event: MouseEvent,
            out: *mut c_char,
            out_size: usize,
            out_len: *mut usize,
        ) -> c_int;

        pub fn ghostty_mouse_event_new(allocator: *const c_void, out: *mut MouseEvent) -> c_int;
        pub fn ghostty_mouse_event_free(event: MouseEvent);
        pub fn ghostty_mouse_event_set_action(event: MouseEvent, action: c_int);
        pub fn ghostty_mouse_event_set_button(event: MouseEvent, button: c_int);
        pub fn ghostty_mouse_event_clear_button(event: MouseEvent);
        pub fn ghostty_mouse_event_set_mods(event: MouseEvent, mods: u16);
        pub fn ghostty_mouse_event_set_position(event: MouseEvent, position: MousePosition);
    }
}

/// Kitty keyboard flags (`CSI > flags u`), as the program set them.
pub mod kitty {
    pub const DISAMBIGUATE: u8 = 1 << 0;
    pub const REPORT_EVENTS: u8 = 1 << 1;
    pub const REPORT_ALTERNATES: u8 = 1 << 2;
    pub const REPORT_ALL: u8 = 1 << 3;
    pub const REPORT_ASSOCIATED: u8 = 1 << 4;
}

/// Modifiers held.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Mods {
    pub shift: bool,
    pub ctrl: bool,
    pub alt: bool,
    pub super_: bool,
}

impl Mods {
    fn bits(self) -> u16 {
        (self.shift as u16) | (self.ctrl as u16) << 1 | (self.alt as u16) << 2 | (self.super_ as u16) << 3
    }
}

/// `GhosttyKey`: a physical key (W3C UI Events code), by value.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Key(c_int);

impl Key {
    pub const UNIDENTIFIED: Key = Key(0);
    pub const BACKQUOTE: Key = Key(1);
    pub const BACKSLASH: Key = Key(2);
    pub const BRACKET_LEFT: Key = Key(3);
    pub const BRACKET_RIGHT: Key = Key(4);
    pub const COMMA: Key = Key(5);
    pub const DIGIT_0: Key = Key(6);
    pub const EQUAL: Key = Key(16);
    pub const A: Key = Key(20);
    pub const MINUS: Key = Key(46);
    pub const PERIOD: Key = Key(47);
    pub const QUOTE: Key = Key(48);
    pub const SEMICOLON: Key = Key(49);
    pub const SLASH: Key = Key(50);
    pub const BACKSPACE: Key = Key(53);
    pub const ENTER: Key = Key(58);
    pub const SPACE: Key = Key(63);
    pub const TAB: Key = Key(64);
    pub const DELETE: Key = Key(68);
    pub const END: Key = Key(69);
    pub const HOME: Key = Key(71);
    pub const INSERT: Key = Key(72);
    pub const PAGE_DOWN: Key = Key(73);
    pub const PAGE_UP: Key = Key(74);
    pub const ARROW_DOWN: Key = Key(75);
    pub const ARROW_LEFT: Key = Key(76);
    pub const ARROW_RIGHT: Key = Key(77);
    pub const ARROW_UP: Key = Key(78);
    pub const ESCAPE: Key = Key(120);
    pub const F1: Key = Key(121);

    /// A letter key, `a`..=`z` (either case).
    pub fn letter(c: char) -> Option<Key> {
        let c = c.to_ascii_lowercase();
        c.is_ascii_lowercase().then(|| Key(Self::A.0 + (c as u8 - b'a') as c_int))
    }

    pub fn digit(c: char) -> Option<Key> {
        c.to_digit(10).map(|d| Key(Self::DIGIT_0.0 + d as c_int))
    }

    /// F1..=F24.
    pub fn function(n: u8) -> Option<Key> {
        (1..=24).contains(&n).then(|| Key(Self::F1.0 + (n - 1) as c_int))
    }

    /// The key a US layout puts this unshifted character on.
    pub fn for_char(c: char) -> Option<Key> {
        Self::letter(c).or_else(|| Self::digit(c)).or(match c {
            '`' => Some(Self::BACKQUOTE),
            '\\' => Some(Self::BACKSLASH),
            '[' => Some(Self::BRACKET_LEFT),
            ']' => Some(Self::BRACKET_RIGHT),
            ',' => Some(Self::COMMA),
            '=' => Some(Self::EQUAL),
            '-' => Some(Self::MINUS),
            '.' => Some(Self::PERIOD),
            '\'' => Some(Self::QUOTE),
            ';' => Some(Self::SEMICOLON),
            '/' => Some(Self::SLASH),
            ' ' => Some(Self::SPACE),
            _ => None,
        })
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum KeyAction {
    Release = 0,
    Press = 1,
    Repeat = 2,
}

/// One key event.
#[derive(Clone, Debug)]
pub struct KeyInput<'a> {
    pub key: Key,
    pub mods: Mods,
    pub action: KeyAction,
    /// The text the key produces with its modifiers (shift applied, ctrl
    /// and alt not), if any.
    pub text: Option<&'a str>,
    /// The character the key produces with no modifiers, for the Kitty
    /// protocol's key code.
    pub unshifted: Option<char>,
}

/// libghostty-vt's key encoder. Not tied to a terminal: each encode reads
/// the modes from the one it is given.
pub struct KeyEncoder {
    raw: raw::KeyEncoder,
    event: raw::KeyEvent,
}

unsafe impl Send for KeyEncoder {}

impl KeyEncoder {
    pub fn new() -> Result<Self, Error> {
        let mut raw: raw::KeyEncoder = std::ptr::null_mut();
        let rc = unsafe { raw::ghostty_key_encoder_new(std::ptr::null(), &mut raw) };
        if rc != ffi::SUCCESS || raw.is_null() {
            return Err(Error(rc));
        }
        let mut event: raw::KeyEvent = std::ptr::null_mut();
        let rc = unsafe { raw::ghostty_key_event_new(std::ptr::null(), &mut event) };
        if rc != ffi::SUCCESS || event.is_null() {
            unsafe { raw::ghostty_key_encoder_free(raw) };
            return Err(Error(rc));
        }
        Ok(Self { raw, event })
    }

    /// The bytes for `input` under `terminal`'s current modes; empty when
    /// the key says nothing (a release the program did not ask for, a bare
    /// modifier).
    pub fn encode(&mut self, terminal: &Terminal, input: &KeyInput) -> Vec<u8> {
        unsafe {
            raw::ghostty_key_encoder_setopt_from_terminal(self.raw, terminal.raw);
            // Option is alt, as the client has always treated it (and the
            // macOS app's `macos-option-as-alt`); reset by the call above.
            let as_alt: c_int = raw::OPTION_AS_ALT_TRUE;
            raw::ghostty_key_encoder_setopt(
                self.raw,
                raw::KEY_OPT_MACOS_OPTION_AS_ALT,
                &as_alt as *const c_int as *const c_void,
            );
            raw::ghostty_key_event_set_action(self.event, input.action as c_int);
            raw::ghostty_key_event_set_key(self.event, input.key.0);
            raw::ghostty_key_event_set_mods(self.event, input.mods.bits());
            // Shift is what turned the text into what it is.
            let consumed = if input.mods.shift && input.text.is_some() { 1 } else { 0 };
            raw::ghostty_key_event_set_consumed_mods(self.event, consumed);
            match input.text {
                Some(t) if !t.is_empty() => {
                    raw::ghostty_key_event_set_utf8(self.event, t.as_ptr() as *const c_char, t.len())
                }
                _ => raw::ghostty_key_event_set_utf8(self.event, std::ptr::null(), 0),
            }
            raw::ghostty_key_event_set_unshifted_codepoint(self.event, input.unshifted.map_or(0, |c| c as u32));
        }
        encode_with(|buf, len, out| unsafe { raw::ghostty_key_encoder_encode(self.raw, self.event, buf, len, out) })
    }
}

impl Drop for KeyEncoder {
    fn drop(&mut self) {
        unsafe {
            raw::ghostty_key_event_free(self.event);
            raw::ghostty_key_encoder_free(self.raw);
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MouseButton {
    Left = 1,
    Right = 2,
    Middle = 3,
    /// The wheel, one notch up / down / left / right.
    WheelUp = 4,
    WheelDown = 5,
    WheelLeft = 6,
    WheelRight = 7,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MouseAction {
    Press = 0,
    Release = 1,
    Motion = 2,
}

/// How the grid sits on the surface, in surface pixels.
#[derive(Clone, Copy, Debug)]
pub struct MouseGeometry {
    pub screen_width: u32,
    pub screen_height: u32,
    pub cell_width: u32,
    pub cell_height: u32,
    /// Padding on every side of the grid.
    pub padding: u32,
}

/// One mouse event.
#[derive(Clone, Copy, Debug)]
pub struct MouseInput {
    pub action: MouseAction,
    /// None for motion with no button held.
    pub button: Option<MouseButton>,
    pub mods: Mods,
    /// Surface pixels from the pane's top left, padding included.
    pub x: f32,
    pub y: f32,
    /// Whether any button is held (motion in button-event mode is reported
    /// only then).
    pub any_pressed: bool,
}

/// libghostty-vt's mouse encoder. Deduplicates motion within a cell, so
/// keep one per pane.
pub struct MouseEncoder {
    raw: raw::MouseEncoder,
    event: raw::MouseEvent,
}

unsafe impl Send for MouseEncoder {}

impl MouseEncoder {
    pub fn new() -> Result<Self, Error> {
        let mut raw: raw::MouseEncoder = std::ptr::null_mut();
        let rc = unsafe { raw::ghostty_mouse_encoder_new(std::ptr::null(), &mut raw) };
        if rc != ffi::SUCCESS || raw.is_null() {
            return Err(Error(rc));
        }
        let mut event: raw::MouseEvent = std::ptr::null_mut();
        let rc = unsafe { raw::ghostty_mouse_event_new(std::ptr::null(), &mut event) };
        if rc != ffi::SUCCESS || event.is_null() {
            unsafe { raw::ghostty_mouse_encoder_free(raw) };
            return Err(Error(rc));
        }
        let track = true;
        unsafe {
            raw::ghostty_mouse_encoder_setopt(raw, raw::MOUSE_OPT_TRACK_LAST_CELL, &track as *const bool as *const c_void)
        };
        Ok(Self { raw, event })
    }

    /// The bytes for `input` under `terminal`'s mouse modes; empty when the
    /// program has not asked for this kind of event.
    pub fn encode(&mut self, terminal: &Terminal, geometry: MouseGeometry, input: &MouseInput) -> Vec<u8> {
        let size = raw::MouseSize {
            size: std::mem::size_of::<raw::MouseSize>(),
            screen_width: geometry.screen_width.max(1),
            screen_height: geometry.screen_height.max(1),
            cell_width: geometry.cell_width.max(1),
            cell_height: geometry.cell_height.max(1),
            padding_top: geometry.padding,
            padding_bottom: geometry.padding,
            padding_right: geometry.padding,
            padding_left: geometry.padding,
        };
        unsafe {
            raw::ghostty_mouse_encoder_setopt_from_terminal(self.raw, terminal.raw);
            raw::ghostty_mouse_encoder_setopt(self.raw, raw::MOUSE_OPT_SIZE, &size as *const raw::MouseSize as *const c_void);
            raw::ghostty_mouse_encoder_setopt(
                self.raw,
                raw::MOUSE_OPT_ANY_BUTTON_PRESSED,
                &input.any_pressed as *const bool as *const c_void,
            );
            raw::ghostty_mouse_event_set_action(self.event, input.action as c_int);
            match input.button {
                Some(b) => raw::ghostty_mouse_event_set_button(self.event, b as c_int),
                None => raw::ghostty_mouse_event_clear_button(self.event),
            }
            raw::ghostty_mouse_event_set_mods(self.event, input.mods.bits());
            raw::ghostty_mouse_event_set_position(self.event, raw::MousePosition { x: input.x, y: input.y });
        }
        encode_with(|buf, len, out| unsafe { raw::ghostty_mouse_encoder_encode(self.raw, self.event, buf, len, out) })
    }
}

impl Drop for MouseEncoder {
    fn drop(&mut self) {
        unsafe {
            raw::ghostty_mouse_event_free(self.event);
            raw::ghostty_mouse_encoder_free(self.raw);
        }
    }
}

/// Run an encoder into a stack buffer, retrying with the size it asks for.
fn encode_with(mut f: impl FnMut(*mut c_char, usize, *mut usize) -> c_int) -> Vec<u8> {
    let mut buf = [0u8; 128];
    let mut len = 0usize;
    match f(buf.as_mut_ptr() as *mut c_char, buf.len(), &mut len) {
        ffi::SUCCESS => buf[..len.min(buf.len())].to_vec(),
        ffi::OUT_OF_SPACE if len > 0 => {
            let mut big = vec![0u8; len];
            let mut got = 0usize;
            if f(big.as_mut_ptr() as *mut c_char, big.len(), &mut got) == ffi::SUCCESS {
                big.truncate(got);
                big
            } else {
                Vec::new()
            }
        }
        _ => Vec::new(),
    }
}

impl Terminal {
    /// Whether the program asked for mouse events (X10, normal, button or
    /// any-event tracking).
    pub fn mouse_tracking(&self) -> bool {
        [9, 1000, 1002, 1003].iter().any(|&m| self.dec_mode(m))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn press<'a>(key: Key, mods: Mods, text: Option<&'a str>, unshifted: Option<char>) -> KeyInput<'a> {
        KeyInput { key, mods, action: KeyAction::Press, text, unshifted }
    }

    const NONE: Mods = Mods { shift: false, ctrl: false, alt: false, super_: false };
    const SHIFT: Mods = Mods { shift: true, ctrl: false, alt: false, super_: false };
    const CTRL: Mods = Mods { shift: false, ctrl: true, alt: false, super_: false };

    #[test]
    fn legacy_keys() {
        let t = Terminal::new(80, 24).unwrap();
        let mut e = KeyEncoder::new().unwrap();
        assert_eq!(e.encode(&t, &press(Key::A, NONE, Some("a"), Some('a'))), b"a");
        assert_eq!(e.encode(&t, &press(Key::letter('c').unwrap(), CTRL, None, Some('c'))), vec![3]);
        assert_eq!(e.encode(&t, &press(Key::ENTER, NONE, None, None)), b"\r");
        assert_eq!(e.encode(&t, &press(Key::ARROW_UP, NONE, None, None)), b"\x1b[A");
        assert_eq!(e.encode(&t, &press(Key::ARROW_UP, SHIFT, None, None)), b"\x1b[1;2A");
    }

    #[test]
    fn application_cursor_keys_follow_the_terminal() {
        let mut t = Terminal::new(80, 24).unwrap();
        t.write(b"\x1b[?1h");
        let mut e = KeyEncoder::new().unwrap();
        assert_eq!(e.encode(&t, &press(Key::ARROW_UP, NONE, None, None)), b"\x1bOA");
    }

    #[test]
    fn kitty_flags_follow_the_terminal() {
        let mut t = Terminal::new(80, 24).unwrap();
        t.write(b"\x1b[>1u");
        assert_eq!(t.kitty_keyboard_flags(), kitty::DISAMBIGUATE);
        let mut e = KeyEncoder::new().unwrap();
        assert_eq!(e.encode(&t, &press(Key::ENTER, SHIFT, None, None)), b"\x1b[13;2u");
        // Plain text stays text under disambiguate.
        assert_eq!(e.encode(&t, &press(Key::A, NONE, Some("a"), Some('a'))), b"a");
        // Releases only when the program asked for event types.
        let release = KeyInput { action: KeyAction::Release, ..press(Key::A, NONE, Some("a"), Some('a')) };
        assert!(e.encode(&t, &release).is_empty());
        t.write(b"\x1b[>3u");
        assert_eq!(e.encode(&t, &release), b"\x1b[97;1:3u");
    }

    #[test]
    fn option_is_alt() {
        let t = Terminal::new(80, 24).unwrap();
        let mut e = KeyEncoder::new().unwrap();
        let alt = Mods { alt: true, ..NONE };
        assert_eq!(e.encode(&t, &press(Key::letter('b').unwrap(), alt, Some("b"), Some('b'))), b"\x1bb");
    }

    const GEO: MouseGeometry = MouseGeometry { screen_width: 816, screen_height: 400, cell_width: 10, cell_height: 20, padding: 8 };

    fn mouse_at(action: MouseAction, button: Option<MouseButton>, col: u32, row: u32) -> MouseInput {
        MouseInput {
            action,
            button,
            mods: NONE,
            x: (8 + col * 10 + 5) as f32,
            y: (8 + row * 20 + 10) as f32,
            any_pressed: action == MouseAction::Press,
        }
    }

    #[test]
    fn no_mouse_report_unless_asked() {
        let t = Terminal::new(80, 19).unwrap();
        assert!(!t.mouse_tracking());
        let mut e = MouseEncoder::new().unwrap();
        assert!(e.encode(&t, GEO, &mouse_at(MouseAction::Press, Some(MouseButton::Left), 3, 4)).is_empty());
    }

    #[test]
    fn sgr_mouse_reports() {
        let mut t = Terminal::new(80, 19).unwrap();
        t.write(b"\x1b[?1000h\x1b[?1006h");
        assert!(t.mouse_tracking());
        let mut e = MouseEncoder::new().unwrap();
        assert_eq!(e.encode(&t, GEO, &mouse_at(MouseAction::Press, Some(MouseButton::Left), 3, 4)), b"\x1b[<0;4;5M");
        assert_eq!(
            e.encode(&t, GEO, &MouseInput { any_pressed: false, ..mouse_at(MouseAction::Release, Some(MouseButton::Left), 3, 4) }),
            b"\x1b[<0;4;5m"
        );
        assert_eq!(e.encode(&t, GEO, &mouse_at(MouseAction::Press, Some(MouseButton::WheelUp), 0, 0)), b"\x1b[<64;1;1M");
        // Motion with no button is reported only in any-event mode.
        assert!(e.encode(&t, GEO, &MouseInput { any_pressed: false, ..mouse_at(MouseAction::Motion, None, 5, 5) }).is_empty());
        t.write(b"\x1b[?1003h");
        assert_eq!(
            e.encode(&t, GEO, &MouseInput { any_pressed: false, ..mouse_at(MouseAction::Motion, None, 6, 5) }),
            b"\x1b[<35;7;6M"
        );
    }
}
