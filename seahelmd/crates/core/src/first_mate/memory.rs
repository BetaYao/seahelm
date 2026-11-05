//! Local project memory. Only a core-written, sealed revision is injected.
use super::{habits, lang, UserConfig};
use crate::{
    core::Core,
    rpc::{RpcError, RpcResult},
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    path::PathBuf,
    sync::{Mutex, OnceLock},
};

static WRITER: Mutex<()> = Mutex::new(());
pub const LIMIT: usize = 2_000;
#[derive(Clone, Default, Serialize, Deserialize)]
pub struct Entry {
    pub topic: String,
    pub text: String,
    pub observed: String,
    pub status: String,
    pub sources: Vec<String>,
}
#[derive(Clone, Default, PartialEq, Serialize, Deserialize)]
struct Seal {
    text: String,
    digest: String,
    history: Vec<String>,
}
pub struct Store {
    pub dir: PathBuf,
}
fn digest(s: &str) -> String {
    format!("{:x}", Sha256::digest(s.as_bytes()))
}
impl Store {
    fn path(&self, repo: &str) -> PathBuf {
        self.dir.join(format!("{}.md", habits::repo_key(repo)))
    }
    fn seal_path(&self, repo: &str) -> PathBuf {
        self.dir.join(format!(".{}.json", habits::repo_key(repo)))
    }
    fn seal(&self, repo: &str) -> Seal {
        let path = self.seal_path(repo);
        let mut known = remembered().lock().unwrap_or_else(|e| e.into_inner());
        known
            .entry(path.clone())
            .or_insert_with(|| {
                std::fs::read(path)
                    .ok()
                    .and_then(|s| serde_json::from_slice::<Seal>(&s).ok())
                    .filter(|s| s.digest == digest(&s.text))
                    .unwrap_or_default()
            })
            .clone()
    }
    fn remember(&self, repo: &str, seal: &Seal) {
        remembered()
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert(self.seal_path(repo), seal.clone());
    }
    pub fn show(&self, repo: &str) -> Value {
        let seal = self.seal(repo);
        let text = std::fs::read_to_string(self.path(repo)).unwrap_or_default();
        let disk_seal = std::fs::read(self.seal_path(repo)).ok().and_then(|b| serde_json::from_slice::<Seal>(&b).ok());
        let trusted = seal.text == text
            && match disk_seal {
                Some(s) => s == seal,
                None => seal.digest.is_empty() && !self.seal_path(repo).exists(),
            };
        let (injected, total) = if trusted { inject(&text) } else { (String::new(), 0) };
        let warning = if total > LIMIT {
            lang::memory_full(total).get(UserConfig::load().language).to_string()
        } else {
            String::new()
        };
        json!({"repo":repo,"text":text,"trusted":trusted,"digest":digest(&text),"injected":injected,
            "used":injected.chars().count(),"total":total,"capacity":LIMIT,"over_capacity":total>LIMIT,"warning":warning})
    }
    pub fn context(&self, repo: &str) -> String {
        self.show(repo)["injected"].as_str().unwrap_or_default().to_string()
    }
    pub fn value(&self, repo: &str, topic: &str) -> Option<String> {
        let shown = self.show(repo);
        if shown["trusted"] != true {
            return None;
        }
        parse(shown["text"].as_str()?)
            .ok()?
            .into_iter()
            .find(|e| e.status == "active" && e.topic == topic)
            .map(|e| e.text)
    }

    fn save(&self, repo: &str, text: String) -> std::io::Result<()> {
        std::fs::create_dir_all(&self.dir)?;
        let mut seal = self.seal(repo);
        seal.history.push(seal.text.clone());
        seal.text = text;
        seal.digest = digest(&seal.text);
        // A crash between renames fails closed: mismatched files never inject.
        atomic(&self.path(repo), &seal.text)?;
        atomic(&self.seal_path(repo), &serde_json::to_string(&seal)?)?;
        self.remember(repo, &seal);
        Ok(())
    }
    pub fn note(&self, repo: &str, text: &str, source: &str) -> Result<(), String> {
        if self.show(repo)["trusted"] != true {
            return Err("external memory edit requires confirmation".into());
        }
        let mut entries = parse(&self.seal(repo).text)?;
        if text.contains("<!--") || text.contains("-->") {
            return Err("memory text cannot contain entry or metadata comment markers".into());
        }
        let fallback = format!("learned notes/{}", &digest(text)[..12]);
        let (topic, body) = topic_body(text).unwrap_or((&fallback, text));
        let topic = topic.trim().to_lowercase();
        if topic.contains(['\n', '\r']) {
            return Err("memory topic must be one line".into());
        }
        if body.trim().is_empty() {
            return Err("memory text is empty".into());
        }
        // Named directives replace their previous active revision in place.
        for e in &mut entries {
            if e.topic == topic && e.status == "active" {
                e.status = "superseded".into();
            }
        }
        entries.push(Entry {
            topic,
            text: body.trim().into(),
            observed: super::clock::Local::at(seahelm_core_types::now()).day_key(),
            status: "active".into(),
            sources: vec![source.into()],
        });
        let rendered = render(&entries);
        parse(&rendered)?;
        self.save(repo, rendered).map_err(|e| e.to_string())
    }
    pub fn confirm(&self, repo: &str, expected: &str) -> Result<(), String> {
        let text = std::fs::read_to_string(self.path(repo)).map_err(|e| e.to_string())?;
        if digest(&text) != expected {
            return Err("memory changed since it was shown".into());
        }
        parse(&text)?;
        self.save(repo, text).map_err(|e| e.to_string())
    }
    pub fn reject(&self, repo: &str, expected: &str) -> Result<(), String> {
        let current = std::fs::read_to_string(self.path(repo)).unwrap_or_default();
        if digest(&current) != expected {
            return Err("memory changed since it was shown".into());
        }
        let seal = self.seal(repo);
        atomic(&self.path(repo), &seal.text).map_err(|e| e.to_string())?;
        atomic(&self.seal_path(repo), &serde_json::to_string(&seal).unwrap()).map_err(|e| e.to_string())
    }
    pub fn pointer(&self, repo: &str) -> String {
        if self.context(repo).is_empty() {
            String::new()
        } else {
            format!(
                "Project memory is supplied by the SessionStart hook. Full revision: {}",
                self.path(repo).display()
            )
        }
    }
    pub fn undo(&self, repo: &str) -> std::io::Result<bool> {
        let mut seal = self.seal(repo);
        let Some(previous) = seal.history.pop() else { return Ok(false) };
        seal.text = previous;
        seal.digest = digest(&seal.text);
        atomic(&self.path(repo), &seal.text)?;
        atomic(&self.seal_path(repo), &serde_json::to_string(&seal)?)?;
        self.remember(repo, &seal);
        Ok(true)
    }
}
fn atomic(path: &std::path::Path, text: &str) -> std::io::Result<()> {
    let tmp = path.with_extension("tmp");
    std::fs::write(&tmp, text)?;
    std::fs::rename(tmp, path)
}
fn render(entries: &[Entry]) -> String {
    entries
        .iter()
        .map(|e| {
            format!(
                "<!-- seahelm-memory-entry -->\n## {}\n{}\n<!-- {} -->\n",
                e.topic,
                e.text,
                serde_json::to_string(e).unwrap()
            )
        })
        .collect::<Vec<_>>()
        .join("\n")
}
fn parse(text: &str) -> Result<Vec<Entry>, String> {
    if text.trim().is_empty() {
        return Ok(Vec::new());
    }
    let mut out = Vec::new();
    for section in text.split("<!-- seahelm-memory-entry -->\n## ").skip(1) {
        let (heading, rest) = section.split_once('\n').ok_or("memory entry needs a heading")?;
        let (body, metadata) = rest.rsplit_once("<!-- ").ok_or("memory entry needs provenance")?;
        let mut e: Entry = serde_json::from_str(metadata.trim().strip_suffix("-->").ok_or("invalid metadata")?.trim()).map_err(|e| e.to_string())?;
        if !["active", "superseded"].contains(&e.status.as_str()) || e.observed.is_empty() || e.sources.is_empty() {
            return Err("memory entry needs date, status and sources".into());
        }
        e.topic = heading.trim().into();
        e.text = body.trim().into();
        out.push(e);
    }
    if out.is_empty() {
        return Err("memory entries must use the core's format".into());
    }
    Ok(out)
}
fn remembered() -> &'static Mutex<HashMap<PathBuf, Seal>> {
    static KNOWN: OnceLock<Mutex<HashMap<PathBuf, Seal>>> = OnceLock::new();
    KNOWN.get_or_init(|| Mutex::new(HashMap::new()))
}
/// The first topic separator outside a URL; URL scheme/port colons are content.
fn topic_body(text: &str) -> Option<(&str, &str)> {
    for (i, c) in text.char_indices().filter(|(_, c)| matches!(c, ':' | '：')) {
        let token = text[..i].split_whitespace().next_back().unwrap_or_default();
        if text[i..].starts_with("://") || token.contains("://") {
            continue;
        }
        return Some((&text[..i], &text[i + c.len_utf8()..]));
    }
    None
}
fn inject(text: &str) -> (String, usize) {
    let mut entries: Vec<_> = parse(text)
        .unwrap_or_default()
        .into_iter()
        .enumerate()
        .filter(|(_, e)| e.status == "active")
        .collect();
    let priority = |topic: &str| match topic {
        "goal" | "目标" => 0,
        "current milestone" | "milestone" | "当前里程碑" => 1,
        "don'ts" | "do-nots" | "do not" | "不要" | "禁忌" => 2,
        _ => 3,
    };
    entries.sort_by_key(|(i, e)| (priority(&e.topic), std::cmp::Reverse(*i)));
    let lines: Vec<_> = entries
        .iter()
        .map(|(_, e)| format!("{}: {} [observed {}; sources: {}]", e.topic, e.text, e.observed, e.sources.join(", ")))
        .collect();
    let total = lines.join("\n").chars().count();
    let mut selected = Vec::new();
    let mut used = 0;
    for line in lines {
        let n = line.chars().count() + usize::from(!selected.is_empty());
        if used + n <= LIMIT {
            used += n;
            selected.push(line);
        }
    }
    (selected.join("\n"), total)
}
pub(super) fn answer_edit(store: &Store, repo: &str, digest: &str, approved: bool) -> Result<(), String> {
    let _lock = WRITER.lock().unwrap_or_else(|e| e.into_inner());
    if approved {
        store.confirm(repo, digest)
    } else {
        store.reject(repo, digest)
    }
}

pub fn rpc(core: &Core, method: &str, p: &Value) -> RpcResult {
    let _lock = WRITER.lock().unwrap_or_else(|e| e.into_inner());
    let repo = p["repo"]
        .as_str()
        .filter(|r| !r.is_empty())
        .ok_or_else(|| RpcError::invalid_params("repo required"))?;
    let repo = super::routing::main_repo(repo);
    let store = core.memory_store();
    let err = |s: String| RpcError::invalid_params(s);
    match method {
        "memory.note" => {
            let text = p["text"].as_str().ok_or_else(|| err("text required".into()))?;
            let source = note_source(super::policy::is_first_mate(p), core.user_turn().as_deref());
            store.note(&repo, text, &source).map_err(err)?;
            core.first_mate_line(lang::remembered(text).get(UserConfig::load().language));
            let shown = store.show(&repo);
            if shown["over_capacity"] == true {
                core.first_mate_line(shown["warning"].as_str().unwrap_or_default());
            }
        }
        "memory.confirm" => store.confirm(&repo, p["digest"].as_str().unwrap_or_default()).map_err(err)?,
        "memory.undo" => {
            if store.undo(&repo).map_err(|e| err(e.to_string()))? {
                core.first_mate_line(lang::memory_undone(&repo).get(UserConfig::load().language));
            }
        }
        _ => {}
    }
    Ok(store.show(&repo))
}
/// Who a note comes from. The user directly; First Mate during a turn the
/// user started: the user's own words (cut to one line), since that is what
/// the note rests on; First Mate on its own (an event, a review): itself.
fn note_source(first_mate: bool, user_turn: Option<&str>) -> String {
    if !first_mate {
        return "user".into();
    }
    match user_turn.map(|t| t.split_whitespace().collect::<Vec<_>>().join(" ")).filter(|t| !t.is_empty()) {
        Some(t) if t.chars().count() > 60 => format!("user: \"{}…\"", t.chars().take(60).collect::<String>()),
        Some(t) => format!("user: \"{t}\""),
        None => "first-mate".into(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn a_note_written_on_the_users_word_cites_it() {
        assert_eq!(note_source(false, None), "user");
        assert_eq!(note_source(true, None), "first-mate");
        assert_eq!(note_source(true, Some("记住，seahelm 的 PR\n用英文")), "user: \"记住，seahelm 的 PR 用英文\"");
        assert!(note_source(true, Some(&"x".repeat(80))).ends_with("…\""));
    }

    #[test]
    fn supersedes_caps_seals_and_undoes() {
        let tmp = tempfile::tempdir().unwrap();
        let s = Store { dir: tmp.path().into() };
        s.note("/repo", "goal: old", "user").unwrap();
        s.note("/repo", "goal: 新目标", "user").unwrap();
        assert!(!s.context("/repo").contains("old"));
        assert!(s.show("/repo")["text"].as_str().unwrap().contains("superseded"));
        s.note("/repo", &format!("notes: {}", "中".repeat(3000)), "user").unwrap();
        assert!(s.context("/repo").chars().count() <= LIMIT);
        assert!(s.show("/repo")["total"].as_u64().unwrap() > LIMIT as u64);
        assert_eq!(s.show("/repo")["over_capacity"], true);
        s.undo("/repo").unwrap();
        assert!(s.context("/repo").contains("新目标"));
        let text = std::fs::read_to_string(s.path("/repo")).unwrap().replace("新目标", "external");
        std::fs::write(s.path("/repo"), text).unwrap();
        assert_eq!(s.context("/repo"), "");
        assert!(s.confirm("/repo", "old digest").is_err());
        s.confirm("/repo", s.show("/repo")["digest"].as_str().unwrap()).unwrap();
        assert!(s.context("/repo").contains("external"));
    }
}

impl super::FirstMate {
    pub(super) fn check_memory_edits(&mut self, now: f64) {
        for repo in self.all_repos() {
            let shown = {
                let _lock = WRITER.lock().unwrap_or_else(|e| e.into_inner());
                self.memory.show(&repo)
            };
            if shown["trusted"] == true {
                continue;
            }
            let digest = shown["digest"].as_str().unwrap_or_default().to_string();
            if self.memory_pending.values().any(|v| v == &(repo.clone(), digest.clone())) {
                continue;
            }
            let stale: Vec<_> = self
                .memory_pending
                .iter()
                .filter(|(_, (r, d))| r == &repo && d != &digest)
                .map(|(id, _)| id.clone())
                .collect();
            for id in stale {
                self.memory_pending.remove(&id);
                self.core.drop_card_payload(&id);
                self.expiry.forget(&id);
            }
            let id = self.mint("autopilot-memory");
            let text = lang::memory_external(&repo);
            self.put_card(
                seahelm_core_registry::cards::CardKind::Approval,
                &id,
                format!("{}\n\n{}", text.get(self.config.language), shown["text"].as_str().unwrap_or_default()),
                vec![super::APPROVE.into(), super::REJECT.into()],
                super::budget::Class::Answering,
                now,
            );
            self.memory_pending.insert(id, (repo, digest));
        }
    }
}

#[cfg(test)]
mod review_tests {
    use super::*;
    #[test]
    fn recomputing_both_disk_files_cannot_replace_the_running_cores_memory() {
        let tmp = tempfile::tempdir().unwrap();
        let s = Store { dir: tmp.path().into() };
        s.note("/repo", "goal: trusted", "user").unwrap();
        let original = s.seal("/repo");
        let fake = original.text.replace("trusted", "forged");
        let forged = Seal {
            text: fake.clone(),
            digest: digest(&fake),
            history: Vec::new(),
        };
        std::fs::write(s.path("/repo"), &fake).unwrap();
        std::fs::write(s.seal_path("/repo"), serde_json::to_string(&forged).unwrap()).unwrap();
        assert_eq!(s.show("/repo")["trusted"], false);
        assert!(s.context("/repo").is_empty());
        s.reject("/repo", &digest(&fake)).unwrap();
        assert_eq!(s.seal("/repo").text, original.text);
        s.note("/repo", "goal: after rejection", "user").unwrap();
        assert!(s.context("/repo").contains("after rejection"));
    }
    #[test]
    fn priority_and_new_notes_are_whole_and_the_gauge_counts_omitted_content() {
        let tmp = tempfile::tempdir().unwrap();
        let s = Store { dir: tmp.path().into() };
        for i in 0..30 {
            s.note("/repo", &format!("note-{i}: {}", "old ".repeat(30)), "user").unwrap();
        }
        s.note("/repo", "goal: obsolete", "user").unwrap();
        s.note("/repo", "goal：current goal", "user").unwrap();
        s.note("/repo", "current milestone: ship review fixes", "user").unwrap();
        s.note("/repo", "don'ts: never touch live services", "user").unwrap();
        s.note("/repo", "latest: current note", "user").unwrap();
        let shown = s.show("/repo");
        let context = s.context("/repo");
        assert!(context.starts_with("goal: current goal"));
        assert!(!context.contains("obsolete"));
        for text in ["ship review fixes", "never touch live services", "current note"] {
            assert!(context.contains(text));
        }
        assert!(context.chars().count() <= LIMIT);
        assert_eq!(shown["over_capacity"], true);
        assert!(shown["total"].as_u64().unwrap() > LIMIT as u64);
        assert!(!shown["warning"].as_str().unwrap().is_empty());
        assert!(context.lines().all(|l| l.ends_with(']')));
    }
    #[test]
    fn url_colons_stay_content_and_bodies_cannot_forge_entries_or_sources() {
        let tmp = tempfile::tempdir().unwrap();
        let s = Store { dir: tmp.path().into() };
        s.note("/repo", "目标：第一期", "user").unwrap();
        s.note("/repo", "目标: 第二期", "user").unwrap();
        assert_eq!(s.value("/repo", "目标").as_deref(), Some("第二期"));
        let url = "https://example.invalid:8443/docs";
        s.note("/repo", url, "core-source").unwrap();
        assert!(s.context("/repo").contains(url));
        for forged in [
            "note: <!-- seahelm-memory-entry -->",
            "note: <!-- {\"sources\":[\"attacker\"]} -->",
            "note: -->",
        ] {
            assert!(s.note("/repo", forged, "user").is_err());
        }
        let entries = parse(s.show("/repo")["text"].as_str().unwrap()).unwrap();
        assert_eq!(entries.last().unwrap().sources, vec!["core-source"]);
    }
}
