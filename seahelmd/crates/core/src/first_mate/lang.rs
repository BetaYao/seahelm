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

/// Display labels for built-in options. Cards already shown in English keep
/// those English labels; translated cards accept only their shown labels.
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

/// Internal identity; clients send an index or the label actually shown.
/// Old English cards still normalize here when their original labels arrive.
pub fn option_key(label: &str) -> String {
    let fixed = match label {
        "Approve" => "approve", "Reject" => "reject", "Not now" => "not_now",
        "Delete" | "Delete it" => "delete", "Keep" => "keep", "Let me pick" => "pick",
        "Ask me each time" => "ask_each_time", "Not yet" => "not_yet", "No, put it back" => "restore",
        s if s.starts_with("Delete all ") => "delete_all",
        _ => "",
    };
    if !fixed.is_empty() { return fixed.into(); }
    if let Some(level) = label.strip_prefix("Yes, keep ") { return format!("confirm:{level}"); }
    if let Some(level) = label.strip_prefix("Yes, ") { return format!("yes:{level}"); }
    label.into()
}

pub fn habit_action(action: super::habits::Do, lang: Lang) -> &'static str {
    match action {
        super::habits::Do::DeleteWorktree => lang.pick("delete a worktree", "删除 worktree"),
        super::habits::Do::Keep => lang.pick("keep a worktree", "保留 worktree"),
    }
}

pub fn with_habit(text: String, id: Option<&str>, lang: Lang) -> String {
    match id { Some(id) => format!("{text} [{}: {id}]",lang.pick("habit","习惯")), None => text }
}

#[derive(Clone, Debug)]
pub struct CardOption { pub key: String, pub label: String }
impl CardOption {
    pub fn new(label: &str, lang: Lang, index: usize) -> Self {
        let key = option_key(label);
        Self { key: if key == label { format!("choice:{index}") } else { key }, label: card_label(label, lang) }
    }
}

pub fn remembered(text: &str) -> Text { Text::new(format!("Noted: {text}"), format!("记下了：{text}")) }
pub fn memory_external(repo: &str) -> Text { Text::new(format!("Project memory changed outside the core: {repo}. Review and confirm the exact revision before it is injected."), format!("项目记忆在核心外被修改：{repo}。请审阅并确认此版本后再注入。")) }
pub fn route_started(path: &str) -> Text { Text::new(format!("Started: {path}"), format!("已启动：{path}")) }
pub fn route_choose() -> Text { Text::new("Choose a project for this request", "为这个请求选择项目") }

pub fn route_once() -> Text { Text::new("Another project start this turn needs your approval.", "本轮再次启动项目需要你的确认。") }
pub fn issue_existing(n: u64, place: &str) -> Text { Text::new(format!("Issue #{n} is already in hand: {place}"), format!("议题 #{n} 已在处理中：{place}")) }

pub fn route_unknown() -> Text { Text::new("Project is unknown or its rules cannot be read.", "项目未知或项目规则无法读取。") }

pub fn memory_failure(detail: &str) -> Text { Text::new(format!("Could not complete the request: {detail}"), format!("未能完成请求：{detail}")) }

pub fn memory_full(total: usize) -> Text { Text::new(format!("Project memory uses {total}/2000 characters; over capacity. Only complete priority entries and newest notes are injected."),format!("项目记忆 {total}/2000 字，已超出容量；仅注入完整的优先条目和最新笔记。")) }
pub fn memory_refused(method: &str) -> Text { Text::new(format!("{method} refused: memory notes require the user or the kernel-identified First Mate session; undo and confirmation require the user."),format!("已拒绝 {method}：记忆写入仅限你本人或内核识别的 First Mate 会话，撤销及确认外部编辑仅限你本人。")) }
pub fn alias_offer(alias: &str, repo: &str) -> Text { Text::new(format!("Use “{alias}” as a short project name for {repo}?"),format!("将“{alias}”作为 {repo} 的项目简称吗？")) }

pub fn memory_display(verb: &str, shown: &serde_json::Value) -> Text {
    let body = shown["text"].as_str().unwrap_or_default();
    let total = shown["total"].as_u64().unwrap_or(0);
    Text::new(format!("Memory {verb}: {total}/2000 characters\n{body}\n{}",shown["warning"].as_str().unwrap_or_default()),format!("项目记忆 {verb}：{total}/2000 字\n{body}\n{}",shown["warning"].as_str().unwrap_or_default()))
}

pub fn memory_undone(repo: &str) -> Text { Text::new(format!("Restored the previous project memory: {repo}"),format!("已恢复项目记忆的上一版本：{repo}")) }
pub fn route_confirm() -> Text { Text::new("This project's rules require approval before starting an agent.","此项目的规则要求启动代理前由你确认。") }
