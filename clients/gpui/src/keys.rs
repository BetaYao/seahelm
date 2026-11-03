//! Keystrokes to what libghostty-vt's key encoder takes (`keep_vt::input`):
//! the physical key, the modifiers, the text it types and its unshifted
//! character. The encoder then writes them as the program's modes ask —
//! legacy xterm, modifyOtherKeys, or the Kitty keyboard protocol.

use gpui::{Keystroke, Modifiers};
use keep_vt::input::{Key, Mods};

/// A keystroke, translated.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Translated {
    pub key: Key,
    pub mods: Mods,
    /// What the key types with shift applied; None under ctrl, where the
    /// encoder works from the key itself.
    pub text: Option<String>,
    pub unshifted: Option<char>,
}

pub fn mods(m: &Modifiers) -> Mods {
    Mods { shift: m.shift, ctrl: m.control, alt: m.alt, super_: m.platform }
}

fn named(key: &str) -> Option<Key> {
    Some(match key {
        "enter" => Key::ENTER,
        "tab" => Key::TAB,
        "backspace" => Key::BACKSPACE,
        "escape" => Key::ESCAPE,
        "space" => Key::SPACE,
        "up" => Key::ARROW_UP,
        "down" => Key::ARROW_DOWN,
        "left" => Key::ARROW_LEFT,
        "right" => Key::ARROW_RIGHT,
        "home" => Key::HOME,
        "end" => Key::END,
        "pageup" => Key::PAGE_UP,
        "pagedown" => Key::PAGE_DOWN,
        "insert" => Key::INSERT,
        "delete" => Key::DELETE,
        _ => {
            let n: u8 = key.strip_prefix('f')?.parse().ok()?;
            return Key::function(n);
        }
    })
}

/// What to hand the encoder for `ks`; None for what the terminal never
/// sees (cmd shortcuts, bare modifiers, keys it has no name for).
pub fn translate(ks: &Keystroke) -> Option<Translated> {
    let m = &ks.modifiers;
    if m.platform {
        return None;
    }
    let mods = mods(m);
    if let Some(key) = named(&ks.key) {
        let text = (key == Key::SPACE && !m.control).then(|| " ".to_string());
        let unshifted = (key == Key::SPACE).then_some(' ');
        return Some(Translated { key, mods, text, unshifted });
    }
    let mut chars = ks.key.chars();
    let (Some(base), None) = (chars.next(), chars.next()) else { return None };
    let unshifted = base.to_lowercase().next().unwrap_or(base);
    let key = Key::for_char(unshifted).unwrap_or(Key::UNIDENTIFIED);
    let text = if m.control {
        None
    } else if m.alt {
        // Option as alt: the key's own character, not what option composes.
        Some(if m.shift { base.to_uppercase().collect() } else { base.to_string() })
    } else {
        ks.key_char.clone().filter(|t| !t.is_empty()).or_else(|| Some(base.to_string()))
    };
    Some(Translated { key, mods, text, unshifted: Some(unshifted) })
}

/// Shift+Enter as alt+Enter when the program has not turned on the Kitty
/// protocol: what agent TUIs read as a newline in a prompt.
pub fn legacy_newline(ks: &Keystroke, kitty_flags: u8) -> Option<&'static [u8]> {
    let m = &ks.modifiers;
    (kitty_flags == 0 && ks.key == "enter" && (m.shift || m.alt) && !m.control && !m.platform).then_some(b"\x1b\r")
}

/// Whether the key types text: a printable character with no modifier
/// but shift. Those go to the platform's input method (`EntityInputHandler`
/// on the terminal view) rather than straight to the terminal, so an IME
/// can compose with them; what it commits arrives as text.
pub fn is_text(key: &Keystroke) -> bool {
    let m = &key.modifiers;
    !m.control
        && !m.alt
        && !m.platform
        && !m.function
        && key.key_char.as_deref().is_some_and(|c| !c.is_empty() && !c.chars().any(char::is_control))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn t(s: &str) -> Option<Translated> {
        translate(&Keystroke::parse(s).unwrap())
    }

    #[test]
    fn keys_translate() {
        let a = t("a->a").unwrap();
        assert_eq!((a.key, a.text.as_deref(), a.unshifted), (Key::A, Some("a"), Some('a')));
        let shift_a = t("shift-a->A").unwrap();
        assert_eq!((shift_a.text.as_deref(), shift_a.unshifted, shift_a.mods.shift), (Some("A"), Some('a'), true));
        let ctrl_c = t("ctrl-c").unwrap();
        assert_eq!((ctrl_c.key, ctrl_c.text, ctrl_c.mods.ctrl), (Key::letter('c').unwrap(), None, true));
        assert_eq!(t("up").unwrap().key, Key::ARROW_UP);
        assert_eq!(t("f5").unwrap().key, Key::function(5).unwrap());
        assert_eq!(t("alt-b").unwrap().text.as_deref(), Some("b"));
        assert_eq!(t("cmd-c"), None);
    }

    #[test]
    fn shift_enter_is_a_newline_without_kitty() {
        let k = Keystroke::parse("shift-enter").unwrap();
        assert_eq!(legacy_newline(&k, 0), Some(&b"\x1b\r"[..]));
        assert_eq!(legacy_newline(&k, 1), None);
        assert_eq!(legacy_newline(&Keystroke::parse("enter").unwrap(), 0), None);
    }

    #[test]
    fn printable_keys_go_to_the_input_method() {
        let t = |s: &str| is_text(&Keystroke::parse(s).unwrap());
        assert!(t("a->a"));
        assert!(t("shift-a->A"));
        assert!(t("space-> "));
        assert!(!t("ctrl-a"));
        assert!(!t("alt-b"));
        assert!(!t("enter"));
        assert!(!t("up"));
    }
}
