//! A worktree's colour label, as the macOS app has it (`SessionLabel`,
//! `WorktreeLabelStore`): one of eight colours, kept by worktree path in
//! `~/.config/seahelm/worktree-labels.json`, the same file the macOS app
//! reads and writes, so a label set in either shows in both.

use std::collections::HashMap;
use std::path::PathBuf;

use gpui::Rgba;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Label {
    Red,
    Orange,
    Yellow,
    Green,
    Teal,
    Blue,
    Purple,
    Pink,
}

impl Label {
    pub const ALL: [Label; 8] = [Label::Red, Label::Orange, Label::Yellow, Label::Green, Label::Teal, Label::Blue, Label::Purple, Label::Pink];

    pub fn key(self) -> &'static str {
        match self {
            Label::Red => "red",
            Label::Orange => "orange",
            Label::Yellow => "yellow",
            Label::Green => "green",
            Label::Teal => "teal",
            Label::Blue => "blue",
            Label::Purple => "purple",
            Label::Pink => "pink",
        }
    }

    pub fn from_key(key: &str) -> Option<Label> {
        Label::ALL.into_iter().find(|l| l.key() == key)
    }

    /// The ribbon's colour: the light theme's denser variant on white.
    pub fn colour(self) -> Rgba {
        let (dark, light) = match self {
            Label::Red => (0xFF6B6B, 0xD92D20),
            Label::Orange => (0xFFA24C, 0xB54708),
            Label::Yellow => (0xF5D64E, 0x9A7400),
            Label::Green => (0x6BD68A, 0x1E7A3C),
            Label::Teal => (0x1FC8DA, 0x0E9BB5),
            Label::Blue => (0x6AA6FF, 0x1B5FD9),
            Label::Purple => (0xB48CFF, 0x6B35D6),
            Label::Pink => (0xFF8FC7, 0xC02580),
        };
        gpui::rgb(if crate::theme::is_dark() { dark } else { light })
    }
}

fn file() -> PathBuf {
    crate::platform::config_dir().join("worktree-labels.json")
}

/// Every label, by worktree path; unknown colours are left out.
pub fn load() -> HashMap<String, Label> {
    read_map().into_iter().filter_map(|(k, v)| Label::from_key(&v).map(|l| (k, l))).collect()
}

fn read_map() -> HashMap<String, String> {
    std::fs::read(file()).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
}

/// Set or clear a worktree's label, keeping every other entry (colours
/// this version does not know included).
pub fn set(path: &str, label: Option<Label>) -> std::io::Result<()> {
    let mut map = read_map();
    match label {
        Some(l) => {
            map.insert(path.to_string(), l.key().to_string());
        }
        None => {
            map.remove(path);
        }
    }
    let _ = std::fs::create_dir_all(crate::platform::config_dir());
    let tmp = file().with_extension("json.tmp");
    std::fs::write(&tmp, serde_json::to_vec(&map).unwrap_or_default())?;
    std::fs::rename(tmp, file())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keys_are_the_macos_apps() {
        for l in Label::ALL {
            assert_eq!(Label::from_key(l.key()), Some(l));
        }
        assert_eq!(Label::Teal.key(), "teal");
        assert_eq!(Label::from_key("magenta"), None);
    }
}
