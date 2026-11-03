//! The scan half of `pane.explain`: what the screen says right now and which
//! rule said it. Ported from `SeahelmControlDataSource.explainPane`; the
//! arbitration fields (status, decided_by, hook_status, …) are the
//! registry's half.

use seahelm_core_types::AgentType;
use serde_json::{json, Map, Value};

use crate::detect::{self, DetectionInput};
use crate::manifest::ManifestStore;
use crate::Snapshot;

/// How much of a rule's evidence is shown, in characters, from the end.
const EVIDENCE_CHARS: usize = 160;

/// The scan fields of `pane.explain`: `agent`, `manifest`,
/// `manifest_version`, `authority`, `scan_status`, `scan_defaulted`,
/// `background_busy`, `osc_title`, `osc_progress`, and `matched_rule`
/// (`{id, state, priority, region, evidence}`) or `matched_rule: null` with
/// `default_status`. When manifests failed to load, `manifest_errors` lists
/// them: an override that was rejected is the first thing to suspect when a
/// rule seems to be ignored.
pub fn explain(snapshot: &Snapshot, agent: AgentType, store: &ManifestStore) -> Value {
    let manifest = store.get(agent.manifest_id());
    let osc_progress = snapshot.osc_progress();
    let scan = detect::detect(snapshot.process_status(), &snapshot.viewport, manifest, &snapshot.title, &osc_progress);

    let mut out = Map::new();
    out.insert("agent".into(), serde_json::to_value(agent).unwrap_or(Value::Null));
    out.insert("manifest".into(), json!(manifest.map(|m| m.manifest.id.as_str()).unwrap_or("")));
    out.insert("manifest_version".into(), json!(manifest.map(|m| m.manifest.version.as_str()).unwrap_or("")));
    // The manifest's own word, as the Swift reported it, so a misspelt
    // authority (read as session_only) is visible as written.
    out.insert("authority".into(), json!(manifest.map(|m| m.manifest.authority.as_str()).unwrap_or("session_only")));
    out.insert("scan_status".into(), json!(scan.state.as_str()));
    // True when no rule matched and scan_status is only the manifest's
    // default: the screen is saying nothing, not saying "idle".
    out.insert("scan_defaulted".into(), json!(scan.is_defaulted));
    out.insert("background_busy".into(), json!(scan.background_busy));
    out.insert("osc_title".into(), json!(snapshot.title));
    out.insert("osc_progress".into(), json!(osc_progress));

    let input = DetectionInput { screen: snapshot.viewport.to_lowercase(), osc_title: snapshot.title.clone(), osc_progress };
    match manifest.and_then(|m| m.match_detail(&input)) {
        Some(d) => {
            let chars = d.evidence.chars().count();
            let evidence: String = d.evidence.chars().skip(chars.saturating_sub(EVIDENCE_CHARS)).collect();
            out.insert(
                "matched_rule".into(),
                json!({
                    "id": d.rule.id,
                    "state": d.rule.state,
                    "priority": d.rule.priority,
                    "region": d.rule.region,
                    "evidence": evidence,
                }),
            );
        }
        None => {
            out.insert("matched_rule".into(), Value::Null);
            out.insert("default_status".into(), json!(manifest.map(|m| m.default_status().as_str()).unwrap_or("")));
        }
    }
    if !store.load_errors().is_empty() {
        out.insert("manifest_errors".into(), json!(store.load_errors()));
    }
    Value::Object(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn explains_the_winning_rule_with_its_line() {
        let snap = Snapshot {
            viewport: "⏺ Read(a.swift)\n✳ Synthesizing… (12m 12s · ↓ 36.4k tokens)\n  ⏵⏵ bypass permissions on".into(),
            ..Default::default()
        };
        let v = explain(&snap, AgentType::ClaudeCode, &ManifestStore::bundled());
        assert_eq!(v["agent"], "claudeCode");
        assert_eq!(v["manifest"], "claude");
        assert_eq!(v["scan_status"], "Running");
        assert_eq!(v["matched_rule"]["id"], "working_spinner");
        assert_eq!(v["matched_rule"]["evidence"], "✳ synthesizing… (12m 12s · ↓ 36.4k tokens)");
        assert!(v.get("manifest_errors").is_none());
    }

    #[test]
    fn explains_a_defaulted_screen() {
        let snap = Snapshot { viewport: "nothing to see".into(), ..Default::default() };
        let v = explain(&snap, AgentType::Codex, &ManifestStore::bundled());
        assert_eq!(v["matched_rule"], Value::Null);
        assert_eq!(v["default_status"], "Idle");
        assert_eq!(v["scan_defaulted"], true);
        assert_eq!(v["authority"], "session_only");
    }
}
