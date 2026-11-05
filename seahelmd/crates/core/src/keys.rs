//! A key press named in text — `a`, `3`, `slash`, `f5`, `ctrl+c`,
//! `shift+tab`, `alt+left` — as the bytes a legacy xterm sends for it, for
//! writing straight into a seahelmd session. The app's `KeyChord`
//! (grammar and `bytes`), so `seahelm pane send-keys` takes the same names
//! whichever of the two answers it.
//!
//! Grammar: modifiers (`ctrl`, `alt`/`option`, `shift`) joined to one key by
//! `+`. Keys are letters, digits, the US punctuation characters or their
//! names (`minus`, `equal`, `left-bracket`, `right-bracket`, `semicolon`,
//! `quote`, `backslash`, `comma`, `period`, `slash`, `backtick`, `plus`), and
//! `enter`, `tab`, `space`, `escape`, `backspace`, `delete`, `insert`,
//! `home`, `end`, `pageup`, `pagedown`, the arrows and `f1`–`f12`. Case is
//! insignificant except for a lone character: `A` and `?` are typed as
//! shift+a and shift+slash. A lone character with no key of its own (`é`)
//! is sent as itself.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Key {
    /// A key that types a character: letter, digit, punctuation, space.
    Char(char),
    Enter,
    Tab,
    Escape,
    Backspace,
    Delete,
    Insert,
    Home,
    End,
    PageUp,
    PageDown,
    Up,
    Down,
    Left,
    Right,
    F(u8),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Chord {
    key: Key,
    ctrl: bool,
    alt: bool,
    shift: bool,
}

/// The bytes for `name`, or None for a name that is no key (or a
/// combination with no legacy encoding, such as ctrl+5's neighbours).
pub fn bytes(name: &str) -> Option<String> {
    match Chord::parse(name) {
        Some(c) => c.bytes(),
        None => (name.chars().count() == 1).then(|| name.to_string()),
    }
}

/// The US layout's shifted punctuation, unshifted → shifted.
const SHIFTED: &[(char, char)] = &[
    ('1', '!'), ('2', '@'), ('3', '#'), ('4', '$'), ('5', '%'), ('6', '^'), ('7', '&'), ('8', '*'),
    ('9', '('), ('0', ')'), ('-', '_'), ('=', '+'), ('[', '{'), (']', '}'), (';', ':'), ('\'', '"'),
    ('\\', '|'), (',', '<'), ('.', '>'), ('/', '?'), ('`', '~'),
];

const NAMES: &[(&str, char)] = &[
    ("minus", '-'), ("equal", '='), ("left-bracket", '['), ("right-bracket", ']'), ("semicolon", ';'),
    ("quote", '\''), ("backslash", '\\'), ("comma", ','), ("period", '.'), ("slash", '/'), ("backtick", '`'),
    ("plus", '+'),
];

/// Every character a key on a US keyboard types unshifted.
fn has_key(c: char) -> bool {
    c.is_ascii_lowercase() || c.is_ascii_digit() || c == ' ' || SHIFTED.iter().any(|(u, _)| *u == c)
}

fn unshifted(c: char) -> Option<char> {
    SHIFTED.iter().find(|(_, s)| *s == c).map(|(u, _)| *u)
}

fn shifted(c: char) -> char {
    SHIFTED.iter().find(|(u, _)| *u == c).map(|(_, s)| *s).unwrap_or_else(|| c.to_ascii_uppercase())
}

impl Chord {
    fn plain(key: Key, shift: bool) -> Self {
        Chord { key, ctrl: false, alt: false, shift }
    }

    fn parse(spec: &str) -> Option<Self> {
        // A lone character is taken literally, case and all.
        let mut chars = spec.chars();
        if let (Some(c), None) = (chars.next(), chars.next()) {
            if let Some(base) = unshifted(c) {
                return Some(Self::plain(Key::Char(base), true));
            }
            if c.is_ascii_uppercase() {
                return Some(Self::plain(Key::Char(c.to_ascii_lowercase()), true));
            }
            return has_key(c).then(|| Self::plain(Key::Char(c), false));
        }
        let lower = spec.to_lowercase();
        let mut parts: Vec<&str> = lower.split('+').collect();
        // `ctrl++` names the plus key itself.
        if parts.len() >= 2 && parts[parts.len() - 2..] == ["", ""] {
            parts.truncate(parts.len() - 2);
            parts.push("+");
        }
        let name = parts.pop().filter(|n| !n.is_empty())?;
        let (key, shift) = parse_key(name)?;
        let mut chord = Self::plain(key, shift);
        for m in parts {
            match m {
                "ctrl" | "control" if !chord.ctrl => chord.ctrl = true,
                "alt" | "option" | "opt" | "meta" if !chord.alt => chord.alt = true,
                "shift" => chord.shift = true,
                _ => return None,
            }
        }
        Some(chord)
    }

    /// What a legacy xterm sends for this key.
    fn bytes(&self) -> Option<String> {
        const ESC: &str = "\x1b";
        // xterm's modifier parameter: 1 + shift + 2·alt + 4·ctrl.
        let param = 1 + self.shift as u8 + 2 * self.alt as u8 + 4 * self.ctrl as u8;
        let csi = |f: &str| if param == 1 { format!("{ESC}[{f}") } else { format!("{ESC}[1;{param}{f}") };
        let tilde = |n: u8| if param == 1 { format!("{ESC}[{n}~") } else { format!("{ESC}[{n};{param}~") };
        let alt = if self.alt { ESC } else { "" };
        Some(match self.key {
            Key::Up => csi("A"),
            Key::Down => csi("B"),
            Key::Right => csi("C"),
            Key::Left => csi("D"),
            Key::Home => csi("H"),
            Key::End => csi("F"),
            Key::Insert => tilde(2),
            Key::Delete => tilde(3),
            Key::PageUp => tilde(5),
            Key::PageDown => tilde(6),
            Key::F(n) if n <= 4 => {
                let f = ["P", "Q", "R", "S"][n as usize - 1];
                if param == 1 { format!("{ESC}O{f}") } else { format!("{ESC}[1;{param}{f}") }
            }
            Key::F(n) => tilde([15, 17, 18, 19, 20, 21, 23, 24][n as usize - 5]),
            Key::Tab if self.shift => format!("{ESC}[Z"),
            Key::Tab => format!("{alt}\t"),
            Key::Enter => format!("{alt}\r"),
            Key::Escape => format!("{alt}{ESC}"),
            Key::Backspace => format!("{alt}{}", if self.ctrl { "\x08" } else { "\x7f" }),
            Key::Char(c) => {
                let typed = if self.ctrl {
                    (control_code(c)? as char).to_string()
                } else if self.shift {
                    shifted(c).to_string()
                } else {
                    c.to_string()
                };
                format!("{alt}{typed}")
            }
        })
    }
}

fn parse_key(name: &str) -> Option<(Key, bool)> {
    let key = match name {
        "enter" | "return" => Key::Enter,
        "tab" => Key::Tab,
        "space" => Key::Char(' '),
        "esc" | "escape" => Key::Escape,
        "backspace" | "bs" => Key::Backspace,
        "delete" | "del" => Key::Delete,
        "insert" | "ins" => Key::Insert,
        "home" => Key::Home,
        "end" => Key::End,
        "pageup" | "pgup" => Key::PageUp,
        "pagedown" | "pgdn" => Key::PageDown,
        "up" => Key::Up,
        "down" => Key::Down,
        "left" => Key::Left,
        "right" => Key::Right,
        _ => {
            if let Some((_, c)) = NAMES.iter().find(|(n, _)| *n == name) {
                return Some(match unshifted(*c) {
                    Some(base) => (Key::Char(base), true),
                    None => (Key::Char(*c), false),
                });
            }
            if let Some(n) = name.strip_prefix('f').and_then(|n| n.parse::<u8>().ok()).filter(|n| (1..=12).contains(n)) {
                return Some((Key::F(n), false));
            }
            let mut chars = name.chars();
            let (Some(c), None) = (chars.next(), chars.next()) else { return None };
            if let Some(base) = unshifted(c) {
                return Some((Key::Char(base), true));
            }
            return has_key(c).then_some((Key::Char(c), false));
        }
    };
    Some((key, false))
}

/// ctrl+<key> in the C0 range: letters, and the keys the ASCII table pairs
/// with the remaining control codes.
fn control_code(c: char) -> Option<u8> {
    Some(match c {
        'a'..='z' => c as u8 - 96,
        ' ' | '2' | '`' => 0,
        '[' | '3' => 0x1b,
        '\\' | '4' => 0x1c,
        ']' | '5' => 0x1d,
        '6' => 0x1e,
        '-' | '7' | '/' => 0x1f,
        '8' => 0x7f,
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::bytes;

    fn b(name: &str) -> Option<String> {
        bytes(name)
    }

    #[test]
    fn named_keys() {
        assert_eq!(b("Enter").as_deref(), Some("\r"));
        assert_eq!(b("escape").as_deref(), Some("\x1b"));
        assert_eq!(b("backspace").as_deref(), Some("\x7f"));
        assert_eq!(b("up").as_deref(), Some("\x1b[A"));
        assert_eq!(b("pagedown").as_deref(), Some("\x1b[6~"));
        assert_eq!(b("shift+tab").as_deref(), Some("\x1b[Z"));
        assert_eq!(b("f1").as_deref(), Some("\x1bOP"));
        assert_eq!(b("f5").as_deref(), Some("\x1b[15~"));
        assert_eq!(b("f12").as_deref(), Some("\x1b[24~"));
        assert_eq!(b("f13"), None);
    }

    #[test]
    fn characters_and_their_shifts() {
        assert_eq!(b("2").as_deref(), Some("2"));
        assert_eq!(b("A").as_deref(), Some("A"));
        assert_eq!(b("?").as_deref(), Some("?"));
        assert_eq!(b("slash").as_deref(), Some("/"));
        assert_eq!(b("shift+slash").as_deref(), Some("?"));
        assert_eq!(b("plus").as_deref(), Some("+"));
        assert_eq!(b("space").as_deref(), Some(" "));
        // No key of its own: sent as itself.
        assert_eq!(b("é").as_deref(), Some("é"));
    }

    #[test]
    fn modifiers() {
        assert_eq!(b("ctrl+c").as_deref(), Some("\x03"));
        assert_eq!(b("CTRL+C").as_deref(), Some("\x03"));
        assert_eq!(b("ctrl+[").as_deref(), Some("\x1b"));
        assert_eq!(b("ctrl+space").as_deref(), Some("\0"));
        assert_eq!(b("ctrl+backspace").as_deref(), Some("\x08"));
        assert_eq!(b("alt+b").as_deref(), Some("\x1bb"));
        assert_eq!(b("alt+left").as_deref(), Some("\x1b[1;3D"));
        assert_eq!(b("ctrl+shift+up").as_deref(), Some("\x1b[1;6A"));
        assert_eq!(b("shift+f1").as_deref(), Some("\x1b[1;2P"));
        assert_eq!(b("alt+enter").as_deref(), Some("\x1b\r"));
        assert_eq!(b("ctrl++").as_deref(), None, "ctrl+plus has no C0 code");
    }

    #[test]
    fn nonsense_is_refused() {
        assert_eq!(b("hyper+q"), None);
        assert_eq!(b("ctrl+ctrl+c"), None);
        assert_eq!(b("ctrl+"), None);
        assert_eq!(b("bogus"), None);
    }
}
