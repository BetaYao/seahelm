//! Local project memory. Only a core-written, sealed revision is injected.
use super::{habits, lang, UserConfig};
use crate::{
    core::Core,
    rpc::{RpcError, RpcResult},
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{path::PathBuf, sync::Mutex};

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
#[derive(Default, Serialize, Deserialize)]
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
    pub fn local() -> Self {
        Self {
            dir: crate::rpc::config_dir().join("first-mate/memory"),
        }
    }
    fn path(&self, repo: &str) -> PathBuf {
        self.dir.join(format!("{}.md", habits::repo_key(repo)))
    }
    fn seal_path(&self, repo: &str) -> PathBuf {
        self.dir.join(format!(".{}.json", habits::repo_key(repo)))
    }
    fn seal(&self, repo: &str) -> Seal {
        std::fs::read(self.seal_path(repo))
            .ok()
            .and_then(|s| serde_json::from_slice::<Seal>(&s).ok())
            .filter(|s| s.digest == digest(&s.text))
            .unwrap_or_default()
    }
    pub fn show(&self, repo: &str) -> Value {
        let text = std::fs::read_to_string(self.path(repo)).unwrap_or_default();
        let trusted = self.seal(repo).text == text;
        let injected = if trusted { inject(&text) } else { String::new() };
        json!({"repo": repo, "text": text, "trusted": trusted, "digest": digest(&text), "injected": injected, "used": injected.chars().count(), "capacity": LIMIT})
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
        atomic(&self.seal_path(repo), &serde_json::to_string(&seal)?)
    }
    pub fn note(&self, repo: &str, text: &str, source: &str) -> Result<(), String> {
        if self.show(repo)["trusted"] != true {
            return Err("external memory edit requires confirmation".into());
        }
        let mut entries = parse(&self.seal(repo).text)?;
        let fallback = format!("learned notes/{}", &digest(text)[..12]);
        let (topic, body) = text.split_once(':').unwrap_or((&fallback, text));
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
    pub fn undo(&self, repo: &str) -> std::io::Result<bool> {
        let mut seal = self.seal(repo);
        let Some(previous) = seal.history.pop() else { return Ok(false) };
        seal.text = previous;
        seal.digest = digest(&seal.text);
        atomic(&self.path(repo), &seal.text)?;
        atomic(&self.seal_path(repo), &serde_json::to_string(&seal)?)?;
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
fn inject(text: &str) -> String {
    let entries = parse(text).unwrap_or_default();
    entries
        .iter()
        .filter(|e| e.status == "active")
        .map(|e| format!("{}: {} [observed {}; sources: {}]", e.topic, e.text, e.observed, e.sources.join(", ")))
        .collect::<Vec<_>>()
        .join("\n")
        .chars()
        .take(LIMIT)
        .collect()
}
pub fn rpc(core: &Core, method: &str, p: &Value) -> RpcResult {
    let _lock = WRITER.lock().unwrap_or_else(|e| e.into_inner());
    let repo = p["repo"]
        .as_str()
        .filter(|r| !r.is_empty())
        .ok_or_else(|| RpcError::invalid_params("repo required"))?;
    let repo = super::routing::main_repo(repo);
    let store = Store::local();
    let err = |s: String| RpcError::invalid_params(s);
    match method {
        "memory.note" => {
            let text = p["text"].as_str().ok_or_else(|| err("text required".into()))?;
            let source = if super::policy::is_first_mate(p) { "first-mate" } else { "user" };
            store.note(&repo, text, source).map_err(err)?;
            core.first_mate_line(lang::remembered(text).get(UserConfig::load().language));
        }
        "memory.confirm" => store.confirm(&repo, p["digest"].as_str().unwrap_or_default()).map_err(err)?,
        "memory.undo" => {
            store.undo(&repo).map_err(|e| err(e.to_string()))?;
        }
        _ => {}
    }
    Ok(store.show(&repo))
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn supersedes_caps_seals_and_undoes() {
        let tmp = tempfile::tempdir().unwrap();
        let s = Store { dir: tmp.path().into() };
        s.note("/repo", "goal: old", "user").unwrap();
        s.note("/repo", "goal: 新目标", "user").unwrap();
        assert!(!s.context("/repo").contains("old"));
        assert!(s.show("/repo")["text"].as_str().unwrap().contains("superseded"));
        s.note("/repo", &format!("notes: {}", "中".repeat(3000)), "user").unwrap();
        assert_eq!(s.context("/repo").chars().count(), LIMIT);
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
            let shown = Store::local().show(&repo);
            if shown["trusted"] == true {
                continue;
            }
            let digest = shown["digest"].as_str().unwrap_or_default().to_string();
            if self.memory_pending.values().any(|v| v == &(repo.clone(), digest.clone())) {
                continue;
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
