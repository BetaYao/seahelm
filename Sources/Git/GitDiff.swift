import Foundation

enum GitChangeStage: Equatable {
    case staged
    case unstaged
    case untracked
}

struct GitChangedFile {
    let path: String
    let oldPath: String?
    let status: DiffFile.FileStatus
    let stage: GitChangeStage
}

struct GitDiffSnapshot {
    let changedFiles: [GitChangedFile]
    let files: [DiffFile]
    /// Uncapped count of changed files before the recent-activity limit.
    let totalChangedFileCount: Int

    init(
        changedFiles: [GitChangedFile],
        files: [DiffFile],
        totalChangedFileCount: Int? = nil
    ) {
        self.changedFiles = changedFiles
        self.files = files
        self.totalChangedFileCount = totalChangedFileCount ?? changedFiles.count
    }
}

struct DiffFile {
    let path: String
    let oldPath: String?
    let status: FileStatus
    let stage: GitChangeStage
    let additions: Int
    let deletions: Int
    let hunks: [DiffHunk]

    init(
        path: String,
        oldPath: String? = nil,
        status: FileStatus = .modified,
        stage: GitChangeStage = .unstaged,
        additions: Int,
        deletions: Int,
        hunks: [DiffHunk]
    ) {
        self.path = path
        self.oldPath = oldPath
        self.status = status
        self.stage = stage
        self.additions = additions
        self.deletions = deletions
        self.hunks = hunks
    }

    enum FileStatus: String {
        case added = "A"
        case modified = "M"
        case deleted = "D"
        case renamed = "R"
        case unknown = "?"
    }
}

struct DiffHunk {
    let header: String       // @@ -1,5 +1,7 @@
    let lines: [DiffLine]
}

struct DiffLine {
    let type: LineType
    let content: String

    enum LineType {
        case context    // unchanged
        case addition   // +
        case deletion   // -
    }
}

/// Files changed on this worktree relative to a base branch (typically main),
/// including commits and the dirty working tree.
struct GitBranchChanges {
    /// Resolved compare base (`origin/main`, `main`, …). `nil` when falling
    /// back to working-tree `git status` only.
    let baseRef: String?
    /// Newest-first slice, capped at `GitDiff.maxListedChangedFiles`.
    let files: [GitChangedFile]
    /// Full change count before capping.
    let totalCount: Int

    var isTruncated: Bool { files.count < totalCount }

    /// Short label for UI (“main” rather than “origin/main”).
    var baseDisplayName: String? {
        guard let baseRef else { return nil }
        if baseRef.hasPrefix("origin/") {
            return String(baseRef.dropFirst("origin/".count))
        }
        return baseRef
    }
}

enum GitDiff {
    /// Deadline for one git invocation. Wider than `GitProcess.defaultTimeout`
    /// because a cold branch diff over a big repo can take a few seconds.
    private static let gitTimeout: TimeInterval = 15

    /// Preferred compare targets, first hit wins. Remote-tracking refs first so
    /// a stale local `main` does not hide origin's tip; no network fetch here.
    static let preferredBaseRefs = ["origin/main", "origin/master", "main", "master"]

    /// Cap for Changes list + DiffReview. Beyond this we keep the most recently
    /// modified files (by mtime) so huge long-lived branches stay responsive.
    static let maxListedChangedFiles = 100

    /// Get diff for a worktree (staged + unstaged)
    static func diff(worktreePath: String) -> [DiffFile] {
        let stagedOutput = runGit(args: ["diff", "--cached", "--no-color"], in: worktreePath) ?? ""
        let unstagedOutput = runGit(args: ["diff", "--no-color"], in: worktreePath) ?? ""

        var files = parseDiff(stagedOutput, stage: .staged)
        files.append(contentsOf: parseDiff(unstagedOutput, stage: .unstaged))
        return files
    }

    /// Snapshot of this worktree vs its base branch (merge-base with main/master).
    /// Includes committed-on-branch changes, staged/unstaged edits, and untracked
    /// files — so Changes stays populated after commit/push until merged to base.
    /// Diff content is limited to the same recent-file cap as the Changes list.
    static func snapshot(
        worktreePath: String,
        maxSyntheticFileBytes: Int = 128 * 1024,
        limit: Int = maxListedChangedFiles,
        selectedPath: String? = nil
    ) -> GitDiffSnapshot {
        let branch = branchChangedFiles(worktreePath: worktreePath, limit: limit)
        let changed: [GitChangedFile]
        if let selectedPath {
            changed = branch.files.filter { $0.path == selectedPath || $0.oldPath == selectedPath }
        } else {
            changed = branch.files
        }
        let paths = changed.map(\.path)

        let files: [DiffFile]
        if let mergeBase = mergeBase(with: branch.baseRef, worktreePath: worktreePath) {
            let output: String
            if paths.isEmpty {
                output = ""
            } else {
                output = runGit(
                    args: ["diff", "--no-color", "-M", mergeBase, "--"] + paths,
                    in: worktreePath
                ) ?? ""
            }
            var parsed = parseDiff(output, stage: .unstaged)
            let knownPaths = Set(parsed.map(\.path))
            let untrackedDiffs = changed
                .filter { $0.stage == .untracked && !knownPaths.contains($0.path) }
                .compactMap {
                    syntheticUntrackedDiff(
                        for: $0.path,
                        worktreePath: worktreePath,
                        maxBytes: maxSyntheticFileBytes
                    )
                }
            parsed.append(contentsOf: untrackedDiffs)
            files = parsed
        } else if paths.isEmpty {
            files = []
        } else {
            // No main/master ref — fall back to working-tree dirty state, scoped
            // to the capped path set so we never materialize a huge patch.
            let stagedOutput = runGit(
                args: ["diff", "--cached", "--no-color", "--"] + paths,
                in: worktreePath
            ) ?? ""
            let unstagedOutput = runGit(
                args: ["diff", "--no-color", "--"] + paths,
                in: worktreePath
            ) ?? ""
            var parsed = parseDiff(stagedOutput, stage: .staged)
            parsed.append(contentsOf: parseDiff(unstagedOutput, stage: .unstaged))
            let untrackedDiffs = changed
                .filter { $0.stage == .untracked }
                .compactMap {
                    syntheticUntrackedDiff(
                        for: $0.path,
                        worktreePath: worktreePath,
                        maxBytes: maxSyntheticFileBytes
                    )
                }
            parsed.append(contentsOf: untrackedDiffs)
            files = parsed
        }

        return GitDiffSnapshot(
            changedFiles: changed,
            files: files,
            totalChangedFileCount: selectedPath == nil ? branch.totalCount : changed.count
        )
    }

    /// Get short stat summary
    static func diffStat(worktreePath: String) -> String {
        let output = runGit(args: ["diff", "--stat", "--no-color", "HEAD"], in: worktreePath) ?? ""
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// List changed files with status
    static func changedFiles(worktreePath: String) -> [(status: String, path: String)] {
        let output = runGit(args: ["status", "--porcelain=v1", "-z"], in: worktreePath) ?? ""
        return parsePorcelainRecords(output).map { record in
            let rawStatus = String([record.x, record.y])
            let status = rawStatus == "??" ? rawStatus : rawStatus.trimmingCharacters(in: .whitespaces)
            return (status: status, path: record.path)
        }
    }

    static func changedFileEntries(worktreePath: String) -> [GitChangedFile] {
        branchChangedFiles(worktreePath: worktreePath).files
    }

    /// Branch-relative change list: `git diff <merge-base(base)>` plus untracked.
    /// Falls back to porcelain `git status` when no base ref exists.
    /// When over `limit`, keeps the most recently modified files.
    static func branchChangedFiles(
        worktreePath: String,
        limit: Int = maxListedChangedFiles
    ) -> GitBranchChanges {
        let uncapped: [GitChangedFile]
        let baseRef: String?
        if let resolved = resolveBaseRef(worktreePath: worktreePath),
           let mergeBase = mergeBase(with: resolved, worktreePath: worktreePath) {
            baseRef = resolved
            let nameStatus = runGit(
                args: ["diff", "--name-status", "-z", "-M", mergeBase],
                in: worktreePath
            ) ?? ""
            var entries = parseNameStatus(nameStatus, stage: .unstaged)

            let porcelain = runGit(
                args: ["status", "--porcelain=v1", "-z", "--untracked-files=all"],
                in: worktreePath
            ) ?? ""
            let known = Set(entries.map(\.path))
            let untracked = parsePorcelainStatus(porcelain)
                .filter { $0.stage == .untracked && !known.contains($0.path) }
            entries.append(contentsOf: untracked)
            uncapped = entries
        } else {
            baseRef = nil
            let output = runGit(
                args: ["status", "--porcelain=v1", "-z", "--untracked-files=all"],
                in: worktreePath
            ) ?? ""
            uncapped = parsePorcelainStatus(output)
        }

        let capped = capToRecentFiles(uncapped, worktreePath: worktreePath, limit: limit)
        return GitBranchChanges(baseRef: baseRef, files: capped, totalCount: uncapped.count)
    }

    /// Keep up to `limit` entries, preferring newest mtime. Deleted/missing paths
    /// sort last so live edits surface first.
    static func capToRecentFiles(
        _ entries: [GitChangedFile],
        worktreePath: String,
        limit: Int = maxListedChangedFiles
    ) -> [GitChangedFile] {
        guard limit >= 0, entries.count > limit else { return entries }
        guard limit > 0 else { return [] }

        let root = URL(fileURLWithPath: worktreePath)
        let ranked: [(GitChangedFile, Date)] = entries.map { entry in
            let url = root.appendingPathComponent(entry.path)
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return (entry, date)
        }
        return ranked
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return lhs.0.path < rhs.0.path
            }
            .prefix(limit)
            .map(\.0)
    }

    static func resolveBaseRef(worktreePath: String) -> String? {
        for ref in preferredBaseRefs {
            if runGit(args: ["rev-parse", "--verify", "--quiet", ref], in: worktreePath) != nil {
                return ref
            }
        }
        return nil
    }

    private static func mergeBase(with baseRef: String?, worktreePath: String) -> String? {
        guard let baseRef else { return nil }
        let output = runGit(args: ["merge-base", "HEAD", baseRef], in: worktreePath)
        let trimmed = output?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }

    // MARK: - Diff Parser

    static func parseDiff(_ output: String, stage: GitChangeStage = .unstaged) -> [DiffFile] {
        var files: [DiffFile] = []
        var currentPath = ""
        var oldPath: String?
        var sourcePath: String?
        var status: DiffFile.FileStatus = .modified
        var currentHunks: [DiffHunk] = []
        var currentHunkHeader = ""
        var currentLines: [DiffLine] = []
        var additions = 0
        var deletions = 0

        func flushHunk() {
            if !currentHunkHeader.isEmpty {
                currentHunks.append(DiffHunk(header: currentHunkHeader, lines: currentLines))
                currentLines = []
                currentHunkHeader = ""
            }
        }

        func flushFile() {
            flushHunk()
            if !currentPath.isEmpty {
                files.append(DiffFile(
                    path: currentPath,
                    oldPath: oldPath,
                    status: status,
                    stage: stage,
                    additions: additions,
                    deletions: deletions,
                    hunks: currentHunks
                ))
            }
            currentPath = ""
            oldPath = nil
            sourcePath = nil
            status = .modified
            currentHunks = []
            additions = 0
            deletions = 0
        }

        for line in output.components(separatedBy: .newlines) {
            let inHunk = !currentHunkHeader.isEmpty
            if line.hasPrefix("diff --git") {
                flushFile()
                // Extract path: "diff --git a/path b/path"
                currentPath = parseDiffGitPath(line) ?? ""
            } else if !inHunk && line.hasPrefix("new file mode") {
                status = .added
            } else if !inHunk && line.hasPrefix("deleted file mode") {
                status = .deleted
            } else if !inHunk && line.hasPrefix("rename from ") {
                oldPath = String(line.dropFirst("rename from ".count))
                status = .renamed
            } else if !inHunk && line.hasPrefix("rename to ") {
                currentPath = String(line.dropFirst("rename to ".count))
                status = .renamed
            } else if !inHunk && line.hasPrefix("--- a/") {
                sourcePath = String(line.dropFirst("--- a/".count))
                if status == .deleted {
                    currentPath = sourcePath ?? currentPath
                }
            } else if !inHunk && line.hasPrefix("+++ b/") {
                currentPath = String(line.dropFirst("+++ b/".count))
            } else if !inHunk && line == "+++ /dev/null", status == .deleted {
                currentPath = sourcePath ?? currentPath
            } else if line.hasPrefix("@@") {
                flushHunk()
                currentHunkHeader = line
            } else if line.hasPrefix("+") && (inHunk || !line.hasPrefix("+++")) {
                currentLines.append(DiffLine(type: .addition, content: String(line.dropFirst())))
                additions += 1
            } else if line.hasPrefix("-") && (inHunk || !line.hasPrefix("---")) {
                currentLines.append(DiffLine(type: .deletion, content: String(line.dropFirst())))
                deletions += 1
            } else if line.hasPrefix(" ") {
                currentLines.append(DiffLine(type: .context, content: String(line.dropFirst())))
            }
        }
        flushFile()

        return files
    }

    private static func status(from char: Character) -> DiffFile.FileStatus {
        switch char {
        case "A", "C": return .added
        case "M": return .modified
        case "D": return .deleted
        case "R": return .renamed
        default: return .unknown
        }
    }

    private struct PorcelainStatusRecord {
        let x: Character
        let y: Character
        let path: String
        let oldPath: String?
    }

    private static func parsePorcelainRecords(_ output: String) -> [PorcelainStatusRecord] {
        let records = output
            .components(separatedBy: "\0")
            .filter { !$0.isEmpty }

        var parsed: [PorcelainStatusRecord] = []
        var index = 0
        while index < records.count {
            let record = records[index]
            guard record.count >= 3 else {
                index += 1
                continue
            }

            let x = record[record.startIndex]
            let y = record[record.index(after: record.startIndex)]
            let path = String(record.dropFirst(3))
            let hasRenamePath = x == "R" || x == "C" || y == "R" || y == "C"
            let oldPath = hasRenamePath && index + 1 < records.count ? records[index + 1] : nil
            parsed.append(PorcelainStatusRecord(x: x, y: y, path: path, oldPath: oldPath))
            index += hasRenamePath ? 2 : 1
        }
        return parsed
    }

    static func parsePorcelainStatus(_ output: String) -> [GitChangedFile] {
        var entries: [GitChangedFile] = []
        for record in parsePorcelainRecords(output) {
            if record.x == "?" && record.y == "?" {
                entries.append(GitChangedFile(path: record.path, oldPath: nil, status: .added, stage: .untracked))
            } else {
                if record.x != " " {
                    let entryStatus = status(from: record.x)
                    entries.append(GitChangedFile(
                        path: record.path,
                        oldPath: entryStatus == .renamed ? record.oldPath : nil,
                        status: entryStatus,
                        stage: .staged
                    ))
                }
                if record.y != " " {
                    let entryStatus = status(from: record.y)
                    entries.append(GitChangedFile(
                        path: record.path,
                        oldPath: entryStatus == .renamed ? record.oldPath : nil,
                        status: entryStatus,
                        stage: .unstaged
                    ))
                }
            }
        }
        return entries
    }

    /// Parse `git diff --name-status -z` output.
    /// Fields are NUL-separated: `M\0path\0`, or `R100\0old\0new\0` for renames/copies.
    static func parseNameStatus(_ output: String, stage: GitChangeStage = .unstaged) -> [GitChangedFile] {
        let records = output
            .components(separatedBy: "\0")
            .filter { !$0.isEmpty }

        var entries: [GitChangedFile] = []
        var index = 0
        while index < records.count {
            let statusField = records[index]
            guard let statusChar = statusField.first else {
                index += 1
                continue
            }

            let entryStatus = status(from: statusChar)
            let isRenameOrCopy = statusChar == "R" || statusChar == "C"
            if isRenameOrCopy {
                guard index + 2 < records.count else { break }
                let oldPath = records[index + 1]
                let newPath = records[index + 2]
                entries.append(GitChangedFile(
                    path: newPath,
                    oldPath: oldPath,
                    status: .renamed,
                    stage: stage
                ))
                index += 3
            } else {
                guard index + 1 < records.count else { break }
                entries.append(GitChangedFile(
                    path: records[index + 1],
                    oldPath: nil,
                    status: entryStatus,
                    stage: stage
                ))
                index += 2
            }
        }
        return entries
    }

    private static func parseDiffGitPath(_ line: String) -> String? {
        let prefix = "diff --git "
        guard line.hasPrefix(prefix) else { return nil }

        let operands = String(line.dropFirst(prefix.count))
        var separator = operands.startIndex
        while let range = operands[separator...].range(of: " b/") {
            let firstOperand = String(operands[..<range.lowerBound])
            let secondOperand = "b/" + String(operands[range.upperBound...])
            let firstPath = stripDiffPrefix(firstOperand, prefix: "a/")
            let secondPath = stripDiffPrefix(secondOperand, prefix: "b/")
            if firstPath == secondPath {
                return secondPath
            }
            separator = range.upperBound
        }

        if let range = operands.range(of: " b/") {
            let secondOperand = "b/" + String(operands[range.upperBound...])
            return stripDiffPrefix(secondOperand, prefix: "b/")
        }
        return nil
    }

    private static func stripDiffPrefix(_ value: String, prefix: String) -> String {
        value.hasPrefix(prefix) ? String(value.dropFirst(prefix.count)) : value
    }

    private static func syntheticUntrackedDiff(for relativePath: String, worktreePath: String, maxBytes: Int) -> DiffFile? {
        let url = URL(fileURLWithPath: worktreePath).appendingPathComponent(relativePath)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let size = values.fileSize,
              size <= maxBytes,
              let data = try? Data(contentsOf: url),
              !data.contains(0),
              let text = String(data: data, encoding: .utf8)
        else {
            return DiffFile(
                path: relativePath,
                status: .added,
                stage: .untracked,
                additions: 0,
                deletions: 0,
                hunks: []
            )
        }

        let lines = text.components(separatedBy: .newlines)
        let effectiveLines = lines.last == "" ? Array(lines.dropLast()) : lines
        let diffLines = effectiveLines.map { DiffLine(type: .addition, content: $0) }
        let hunk = DiffHunk(header: "@@ -0,0 +1,\(diffLines.count) @@", lines: diffLines)
        return DiffFile(
            path: relativePath,
            status: .added,
            stage: .untracked,
            additions: diffLines.count,
            deletions: 0,
            hunks: [hunk]
        )
    }

    /// Diff output routinely runs to hundreds of KB, so this must go through
    /// `GitProcess` — reading the pipe only after the child exits deadlocks.
    /// Allow longer than the default: a cold `git diff` over a large branch on a
    /// slow volume is legitimately slow, and these all run off the main thread.
    private static func runGit(args: [String], in directory: String) -> String? {
        GitProcess.run(args, in: directory, timeout: gitTimeout)
    }
}
