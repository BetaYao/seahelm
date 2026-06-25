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
        var last: String?
        contents.enumerateLines { line, _ in
            guard
                let data = line.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                object["type"] as? String == "summary",
                let summary = object["summary"] as? String,
                !summary.isEmpty
            else { return }
            last = summary
        }
        return last
    }

    private static func defaultProjectsRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
    }
}
