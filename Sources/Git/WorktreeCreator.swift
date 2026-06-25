import Foundation

enum WorktreeCreatorError: Error, LocalizedError {
    case gitFailed(String)
    case branchExists(String)
    case worktreePathExists(String)

    var errorDescription: String? {
        switch self {
        case .gitFailed(let msg): return "Git error: \(msg)"
        case .branchExists(let name): return "Branch '\(name)' already exists"
        case .worktreePathExists(let path): return "Worktree path already exists: \(path)"
        }
    }
}

enum WorktreeCreator {
    static func branchName(fromTaskDescription description: String) -> String {
        branchName(fromTaskDescription: description, existingBranches: [])
    }

    static func branchName(fromTaskDescription description: String, existingBranches: [String]) -> String {
        let slug = slugFromTaskDescription(description)
        let base = "task/\(slug)"
        let existing = Set(existingBranches)
        guard existing.contains(base) else { return base }

        var suffix = 2
        while existing.contains("\(base)-\(suffix)") {
            suffix += 1
        }
        return "\(base)-\(suffix)"
    }

    /// List remote and local branches for a repo
    static func listBranches(repoPath: String) -> [String] {
        let output = runGit(args: ["branch", "-a", "--format=%(refname:short)"], in: repoPath)
        guard let output else { return ["main"] }
        return output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains("HEAD") }
            .map { branch in
                // Strip "origin/" prefix for remote branches
                if branch.hasPrefix("origin/") {
                    return String(branch.dropFirst("origin/".count))
                }
                return branch
            }
            .reduce(into: [String]()) { result, branch in
                if !result.contains(branch) { result.append(branch) }
            }
    }

    /// Create a new worktree with a new branch
    static func createWorktree(
        repoPath: String,
        branchName: String,
        baseBranch: String
    ) throws -> WorktreeInfo {
        // Determine worktree directory (sibling to repo)
        let repoURL = URL(fileURLWithPath: repoPath)
        let repoName = repoURL.lastPathComponent
        let parentDir = repoURL.deletingLastPathComponent()
        let worktreePath = parentDir.appendingPathComponent("\(repoName)-worktrees/\(branchName)").path

        // Check if path already exists
        if FileManager.default.fileExists(atPath: worktreePath) {
            throw WorktreeCreatorError.worktreePathExists(worktreePath)
        }

        // Create parent directory
        let worktreeParent = URL(fileURLWithPath: worktreePath).deletingLastPathComponent().path
        try FileManager.default.createDirectory(atPath: worktreeParent, withIntermediateDirectories: true)

        // git worktree add -b <branch> <path> <base>
        let result = runGit(
            args: ["worktree", "add", "-b", branchName, worktreePath, baseBranch],
            in: repoPath
        )

        // Check if it failed (branch might already exist)
        if result == nil {
            // Try without -b (branch already exists, just create worktree)
            let result2 = runGit(
                args: ["worktree", "add", worktreePath, branchName],
                in: repoPath
            )
            if result2 == nil {
                throw WorktreeCreatorError.gitFailed("Failed to create worktree for branch '\(branchName)'")
            }
        }

        // Get commit hash
        let hash = runGit(args: ["rev-parse", "--short", "HEAD"], in: worktreePath)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // Write seahelm-suggest guidance to worktree
        SuggestGuidanceWriter.writeForWorktree(worktreePath)

        return WorktreeInfo(
            path: worktreePath,
            branch: branchName,
            commitHash: hash,
            isMainWorktree: false
        )
    }

    /// Copy environment files (.env, .env.*, .envrc) from one worktree root to
    /// another. Best-effort: missing files and copy failures are ignored.
    static func copyEnvironmentFiles(from sourcePath: String, to destPath: String) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: sourcePath) else { return }
        for name in entries where isEnvironmentFile(name) {
            let srcFile = (sourcePath as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: srcFile, isDirectory: &isDir), !isDir.boolValue else { continue }
            let dstFile = (destPath as NSString).appendingPathComponent(name)
            try? fm.removeItem(atPath: dstFile)
            try? fm.copyItem(atPath: srcFile, toPath: dstFile)
        }
    }

    private static func isEnvironmentFile(_ name: String) -> Bool {
        name == ".env" || name == ".envrc" || name.hasPrefix(".env.")
    }

    private static func slugFromTaskDescription(_ description: String) -> String {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let latinized = NSMutableString(string: trimmed) as CFMutableString
        CFStringTransform(latinized, nil, kCFStringTransformToLatin, false)
        CFStringTransform(latinized, nil, kCFStringTransformStripCombiningMarks, false)

        var parts: [String] = []
        var current = ""
        for scalar in (latinized as String).lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                parts.append(current)
                current = ""
            }
        }
        if !current.isEmpty { parts.append(current) }

        let joined = parts.joined(separator: "-")
        guard !joined.isEmpty else {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            return "task-\(formatter.string(from: Date()))"
        }

        if joined.count <= 48 { return joined }
        let end = joined.index(joined.startIndex, offsetBy: 48)
        return String(joined[..<end]).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
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
