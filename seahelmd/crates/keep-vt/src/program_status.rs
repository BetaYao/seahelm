//! OSC 7501, the Program Status Protocol: a program telling its terminal
//! what it is doing. Spec: https://www.superlogical.com/rex/docs/build/program-status
//! (rev 0.4).
//!
//! Two halves, both ports. [`parse`] reads and validates one report, as
//! seahelm's Ghostty patch does
//! (`scripts/ghostty-patches/0001-osc7501-program-status.patch`,
//! `program_status.zig`), and its tests come with it. [`Store`] keeps the
//! records with the spec's lifetime rules, as the macOS app does
//! (`Sources/Status/ProgramStatus.swift`).
//!
//! A report is `key=value` pairs joined by colons:
//!
//! ```text
//! ESC ] 7501 ; state=working:app=cargo:progress=40 ESC \
//! ```

use std::collections::HashMap;

/// The longest whole sequence, from `ESC ]` through the terminator.
pub const MAX_SEQUENCE_BYTES: usize = 4096;
/// The longest body (after `7501;`), assuming the longer terminator `ESC \`.
pub const MAX_BODY_BYTES: usize = MAX_SEQUENCE_BYTES - "\x1b]7501;".len() - "\x1b\\".len();
pub const MAX_KEY_BYTES: usize = 16;
pub const MAX_MSG_ENCODED_BYTES: usize = 2732;
pub const MAX_MSG_BYTES: usize = 2048;
pub const MAX_TITLE_ENCODED_BYTES: usize = 256;
pub const MAX_TITLE_BYTES: usize = 192;
pub const MAX_APP_BYTES: usize = 32;
pub const MAX_ID_BYTES: usize = 128;
pub const MAX_ID_SEGMENT_BYTES: usize = 32;
pub const MAX_ID_DEPTH: usize = 8;

/// The body of the answer to a support query (`OSC 7501 ; ?`), sent back with
/// the terminator the query used.
pub const QUERY_REPLY: &str = "?:states=idle,working,done,blocked,error:kinds=permission,question,auth";

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum State {
    Idle,
    Working,
    Done,
    Blocked,
    Error,
    /// Not a state: removes the addressed record and its subtree, or every
    /// record when there is no id.
    Clear,
}

impl State {
    fn from_name(s: &str) -> Option<Self> {
        Some(match s {
            "idle" => State::Idle,
            "working" => State::Working,
            "done" => State::Done,
            "blocked" => State::Blocked,
            "error" => State::Error,
            "clear" => State::Clear,
            _ => return None,
        })
    }

    pub fn name(self) -> &'static str {
        match self {
            State::Idle => "idle",
            State::Working => "working",
            State::Done => "done",
            State::Blocked => "blocked",
            State::Error => "error",
            State::Clear => "clear",
        }
    }
}

/// What a blocked program needs from the user.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Kind {
    Permission,
    Question,
    Auth,
}

impl Kind {
    fn from_name(s: &str) -> Option<Self> {
        Some(match s {
            "permission" => Kind::Permission,
            "question" => Kind::Question,
            "auth" => Kind::Auth,
            _ => return None,
        })
    }

    pub fn name(self) -> &'static str {
        match self {
            Kind::Permission => "permission",
            Kind::Question => "question",
            Kind::Auth => "auth",
        }
    }
}

/// A report that passed every check, with its values read out.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Report {
    pub state: State,
    /// Only for `blocked`.
    pub kind: Option<Kind>,
    /// 0…100, only for `working` and `blocked`; None is indeterminate.
    pub progress: Option<u8>,
    /// `/`-separated record id; empty is the root record, the program itself.
    pub id: String,
    pub app: String,
    /// Decoded, safe to show (no controls, no bidi overrides).
    pub title: String,
    pub msg: String,
}

/// One OSC 7501 sequence.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Command {
    /// `?`: answer with [`QUERY_REPLY`].
    Query,
    Report(Report),
}

const NAME_BYTES: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.+-";

fn is_name_byte(b: u8) -> bool {
    NAME_BYTES.contains(&b)
}

fn is_value_byte(b: u8) -> bool {
    is_name_byte(b) || b == b',' || b == b'/' || b == b'='
}

fn is_name(s: &str) -> bool {
    !s.is_empty() && s.bytes().all(is_name_byte)
}

fn trim_ascii_ws(s: &str) -> &str {
    s.trim_matches(|c: char| matches!(c, ' ' | '\t' | '\n' | '\r' | '\x0b' | '\x0c'))
}

/// Every valid value of `key`, in order (Kitty's metadata iterator): pairs
/// without `=`, other keys, and values with bytes outside the value alphabet
/// are skipped.
fn values<'a>(key: &'a str, data: &'a str) -> impl Iterator<Item = &'a str> + 'a {
    data.split(':').filter_map(move |field| {
        let eq = field.find('=')?;
        if trim_ascii_ws(&field[..eq]) != key {
            return None;
        }
        let value = trim_ascii_ws(&field[eq + 1..]);
        value.bytes().all(is_value_byte).then_some(value)
    })
}

fn last_value<'a>(key: &'a str, data: &'a str) -> Option<&'a str> {
    values(key, data).last()
}

/// Parse the body of an OSC 7501 (everything after `7501;`). None when the
/// report must be discarded as a whole.
pub fn parse(body: &[u8]) -> Option<Command> {
    if body.len() > MAX_BODY_BYTES {
        return None;
    }
    if body == b"?" {
        return Some(Command::Query);
    }
    // The alphabet is ASCII; anything else cannot be a valid pair anyway,
    // but must not make the whole report unreadable.
    let data = String::from_utf8_lossy(body);
    let data = data.as_ref();
    let state = validate(data)?;

    let kind = (state == State::Blocked).then(|| last_value("kind", data).and_then(Kind::from_name)).flatten();
    let progress = matches!(state, State::Working | State::Blocked)
        .then(|| last_value("progress", data).and_then(parse_progress))
        .flatten();
    let id = last_value("id", data).unwrap_or("").to_string();
    let app = last_value("app", data).filter(|v| is_name(v)).unwrap_or("").to_string();
    let text = |key: &str| {
        last_value(key, data)
            .filter(|v| !v.is_empty())
            .and_then(|v| decode_text(v).ok())
            .map(|t| display_safe(&t))
            .unwrap_or_default()
    };
    Some(Command::Report(Report { state, kind, progress, id, app, title: text("title"), msg: text("msg") }))
}

fn validate(data: &str) -> Option<State> {
    // A key that is too long breaks a limit, even a key we don't know.
    for pair in data.split(':') {
        if let Some(eq) = pair.find('=') {
            if trim_ascii_ws(&pair[..eq]).len() > MAX_KEY_BYTES {
                return None;
            }
        }
    }
    // Every value against its limit, even one a later pair replaces.
    for id in values("id", data) {
        validate_id(id)?;
    }
    for (key, limit) in [("app", MAX_APP_BYTES), ("title", MAX_TITLE_ENCODED_BYTES), ("msg", MAX_MSG_ENCODED_BYTES)] {
        if values(key, data).any(|v| v.len() > limit) {
            return None;
        }
    }
    if let Some(v) = last_value("title", data) {
        if decode_text(v).ok()?.len() > MAX_TITLE_BYTES {
            return None;
        }
    }
    if let Some(v) = last_value("msg", data) {
        decode_text(v).ok()?;
    }
    // An unknown state discards the report rather than guessing.
    State::from_name(last_value("state", data)?)
}

fn validate_id(value: &str) -> Option<()> {
    if value.len() > MAX_ID_BYTES {
        return None;
    }
    let mut depth = 0;
    for segment in value.split('/') {
        depth += 1;
        if depth > MAX_ID_DEPTH || segment.len() > MAX_ID_SEGMENT_BYTES || !is_name(segment) {
            return None;
        }
    }
    Some(())
}

/// 0…100, digits only (no sign, no underscores).
fn parse_progress(value: &str) -> Option<u8> {
    if value.is_empty() {
        return None;
    }
    let mut n: u16 = 0;
    for c in value.bytes() {
        if !c.is_ascii_digit() {
            return None;
        }
        n = n * 10 + (c - b'0') as u16;
        if n > 100 {
            return None;
        }
    }
    Some(n as u8)
}

/// Standard base64, padding optional, to UTF-8 with no control characters.
fn decode_text(encoded: &str) -> Result<String, ()> {
    let bytes = base64_decode(encoded).ok_or(())?;
    if bytes.len() > MAX_MSG_BYTES {
        return Err(());
    }
    let text = String::from_utf8(bytes).map_err(|_| ())?;
    if text.chars().any(|c| c.is_control()) {
        return Err(());
    }
    Ok(text)
}

fn base64_decode(s: &str) -> Option<Vec<u8>> {
    fn val(c: u8) -> Option<u32> {
        Some(match c {
            b'A'..=b'Z' => c - b'A',
            b'a'..=b'z' => c - b'a' + 26,
            b'0'..=b'9' => c - b'0' + 52,
            b'+' => 62,
            b'/' => 63,
            _ => return None,
        } as u32)
    }
    let bytes = s.as_bytes();
    let body_len = bytes.iter().position(|&b| b == b'=').unwrap_or(bytes.len());
    let (body, pad) = bytes.split_at(body_len);
    // One leftover character is never a byte; padding, when present, is
    // exactly what completes the last quantum.
    if body.len() % 4 == 1 || pad.iter().any(|&b| b != b'=') {
        return None;
    }
    if !pad.is_empty() && (body.len() + pad.len()) % 4 != 0 {
        return None;
    }
    let mut out = Vec::with_capacity(body.len() * 3 / 4);
    let (mut acc, mut bits) = (0u32, 0u32);
    for &c in body {
        acc = (acc << 6) | val(c)?;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((acc >> bits) as u8);
            acc &= (1 << bits) - 1;
        }
    }
    // Bits left over must be zero, as Zig's decoder (and the spec) insist.
    (acc == 0).then_some(out)
}

/// Drop bidi overrides and invisible formatting, so a program cannot make one
/// line read as another where the text is shown outside the grid.
pub fn display_safe(s: &str) -> String {
    const BANNED: &[u32] = &[
        0x061C, 0x200B, 0x200C, 0x200D, 0x200E, 0x200F, 0x2028, 0x2029, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
        0x2060, 0x2066, 0x2067, 0x2068, 0x2069, 0xFEFF,
    ];
    s.chars().filter(|c| !BANNED.contains(&(*c as u32))).collect()
}

/// One record as a terminal keeps it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Record {
    pub report: Report,
    /// `app`, resolved through the nearest ancestor that has one.
    pub app: String,
    stamp: u64,
}

/// The records one terminal holds, with the spec's lifetime rules.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Store {
    records: HashMap<String, Record>,
    clock: u64,
    /// The program that wrote the records has handed the terminal back to
    /// the shell: `done` / `error` outlive it, but no longer drive status.
    process_exited: bool,
}

impl Store {
    /// Spec: at most 256, at least 64.
    pub const MAX_RECORDS: usize = 256;

    pub fn root(&self) -> Option<&Record> {
        self.records.get("")
    }

    /// What the pane's status should take from 7501: the root record while
    /// the program that wrote it still holds the terminal.
    pub fn live_root(&self) -> Option<&Record> {
        if self.process_exited {
            None
        } else {
            self.root()
        }
    }

    pub fn len(&self) -> usize {
        self.records.len()
    }

    pub fn is_empty(&self) -> bool {
        self.records.is_empty()
    }

    pub fn get(&self, id: &str) -> Option<&Record> {
        self.records.get(id)
    }

    /// Apply one report. Whether anything changed.
    pub fn apply(&mut self, report: Report) -> bool {
        let before = self.clone();
        if report.state == State::Clear {
            if report.id.is_empty() {
                self.records.clear();
            } else {
                let prefix = format!("{}/", report.id);
                self.records.retain(|k, _| k != &report.id && !k.starts_with(&prefix));
            }
            return *self != before;
        }
        // A report means the program is running in this terminal now.
        self.process_exited = false;
        self.clock += 1;
        let app = if report.app.is_empty() { self.inherited_app(&report.id) } else { report.app.clone() };
        self.records.insert(report.id.clone(), Record { report, app, stamp: self.clock });
        if self.records.len() > Self::MAX_RECORDS {
            if let Some(oldest) = self.records.iter().min_by_key(|(_, r)| r.stamp).map(|(k, _)| k.clone()) {
                self.records.remove(&oldest);
            }
        }
        *self != before
    }

    /// The shell has the terminal back (OSC 133 command finished): `working`
    /// and `blocked` die with the process and `idle` may; `done` and `error`
    /// stay until the user has seen them.
    pub fn prompt_returned(&mut self) -> bool {
        let before = self.clone();
        self.records.retain(|_, r| matches!(r.report.state, State::Done | State::Error));
        self.process_exited = true;
        *self != before
    }

    fn inherited_app(&self, id: &str) -> String {
        if id.is_empty() {
            return String::new();
        }
        let mut parts: Vec<&str> = id.split('/').collect();
        loop {
            parts.pop();
            if let Some(r) = self.records.get(&parts.join("/")) {
                if !r.app.is_empty() {
                    return r.app.clone();
                }
            }
            if parts.is_empty() {
                return String::new();
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn report(body: &str) -> Report {
        match parse(body.as_bytes()) {
            Some(Command::Report(r)) => r,
            other => panic!("{body:?} parsed as {other:?}"),
        }
    }

    fn ok(body: &str) -> bool {
        parse(body.as_bytes()).is_some()
    }

    // ---- program_status.zig ----

    #[test]
    fn query() {
        assert_eq!(parse(b"?"), Some(Command::Query));
    }

    #[test]
    fn query_reply_lists_every_state_and_kind() {
        assert_eq!(QUERY_REPLY, "?:states=idle,working,done,blocked,error:kinds=permission,question,auth");
    }

    #[test]
    fn minimal_report() {
        let r = report("state=idle");
        assert_eq!(r.state, State::Idle);
        assert_eq!((r.kind, r.progress), (None, None));
        assert!(r.id.is_empty() && r.app.is_empty() && r.title.is_empty() && r.msg.is_empty());
    }

    #[test]
    fn all_keys() {
        let r = report(
            "state=blocked:kind=permission:progress=42:id=tf/plan:app=terraform\
             :title=UGxhbg==:msg=QXBwbHkgMyB0byBhZGQsIDEgdG8gY2hhbmdlLCAwIHRvIGRlc3Ryb3k/",
        );
        assert_eq!(r.state, State::Blocked);
        assert_eq!(r.kind, Some(Kind::Permission));
        assert_eq!(r.progress, Some(42));
        assert_eq!(r.id, "tf/plan");
        assert_eq!(r.app, "terraform");
        assert_eq!(r.title, "Plan");
        assert_eq!(r.msg, "Apply 3 to add, 1 to change, 0 to destroy?");
    }

    #[test]
    fn base64_padding_is_optional() {
        assert_eq!(report("state=done:msg=UGxhbg").msg, "Plan");
    }

    #[test]
    fn whitespace_around_keys_and_values() {
        let r = report(" state = working :\tapp=cargo\t");
        assert_eq!((r.state, r.app.as_str()), (State::Working, "cargo"));
    }

    #[test]
    fn last_value_wins() {
        let r = report("state=idle:app=a:state=done:app=b");
        assert_eq!((r.state, r.app.as_str()), (State::Done, "b"));
    }

    #[test]
    fn malformed_pairs_and_unknown_keys_are_skipped() {
        let r = report("garbage:=x:Bad=1:app=b@d:future=yes:state=working:app=ok:::");
        assert_eq!((r.state, r.app.as_str()), (State::Working, "ok"));
    }

    #[test]
    fn kind_and_progress_only_apply_to_some_states() {
        let r = report("state=working:kind=auth:progress=10");
        assert_eq!((r.kind, r.progress), (None, Some(10)));
        let r = report("state=done:kind=auth:progress=10");
        assert_eq!((r.kind, r.progress), (None, None));
        assert_eq!(report("state=blocked:kind=dance").kind, None);
    }

    #[test]
    fn out_of_range_progress_is_absent() {
        for (v, want) in [
            ("0", Some(0)),
            ("100", Some(100)),
            ("101", None),
            ("256", None),
            ("99999999999999999999", None),
            ("-1", None),
            ("+1", None),
            ("4.5", None),
            ("1_0", None),
            ("007", Some(7)),
            ("", None),
        ] {
            assert_eq!(report(&format!("state=working:progress={v}")).progress, want, "{v:?}");
        }
    }

    #[test]
    fn invalid_app_is_ignored() {
        assert_eq!(report("state=idle:app=a/b").app, "");
    }

    #[test]
    fn ids() {
        let seg = "a".repeat(MAX_ID_SEGMENT_BYTES);
        for id in ["a", "build/test", "A-Z_0.9+", seg.as_str(), "a/b/c/d/e/f/g/h"] {
            assert_eq!(report(&format!("state=clear:id={id}")).id, id);
        }
        let too_long_segment = format!("{seg}a");
        let too_long = format!("{}a", format!("{}/", "a".repeat(31)).repeat(4));
        for id in ["", "/", "a/", "/a", "a//b", "a,b", "a=b", &too_long_segment, "a/b/c/d/e/f/g/h/i", &too_long] {
            assert!(!ok(&format!("state=clear:id={id}")), "{id:?} must discard the report");
        }
    }

    #[test]
    fn text_must_decode_to_safe_utf8() {
        for input in [
            "state=done:msg=a",
            "state=done:msg=QQ=",
            "state=done:title=a",
            "state=done:msg=YQpi",
            "state=done:msg=wps=",
            "state=done:msg=/w==",
        ] {
            assert!(!ok(input), "{input:?}");
        }
        assert_eq!(report("state=done:msg=5a6J5YWo").msg, "安全");
    }

    #[test]
    fn empty_text_is_absent() {
        let r = report("state=done:msg=:title=");
        assert!(r.msg.is_empty() && r.title.is_empty());
    }

    #[test]
    fn discarded_reports() {
        let title = "QUFB".repeat(MAX_TITLE_ENCODED_BYTES / 4);
        let msg = format!("{}QUE", "QUFB".repeat(MAX_MSG_BYTES / 3));
        let fill = MAX_SEQUENCE_BYTES - "\x1b]7501;state=idle:".len() - "\x1b\\".len();
        let cases: Vec<(String, bool)> = vec![
            ("".into(), false),
            ("app=cargo".into(), false),
            ("state=sleeping".into(), false),
            ("state=".into(), false),
            ("state=IDLE".into(), false),
            (format!("state=idle:{}=1", "a".repeat(MAX_KEY_BYTES)), true),
            (format!("state=idle:{}=1", "a".repeat(MAX_KEY_BYTES + 1)), false),
            (format!("state=idle:app={}", "a".repeat(MAX_APP_BYTES + 1)), false),
            (format!("state=idle:app={}:app=ok", "a".repeat(MAX_APP_BYTES + 1)), false),
            (format!("state=idle:title={title}"), true),
            (format!("state=idle:title={title}QUFB"), false),
            (format!("state=idle:msg={msg}"), true),
            (format!("state=idle:msg={}", "QUFB".repeat(MAX_MSG_BYTES / 3 + 1)), false),
            (format!("state=idle:{}", "x".repeat(fill)), true),
            (format!("state=idle:{}", "x".repeat(fill + 1)), false),
        ];
        for (body, want) in cases {
            assert_eq!(ok(&body), want, "{} bytes: {:?}…", body.len(), &body[..body.len().min(40)]);
        }
    }

    // ---- ProgramStatusTests.swift (the store) ----

    fn r(state: State, id: &str, app: &str) -> Report {
        Report { state, kind: None, progress: None, id: id.into(), app: app.into(), title: String::new(), msg: String::new() }
    }

    #[test]
    fn report_replaces_whole_record() {
        let mut s = Store::default();
        s.apply(Report { msg: "first".into(), ..r(State::Working, "", "x") });
        s.apply(r(State::Idle, "", ""));
        let root = s.root().unwrap();
        assert_eq!(root.report.state, State::Idle);
        assert!(root.report.msg.is_empty(), "nothing carried over");
    }

    #[test]
    fn clear_with_id_removes_that_subtree_only() {
        let mut s = Store::default();
        for id in ["", "a", "a/b", "ab"] {
            s.apply(r(State::Working, id, ""));
        }
        s.apply(r(State::Clear, "a", ""));
        assert!(s.get("a").is_none() && s.get("a/b").is_none());
        assert!(s.get("").is_some() && s.get("ab").is_some(), "a prefix is not a parent");
    }

    #[test]
    fn clear_without_id_removes_everything() {
        let mut s = Store::default();
        s.apply(r(State::Working, "", ""));
        s.apply(r(State::Working, "a", ""));
        assert!(s.apply(r(State::Clear, "", "")));
        assert!(s.is_empty());
    }

    #[test]
    fn app_is_inherited_from_nearest_ancestor() {
        let mut s = Store::default();
        s.apply(r(State::Working, "", "root"));
        s.apply(r(State::Working, "a", "mid"));
        s.apply(r(State::Working, "a/b/c", ""));
        s.apply(r(State::Working, "x", ""));
        assert_eq!(s.get("a/b/c").unwrap().app, "mid");
        assert_eq!(s.get("x").unwrap().app, "root");
    }

    #[test]
    fn prompt_returned_ends_the_programs_records() {
        let mut s = Store::default();
        s.apply(r(State::Working, "", ""));
        s.apply(r(State::Blocked, "a", ""));
        s.apply(r(State::Done, "b", ""));
        s.apply(r(State::Error, "c", ""));
        s.apply(r(State::Idle, "d", ""));
        assert!(s.prompt_returned());
        let mut left: Vec<_> = ["", "a", "b", "c", "d"].into_iter().filter(|id| s.get(id).is_some()).collect();
        left.sort();
        assert_eq!(left, ["b", "c"]);
        assert!(s.live_root().is_none());
        s.apply(r(State::Done, "", ""));
        assert!(s.live_root().is_some(), "a new report means the program is back");
    }

    #[test]
    fn evicts_least_recently_updated_past_the_limit() {
        let mut s = Store::default();
        for i in 0..Store::MAX_RECORDS {
            s.apply(r(State::Working, &format!("r{i}"), ""));
        }
        s.apply(r(State::Working, "r0", "")); // r0 is fresh again; r1 is oldest
        s.apply(r(State::Working, "new", ""));
        assert_eq!(s.len(), Store::MAX_RECORDS);
        assert!(s.get("r1").is_none() && s.get("r0").is_some() && s.get("new").is_some());
    }

    #[test]
    fn display_text_loses_bidi_and_invisible_formatting() {
        assert_eq!(display_safe("a\u{202E}b\u{200B}c"), "abc");
    }
}
