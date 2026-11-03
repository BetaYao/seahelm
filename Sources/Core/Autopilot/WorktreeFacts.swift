import Foundation

/// What is actually in a worktree, measured by seahelm rather than described by
/// First Mate: its uncommitted files and lines, commits no remote has, and
/// whether a pane in it is busy. Put in front of First Mate in every event and
/// on every card that would delete the worktree, so a summary that leaves
/// something out cannot be what the user approves on.
struct WorktreeFacts: Equatable {
    var changedFiles = 0
    var deletedFiles = 0
    var untrackedFiles = 0
    var insertions = 0
    var deletions = 0
    /// Commits on HEAD that no remote-tracking ref has. Nil when git could not say.
    var unpushedCommits: Int?
    var busyPanes = 0

    var isClean: Bool { changedFiles == 0 && untrackedFiles == 0 && (unpushedCommits ?? 0) == 0 }

    /// One line: "41 files uncommitted (+16 −47942; 40 deleted, 1 untracked) · 0 commits on no remote · panes idle".
    var summary: String {
        var parts: [String] = []
        if changedFiles + untrackedFiles == 0 {
            parts.append("nothing uncommitted")
        } else {
            var kinds: [String] = []
            if deletedFiles > 0 { kinds.append("\(deletedFiles) deleted") }
            if untrackedFiles > 0 { kinds.append("\(untrackedFiles) untracked") }
            let detail = "+\(insertions) −\(deletions)" + (kinds.isEmpty ? "" : "; " + kinds.joined(separator: ", "))
            let n = changedFiles + untrackedFiles
            parts.append("\(n) file\(n == 1 ? "" : "s") uncommitted (\(detail))")
        }
        if let unpushed = unpushedCommits {
            parts.append(unpushed == 0 ? "every commit is on a remote" : "\(unpushed) commit\(unpushed == 1 ? "" : "s") on no remote")
        } else {
            parts.append("unpushed commits unknown")
        }
        parts.append(busyPanes == 0 ? "panes idle" : "\(busyPanes) pane\(busyPanes == 1 ? "" : "s") busy")
        return parts.joined(separator: " · ")
    }

    /// `git status --porcelain=v1` lines → changed / deleted / untracked counts.
    static func parseStatus(_ porcelain: String) -> (changed: Int, deleted: Int, untracked: Int) {
        var changed = 0, deleted = 0, untracked = 0
        for line in porcelain.split(separator: "\n", omittingEmptySubsequences: true) {
            let code = line.prefix(2)
            if code == "??" { untracked += 1; continue }
            changed += 1
            if code.contains("D") { deleted += 1 }
        }
        return (changed, deleted, untracked)
    }

    /// `git diff --shortstat` → insertions / deletions.
    static func parseShortstat(_ text: String) -> (insertions: Int, deletions: Int) {
        func number(before word: String) -> Int {
            guard let range = text.range(of: word) else { return 0 }
            let head = text[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            return Int(head.split(separator: " ").last ?? "") ?? 0
        }
        return (number(before: "insertion"), number(before: "deletion"))
    }

    /// Measure `path` with git. Blocking — call off the main thread. `busyPanes`
    /// is the caller's to fill in, since it comes from the live registry.
    static func probe(worktreePath path: String) -> WorktreeFacts {
        var facts = WorktreeFacts()
        if let status = GitProcess.run(["status", "--porcelain=v1"], in: path) {
            let counts = parseStatus(status)
            facts.changedFiles = counts.changed
            facts.deletedFiles = counts.deleted
            facts.untrackedFiles = counts.untracked
        }
        if let stat = GitProcess.run(["diff", "HEAD", "--shortstat"], in: path) {
            let lines = parseShortstat(stat)
            facts.insertions = lines.insertions
            facts.deletions = lines.deletions
        }
        if let count = GitProcess.run(["rev-list", "--count", "HEAD", "--not", "--remotes"], in: path) {
            facts.unpushedCommits = Int(count.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return facts
    }

    /// Busy = running or waiting on someone, in any pane filed under `path`.
    static func busyPanes(worktreePath path: String) -> Int {
        AgentRegistry.shared.panes(forWorktree: path).filter { $0.status == .running || $0.status == .waiting }.count
    }
}
