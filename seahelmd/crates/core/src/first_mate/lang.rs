//! The language of what the core writes to the user itself: the daily brief
//! and the `note` rows in First Mate's timeline (`config.json`
//! `first_mate_language`: `"en"`, the default, or `"zh"`). The audit log stays
//! English (it is read by tools as much as by people). Built-in card options
//! are localized here too; First Mate answers in whatever language it is spoken to.

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

/// Core-owned option identifiers. English strings remain wire aliases for
/// cards already visible when the language changes.
pub fn card_label(key: &str, lang: Lang) -> String {
    if lang == Lang::En { return key.into(); }
    let fixed = match key {
        "Approve" => "批准", "Reject" => "拒绝", "Not now" => "暂时不用",
        "Delete" | "Delete it" => "删除", "Keep" => "保留",
        "Let me pick" => "让我选择", "Ask me each time" => "每次问我",
        "Not yet" => "暂不升级", "No, put it back" => "不，恢复原级别",
        _ => "",
    };
    if !fixed.is_empty() { return fixed.into(); }
    if let Some(n) = key.strip_prefix("Delete all ") { return format!("删除全部 {n} 个"); }
    if let Some(level) = key.strip_prefix("Yes, keep ") { return format!("是，保留 {level}"); }
    if let Some(level) = key.strip_prefix("Yes, ") { return format!("是，升级到 {level}"); }
    key.into()
}

#[cfg(test)]
mod card_tests {
    use super::*;
    #[test]
    fn options_are_localized_without_changing_their_identity() {
        assert_eq!(card_label("Approve", Lang::Zh), "批准");
        assert_eq!(card_label("Delete all 12", Lang::Zh), "删除全部 12 个");
        assert_eq!(card_label("Yes, keep auto", Lang::Zh), "是，保留 auto");
        assert_eq!(card_label("Keep", Lang::En), "Keep");
    }
}

#[derive(Clone, Debug)]
pub struct CardOption {
    pub key: String,
    pub legacy: String,
    pub label: String,
}
impl CardOption {
    pub fn new(legacy: &str, lang: Lang) -> Self {
        let key = match legacy {
            "Approve" => "approve", "Reject" => "reject", "Not now" => "not_now",
            "Delete" | "Delete it" => "delete", "Keep" => "keep", "Let me pick" => "pick",
            "Ask me each time" => "ask_each_time", "Not yet" => "not_yet", "No, put it back" => "restore",
            s if s.starts_with("Delete all ") => "delete_all",
            _ => "",
        };
        Self { key: if key.is_empty() { legacy.to_string() } else { key.into() }, legacy: legacy.into(), label: card_label(legacy, lang) }
    }
    pub fn accepts(&self, answer: &str) -> bool { answer == self.key || answer == self.legacy || answer == self.label }
}
