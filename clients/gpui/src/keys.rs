//! Keystrokes to the bytes a terminal sends for them (xterm's legacy
//! encoding). The Kitty keyboard protocol, which libghostty-vt's key encoder
//! does properly, comes later; until then a program that asks for it still
//! gets keys it can read, because legacy is what it falls back to.

use gpui::Keystroke;

/// What to send for `key`, or None when the terminal has nothing to say
/// (a bare modifier, a cmd shortcut the app keeps).
pub fn encode(key: &Keystroke, app_cursor: bool) -> Option<Vec<u8>> {
    let m = &key.modifiers;
    if m.platform {
        return None;
    }
    let csi_mod = 1 + (m.shift as u8) + 2 * (m.alt as u8) + 4 * (m.control as u8);
    let cursor = |c: u8| -> Vec<u8> {
        if csi_mod > 1 {
            format!("\x1b[1;{csi_mod}{}", c as char).into_bytes()
        } else if app_cursor {
            vec![0x1b, b'O', c]
        } else {
            vec![0x1b, b'[', c]
        }
    };
    let tilde = |n: u8| -> Vec<u8> {
        if csi_mod > 1 {
            format!("\x1b[{n};{csi_mod}~").into_bytes()
        } else {
            format!("\x1b[{n}~").into_bytes()
        }
    };
    let named = match key.key.as_str() {
        // Shift+Enter as alt+Enter: what agent TUIs read as a newline in a
        // prompt when the Kitty protocol is not on.
        "enter" if m.shift || m.alt => Some(b"\x1b\r".to_vec()),
        "enter" => Some(b"\r".to_vec()),
        "tab" if m.shift => Some(b"\x1b[Z".to_vec()),
        "tab" => Some(b"\t".to_vec()),
        "backspace" if m.alt => Some(b"\x1b\x7f".to_vec()),
        "backspace" if m.control => Some(b"\x08".to_vec()),
        "backspace" => Some(b"\x7f".to_vec()),
        "escape" => Some(b"\x1b".to_vec()),
        "space" if m.control => Some(vec![0]),
        "up" => Some(cursor(b'A')),
        "down" => Some(cursor(b'B')),
        "right" => Some(cursor(b'C')),
        "left" => Some(cursor(b'D')),
        "home" => Some(cursor(b'H')),
        "end" => Some(cursor(b'F')),
        "insert" => Some(tilde(2)),
        "delete" => Some(tilde(3)),
        "pageup" => Some(tilde(5)),
        "pagedown" => Some(tilde(6)),
        "f1" => Some(b"\x1bOP".to_vec()),
        "f2" => Some(b"\x1bOQ".to_vec()),
        "f3" => Some(b"\x1bOR".to_vec()),
        "f4" => Some(b"\x1bOS".to_vec()),
        "f5" => Some(tilde(15)),
        "f6" => Some(tilde(17)),
        "f7" => Some(tilde(18)),
        "f8" => Some(tilde(19)),
        "f9" => Some(tilde(20)),
        "f10" => Some(tilde(21)),
        "f11" => Some(tilde(23)),
        "f12" => Some(tilde(24)),
        _ => None,
    };
    if named.is_some() {
        return named;
    }

    if m.control {
        // ctrl+letter and the punctuation that has a control code.
        let k = key.key.as_bytes();
        if k.len() == 1 {
            let c = k[0].to_ascii_lowercase();
            let code = match c {
                b'a'..=b'z' => Some(c - b'a' + 1),
                b'@' | b'2' => Some(0),
                b'[' | b'3' => Some(0x1b),
                b'\\' | b'4' => Some(0x1c),
                b']' | b'5' => Some(0x1d),
                b'^' | b'6' => Some(0x1e),
                b'_' | b'-' | b'7' => Some(0x1f),
                b'/' => Some(0x1f),
                _ => None,
            };
            if let Some(code) = code {
                return Some(if m.alt { vec![0x1b, code] } else { vec![code] });
            }
        }
    }

    // Option as Meta: ESC, then the key itself (not the composed character).
    if m.alt {
        let base = if m.shift { key.key.to_uppercase() } else { key.key.clone() };
        if base.chars().count() == 1 {
            let mut out = vec![0x1b];
            out.extend_from_slice(base.as_bytes());
            return Some(out);
        }
    }

    match key.key_char.as_deref() {
        Some(text) if !text.is_empty() => Some(text.as_bytes().to_vec()),
        _ if key.key.chars().count() == 1 && !m.control => Some(key.key.as_bytes().to_vec()),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::encode;
    use gpui::Keystroke;

    fn k(s: &str) -> Option<Vec<u8>> {
        encode(&Keystroke::parse(s).unwrap(), false)
    }

    #[test]
    fn common_keys() {
        assert_eq!(k("enter"), Some(b"\r".to_vec()));
        assert_eq!(k("shift-enter"), Some(b"\x1b\r".to_vec()));
        assert_eq!(k("ctrl-c"), Some(vec![3]));
        assert_eq!(k("up"), Some(b"\x1b[A".to_vec()));
        assert_eq!(k("shift-up"), Some(b"\x1b[1;2A".to_vec()));
        assert_eq!(k("alt-b"), Some(b"\x1bb".to_vec()));
        assert_eq!(k("cmd-c"), None);
        assert_eq!(k("shift-tab"), Some(b"\x1b[Z".to_vec()));
        assert_eq!(encode(&Keystroke::parse("up").unwrap(), true), Some(b"\x1bOA".to_vec()));
    }
}
