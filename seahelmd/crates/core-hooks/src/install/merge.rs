//! Merging seahelm's entry into one event of an agent's hook config
//! (`HookEventMerge.swift`), shared by Claude and Codex because both model
//! an event the same way: a list of groups, each holding a list of entries.
//!
//! The rule it enforces, in one place: **an event already carrying someone
//! else's hook is no reason for us not to run.** Both installers once bailed
//! out of an event a foreign hook owned — silently, since the other events
//! still counted as a change — and Claude's tested the *whole event* for
//! `seahelm-hook`, so an event holding ours and the user's was overwritten,
//! deleting theirs. So: foreign entries are never rewritten or removed, our
//! own are migrated in place, duplicates of ours collapse to the first, and
//! an event with none of ours gets a group appended.

use serde_json::Value;

use super::sorted;

/// Canonical JSON (sorted keys), so an already-correct entry is recognised
/// rather than rewritten.
pub fn canonical(v: &Value) -> String {
    sorted(v).to_string()
}

/// Whether an entry is one seahelm wrote, in any form it ever wrote: the
/// `seahelm-hook` command, or the older `type: "http"` hook at `/webhook`.
/// Matched on the serialized entry, so either shape is caught whichever key
/// carries the address.
pub fn is_seahelm_entry(entry: &Value) -> bool {
    let s = canonical(entry);
    s.contains("seahelm-hook") || s.contains("/webhook")
}

/// A group's entries when it has a readable, non-empty list of them. A
/// group we cannot read is not ours to reshape.
fn entries(group: &Value) -> Option<&Vec<Value>> {
    group.get("hooks")?.as_array().filter(|e| !e.is_empty() && e.iter().all(Value::is_object))
}

fn with_entries(group: &Value, kept: Vec<Value>) -> Value {
    // Copying the group keeps anything else it carries, e.g. a `matcher`
    // the user set around our entry.
    let mut group = group.clone();
    group["hooks"] = Value::Array(kept);
    group
}

/// `entry` merged into one event's groups, or None when the event already
/// says exactly what it should.
pub fn merging(groups: &[Value], entry: &Value) -> Option<Vec<Value>> {
    let wanted = canonical(entry);
    let mut merged = Vec::with_capacity(groups.len() + 1);
    let mut changed = false;
    let mut installed = false;
    for group in groups {
        let Some(list) = entries(group) else {
            merged.push(group.clone());
            continue;
        };
        let mut kept = Vec::with_capacity(list.len());
        for existing in list {
            if !is_seahelm_entry(existing) {
                kept.push(existing.clone());
            } else if installed {
                changed = true; // a second copy of ours: drop it
            } else {
                installed = true;
                if canonical(existing) == wanted {
                    kept.push(existing.clone());
                } else {
                    kept.push(entry.clone()); // migrate ours in place
                    changed = true;
                }
            }
        }
        if kept.is_empty() {
            changed = true; // the group held nothing but that copy
            continue;
        }
        merged.push(with_entries(group, kept));
    }
    if !installed {
        merged.push(serde_json::json!({ "hooks": [entry] }));
        changed = true;
    }
    changed.then_some(merged)
}

/// Our entries stripped from an event we used to install and must now
/// retire. The groups that remain — empty when the event was only ours, so
/// the caller drops the key — or None when nothing of ours was there.
/// Anything foreign stays: retiring ours is no licence to delete theirs.
pub fn removing(groups: &[Value]) -> Option<Vec<Value>> {
    let mut remaining = Vec::with_capacity(groups.len());
    let mut changed = false;
    for group in groups {
        let Some(list) = entries(group) else {
            remaining.push(group.clone());
            continue;
        };
        let kept: Vec<Value> = list.iter().filter(|e| !is_seahelm_entry(e)).cloned().collect();
        if kept.len() != list.len() {
            changed = true;
        }
        if !kept.is_empty() {
            remaining.push(with_entries(group, kept));
        }
    }
    changed.then_some(remaining)
}

/// An event's value as a list of group objects, as the Swift's
/// `as? [[String: Any]]` read it: None for any other shape.
pub(crate) fn as_groups(v: &Value) -> Option<Vec<Value>> {
    v.as_array().filter(|a| a.iter().all(Value::is_object)).cloned()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn ours() -> Value {
        json!({"type": "command", "command": "/x/seahelm-hook codex"})
    }

    fn theirs() -> Value {
        json!({"type": "command", "command": "other-tool-hook"})
    }

    fn commands(groups: &[Value]) -> Vec<String> {
        groups
            .iter()
            .filter_map(|g| g.get("hooks").and_then(Value::as_array))
            .flatten()
            .filter_map(|e| e.get("command").and_then(Value::as_str).map(str::to_string))
            .collect()
    }

    #[test]
    fn test_empty_event_gets_ours() {
        assert_eq!(commands(&merging(&[], &ours()).unwrap()), vec!["/x/seahelm-hook codex"]);
    }

    #[test]
    fn test_foreign_event_gets_ours_appended() {
        let merged = merging(&[json!({"hooks": [theirs()]})], &ours()).unwrap();
        assert_eq!(commands(&merged), vec!["other-tool-hook", "/x/seahelm-hook codex"]);
    }

    #[test]
    fn test_settled_event_reports_no_change() {
        assert_eq!(merging(&[json!({"hooks": [theirs()]}), json!({"hooks": [ours()]})], &ours()), None);
    }

    #[test]
    fn test_stale_entry_of_ours_is_migrated_in_place_not_duplicated() {
        let stale = json!({"type": "http", "url": "http://127.0.0.1:8765/webhook"});
        let merged = merging(&[json!({"hooks": [stale]})], &ours()).unwrap();
        assert_eq!(commands(&merged), vec!["/x/seahelm-hook codex"]);
        assert_eq!(merged.len(), 1, "migration must not add a second group");
    }

    #[test]
    fn test_duplicates_of_ours_collapse() {
        let stale = json!({"type": "command", "command": "/x/seahelm-hook"});
        let merged = merging(&[json!({"hooks": [stale]}), json!({"hooks": [ours()]})], &ours()).unwrap();
        assert_eq!(commands(&merged), vec!["/x/seahelm-hook codex"]);
    }

    #[test]
    fn test_group_matcher_survives_a_migration() {
        let stale = json!({"type": "command", "command": "/x/seahelm-hook"});
        let merged = merging(&[json!({"matcher": "Edit", "hooks": [stale]})], &ours()).unwrap();
        assert_eq!(merged[0]["matcher"], "Edit");
    }

    #[test]
    fn test_group_we_cannot_read_is_left_intact() {
        let merged = merging(&[json!({"hooks": "not-a-list"})], &ours()).unwrap();
        assert_eq!(merged.len(), 2);
        assert_eq!(merged[0]["hooks"], "not-a-list");
    }

    #[test]
    fn test_foreign_entry_in_the_same_group_as_ours_survives() {
        let stale = json!({"type": "command", "command": "/x/seahelm-hook"});
        let merged = merging(&[json!({"hooks": [theirs(), stale]})], &ours()).unwrap();
        assert_eq!(commands(&merged), vec!["other-tool-hook", "/x/seahelm-hook codex"]);
    }

    #[test]
    fn test_removing_takes_only_ours() {
        let remaining = removing(&[json!({"hooks": [theirs(), ours()]})]).unwrap();
        assert_eq!(commands(&remaining), vec!["other-tool-hook"]);
    }

    #[test]
    fn test_removing_empties_an_event_that_was_only_ours() {
        assert!(removing(&[json!({"hooks": [ours()]})]).unwrap().is_empty(), "caller drops the key on empty");
    }

    #[test]
    fn test_removing_reports_nothing_when_none_of_it_is_ours() {
        assert_eq!(removing(&[json!({"hooks": [theirs()]})]), None);
    }
}
