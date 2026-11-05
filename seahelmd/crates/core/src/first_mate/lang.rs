//! The language of what the core writes to the user itself: the daily brief
//! and the `note` rows in First Mate's timeline (`config.json`
//! `first_mate_language`: `"en"`, the default, or `"zh"`). The audit log,
//! cards and First Mate's own words are not covered: the audit stays
//! English (it is read by tools as much as by people), cards are a later
//! step, and First Mate answers in whatever language it is spoken to.

use std::ops::Deref;

use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Lang {
    #[default]
    En,
    Zh,
}

impl Lang {
    /// `"zh"`, `"zh-CN"`, `"zh_Hans"` … are Chinese; anything else English.
    pub fn parse(s: Option<&str>) -> Lang {
        match s.map(|s| s.trim().to_ascii_lowercase()) {
            Some(s) if s.starts_with("zh") => Lang::Zh,
            _ => Lang::En,
        }
    }

    pub fn pick<'a>(self, en: &'a str, zh: &'a str) -> &'a str {
        match self {
            Lang::En => en,
            Lang::Zh => zh,
        }
    }
}

/// One line in both languages. Reads as its English text (`Deref`), which
/// is what the audit log keeps.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Text {
    pub en: String,
    pub zh: String,
}

impl Text {
    pub fn new(en: impl Into<String>, zh: impl Into<String>) -> Text {
        Text { en: en.into(), zh: zh.into() }
    }

    pub fn get(&self, lang: Lang) -> &str {
        match lang {
            Lang::En => &self.en,
            Lang::Zh if self.zh.is_empty() => &self.en,
            Lang::Zh => &self.zh,
        }
    }
}

impl std::fmt::Display for Text {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.en)
    }
}

impl Deref for Text {
    type Target = str;
    fn deref(&self) -> &str {
        &self.en
    }
}

/// "1 worktree" / "3 worktrees".
pub fn plural_en(n: usize, one: &str) -> String {
    format!("{n} {one}{}", if n == 1 { "" } else { "s" })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_and_falls_back() {
        assert_eq!(Lang::parse(None), Lang::En);
        assert_eq!(Lang::parse(Some("en")), Lang::En);
        assert_eq!(Lang::parse(Some("zh")), Lang::Zh);
        assert_eq!(Lang::parse(Some(" zh-CN ")), Lang::Zh);
        assert_eq!(Lang::parse(Some("fr")), Lang::En);
        let t = Text::new("Deleted a", "删了 a");
        assert_eq!((t.get(Lang::En), t.get(Lang::Zh), &*t), ("Deleted a", "删了 a", "Deleted a"));
        assert_eq!(Text::new("only", "").get(Lang::Zh), "only");
    }
}
