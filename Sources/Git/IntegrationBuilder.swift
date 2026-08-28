import Foundation

/// One worktree offered to an integration round.
struct IntegrationSource: Equatable {
    /// How this shows up in the report — a branch, or a worktree's name.
    let label: String
    /// Commit to merge, normally from `WorktreeSnapshotter`.
    let commit: String
}

/// A source that did not make it in, and what it collided on.
struct IntegrationExclusion: Equatable {
    let label: String
    /// Paths git could not merge. Empty only if git reported a conflict without
    /// naming one, which would be a git bug rather than a state to act on.
    let conflictingPaths: [String]
}

struct IntegrationResult: Equatable {
    /// The integrated commit. Equal to the base when nothing merged in.
    ///
    /// Not an identity: `commit-tree` stamps a timestamp, so two rounds over an
    /// unchanged fleet produce different commits holding the same files. Compare
    /// `tree` to ask whether anything actually changed.
    let commit: String
    /// The integrated tree — the change key. Same tree, same files, whatever
    /// the commits say.
    let tree: String
    let base: String
    /// Labels that merged, in the order they were applied.
    let included: [String]
    let excluded: [IntegrationExclusion]
    /// Paths carrying conflict markers. Only ever populated in
    /// `.includeWithMarkers`, where a conflicted source is kept rather than
    /// dropped.
    let conflictedPaths: [String]

    var isEmpty: Bool { commit == base }
    var hasConflicts: Bool { !excluded.isEmpty || !conflictedPaths.isEmpty }
}

/// What to do with a source that will not merge cleanly.
enum IntegrationConflictMode: Equatable {
    /// Drop it. The result stays buildable and testable, at the cost of that
    /// source's other work.
    case excludeConflicting
    /// Keep it, conflict markers and all. Nothing is lost and nothing compiles;
    /// this is the mode for looking at a conflict, not for running tests.
    case includeWithMarkers
}

/// Combines several worktrees into one commit without checking anything out.
///
/// Every merge happens in the object database: `merge-tree` produces a tree,
/// `commit-tree` turns it into a commit, and that commit is the next merge's
/// left side. Nothing here touches a worktree or an index, so nothing here can
/// leave one wedged mid-merge — which is what makes it safe to run
/// automatically. A `git merge` in a checkout could not be: one conflict and
/// the integration worktree sits in a conflicted state until someone clears it.
///
/// Conflicts are therefore a *result*, reported per source, rather than a
/// failure that stops the round.
///
/// Order matters and cannot not matter: when two sources collide, whichever is
/// applied second is the one reported. `sources` is applied as given, so the
/// caller owns that order and gets the same answer twice for the same input.
enum IntegrationBuilder {
    static let timeout: TimeInterval = 60

    static func build(
        repoPath: String,
        base: String,
        sources: [IntegrationSource],
        mode: IntegrationConflictMode = .excludeConflicting
    ) -> IntegrationResult? {
        guard let baseCommit = GitProcess.run(
            ["rev-parse", "--verify", "--quiet", base],
            in: repoPath,
            timeout: timeout
        )?.trimmingCharacters(in: .whitespacesAndNewlines), !baseCommit.isEmpty else {
            return nil
        }

        var accumulator = baseCommit
        var included: [String] = []
        var excluded: [IntegrationExclusion] = []
        var conflicted: [String] = []

        for source in sources {
            guard let merge = mergeTree(accumulator, source.commit, repoPath: repoPath) else {
                // git could not run the merge at all — a missing commit, say.
                // Treat it like a conflict with nothing to name rather than
                // abandoning the whole round.
                excluded.append(IntegrationExclusion(label: source.label, conflictingPaths: []))
                continue
            }

            if merge.conflictingPaths.isEmpty {
                guard let next = commit(tree: merge.tree, onto: accumulator, merging: source, repoPath: repoPath) else {
                    excluded.append(IntegrationExclusion(label: source.label, conflictingPaths: []))
                    continue
                }
                accumulator = next
                included.append(source.label)
                continue
            }

            switch mode {
            case .excludeConflicting:
                excluded.append(
                    IntegrationExclusion(label: source.label, conflictingPaths: merge.conflictingPaths)
                )
            case .includeWithMarkers:
                guard let next = commit(tree: merge.tree, onto: accumulator, merging: source, repoPath: repoPath) else {
                    excluded.append(
                        IntegrationExclusion(label: source.label, conflictingPaths: merge.conflictingPaths)
                    )
                    continue
                }
                accumulator = next
                included.append(source.label)
                for path in merge.conflictingPaths where !conflicted.contains(path) {
                    conflicted.append(path)
                }
            }
        }

        guard let tree = GitProcess.run(
            ["rev-parse", "--verify", "--quiet", "\(accumulator)^{tree}"],
            in: repoPath,
            timeout: timeout
        )?.trimmingCharacters(in: .whitespacesAndNewlines), !tree.isEmpty else {
            return nil
        }

        return IntegrationResult(
            commit: accumulator,
            tree: tree,
            base: baseCommit,
            included: included,
            excluded: excluded,
            conflictedPaths: conflicted
        )
    }

    // MARK: - merge-tree

    struct MergeTreeOutcome: Equatable {
        /// Always present: on a conflict this tree carries the merge with
        /// conflict markers in the paths below.
        let tree: String
        let conflictingPaths: [String]
    }

    /// `git merge-tree --write-tree`, which merges two commits and writes the
    /// result to the object database without a worktree or an index.
    static func mergeTree(_ lhs: String, _ rhs: String, repoPath: String) -> MergeTreeOutcome? {
        let result = GitProcess.capture(
            ["merge-tree", "--write-tree", "--name-only", "-z", lhs, rhs],
            in: repoPath,
            timeout: timeout
        )
        // Exit 0 is a clean merge and 1 a conflicted one; both print a tree.
        // Anything else is a real failure, and prints nothing usable.
        guard result.exitCode == 0 || result.exitCode == 1 else { return nil }
        return parseMergeTree(result.stdout)
    }

    /// `<tree>\0` on success; `<tree>\0<path>\0...\0\0<informational records>`
    /// on conflict, the empty field closing the path list.
    static func parseMergeTree(_ output: String) -> MergeTreeOutcome? {
        var fields = output.components(separatedBy: "\0")
        guard let tree = fields.first?.trimmingCharacters(in: .whitespacesAndNewlines),
              !tree.isEmpty else { return nil }
        fields.removeFirst()

        var paths: [String] = []
        for field in fields {
            if field.isEmpty { break }
            paths.append(field)
        }
        return MergeTreeOutcome(tree: tree, conflictingPaths: paths)
    }

    private static func commit(
        tree: String,
        onto accumulator: String,
        merging source: IntegrationSource,
        repoPath: String
    ) -> String? {
        WorktreeSnapshotter.commitTree(
            tree: tree,
            parents: [accumulator, source.commit],
            message: "seahelm: integrate \(source.label)",
            repoPath: repoPath
        )
    }
}
