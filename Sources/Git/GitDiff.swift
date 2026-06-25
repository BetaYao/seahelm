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

enum GitDiff {
    /// Get diff for a worktree (staged + unstaged)
    static func diff(worktreePath: String) -> [DiffFile] {
        let stagedOutput = runGit(args: ["diff", "--cached", "--no-color"], in: worktreePath) ?? ""
        let unstagedOutput = runGit(args: ["diff", "--no-color"], in: worktreePath) ?? ""

        var files = parseDiff(stagedOutput, stage: .staged)
        files.append(contentsOf: parseDiff(unstagedOutput, stage: .unstaged))
        return files
    }

    static func snapshot(worktreePath: String, maxSyntheticFileBytes: Int = 128 * 1024) -> GitDiffSnapshot {
        let changed = changedFileEntries(worktreePath: worktreePath)
        let stagedOutput = runGit(args: ["diff", "--cached", "--no-color"], in: worktreePath) ?? ""
        let unstagedOutput = runGit(args: ["diff", "--no-color"], in: worktreePath) ?? ""

        var files = parseDiff(stagedOutput, stage: .staged)
        files.append(contentsOf: parseDiff(unstagedOutput, stage: .unstaged))

        let untrackedDiffs = changed
            .filter { $0.stage == .untracked }
            .compactMap {
                syntheticUntrackedDiff(
                    for: $0.path,
                    worktreePath: worktreePath,
                    maxBytes: maxSyntheticFileBytes
                )
            }
        files.append(contentsOf: untrackedDiffs)

        return GitDiffSnapshot(changedFiles: changed, files: files)
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
        let output = runGit(args: ["status", "--porcelain=v1", "-z", "--untracked-files=all"], in: worktreePath) ?? ""
        return parsePorcelainStatus(output)
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

    private static func runGit(args: [String], in directory: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: directory)

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}
