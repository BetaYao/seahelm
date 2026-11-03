//! What a terminal does with what a program says to it, beyond the screen.
//!
//! A program asks its terminal things — where the cursor is, what colour the
//! background is, which keyboard protocol it speaks — and tells it things: a
//! title, the directory it is in, text for the clipboard. A terminal somebody
//! is looking at answers and acts on all of it. This one does so only when
//! asked: to answer the questions nobody else is there to answer
//! ([`Terminal::answer_queries`], the daemon's grid on Windows), or to stand
//! in for a terminal that is not drawing at the moment
//! ([`Terminal::act_as_terminal`], a tab put to sleep by the app, whose
//! program must find its terminal still there).

use std::ffi::c_void;
use std::os::raw::c_int;

use crate::{Error, Terminal, ffi};

/// How much unanswered reply is kept. A program asking the same question in
/// a loop with nobody collecting must not grow this without end.
const REPLY_LIMIT: usize = 64 * 1024;
/// The clipboard read for a program, as base64 — a reply a surface sends
/// whatever its size, and that is read once.
const CLIPBOARD_REPLY_LIMIT: usize = 64 << 20;

/// What the terminal being stood in for would say about itself.
///
/// Each one left out is a question left as libghostty-vt answers it on its
/// own — or unanswered, where it has nothing to say (the colours, the size in
/// pixels, the colour scheme).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Facts {
    /// The default foreground, background and cursor colours, as OSC 10, 11
    /// and 12 report them.
    pub foreground: Option<[u8; 3]>,
    pub background: Option<[u8; 3]>,
    pub cursor: Option<[u8; 3]>,
    /// The 256 colours of the palette, as OSC 4 reports them.
    pub palette: Option<Vec<[u8; 3]>>,
    /// Dark or light, as CSI ? 996 n reports it.
    pub dark: Option<bool>,
    /// A cell's width and height in pixels, for CSI 14/16 t and mode 2048.
    pub cell: Option<(u32, u32)>,
    /// What CSI > q is answered with: "ghostty 1.3.2", say.
    pub xtversion: Option<String>,
    /// The device attributes (CSI c, CSI > c, CSI = c).
    pub device: Option<Device>,
    /// The terminfo entry the terminal says it runs as, to XTGETTCAP `TN`:
    /// "xterm-ghostty", say. Unanswered where unknown.
    pub terminfo: Option<String>,
}

/// The answers to CSI c, CSI > c and CSI = c.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Device {
    pub conformance: u16,
    pub features: Vec<u16>,
    pub device_type: u16,
    pub firmware: u16,
    pub rom: u16,
    /// Whether CSI = c is answered at all. Ghostty leaves it unanswered;
    /// libghostty-vt answers it whenever it answers the other two.
    pub tertiary: Option<u32>,
}

/// What a program did since this was last asked.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Events {
    /// The answers to its questions, for the program, in order.
    pub replies: Vec<u8>,
    /// It renamed itself (OSC 0/2): `Terminal::title` has the name.
    pub title: bool,
    /// It said where it is (OSC 7): `Terminal::pwd` has the place.
    pub pwd: bool,
    /// The text it put on the clipboard (OSC 52), oldest first.
    pub clipboard: Vec<Vec<u8>>,
}

/// What a program reading the clipboard (OSC 52 `?`) is answered with, as
/// the terminal stood in for would answer it.
pub enum ClipboardAnswer {
    /// The clipboard's text — empty, where the person said no.
    Text(Vec<u8>),
    /// Nothing at all: a terminal whose config denies reading the clipboard
    /// leaves the question unanswered.
    Nothing,
}

/// Asked for the answer each time a program reads the clipboard, with the
/// clipboard it named as the answer names it — `c`, `s` or `p`. May take its
/// time (asking the person), the stream waiting meanwhile; or answer
/// `Nothing` and have the answer written by whoever asked for it later, in
/// those words (`\e]52;c;<base64>\e\\`).
pub type ClipboardReader = Box<dyn FnMut(u8) -> ClipboardAnswer + Send>;

pub(crate) struct Effects {
    events: Events,
    /// Who answers a program reading the clipboard; see `read_clipboard_with`.
    reader: Option<ClipboardReader>,
    /// The library answers a read whatever the reply says: the answer to one
    /// meant to go unanswered is taken out as it is written.
    unanswered: bool,
    /// The OSC the stream is ending as the reader is asked: 52 is the
    /// clipboard a surface reads; 5522, the Kitty protocol, it does not.
    pub(crate) osc: Option<u32>,
    /// Where the stream is, for `osc_ends`: 0 elsewhere, 1 after ESC, 2 in
    /// an OSC's number, 3 in its text.
    scan: u8,
    number: u32,
    facts: Facts,
    /// The XTVERSION answer, kept here because the library reads it after
    /// the callback has returned the pointer.
    xtversion: Vec<u8>,
    /// Inside a CSI = c that the terminal stood in for leaves unanswered.
    quiet: bool,
    /// The start of a CSI = c that the last write ended in the middle of.
    pending: Vec<u8>,
    /// Whether the callbacks beyond the answers are set: standing in.
    standing_in: bool,
}

impl Effects {
    fn new() -> Self {
        Self {
            events: Events::default(),
            reader: None,
            unanswered: false,
            osc: None,
            scan: 0,
            number: 0,
            facts: Facts::default(),
            xtversion: Vec::new(),
            quiet: false,
            pending: Vec::new(),
            standing_in: false,
        }
    }

    /// A write is over: whatever answer to a clipboard read it was to leave
    /// out has been, or will not come.
    pub(crate) fn answered_clipboard(&mut self) {
        self.unanswered = false;
    }

    pub(crate) fn reads_clipboard(&self) -> bool {
        self.reader.is_some()
    }

    /// Whether writes go in OSC by OSC, for the clipboard's callbacks to
    /// know which protocol is speaking: standing in, or reading for one.
    pub(crate) fn follows_oscs(&self) -> bool {
        self.standing_in || self.reader.is_some()
    }

    /// Where in `data` an OSC ends — the byte on which the terminal acts on
    /// it: BEL, or the ESC that ends it (an ST's or any other) — and its
    /// number. Followed across writes.
    pub(crate) fn osc_ends(&mut self, data: &[u8]) -> Vec<(usize, u32)> {
        let mut ends = Vec::new();
        for (at, &byte) in data.iter().enumerate() {
            self.scan = match (self.scan, byte) {
                (2 | 3, 0x07) => {
                    ends.push((at, self.number));
                    0
                }
                (2 | 3, 0x1b) => {
                    ends.push((at, self.number));
                    1
                }
                (2 | 3, 0x18 | 0x1a) => 0,
                (2, b'0'..=b'9') => {
                    self.number = self.number.saturating_mul(10).saturating_add(u32::from(byte - b'0'));
                    2
                }
                (2 | 3, _) => 3,
                (1, b']') => {
                    self.number = 0;
                    2
                }
                (_, 0x1b) => 1,
                _ => 0,
            };
        }
        ends
    }

    /// Whether writes have to look for CSI = c on their way in.
    pub(crate) fn screens_tertiary(&self) -> bool {
        self.standing_in
            && self.facts.device.as_ref().map(|d| d.tertiary.is_none()).unwrap_or(false)
    }

    /// About to write the last byte of a CSI = c: how much has been said
    /// so far, for `unsay`.
    pub(crate) fn set_quiet(&mut self, quiet: bool) -> usize {
        self.quiet = quiet;
        self.events.replies.len()
    }

    /// Take back whatever was answered since `set_quiet` said `before`.
    pub(crate) fn unsay(&mut self, before: usize) {
        self.quiet = false;
        self.events.replies.truncate(before);
    }

    /// Where in `data` each CSI = c (or CSI = 0 c) ends: the byte on which
    /// the terminal would answer it. A query begun in the last write and
    /// finished in this one counts, at its final byte here.
    pub(crate) fn tertiary_queries(&mut self, data: &[u8]) -> Vec<usize> {
        let mut cuts = Vec::new();
        let mut stream = std::mem::take(&mut self.pending);
        let carried = stream.len();
        stream.extend_from_slice(data);
        let mut at = 0;
        while at < stream.len() {
            if stream[at] != 0x1b {
                at += 1;
                continue;
            }
            // ESC [ = [0] c, nothing else.
            let rest = &stream[at..];
            let mut matched = None;
            for query in [&b"\x1b[=c"[..], &b"\x1b[=0c"[..]] {
                if rest.len() >= query.len() {
                    if rest.starts_with(query) {
                        matched = Some(query.len());
                        break;
                    }
                } else if query.starts_with(rest) {
                    // The write ends inside what may be one.
                    self.pending = rest.to_vec();
                    return cuts;
                }
            }
            match matched {
                Some(len) => {
                    let end = at + len - 1;
                    if end >= carried {
                        cuts.push(end - carried);
                    }
                    at += len;
                }
                None => at += 1,
            }
        }
        cuts
    }
}

unsafe fn effects<'a>(userdata: *mut c_void) -> Option<&'a mut Effects> {
    if userdata.is_null() {
        None
    } else {
        Some(unsafe { &mut *(userdata as *mut Effects) })
    }
}

unsafe extern "C" fn on_write_pty(
    _terminal: ffi::Terminal,
    userdata: *mut c_void,
    data: *const u8,
    len: usize,
) {
    let Some(effects) = (unsafe { effects(userdata) }) else { return };
    if data.is_null() || len == 0 {
        return;
    }
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    // Reading the clipboard makes the library speak the Kitty protocol's
    // paste events (mode 5522), which a Ghostty surface does not: said
    // unknown, as the surface says it.
    if effects.reads_clipboard()
        && bytes.starts_with(b"\x1b[?5522;")
        && bytes.ends_with(b"$y")
    {
        if effects.events.replies.len() + len <= REPLY_LIMIT {
            effects.events.replies.extend_from_slice(b"\x1b[?5522;0$y");
        }
        return;
    }
    if effects.standing_in {
        // The Kitty clipboard protocol, which a Ghostty surface leaves
        // unanswered whatever is asked of it.
        if bytes.starts_with(b"\x1b]5522;") {
            return;
        }
        if bytes.starts_with(b"\x1b]52;") {
            if effects.unanswered {
                effects.unanswered = false;
                return;
            }
            // A Ghostty surface ends its answer with ST whatever the
            // question ended with; the library answers in kind.
            let body = bytes.strip_suffix(b"\x07");
            if effects.events.replies.len() + len + 1 <= CLIPBOARD_REPLY_LIMIT {
                effects.events.replies.extend_from_slice(body.unwrap_or(bytes));
                if body.is_some() {
                    effects.events.replies.extend_from_slice(b"\x1b\\");
                }
            }
            return;
        }
    }
    if effects.events.replies.len() + len <= REPLY_LIMIT {
        effects.events.replies.extend_from_slice(bytes);
    }
}

unsafe extern "C" fn on_title(_terminal: ffi::Terminal, userdata: *mut c_void) {
    if let Some(effects) = unsafe { effects(userdata) } {
        effects.events.title = true;
    }
}

unsafe extern "C" fn on_pwd(_terminal: ffi::Terminal, userdata: *mut c_void) {
    if let Some(effects) = unsafe { effects(userdata) } {
        effects.events.pwd = true;
    }
}

unsafe extern "C" fn on_xtversion(_terminal: ffi::Terminal, userdata: *mut c_void) -> ffi::GhosttyString {
    match unsafe { effects(userdata) } {
        // Empty means libghostty's own answer.
        Some(effects) => ffi::GhosttyString { ptr: effects.xtversion.as_ptr(), len: effects.xtversion.len() },
        None => ffi::GhosttyString { ptr: std::ptr::null(), len: 0 },
    }
}

unsafe extern "C" fn on_size(
    terminal: ffi::Terminal,
    userdata: *mut c_void,
    out: *mut ffi::SizeReportSize,
) -> bool {
    let Some(effects) = (unsafe { effects(userdata) }) else { return false };
    let Some((width, height)) = effects.facts.cell else { return false };
    if out.is_null() {
        return false;
    }
    let get = |data: c_int| {
        let mut value: u16 = 0;
        let rc = unsafe { ffi::ghostty_terminal_get(terminal, data, &mut value as *mut u16 as *mut c_void) };
        if rc == ffi::SUCCESS { value } else { 0 }
    };
    unsafe {
        *out = ffi::SizeReportSize {
            rows: get(ffi::DATA_ROWS),
            columns: get(ffi::DATA_COLS),
            cell_width: width,
            cell_height: height,
        };
    }
    true
}

unsafe extern "C" fn on_scheme(_terminal: ffi::Terminal, userdata: *mut c_void, out: *mut c_int) -> bool {
    let Some(effects) = (unsafe { effects(userdata) }) else { return false };
    let Some(dark) = effects.facts.dark else { return false };
    if out.is_null() {
        return false;
    }
    unsafe { *out = if dark { 1 } else { 0 } };
    true
}

unsafe extern "C" fn on_device(
    _terminal: ffi::Terminal,
    userdata: *mut c_void,
    out: *mut ffi::DeviceAttributes,
) -> bool {
    let Some(effects) = (unsafe { effects(userdata) }) else { return false };
    if effects.quiet || out.is_null() {
        return false;
    }
    let Some(device) = effects.facts.device.as_ref() else { return false };
    let mut features = [0u16; 64];
    let count = device.features.len().min(64);
    features[..count].copy_from_slice(&device.features[..count]);
    unsafe {
        *out = ffi::DeviceAttributes {
            primary: ffi::DeviceAttributesPrimary {
                conformance_level: device.conformance,
                features,
                num_features: count,
            },
            secondary: ffi::DeviceAttributesSecondary {
                device_type: device.device_type,
                firmware_version: device.firmware,
                rom_cartridge: device.rom,
            },
            tertiary: ffi::DeviceAttributesTertiary { unit_id: device.tertiary.unwrap_or(0) },
        };
    }
    true
}

unsafe extern "C" fn on_clipboard(
    _terminal: ffi::Terminal,
    userdata: *mut c_void,
    write: *const ffi::ClipboardWrite,
) -> c_int {
    let Some(effects) = (unsafe { effects(userdata) }) else { return ffi::CLIPBOARD_WRITE_DENIED };
    if write.is_null() {
        return ffi::CLIPBOARD_WRITE_DENIED;
    }
    let write = unsafe { &*write };
    // The standard clipboard, as the app writes it: a Mac has no other. And
    // by OSC 52, the one way a Ghostty surface takes a program's text: not
    // iTerm2's OSC 1337 nor the Kitty protocol's OSC 5522.
    if write.location != ffi::CLIPBOARD_LOCATION_STANDARD || effects.osc != Some(52) {
        return ffi::CLIPBOARD_WRITE_DENIED;
    }
    let contents: &[ffi::ClipboardContent] = if write.contents.is_null() || write.contents_len == 0 {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(write.contents, write.contents_len) }
    };
    let text = contents.iter().find_map(|content| {
        let mime = bytes(content.mime);
        (mime.is_empty() || mime.starts_with(b"text/")).then(|| bytes(content.data).to_vec())
    });
    // Taken, said both ways: by the reply where the library hands one over,
    // and by what is returned, which is how the pinned library hears it.
    let Some(text) = text.filter(|t| !t.is_empty()) else { return ffi::CLIPBOARD_WRITE_DENIED };
    effects.events.clipboard.push(text);
    if let Some(reply) = write.reply_fn() {
        let answer = ffi::ClipboardWriteReply {
            size: std::mem::size_of::<ffi::ClipboardWriteReply>(),
            result: ffi::CLIPBOARD_WRITE_SUCCESS,
            remember: false,
        };
        unsafe { reply(write, &answer) };
    }
    ffi::CLIPBOARD_WRITE_SUCCESS
}

unsafe extern "C" fn on_clipboard_read(
    _terminal: ffi::Terminal,
    userdata: *mut c_void,
    read: *const ffi::ClipboardRead,
) {
    let Some(effects) = (unsafe { effects(userdata) }) else { return };
    if read.is_null() {
        return;
    }
    let request = unsafe { &*read };
    let Some(reply) = request.reply else { return };
    // OSC 52 only: the Kitty protocol's read (OSC 5522) is refused — and
    // the refusal not written (`on_write_pty`), a surface leaving the
    // protocol unanswered. Whichever clipboard OSC 52 names, the standard
    // one is read, as a Ghostty surface reads it.
    if effects.osc != Some(52) {
        let refused = ffi::ClipboardReadReply {
            size: std::mem::size_of::<ffi::ClipboardReadReply>(),
            result: ffi::CLIPBOARD_READ_DENIED,
            contents: std::ptr::null(),
            contents_len: 0,
            available: std::ptr::null(),
            available_len: 0,
            remember: false,
        };
        unsafe { reply(read, &refused) };
        return;
    }
    let kind = match request.location {
        ffi::CLIPBOARD_LOCATION_SELECTION => b's',
        ffi::CLIPBOARD_LOCATION_PRIMARY => b'p',
        _ => b'c',
    };
    let answer = match effects.reader.as_mut() {
        Some(reader) => reader(kind),
        None => ClipboardAnswer::Nothing,
    };
    let mime = b"text/plain";
    match answer {
        ClipboardAnswer::Text(text) => {
            let content = ffi::ClipboardContent {
                mime: ffi::GhosttyString { ptr: mime.as_ptr(), len: mime.len() },
                data: ffi::GhosttyString { ptr: text.as_ptr(), len: text.len() },
            };
            let answer = ffi::ClipboardReadReply {
                size: std::mem::size_of::<ffi::ClipboardReadReply>(),
                result: ffi::CLIPBOARD_READ_SUCCESS,
                contents: &content,
                contents_len: 1,
                available: std::ptr::null(),
                available_len: 0,
                remember: false,
            };
            unsafe { reply(read, &answer) };
        }
        ClipboardAnswer::Nothing => {
            effects.unanswered = true;
            let answer = ffi::ClipboardReadReply {
                size: std::mem::size_of::<ffi::ClipboardReadReply>(),
                result: ffi::CLIPBOARD_READ_DENIED,
                contents: std::ptr::null(),
                contents_len: 0,
                available: std::ptr::null(),
                available_len: 0,
                remember: false,
            };
            unsafe { reply(read, &answer) };
        }
    }
}

fn bytes<'a>(s: ffi::GhosttyString) -> &'a [u8] {
    if s.ptr.is_null() || s.len == 0 {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(s.ptr, s.len) }
    }
}

impl Terminal {
    fn effects_box(&mut self) -> Result<&mut Effects, Error> {
        if self.effects.is_none() {
            let mut boxed = Box::new(Effects::new());
            let userdata = &mut *boxed as *mut Effects as *const c_void;
            self.set(ffi::OPT_USERDATA, userdata)?;
            self.effects = Some(boxed);
        }
        Ok(self.effects.as_mut().expect("just made"))
    }

    fn set(&mut self, option: c_int, value: *const c_void) -> Result<(), Error> {
        let rc = unsafe { ffi::ghostty_terminal_set(self.raw, option, value) };
        if rc != ffi::SUCCESS {
            return Err(Error(rc));
        }
        Ok(())
    }

    /// Have the terminal answer what programs ask of it — where the cursor
    /// is, which modes are set — into a buffer, collected with
    /// [`Terminal::take_replies`].
    ///
    /// By default the questions go unanswered here, because whoever is
    /// watching the tab answers them; this is for when nobody is.
    pub fn answer_queries(&mut self) -> Result<(), Error> {
        self.effects_box()?;
        let callback: ffi::WritePtyFn = on_write_pty;
        self.set(ffi::OPT_WRITE_PTY, callback as *const c_void)
    }

    /// The answers written since the last call, oldest first.
    pub fn take_replies(&mut self) -> Vec<u8> {
        self.effects.as_mut().map(|e| std::mem::take(&mut e.events.replies)).unwrap_or_default()
    }

    /// Stand in for a terminal somebody is using: answer the program as
    /// that terminal would (`facts`), and note what it says about itself —
    /// collected with [`Terminal::take_events`].
    pub fn act_as_terminal(&mut self, facts: Facts) -> Result<(), Error> {
        let effects = self.effects_box()?;
        effects.xtversion = facts.xtversion.clone().unwrap_or_default().into_bytes();
        effects.facts = facts.clone();
        effects.standing_in = true;
        let write: ffi::WritePtyFn = on_write_pty;
        let title: ffi::TitleChangedFn = on_title;
        let pwd: ffi::PwdChangedFn = on_pwd;
        let xtversion: ffi::XtversionFn = on_xtversion;
        let size: ffi::SizeFn = on_size;
        let scheme: ffi::ColorSchemeFn = on_scheme;
        let device: ffi::DeviceAttributesFn = on_device;
        let clipboard: ffi::ClipboardWriteFn = on_clipboard;
        self.set(ffi::OPT_WRITE_PTY, write as *const c_void)?;
        self.set(ffi::OPT_TITLE_CHANGED, title as *const c_void)?;
        self.set(ffi::OPT_PWD_CHANGED, pwd as *const c_void)?;
        if facts.xtversion.is_some() {
            self.set(ffi::OPT_XTVERSION, xtversion as *const c_void)?;
        }
        self.set(ffi::OPT_SIZE, size as *const c_void)?;
        self.set(ffi::OPT_COLOR_SCHEME, scheme as *const c_void)?;
        if facts.device.is_some() {
            self.set(ffi::OPT_DEVICE_ATTRIBUTES, device as *const c_void)?;
        }
        self.set(ffi::OPT_CLIPBOARD_WRITE, clipboard as *const c_void)?;
        // The library copies the name; none clears it.
        let name = facts.terminfo.as_deref().unwrap_or_default().as_bytes();
        let name = ffi::GhosttyString { ptr: name.as_ptr(), len: name.len() };
        self.set(ffi::OPT_TERMINFO_NAME, &name as *const ffi::GhosttyString as *const c_void)?;
        self.set_default_colors(&facts)
    }

    /// Answer a program reading the clipboard (OSC 52 `?`) as `reader`
    /// says, standing in for a terminal that would have read it.
    pub fn read_clipboard_with(&mut self, reader: ClipboardReader) -> Result<(), Error> {
        let effects = self.effects_box()?;
        effects.reader = Some(reader);
        let callback: ffi::ClipboardReadFn = on_clipboard_read;
        self.set(ffi::OPT_CLIPBOARD_READ, callback as *const c_void)
    }

    /// The colours the terminal starts from, before any program changes
    /// them: what OSC 10, 11, 12 and 4 report when asked, and what a program
    /// resetting a colour gets back.
    pub fn set_default_colors(&mut self, facts: &Facts) -> Result<(), Error> {
        let rgb = |c: [u8; 3]| ffi::ColorRgb { r: c[0], g: c[1], b: c[2] };
        for (option, colour) in [
            (ffi::OPT_COLOR_FOREGROUND, facts.foreground),
            (ffi::OPT_COLOR_BACKGROUND, facts.background),
            (ffi::OPT_COLOR_CURSOR, facts.cursor),
        ] {
            if let Some(colour) = colour {
                let value = rgb(colour);
                self.set(option, &value as *const ffi::ColorRgb as *const c_void)?;
            }
        }
        if let Some(palette) = facts.palette.as_ref().filter(|p| p.len() == 256) {
            let values: Vec<ffi::ColorRgb> = palette.iter().map(|&c| rgb(c)).collect();
            self.set(ffi::OPT_COLOR_PALETTE, values.as_ptr() as *const c_void)?;
        }
        Ok(())
    }

    /// What the program did since the last call: its answers waiting to be
    /// sent, whether it renamed itself or moved, what it copied.
    pub fn take_events(&mut self) -> Events {
        self.effects.as_mut().map(|e| std::mem::take(&mut e.events)).unwrap_or_default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// What a Ghostty surface answers, measured in Keep (tools/hibernate-test.sh
    /// measures it again against the build under test).
    pub(crate) fn ghostty() -> Facts {
        Facts {
            foreground: Some([0xff, 0xff, 0xff]),
            background: Some([0x28, 0x2c, 0x34]),
            cursor: Some([0xff, 0xff, 0xff]),
            palette: None,
            dark: Some(false),
            cell: Some((16, 34)),
            xtversion: Some("ghostty 1.3.2-HEAD-+a53771a".into()),
            device: Some(Device {
                conformance: 62,
                features: vec![22, 52],
                device_type: 1,
                firmware: 10,
                rom: 0,
                tertiary: None,
            }),
            terminfo: Some("xterm-ghostty".into()),
        }
    }

    fn answer(t: &mut Terminal, query: &[u8]) -> String {
        t.write(query);
        String::from_utf8_lossy(&t.take_events().replies).into_owned()
    }

    /// XTGETTCAP `TN`: the terminfo entry it runs as, in hex, as a Ghostty
    /// surface answers; nothing where it is not known.
    #[test]
    fn it_names_the_terminfo_entry_it_runs_as() {
        let mut t = Terminal::new(80, 24).unwrap();
        t.act_as_terminal(ghostty()).unwrap();
        assert_eq!(answer(&mut t, b"\x1bP+q544E\x1b\\"), "\x1bP1+r544E=787465726D2D67686F73747479\x1b\\");
        t.act_as_terminal(Facts { terminfo: None, ..ghostty() }).unwrap();
        assert_eq!(answer(&mut t, b"\x1bP+q544E\x1b\\\x1b[5n"), "\x1b[0n");
    }

    #[test]
    fn it_answers_as_the_terminal_it_stands_in_for() {
        let mut t = Terminal::new(105, 38).unwrap();
        t.act_as_terminal(ghostty()).unwrap();
        assert_eq!(answer(&mut t, b"\x1b[c"), "\x1b[?62;22;52c");
        assert_eq!(answer(&mut t, b"\x1b[>c"), "\x1b[>1;10;0c");
        assert_eq!(answer(&mut t, b"\x1b[=c"), "", "Ghostty leaves CSI = c unanswered");
        assert_eq!(answer(&mut t, b"\x1b[=0c"), "");
        assert_eq!(answer(&mut t, b"\x1b[>q"), "\x1bP>|ghostty 1.3.2-HEAD-+a53771a\x1b\\");
        assert_eq!(answer(&mut t, b"\x1b]11;?\x1b\\"), "\x1b]11;rgb:2828/2c2c/3434\x1b\\");
        assert_eq!(answer(&mut t, b"\x1b]10;?\x1b\\"), "\x1b]10;rgb:ffff/ffff/ffff\x1b\\");
        assert_eq!(answer(&mut t, b"\x1b]12;?\x1b\\"), "\x1b]12;rgb:ffff/ffff/ffff\x1b\\");
        assert_eq!(answer(&mut t, b"\x1b[?996n"), "\x1b[?997;2n");
        assert_eq!(answer(&mut t, b"\x1b[14t"), "\x1b[4;1292;1680t");
        assert_eq!(answer(&mut t, b"\x1b[16t"), "\x1b[6;34;16t");
        assert_eq!(answer(&mut t, b"\x1b[18t"), "\x1b[8;38;105t");
        assert_eq!(answer(&mut t, b"\x1b[?u"), "\x1b[?0u");
        // The answer to CSI c around a CSI = c, in one write, still comes.
        assert_eq!(answer(&mut t, b"\x1b[=c\x1b[c\x1b[=0c"), "\x1b[?62;22;52c");
    }

    #[test]
    fn a_query_split_across_writes_is_still_seen() {
        let mut t = Terminal::new(80, 24).unwrap();
        t.act_as_terminal(ghostty()).unwrap();
        t.write(b"text \x1b[");
        t.write(b"=");
        assert_eq!(answer(&mut t, b"c and more"), "", "the CSI = c split in three is not answered");
        t.write(b"\x1b");
        assert_eq!(answer(&mut t, b"[c"), "\x1b[?62;22;52c", "a CSI c split in two is");
    }

    #[test]
    fn what_the_program_says_about_itself_is_noted() {
        let mut t = Terminal::new(80, 24).unwrap();
        t.act_as_terminal(ghostty()).unwrap();
        t.write(b"\x1b]2;building\x07\x1b]7;file://host/tmp/x\x07\x1b]52;c;aGVsbG8=\x07");
        let events = t.take_events();
        assert!(events.title);
        assert_eq!(t.title(), "building");
        assert!(events.pwd);
        assert_eq!(t.pwd(), "file://host/tmp/x");
        assert_eq!(events.clipboard, vec![b"hello".to_vec()]);
        assert_eq!(t.take_events(), Events::default(), "collected once");
    }

    /// A program reading the clipboard gets what the reader says, in the
    /// form a Ghostty surface answers it; a reader saying nothing leaves it
    /// unanswered, as a surface whose config denies it does.
    #[test]
    fn a_program_reading_the_clipboard_is_answered_as_the_reader_says() {
        let mut t = Terminal::new(80, 24).unwrap();
        t.act_as_terminal(ghostty()).unwrap();
        let answers = std::sync::Arc::new(std::sync::Mutex::new(vec![
            ClipboardAnswer::Text(b"pasted".to_vec()),
            ClipboardAnswer::Text(Vec::new()),
            ClipboardAnswer::Nothing,
        ]));
        let feed = std::sync::Arc::clone(&answers);
        t.read_clipboard_with(Box::new(move |_| feed.lock().unwrap().remove(0))).unwrap();
        assert_eq!(answer(&mut t, b"\x1b]52;c;?\x1b\\"), "\x1b]52;c;cGFzdGVk\x1b\\");
        assert_eq!(answer(&mut t, b"\x1b]52;c;?\x07"), "\x1b]52;c;\x1b\\", "the person said no");
        assert_eq!(answer(&mut t, b"\x1b]52;c;?\x1b\\\x1b[5n"), "\x1b[0n", "unanswered, the rest answered");
        assert_eq!(answer(&mut t, b"\x1b[5n"), "\x1b[0n");
        assert!(answers.lock().unwrap().is_empty());
    }

    /// OSC 52 naming another clipboard is read from the standard one, as a
    /// Ghostty surface reads it, and answered under the name asked for; a
    /// clipboard of any size is answered whole.
    #[test]
    fn every_osc_52_read_is_answered_whatever_its_size() {
        let mut t = Terminal::new(80, 24).unwrap();
        t.act_as_terminal(ghostty()).unwrap();
        let big = vec![b'x'; 100_000];
        let feed = big.clone();
        let named = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        let told = std::sync::Arc::clone(&named);
        t.read_clipboard_with(Box::new(move |kind| {
            told.lock().unwrap().push(kind);
            ClipboardAnswer::Text(feed.clone())
        }))
        .unwrap();
        for kind in ["s", "p", "c"] {
            let reply = answer(&mut t, format!("\x1b]52;{kind};?\x1b\\").as_bytes());
            assert!(reply.starts_with(&format!("\x1b]52;{kind};eHh4")), "{kind}: {}", &reply[..reply.len().min(20)]);
            assert!(reply.ends_with("\x1b\\"), "{kind}");
            assert_eq!(reply.len(), 7 + 100_000 / 3 * 4 + 4 + 2, "{kind}: the whole clipboard");
        }
        // And the reader told which, as the answer names it: one it does
        // not know is the standard one.
        answer(&mut t, b"\x1b]52;;?\x1b\\");
        answer(&mut t, b"\x1b]52;0;?\x07");
        assert_eq!(*named.lock().unwrap(), b"spccc".to_vec());
    }

    /// The Kitty clipboard protocol and iTerm2's are not spoken: no answer
    /// to either, nothing put on the clipboard by either; OSC 52 still is.
    #[test]
    fn only_osc_52_reaches_the_clipboard() {
        let mut t = Terminal::new(80, 24).unwrap();
        t.act_as_terminal(ghostty()).unwrap();
        t.write(b"\x1b]5522;type=write\x1b\\\x1b]5522;type=wdata:mime=dGV4dC9wbGFpbg==;aGVsbG8=\x1b\\\x1b]5522;type=wdata\x1b\\");
        t.write(b"\x1b]1337;Copy=:aGVsbG8=\x07");
        let events = t.take_events();
        assert_eq!(events.clipboard, Vec::<Vec<u8>>::new(), "nothing on the clipboard");
        assert_eq!(String::from_utf8_lossy(&events.replies), "", "and no answer");
        t.write(b"\x1b]52;c;aGVsbG8=\x07");
        assert_eq!(t.take_events().clipboard, vec![b"hello".to_vec()]);
        assert_eq!(answer(&mut t, b"\x1b]5522;type=read;dGV4dC9wbGFpbg==\x1b\\\x1b[5n"), "\x1b[0n");
    }

    /// The Kitty clipboard protocol is no more spoken for reading the
    /// clipboard than a surface speaks it: its mode said unknown, its read
    /// left unanswered, and the reader never asked.
    #[test]
    fn reading_the_clipboard_speaks_no_more_than_a_surface() {
        let mut plain = Terminal::new(80, 24).unwrap();
        plain.act_as_terminal(ghostty()).unwrap();
        let mut t = Terminal::new(80, 24).unwrap();
        t.act_as_terminal(ghostty()).unwrap();
        let asked = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let count = std::sync::Arc::clone(&asked);
        t.read_clipboard_with(Box::new(move |_| {
            count.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            ClipboardAnswer::Text(b"secret".to_vec())
        }))
        .unwrap();
        assert_eq!(answer(&mut t, b"\x1b[?5522$p"), "\x1b[?5522;0$y");
        assert_eq!(answer(&mut t, b"\x1b[?5522h\x1b[?5522$p"), answer(&mut plain, b"\x1b[?5522h\x1b[?5522$p"));
        // A read in the Kitty protocol, also split in two, and one with text
        // around it.
        for query in [&b"\x1b]5522;type=read;dGV4dC9wbGFpbg==\x1b\\"[..], b"x\x1b]5522;type=read;dGV4dC9wbGFpbg==\x07y"] {
            assert_eq!(answer(&mut t, query), "", "{}", String::from_utf8_lossy(query));
        }
        t.write(b"\x1b]55");
        assert_eq!(answer(&mut t, b"22;type=read;dGV4dC9wbGFpbg==\x1b\\"), "");
        assert_eq!(asked.load(std::sync::atomic::Ordering::SeqCst), 0, "the reader was never asked");
        // While OSC 52, split in two, is read.
        t.write(b"\x1b]5");
        assert_eq!(answer(&mut t, b"2;c;?\x1b\\"), "\x1b]52;c;c2VjcmV0\x1b\\");
        assert_eq!(asked.load(std::sync::atomic::Ordering::SeqCst), 1);
    }

    #[test]
    fn without_standing_in_only_the_answers_are_collected() {
        let mut t = Terminal::new(80, 24).unwrap();
        t.answer_queries().unwrap();
        t.write(b"\x1b]2;x\x07\x1b[6n");
        assert_eq!(t.take_replies(), b"\x1b[1;1R");
        assert!(!t.take_events().title, "the title is not watched for the daemon");
    }
}
