import Foundation

/// What one integration round did.
struct IntegrationRunReport: Equatable {
    let integrationWorktreePath: String
    let result: IntegrationResult
    let outcome: IntegrationPublishOutcome
    /// Worktrees that offered nothing — no HEAD to snapshot, usually an unborn
    /// branch. Reported rather than silently skipped.
    let unsnapshotable: [String]
    /// Worktrees taken at HEAD because their agent was mid-turn, so their
    /// uncommitted work is not in this round.
    let committedOnly: [String]

    /// Whether this round is worth telling the user about. A clean publish is
    /// meant to be invisible; anything dropped, marked or held is not.
    var needsAttention: Bool {
        if result.hasConflicts || !unsnapshotable.isEmpty { return true }
        switch outcome {
        case .published, .unchanged: return false
        case .held, .failed: return true
        }
    }

    /// The ambient line on the checkout's card. Says what is in it, not what
    /// went wrong — the report card covers that.
    var cardLine: String {
        var line = result.included.isEmpty
            ? "integration · empty"
            : "integration · \(result.included.count) worktree\(result.included.count == 1 ? "" : "s")"
        if !result.excluded.isEmpty {
            line += " · excluded \(result.excluded.map(\.label).joined(separator: ", "))"
        }
        if !committedOnly.isEmpty {
            // Ambient, not a card: an agent still working is the normal case,
            // and raising one every round would be pure noise.
            line += " · \(committedOnly.count) still working"
        }
        switch outcome {
        case .held(.dirtyWorktree, _): line += " · held · local edits"
        case .held(.movedHead, _): line += " · held · commits made here"
        case .published, .unchanged, .failed: break
        }
        return line
    }

    /// Everything the card, the banner and the Changes panel show, from one
    /// round, so they cannot disagree about it.
    var panelState: IntegrationPanelState {
        var held = false
        var heldPaths: [String]?
        var heldHead: String?
        if case .held(let reason, _) = outcome {
            held = true
            switch reason {
            case .dirtyWorktree(let paths): heldPaths = paths
            case .movedHead(let head): heldHead = head
            }
        }
        return IntegrationPanelState(
            line: cardLine,
            included: result.included,
            excluded: result.excluded.map {
                IntegrationPanelState.Excluded(label: $0.label, paths: $0.conflictingPaths)
            },
            conflictedPaths: result.conflictedPaths,
            isHeld: held,
            heldPaths: heldPaths,
            heldHead: heldHead
        )
    }

    /// Whether the hold is one `force` would clear. Drives the card's options:
    /// offering to discard is only honest when there is something to discard.
    var isHeld: Bool {
        if case .held = outcome { return true }
        return false
    }

    /// Buttons for the report card. A held round is the only one with something
    /// to decide — publishing would destroy what is in the checkout — and the
    /// label has to name what goes, because that is the whole decision.
    /// Everything else is a notice, and takes the default single button.
    var cardOptions: [String]? {
        switch outcome {
        case .held(.dirtyWorktree, _): return ["Discard edits & update", "Leave it"]
        case .held(.movedHead, _): return ["Discard commits & update", "Leave it"]
        case .published, .unchanged, .failed: return nil
        }
    }

    /// Whether a card option means "run it again with force". Matched on the
    /// prefix the two discard labels share, so the wording stays free to change.
    static func isDiscardOption(_ text: String) -> Bool { text.hasPrefix("Discard") }

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
        if !committedOnly.isEmpty {
            parts.append("committed work only from \(committedOnly.joined(separator: ", ")) — still working")
        }
        switch outcome {
        case .published: break
        case .unchanged: parts.append("already current")
        case .held(.dirtyWorktree(let paths), _):
            parts.append(
                "not checked out — local edits in the integration worktree"
                    + Self.pathList(paths)
                    + "; `/integrate force` to discard them"
            )
        case .held(.movedHead(let head), _):
            parts.append(
                "not checked out — the checkout is at \(head.prefix(9)), which seahelm did not put there;"
                    + " commit or move that work somewhere it will survive, or `/integrate force` to drop it"
            )
        case .failed(let message): parts.append("checkout failed: \(message)")
        }
        return parts.joined(separator: " · ")
    }

    private static func pathList(_ paths: [String], limit: Int = 4) -> String {
        IntegrationWorktree.pathList(paths, limit: limit)
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
    ///   - isBusy: whether a worktree has an agent mid-turn. A round is
    ///     triggered by *one* agent finishing, but it folds in every worktree,
    ///     and the others may be mid-write — half a file, half a rename. Those
    ///     contribute their HEAD instead: their last self-consistent state,
    ///     rather than a torn one that could fail the integration in a way that
    ///     looks like a real conflict. They come in whole on the round their own
    ///     turn ends.
    static func run(
        repoPath: String,
        integrationPath: String,
        worktrees: [WorktreeInfo],
        mode: IntegrationConflictMode = .excludeConflicting,
        force: Bool = false,
        lastPublished: String? = nil,
        isBusy: (String) -> Bool = { _ in false }
    ) throws -> IntegrationRunReport {
        guard let base = GitDiff.resolveBaseRef(worktreePath: repoPath) else {
            throw IntegrationRunError.noBaseRef
        }

        var createdHead: String?
        if !FileManager.default.fileExists(atPath: integrationPath) {
            do {
                try IntegrationWorktree.create(repoPath: repoPath, at: integrationPath, base: base)
                createdHead = GitProcess.run(
                    ["rev-parse", "--verify", "--quiet", "HEAD"],
                    in: integrationPath,
                    timeout: IntegrationWorktree.timeout
                )?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
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
        var partial: [String] = []
        for worktree in candidates {
            if isBusy(worktree.path) {
                guard let head = WorktreeSnapshotter.head(worktreePath: worktree.path) else {
                    unsnapshotable.append(worktree.displayName)
                    continue
                }
                partial.append(worktree.displayName)
                integrationSources.append(
                    IntegrationSource(label: worktree.displayName, commit: head)
                )
                continue
            }
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

        let outcome = IntegrationWorktree.publish(
            commit: result.commit,
            to: integrationPath,
            force: force,
            // A checkout this round just created is at `base` and nothing else,
            // so it is its own provenance — without this the very first round
            // into a new checkout would hold on a head it wrote itself.
            expectedHead: lastPublished ?? createdHead,
            base: base
        )
        return IntegrationRunReport(
            integrationWorktreePath: integrationPath,
            result: result,
            outcome: outcome,
            unsnapshotable: unsnapshotable,
            committedOnly: partial
        )
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
