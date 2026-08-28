import Foundation

/// What one integration round did.
struct IntegrationRunReport: Equatable {
    let integrationWorktreePath: String
    let result: IntegrationResult
    let outcome: IntegrationPublishOutcome
    /// Worktrees that offered nothing — no HEAD to snapshot, usually an unborn
    /// branch. Reported rather than silently skipped.
    let unsnapshotable: [String]

    /// Whether this round is worth telling the user about. A clean publish is
    /// meant to be invisible; anything dropped, marked or held is not.
    var needsAttention: Bool {
        if result.hasConflicts || !unsnapshotable.isEmpty { return true }
        switch outcome {
        case .published, .unchanged: return false
        case .held, .failed: return true
        }
    }

    /// One line for a notification or the helm.
    var summary: String {
        var parts: [String] = []
        if result.included.isEmpty {
            parts.append("nothing to integrate")
        } else {
            parts.append("integrated \(result.included.joined(separator: ", "))")
        }
        if !result.excluded.isEmpty {
            let details = result.excluded.map { exclusion -> String in
                exclusion.conflictingPaths.isEmpty
                    ? exclusion.label
                    : "\(exclusion.label) (\(exclusion.conflictingPaths.joined(separator: ", ")))"
            }
            parts.append("excluded \(details.joined(separator: "; "))")
        }
        if !result.conflictedPaths.isEmpty {
            parts.append("conflict markers in \(result.conflictedPaths.joined(separator: ", "))")
        }
        switch outcome {
        case .published: break
        case .unchanged: parts.append("already current")
        case .held(.dirtyWorktree, _): parts.append("not checked out — local edits in the integration worktree")
        case .failed(let message): parts.append("checkout failed: \(message)")
        }
        return parts.joined(separator: " · ")
    }
}

enum IntegrationRunError: LocalizedError {
    case noBaseRef
    case worktreeUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .noBaseRef:
            return "Could not find a trunk to integrate onto"
        case .worktreeUnavailable(let message):
            return "Integration worktree unavailable: \(message)"
        }
    }
}

/// One integration round, start to finish: snapshot every fleet worktree, fold
/// them onto trunk, and move the integration checkout to the result.
///
/// Everything before the last step happens in the object database, so a round
/// that ends up held — or that fails outright — leaves the checkout exactly as
/// it was.
enum IntegrationRunner {
    /// Sources are taken in a stable order, because merge order decides which
    /// of two colliding worktrees gets reported. Path order is arbitrary but
    /// repeatable, which is the property that matters: the same fleet produces
    /// the same report twice running.
    static func sources(from worktrees: [WorktreeInfo], excluding excludedPaths: Set<String>) -> [WorktreeInfo] {
        worktrees
            .filter { !$0.isMainWorktree }
            .filter { !excludedPaths.contains(WorktreeDiscovery.canonicalPath($0.path)) }
            .sorted { $0.path < $1.path }
    }

    /// - Parameters:
    ///   - integrationPath: the checkout to publish into. Created if absent.
    ///   - worktrees: the repo's worktrees, main and integration included; both
    ///     are filtered out here.
    static func run(
        repoPath: String,
        integrationPath: String,
        worktrees: [WorktreeInfo],
        mode: IntegrationConflictMode = .excludeConflicting,
        force: Bool = false
    ) throws -> IntegrationRunReport {
        guard let base = GitDiff.resolveBaseRef(worktreePath: repoPath) else {
            throw IntegrationRunError.noBaseRef
        }

        if !FileManager.default.fileExists(atPath: integrationPath) {
            do {
                try IntegrationWorktree.create(repoPath: repoPath, at: integrationPath, base: base)
            } catch {
                throw IntegrationRunError.worktreeUnavailable(error.localizedDescription)
            }
        }

        let candidates = sources(
            from: worktrees,
            excluding: [WorktreeDiscovery.canonicalPath(integrationPath)]
        )

        var integrationSources: [IntegrationSource] = []
        var unsnapshotable: [String] = []
        for worktree in candidates {
            guard let snapshot = WorktreeSnapshotter.snapshot(worktreePath: worktree.path) else {
                unsnapshotable.append(worktree.displayName)
                continue
            }
            integrationSources.append(
                IntegrationSource(label: worktree.displayName, commit: snapshot.commit)
            )
        }

        guard let result = IntegrationBuilder.build(
            repoPath: repoPath,
            base: base,
            sources: integrationSources,
            mode: mode
        ) else {
            throw IntegrationRunError.noBaseRef
        }

        let outcome = IntegrationWorktree.publish(commit: result.commit, to: integrationPath, force: force)
        return IntegrationRunReport(
            integrationWorktreePath: integrationPath,
            result: result,
            outcome: outcome,
            unsnapshotable: unsnapshotable
        )
    }
}
