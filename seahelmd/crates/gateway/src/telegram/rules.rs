//! "A message arrived → put an agent on it": the signal half of the bot, for
//! messages that are not orders (anyone off the allowlist: a monitoring
//! channel, a colleague, an alerting SMS bridge). Rules never reply and never
//! create anything; they route text into a pane that already exists, so the
//! worst a noisy source can do is make one pane noisy.

use std::collections::HashMap;

use fancy_regex::RegexBuilder;
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Rule {
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub enabled: Option<bool>,
    /// Regex over the sender handle; empty matches anyone.
    #[serde(default)]
    pub from: Option<String>,
    /// Regex over the body; empty matches anything. Its groups fill `{{1}}`….
    #[serde(default, rename = "match")]
    pub pattern: Option<String>,
    /// `{{text}}`, `{{from}}` and `{{1}}`…`{{9}}`.
    #[serde(default)]
    pub prompt: String,
    pub target: Target,
}

impl Rule {
    pub fn is_enabled(&self) -> bool {
        self.enabled.unwrap_or(true)
    }
}

/// Where a rule's prompt goes. Always a pane that exists.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Target {
    /// `pane` (session key or pane id), `worktree` (path or its last
    /// component) or `project` (repo name or path).
    pub kind: String,
    #[serde(default)]
    pub value: String,
}

impl Target {
    pub fn key(&self) -> String {
        format!("{}:{}", self.kind, self.value.trim())
    }
}

/// The rules as config holds them; entries that do not parse are skipped.
pub fn parse_rules(raw: &[Value]) -> Vec<Rule> {
    raw.iter().filter_map(|v| serde_json::from_value(v.clone()).ok()).collect()
}

#[derive(Debug, Clone, PartialEq)]
pub struct Match {
    pub rule: Rule,
    pub prompt: String,
}

/// The first enabled rule whose sender and body patterns both match.
/// First-wins: two rules firing on one alert would type the same text into
/// two panes. Order the list from most specific to least.
pub fn first_match(rules: &[Rule], sender: &str, text: &str) -> Option<Match> {
    rules.iter().filter(|r| r.is_enabled()).find_map(|rule| {
        matches(rule.from.as_deref(), sender)?;
        let groups = matches(rule.pattern.as_deref(), text)?;
        Some(Match { rule: rule.clone(), prompt: render(&rule.prompt, text, sender, &groups) })
    })
}

/// The groups when `pattern` matches, `[]` when it is empty (anything goes),
/// None when it does not match or does not compile — a typo'd pattern must
/// not fire an agent on every message. Case-insensitive, and `.` spans
/// newlines: alert texts are multi-line, and `^(?=.*a)(?=.*b).*` must mean
/// "mentions both somewhere".
pub fn matches(pattern: Option<&str>, subject: &str) -> Option<Vec<String>> {
    let pattern = pattern.map(str::trim).unwrap_or_default();
    if pattern.is_empty() {
        return Some(Vec::new());
    }
    // fancy-regex has no dot-all switch on the builder; the inline flag does it.
    let re = RegexBuilder::new(&format!("(?s){pattern}")).case_insensitive(true).build().ok()?;
    let caps = re.captures(subject).ok()??;
    Some((1..caps.len()).map(|i| caps.get(i).map(|m| m.as_str().to_string()).unwrap_or_default()).collect())
}

pub fn render(template: &str, text: &str, from: &str, groups: &[String]) -> String {
    let mut out = template.replace("{{text}}", text).replace("{{from}}", from);
    for (i, g) in groups.iter().enumerate() {
        out = out.replace(&format!("{{{{{}}}}}", i + 1), g);
    }
    // An absent capture is empty, not a literal `{{3}}`.
    for i in 1..=9 {
        out = out.replace(&format!("{{{{{i}}}}}"), "");
    }
    out
}

/// A pane as the rule resolver sees it (from the core's `pane.list`).
#[derive(Debug, Clone, PartialEq)]
pub struct PaneRow {
    pub session_key: String,
    pub pane_id: String,
    pub worktree_path: String,
    pub project: String,
}

/// The pane a target names, or None: a rule pointing at a deleted worktree
/// does nothing rather than guess at a neighbour.
pub fn resolve_pane<'a>(target: &Target, panes: &'a [PaneRow]) -> Option<&'a PaneRow> {
    let needle = target.value.trim();
    if needle.is_empty() {
        return None;
    }
    let last = |p: &str| p.trim_end_matches('/').rsplit('/').next().unwrap_or(p).to_string();
    match target.kind.as_str() {
        "pane" => panes.iter().find(|p| p.session_key == needle || p.pane_id == needle),
        "worktree" => panes.iter().find(|p| p.worktree_path == needle).or_else(|| panes.iter().find(|p| last(&p.worktree_path) == needle)),
        "project" => panes.iter().find(|p| p.project == needle).or_else(|| panes.iter().find(|p| last(&p.project) == needle)),
        _ => None,
    }
}

/// Merges rule prompts aimed at one pane within a window, so a burst of
/// related alerts (80% and 90% in the same second) is one agent turn. The
/// window is fixed from the first hit; later hits append without sliding it,
/// so a noisy source cannot delay forever.
#[derive(Debug, Default)]
pub struct Coalescer {
    buckets: HashMap<String, (Target, Vec<String>)>,
}

pub const COALESCE_WINDOW_SECS: u64 = 30;

impl Coalescer {
    /// Buffer a prompt. The bucket's key when this hit armed it: the caller
    /// schedules `flush(key)` after the window.
    pub fn enqueue(&mut self, prompt: &str, target: &Target) -> Option<String> {
        let trimmed = prompt.trim();
        if trimmed.is_empty() {
            return None;
        }
        let key = target.key();
        let fresh = !self.buckets.contains_key(&key);
        let bucket = self.buckets.entry(key.clone()).or_insert_with(|| (target.clone(), Vec::new()));
        if !bucket.1.iter().any(|p| p == trimmed) {
            bucket.1.push(trimmed.to_string());
        }
        fresh.then_some(key)
    }

    /// The combined prompt and its target, once the window is over.
    pub fn flush(&mut self, key: &str) -> Option<(String, Target)> {
        let (target, prompts) = self.buckets.remove(key)?;
        let combined = combine(&prompts);
        (!combined.is_empty()).then_some((combined, target))
    }
}

/// One alert stays verbatim, so rule templates keep their wording; a burst
/// gets a header.
pub fn combine(prompts: &[String]) -> String {
    let parts: Vec<&str> = prompts.iter().map(|p| p.trim()).filter(|p| !p.is_empty()).collect();
    match parts.len() {
        0 => String::new(),
        1 => parts[0].to_string(),
        n => {
            let mut lines = vec![format!("收到 {n} 条告警（已合并），请一并排查：")];
            for (i, p) in parts.iter().enumerate() {
                lines.push(format!("—— {}/{n} ——\n{p}", i + 1));
            }
            lines.join("\n\n")
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn rule(from: Option<&str>, pattern: Option<&str>, prompt: &str) -> Rule {
        Rule { name: "r".into(), enabled: None, from: from.map(Into::into), pattern: pattern.map(Into::into), prompt: prompt.into(), target: Target { kind: "worktree".into(), value: "wt".into() } }
    }

    #[test]
    fn parses_the_rules_editor_shape() {
        let raw = vec![
            json!({"name": "a", "from": "@ops", "match": "CPU (\\d+)%", "prompt": "look {{1}}", "target": {"kind": "pane", "value": "s-1"}}),
            json!({"name": "broken"}),
        ];
        let rules = parse_rules(&raw);
        assert_eq!(rules.len(), 1);
        assert_eq!(rules[0].pattern.as_deref(), Some("CPU (\\d+)%"));
        assert!(rules[0].is_enabled());
    }

    #[test]
    fn matches_with_lookaheads_across_lines() {
        let r = rule(None, Some("^(?=.*阿里云)(?=.*告警).*"), "{{text}}");
        assert!(first_match(std::slice::from_ref(&r), "x", "【阿里云】\n您的实例告警").is_some());
        assert!(first_match(&[r], "x", "阿里云 only").is_none());
    }

    #[test]
    fn renders_groups_and_sender() {
        let r = rule(Some("^@ops$"), Some("cpu (\\d+)% on (\\w+)(x)?"), "{{from}}: {{2}} at {{1}}{{3}} / {{text}}");
        let m = first_match(std::slice::from_ref(&r), "@OPS", "CPU 93% on web1").unwrap();
        assert_eq!(m.prompt, "@OPS: web1 at 93 / CPU 93% on web1");
        assert!(first_match(&[r], "@dev", "CPU 93% on web1").is_none());
    }

    #[test]
    fn bad_patterns_and_disabled_rules_fail_closed() {
        assert!(matches(Some("(unclosed"), "anything").is_none());
        assert_eq!(matches(Some("  "), "x"), Some(vec![]));
        let mut r = rule(None, None, "p");
        r.enabled = Some(false);
        assert!(first_match(&[r], "a", "b").is_none());
    }

    #[test]
    fn resolves_targets_without_guessing() {
        let panes = vec![
            PaneRow { session_key: "s-a".into(), pane_id: "A".into(), worktree_path: "/r/wt/fix".into(), project: "repo".into() },
            PaneRow { session_key: "s-b".into(), pane_id: "B".into(), worktree_path: "/r".into(), project: "repo".into() },
        ];
        let t = |k: &str, v: &str| Target { kind: k.into(), value: v.into() };
        assert_eq!(resolve_pane(&t("pane", "B"), &panes).unwrap().session_key, "s-b");
        assert_eq!(resolve_pane(&t("worktree", "fix"), &panes).unwrap().session_key, "s-a");
        assert_eq!(resolve_pane(&t("project", "repo"), &panes).unwrap().session_key, "s-a");
        assert!(resolve_pane(&t("worktree", "gone"), &panes).is_none());
        assert!(resolve_pane(&t("pane", " "), &panes).is_none());
    }

    #[test]
    fn coalesces_a_burst() {
        let mut c = Coalescer::default();
        let t = Target { kind: "pane".into(), value: "s".into() };
        let key = c.enqueue("80%", &t).unwrap();
        assert!(c.enqueue("90%", &t).is_none());
        assert!(c.enqueue("80%", &t).is_none());
        let (text, target) = c.flush(&key).unwrap();
        assert_eq!(target, t);
        assert!(text.starts_with("收到 2 条告警"));
        assert!(text.contains("—— 2/2 ——\n90%"));
        assert!(c.flush(&key).is_none());
        let key = c.enqueue("solo", &t).unwrap();
        assert_eq!(c.flush(&key).unwrap().0, "solo");
    }
}
