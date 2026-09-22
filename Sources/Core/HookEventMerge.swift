import Foundation

/// Merging seahelm's hook entry into one event of an agent's hook config,
/// shared by `ClaudeHooksSetup` and `CodexHooksSetup` because both tools model
/// an event the same way: a list of groups, each holding a list of entries.
///
/// The rule this enforces, and the reason it exists in one place: **an event
/// already carrying someone else's hook is no reason for us not to run.** Both
/// installers used to bail out of an event a foreign hook owned, which left the
/// install reporting nothing for it — silently, because the remaining events
/// still counted as a change, so the function still claimed success. Claude's
/// was worse than a bail-out: it tested the *whole event* for the string
/// `seahelm-hook`, so an event holding our entry **and** the user's was treated
/// as ours and overwritten wholesale, deleting theirs.
///
/// So: foreign entries are never rewritten and never removed, our own are
/// migrated in place, duplicates of ours collapse to the first, and if the event
/// has none of ours we append a group. `Sources/Core/CursorHooksSetup.swift`
/// already worked this way and is left on its own (its event is a flat list of
/// entries, not of groups).
enum HookEventMerge {

    /// Canonical JSON (sorted keys) so an already-correct entry is recognised
    /// rather than needlessly rewritten.
    static func canonical(_ value: Any?) -> String? {
        guard let value,
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Whether an entry is one seahelm wrote, in any form we have ever written:
    /// the `seahelm-hook` bridge command, or the older `type: "http"` entry
    /// pointing at our `/webhook`. Matched against the serialized entry so both
    /// shapes are caught without knowing which key carries the address.
    static func isSeahelmEntry(_ entry: [String: Any]) -> Bool {
        guard let serialized = canonical(entry) else { return false }
        return serialized.contains("seahelm-hook") || serialized.contains("/webhook")
    }

    /// Merge `entry` into one event's groups. Returns nil when the event already
    /// says exactly what it should, so callers can leave the file untouched.
    static func merging(event groups: [[String: Any]], entry: [String: Any]) -> [[String: Any]]? {
        var merged: [[String: Any]] = []
        var changed = false
        var installed = false
        let wanted = canonical(entry)

        for group in groups {
            // A group we cannot read the entries of is not ours to reshape.
            guard let entries = group["hooks"] as? [[String: Any]], !entries.isEmpty else {
                merged.append(group)
                continue
            }
            var kept: [[String: Any]] = []
            for existing in entries {
                guard isSeahelmEntry(existing) else {
                    kept.append(existing)
                    continue
                }
                guard !installed else {
                    changed = true          // a second copy of ours — drop it
                    continue
                }
                installed = true
                if canonical(existing) == wanted {
                    kept.append(existing)
                } else {
                    kept.append(entry)      // migrate ours in place
                    changed = true
                }
            }
            guard !kept.isEmpty else {
                changed = true              // the group held nothing but that copy
                continue
            }
            // Copying the group preserves anything else it carries, e.g. a
            // `matcher` the user set around our entry.
            var group = group
            group["hooks"] = kept
            merged.append(group)
        }

        if !installed {
            merged.append(["hooks": [entry]])
            changed = true
        }
        return changed ? merged : nil
    }

    /// Strip our entries from an event, for an event we used to install and now
    /// must actively retire. Returns the groups that remain — empty when the
    /// event was only ever ours, so the caller can drop the key — or nil when
    /// there was nothing of ours to remove.
    ///
    /// Anything foreign in the event stays, including a hook the user wrote for
    /// the same event; retiring ours is not licence to delete theirs.
    static func removing(event groups: [[String: Any]]) -> [[String: Any]]? {
        var remaining: [[String: Any]] = []
        var changed = false

        for group in groups {
            guard let entries = group["hooks"] as? [[String: Any]], !entries.isEmpty else {
                remaining.append(group)
                continue
            }
            let kept = entries.filter { !isSeahelmEntry($0) }
            if kept.count != entries.count { changed = true }
            guard !kept.isEmpty else { continue }
            var group = group
            group["hooks"] = kept
            remaining.append(group)
        }
        return changed ? remaining : nil
    }
}
