import Foundation

/// Reads Claude Code's auto-generated session title (the `summary` record) for a
/// given worktree. Claude stores sessions under
/// `~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl`, where `<encoded-cwd>` is
/// the absolute path with `/` and `.` replaced by `-`.
enum SessionTitleLookup {
    /// Title from the most recently modified session JSONL in the worktree's
    /// project directory, or nil if none has a `summary` record.
    static func title(
        worktreePath: String,
        fileManager: FileManager = .default,
        projectsRoot: URL = defaultProjectsRoot()
    ) -> String? {
        guard !worktreePath.isEmpty else { return nil }
        let dir = projectsRoot.appendingPathComponent(
            encodedProjectComponent(worktreePath: worktreePath), isDirectory: true
        )
        guard let entries = try? fileManager.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let sessions = entries
            .filter { $0.pathExtension == "jsonl" }
            .sorted { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return l > r
            }

        for session in sessions {
            if let summary = lastSummary(in: session) {
                return summary
            }
        }
        return nil
    }

    /// Title for one named session, rather than for whatever ran in the worktree
    /// last. Two agents sharing a worktree write two transcripts into the same
    /// directory, so `title(worktreePath:)` hands them both the same words —
    /// which is no use when the point of the listing is telling them apart.
    ///
    /// Returns nil when the transcript has no title record yet, and for agents
    /// that don't keep transcripts here at all (only Claude writes under
    /// ~/.claude/projects) — callers need a fallback either way.
    static func title(
        worktreePath: String,
        sessionId: String,
        fileManager: FileManager = .default,
        projectsRoot: URL = defaultProjectsRoot()
    ) -> String? {
        guard !worktreePath.isEmpty, !sessionId.isEmpty else { return nil }
        // The id is a transcript stem, but it reaches us from a webhook payload:
        // keep a crafted one from walking out of the projects directory.
        guard !sessionId.contains("/"), !sessionId.hasPrefix(".") else { return nil }
        let url = projectsRoot
            .appendingPathComponent(encodedProjectComponent(worktreePath: worktreePath), isDirectory: true)
            .appendingPathComponent("\(sessionId).jsonl")
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return lastSummary(in: url)
    }

    /// Encodes an absolute path the way Claude Code names its project directories.
    static func encodedProjectComponent(worktreePath: String) -> String {
        var result = ""
        for ch in worktreePath {
            result.append(ch == "/" || ch == "." ? "-" : ch)
        }
        return result
    }

    private static func lastSummary(in fileURL: URL) -> String? {
        guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        // Newer Claude Code writes `ai-title` records (and `custom-title` when the
        // user renames a session in the resume picker); older versions wrote
        // `summary`. Track the last of each and prefer the user's own rename.
        var lastCustom: String?
        var lastAI: String?
        var lastLegacy: String?
        contents.enumerateLines { line, _ in
            // Cheap pre-filter: title records are rare, full JSON parse per line is not.
            guard line.contains("\"type\":\"summary\"")
                || line.contains("\"type\":\"ai-title\"")
                || line.contains("\"type\":\"custom-title\"") else { return }
            guard
                let data = line.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let type = object["type"] as? String
            else { return }
            switch type {
            case "custom-title":
                if let t = object["customTitle"] as? String, !t.isEmpty { lastCustom = t }
            case "ai-title":
                if let t = object["aiTitle"] as? String, !t.isEmpty { lastAI = t }
            case "summary":
                if let t = object["summary"] as? String, !t.isEmpty { lastLegacy = t }
            default: break
            }
        }
        return lastCustom ?? lastAI ?? lastLegacy
    }

    private static func defaultProjectsRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
    }
}
