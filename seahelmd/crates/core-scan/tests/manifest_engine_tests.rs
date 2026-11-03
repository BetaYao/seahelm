//! Port of Tests/ManifestEngineTests.swift.

use seahelm_core_scan::detect::DetectionInput;
use seahelm_core_scan::manifest::{status_from_manifest, AgentManifest, CompiledManifest};
use seahelm_core_scan::ManifestStore;
use seahelm_core_types::AgentStatus;

fn manifest(json: &str) -> CompiledManifest {
    CompiledManifest::from_json(json).expect("manifest")
}

fn lines(l: &[&str]) -> String {
    l.join("\n")
}

fn screen(s: &str) -> DetectionInput {
    DetectionInput::screen(s)
}

/// Every bundled manifest must read a braille-spinner OSC title as running;
/// once only claude did, and codex showed idle while thinking.
#[test]
fn all_bundled_manifests_detect_spinner_title() {
    let store = ManifestStore::bundled();
    for id in ["claude", "codex", "opencode", "gemini", "cline", "goose", "amp", "aider", "cursor", "kiro", "pi", "agent"] {
        let cm = store.get(id).unwrap_or_else(|| panic!("missing {id}"));
        let d = cm.evaluate(&DetectionInput::title("", "\u{2810} 调查查询服务不稳定的问题"));
        assert_eq!(d.state, AgentStatus::Running, "{id} did not detect the spinner title as running");
        assert!(d.visible_working, "{id} spinner should be visible_working");
    }
}

/// Cursor animates an hourglass in its title, not the braille spinner.
#[test]
fn cursor_hourglass_title_detects_as_running() {
    let store = ManifestStore::bundled();
    let cm = store.get("cursor").expect("cursor");
    let working = cm.evaluate(&DetectionInput::title("", "Tauri Performance Check - \u{23F3} Working .\u{00B7}\u{00B7}"));
    assert_eq!(working.state, AgentStatus::Running);
    assert!(working.visible_working);
    let idle = cm.evaluate(&DetectionInput::title("", "/Volumes/openbeta/workspace/teamclaw"));
    assert_ne!(idle.state, AgentStatus::Running);
}

#[test]
fn pi_manifest_detection() {
    let store = ManifestStore::bundled();
    let cm = store.get("pi").expect("pi");
    let trust = cm.evaluate(&screen("project trust\n/users/me/proj\n↑↓ navigate  save  cancel"));
    assert_eq!(trust.state, AgentStatus::Waiting, "pi trust prompt should be waiting");
    assert!(trust.visible_blocker);
    let working = cm.evaluate(&screen("summarizing branch... (ctrl+c to cancel)"));
    assert_eq!(working.state, AgentStatus::Running, "pi working line should be running");
    assert!(store.get("pi-coding-agent").is_some());
}

/// Background work is reported as background-busy, never as the agent's
/// own status.
#[test]
fn claude_background_tasks_detect_as_background_busy() {
    let store = ManifestStore::bundled();
    let cm = store.get("claude").expect("claude");
    let footers = [
        "some transcript text\n\n❯ \n▸▸ bypass permissions on · 1 shell · ← 2 agents",
        "some transcript text\n\n❯ \n▸▸ bypass permissions on · 2 shells",
        "* sautéed for 2m 10s · 1 shell still running\n\n❯ \ncontext 6%",
        "some text\n\n❯ \n▸▸ bypass permissions on · pr #4902 · 1 shell, 1 monitor · ← 3 agents",
        "some text\n\n❯ \n▸▸ bypass permissions on · 1 monitor · ← 3 agents",
    ];
    for s in footers {
        let d = cm.evaluate(&screen(&s.to_lowercase()));
        assert!(d.background_busy, "expected background-busy for: {s}");
        assert_ne!(d.state, AgentStatus::Running, "background work must not decide the agent's own status: {s}");
    }
    let idles = [
        "ran 2 shell commands\ndone.\n\n❯ \n▸▸ bypass permissions on",
        "done.\n\n❯ \n▸▸ bypass permissions on (shift+tab to cycle) · ← 2 agents",
    ];
    for s in idles {
        let d = cm.evaluate(&screen(s));
        assert_eq!(d.state, AgentStatus::Unknown, "expected no match for: {s}");
        assert!(!d.background_busy, "expected no background work for: {s}");
    }
}

#[test]
fn background_rule_does_not_shadow_the_status_rule() {
    let store = ManifestStore::bundled();
    let cm = store.get("claude").expect("claude");
    let s = lines(&["do you want to proceed?", "❯ ", "▸▸ bypass permissions on · 1 shell · ← 2 agents"]);
    let d = cm.evaluate(&screen(&s));
    assert_eq!(d.state, AgentStatus::Waiting, "a blocked agent still reads as waiting");
    assert!(d.background_busy, "and the background work is still reported");
}

fn claude_footer(model: &str, extra: &[&str]) -> String {
    let mut l = vec!["", "───────────────────────────────", "❯", "───────────────────────────────"];
    let model_line = format!("  [{model}]");
    l.push(&model_line);
    l.extend_from_slice(extra);
    lines(&l)
}

#[test]
fn claude_spinner_without_interrupt_hint_detects_as_running() {
    let store = ManifestStore::bundled();
    let cm = store.get("claude").expect("claude");
    let footer = lines(&[
        "",
        "───────────────────────────────",
        "❯",
        "───────────────────────────────",
        "  [opus 4.8 (1m context)] │ seahelm git:(fix/notification-unique-identifier*)",
        "  context ██░░░░ 38% │ usage █░░░░░ 11% (resets in 3h 51m)",
        "  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← 3 agents",
    ]);
    for spinner in ["· sprouting… (3m 55s · ↓ 11.1k tokens)", "✻ sprouting… (26s · ↓ 762 tokens)", "✳ cogitating... (1h 2m · ↑ 3 tokens)"] {
        let d = cm.evaluate(&screen(&format!("{spinner}{footer}").to_lowercase()));
        assert_eq!(d.state, AgentStatus::Running, "expected running for: {spinner}");
        assert!(d.visible_working);
    }
    for marker in ["✻ sautéed for 6m 25s", "✻ worked for 37s", "✻ brewed for 1m 3s", "* crunched for 2m 30s", "reading 1 file, running 1 shell command…"] {
        let d = cm.evaluate(&screen(&format!("{marker}{footer}").to_lowercase()));
        assert_eq!(d.state, AgentStatus::Unknown, "expected no match for: {marker}");
    }
}

#[test]
fn claude_tool_progress_and_buried_spinner_detect_as_running() {
    let store = ManifestStore::bundled();
    let cm = store.get("claude").expect("claude");
    let footer = claude_footer(
        "opus 5 (1m context)",
        &["  teamclaw git:(chore/guard-against-stray-file-commits*)", "  ⏵⏵ bypass permissions on (shift+tab to cycle) · pr #662 · ← 3 agents"],
    );
    let tool_only = format!(
        "{}\n{}",
        lines(&[
            "running 2 shell commands · 53s…",
            "  ⎿  $ cargo test -p amuxd --manifest-path apps/daemon/cargo.toml",
            "     (ctrl+b to run in background)",
        ]),
        footer
    )
    .to_lowercase();
    let d = cm.evaluate(&screen(&tool_only));
    assert_eq!(d.state, AgentStatus::Running, "expected running for tool-progress line");
    assert!(d.visible_working);

    let mut buried = (0..20).map(|i| format!("[cron] scheduler gen {i} stopped (current: 20)")).collect::<Vec<_>>().join("\n");
    buried += "\n✢ thundering… (5m 33s · ↓ 15.7k tokens)\n";
    buried += &(0..14).map(|_| "  ⎿  cargo test output line").collect::<Vec<_>>().join("\n");
    buried += &footer;
    let d = cm.evaluate(&screen(&buried.to_lowercase()));
    assert_eq!(d.state, AgentStatus::Running, "spinner above bottom_lines:12 must still match");
    assert!(d.visible_working);

    assert_eq!(cm.evaluate(&screen(&footer.to_lowercase())).state, AgentStatus::Unknown);
}

#[test]
fn cursor_agent_cli_working_signals_detect_as_running() {
    let store = ManifestStore::bundled();
    let cm = store.get("cursor").expect("cursor");
    let working = [
        lines(&[
            "✶ grepping  83.03k tokens",
            "    tip: use /mcp to connect cursor to your tools and data sources.",
            "  ❯ add a follow-up                                     ctrl+c to stop",
            "  auto · 62.1% · 8 files edited                         run everything",
        ]),
        lines(&[
            "✶ working",
            "  ❯ add a follow-up                                     ctrl+c to stop",
            "  auto · 27% · 5 files edited                           run everything",
        ]),
        lines(&["✶ updating  17.71k tokens", "  ❯ add a follow-up                                     ctrl+c to stop"]),
        "esc to interrupt\n(thinking)".to_string(),
    ];
    for s in &working {
        let d = cm.evaluate(&screen(&s.to_lowercase()));
        assert_eq!(d.state, AgentStatus::Running, "expected running for:\n{s}");
        assert!(d.visible_working);
    }
    let idle = lines(&["❯ add a follow-up", "auto · 17.5%                                          run everything"]);
    assert_eq!(cm.evaluate(&screen(&idle.to_lowercase())).state, AgentStatus::Unknown, "idle follow-up must not match running rules");
    let todo = "to-do working on 1 to-do · 1 done\n❯ add a follow-up";
    assert_eq!(cm.evaluate(&screen(todo)).state, AgentStatus::Unknown, "todo 'Working on' must not match bare Working status line");
}

#[test]
fn highest_priority_wins() {
    let cm = manifest(
        r#"{ "id": "t", "default_status": "idle", "rules": [
          { "id": "run", "state": "running", "priority": 100, "region": "whole_recent", "contains": ["to interrupt"] },
          { "id": "wait", "state": "waiting", "priority": 900, "region": "whole_recent", "contains": ["(y/n)"] }
        ]}"#,
    );
    let d = cm.evaluate(&screen("esc to interrupt ... proceed? (y/n)"));
    assert_eq!(d.state, AgentStatus::Waiting);
    assert_eq!(d.matched_rule_id.as_deref(), Some("wait"));
}

#[test]
fn no_match_returns_unknown_then_default() {
    let cm = manifest(
        r#"{ "id": "t", "default_status": "idle", "rules": [
          { "id": "run", "state": "running", "priority": 100, "region": "whole_recent", "contains": ["to interrupt"] }
        ]}"#,
    );
    assert_eq!(cm.evaluate(&screen("nothing here")).state, AgentStatus::Unknown);
    assert_eq!(cm.default_status(), AgentStatus::Idle);
}

#[test]
fn any_gate() {
    let cm = manifest(
        r#"{ "id": "t", "default_status": "idle", "rules": [
          { "id": "perm", "state": "waiting", "priority": 500, "region": "whole_recent",
            "any": [ { "contains": ["yes, proceed"] }, { "contains": ["(yes/no)"] } ] }
        ]}"#,
    );
    assert_eq!(cm.evaluate(&screen("1. yes, proceed")).state, AgentStatus::Waiting);
    assert_eq!(cm.evaluate(&screen("run this? (yes/no)")).state, AgentStatus::Waiting);
    assert_eq!(cm.evaluate(&screen("unrelated")).state, AgentStatus::Unknown);
}

#[test]
fn not_gate_blocks() {
    let cm = manifest(
        r#"{ "id": "t", "default_status": "idle", "rules": [
          { "id": "run", "state": "running", "priority": 500, "region": "whole_recent",
            "contains": ["working"], "not": [ { "contains": ["done"] } ] }
        ]}"#,
    );
    assert_eq!(cm.evaluate(&screen("working hard")).state, AgentStatus::Running);
    assert_eq!(cm.evaluate(&screen("working done")).state, AgentStatus::Unknown);
}

#[test]
fn region_bottom_lines_ignores_old_output() {
    let cm = manifest(
        r#"{ "id": "t", "default_status": "idle", "rules": [
          { "id": "err", "state": "error", "priority": 700, "region": "bottom_lines:2", "contains": ["error:"] }
        ]}"#,
    );
    assert_eq!(cm.evaluate(&screen("error: old failure\nline1\nline2\nline3")).state, AgentStatus::Unknown);
    assert_eq!(cm.evaluate(&screen("ok\nerror: fresh")).state, AgentStatus::Error);
}

#[test]
fn osc_title_region() {
    let cm = manifest(
        r#"{ "id": "t", "default_status": "idle", "rules": [
          { "id": "spin", "state": "running", "priority": 1100, "region": "osc_title",
            "regex": ["^[\\x{2800}-\\x{28FF}] "], "visible_working": true }
        ]}"#,
    );
    let d = cm.evaluate(&DetectionInput::title("", "\u{2807} Working…"));
    assert_eq!(d.state, AgentStatus::Running);
    assert!(d.visible_working);
}

#[test]
fn skip_state_update_flag_carried() {
    let cm = manifest(
        r#"{ "id": "t", "default_status": "idle", "rules": [
          { "id": "viewer", "state": "idle", "priority": 300, "region": "whole_recent",
            "contains": ["show transcript"], "skip_state_update": true }
        ]}"#,
    );
    let d = cm.evaluate(&screen("show transcript"));
    assert!(d.skip_state_update);
    assert_eq!(d.matched_rule_id.as_deref(), Some("viewer"));
}

#[test]
fn engine_version_guard_rejects() {
    let m = AgentManifest::from_json(r#"{ "id": "t", "min_engine_version": 999, "rules": [] }"#).unwrap();
    assert!(m.validated().is_err());
}

#[test]
fn status_mapping() {
    assert_eq!(status_from_manifest("working"), AgentStatus::Running);
    assert_eq!(status_from_manifest("blocked"), AgentStatus::Waiting);
    assert_eq!(status_from_manifest("IDLE"), AgentStatus::Idle);
}

/// Evidence names the line that fired, not the whole region.
#[test]
fn match_detail_narrows_evidence_to_the_matching_line() {
    let store = ManifestStore::bundled();
    let cm = store.get("claude").expect("claude");
    let s = lines(&[
        "⏺ read(sources/status/manifestengine.swift)",
        "✳ synthesizing… (12m 12s · ↓ 36.4k tokens)",
        "  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← 5 agents",
    ]);
    let detail = cm.match_detail(&screen(&s)).expect("a match");
    assert_eq!(detail.rule.id, "working_spinner");
    assert_eq!(detail.evidence, "✳ synthesizing… (12m 12s · ↓ 36.4k tokens)");
}

// Beyond the Swift: the port's own load rules.

/// An invalid regex rejects the manifest (the Swift dropped the pattern).
#[test]
fn invalid_regex_is_a_load_error() {
    let err = CompiledManifest::from_json(r#"{ "id": "t", "rules": [ { "id": "bad", "state": "running", "regex": ["(unclosed"] } ]}"#)
        .expect_err("rejected");
    assert!(err.to_string().contains("bad"), "{err}");
}

#[test]
fn user_overrides_win_by_id_and_errors_are_reported() {
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(
        dir.path().join("claude.json"),
        r#"{ "id": "claude", "version": "mine", "aliases": ["cc"], "authority": "full_lifecycle", "rules": [] }"#,
    )
    .unwrap();
    std::fs::write(dir.path().join("broken.json"), r#"{ "id": "x", "rules": [ { "id": "r", "state": "idle", "line_regex": ["["] } ] }"#).unwrap();
    std::fs::write(dir.path().join("notes.txt"), "ignored").unwrap();
    let (store, errors) = ManifestStore::with_user_dir(dir.path());
    assert_eq!(errors.len(), 1, "{errors:?}");
    assert!(errors[0].starts_with("broken.json"));
    assert_eq!(store.get("claude").unwrap().manifest.version, "mine");
    assert_eq!(store.get("CC").unwrap().manifest.id, "claude");
    assert!(store.get("claude-code").is_none(), "the override replaces the bundled aliases too");
    assert_eq!(store.authority(seahelm_core_types::AgentType::ClaudeCode), seahelm_core_types::Authority::FullLifecycle);
    assert!(store.is_user_override("claude"));
    // Deterministic order: user overrides first, then bundled by id.
    let ids: Vec<_> = store.all().map(|c| c.manifest.id.clone()).collect();
    assert_eq!(ids[0], "claude");
    assert_eq!(&ids[1..3], ["agent", "aider"]);
    assert_eq!(store.load_errors(), errors.as_slice());

    let (missing, errors) = ManifestStore::with_user_dir(&dir.path().join("nope"));
    assert!(errors.is_empty());
    assert_eq!(missing.all().count(), 12);
}
