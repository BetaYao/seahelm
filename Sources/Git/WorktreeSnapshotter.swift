import Foundation

/// A worktree's full current state as a commit: what is committed, plus what is
/// staged, modified and untracked on top of it.
struct WorktreeSnapshot: Equatable {
    /// Commit holding the state. Equal to `head` when nothing is outstanding.
    let commit: String
    /// Tree of that commit. This is the change key: two snapshots with the same
    /// tree describe the same files, whatever their commits are.
    let tree: String
    /// The worktree's own HEAD at snapshot time.
    let head: String

    /// Nothing outstanding — the snapshot is HEAD itself, no objects written.
    var isClean: Bool { commit == head }
}

/// Captures a worktree without disturbing it.
///
/// Integration needs a commit per worktree, but an agent's turn usually ends
/// with work that is edited and not committed — and requiring a commit first
/// brings back everything wrong with `git add -A && git commit`: the repo's
/// pre-commit hooks, whatever `-A` happens to sweep up, and a history full of
/// machine commits.
///
/// So the snapshot is built in a scratch index instead. `GIT_INDEX_FILE` points
/// `read-tree`/`add` at a temporary file, `write-tree` turns it into a tree and
/// `commit-tree` into a commit. The worktree, the real index and HEAD are never
/// touched, so an agent working in that directory cannot tell this happened.
///
/// `git stash create` looks like it would do this and is the obvious first
/// guess, but it omits untracked files — which is most of what an agent
/// produces.
enum WorktreeSnapshotter {
    /// `add -A` walks the whole worktree, so this gets more room than a quick
    /// lookup, and rather less than a command that runs the repo's hooks.
    static let timeout: TimeInterval = 60

    /// Snapshots carry seahelm's own identity rather than the user's: they are
    /// machine artefacts of a throwaway integration, and should not read as
    /// something the user authored.
    static let authorName = "seahelm"
    static let authorEmail = "seahelm@localhost"

    static func snapshot(worktreePath: String) -> WorktreeSnapshot? {
        guard let head = revParse("HEAD", in: worktreePath),
              let headTree = revParse("HEAD^{tree}", in: worktreePath) else {
            // Unborn branch, or not a worktree at all. Nothing to integrate.
            return nil
        }

        // The common case by a wide margin, and the only one that writes no
        // objects: skip straight to HEAD when there is nothing on top of it.
        guard let status = GitProcess.run(
            ["status", "--porcelain=v1", "-z", "--untracked-files=all"],
            in: worktreePath,
            timeout: timeout
        ), !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return WorktreeSnapshot(commit: head, tree: headTree, head: head)
        }

        guard let scratch = makeScratchIndex() else { return nil }
        defer { try? FileManager.default.removeItem(at: scratch.directory) }
        let env = ["GIT_INDEX_FILE": scratch.indexPath]

        guard GitProcess.run(["read-tree", "HEAD"], in: worktreePath, timeout: timeout, environment: env) != nil,
              GitProcess.run(["add", "-A"], in: worktreePath, timeout: timeout, environment: env) != nil,
              let tree = GitProcess.run(["write-tree"], in: worktreePath, timeout: timeout, environment: env)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !tree.isEmpty else {
            return nil
        }

        // An `add -A` that changes nothing still lands here when status saw only
        // ignored noise; returning HEAD keeps the commit out of the graph.
        if tree == headTree {
            return WorktreeSnapshot(commit: head, tree: headTree, head: head)
        }

        guard let commit = commitTree(
            tree: tree,
            parents: [head],
            message: "seahelm: worktree snapshot",
            repoPath: worktreePath
        ) else { return nil }

        return WorktreeSnapshot(commit: commit, tree: tree, head: head)
    }

    /// `commit-tree` with seahelm's identity, so it works in a repo where the
    /// user has configured none.
    static func commitTree(
        tree: String,
        parents: [String],
        message: String,
        repoPath: String
    ) -> String? {
        var args = ["-c", "user.name=\(authorName)", "-c", "user.email=\(authorEmail)", "commit-tree", tree]
        for parent in parents {
            args.append(contentsOf: ["-p", parent])
        }
        args.append(contentsOf: ["-m", message])
        return GitProcess.run(args, in: repoPath, timeout: timeout)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
    }

    private static func revParse(_ rev: String, in worktreePath: String) -> String? {
        GitProcess.run(["rev-parse", "--verify", "--quiet", rev], in: worktreePath, timeout: timeout)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
    }

    /// A private directory holding one scratch index. The directory is what
    /// gets cleaned up — git writes lock files next to the index, so removing
    /// the index alone leaves them behind.
    private struct ScratchIndex {
        let directory: URL
        var indexPath: String { directory.appendingPathComponent("index").path }
    }

    private static func makeScratchIndex() -> ScratchIndex? {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("seahelm-index-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            NSLog("WorktreeSnapshotter: could not create scratch index dir: \(error)")
            return nil
        }
        return ScratchIndex(directory: dir)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
