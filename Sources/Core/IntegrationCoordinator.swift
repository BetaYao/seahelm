import Foundation

/// Keeps each repo's integration checkout current as agents finish turns.
///
/// The trigger is the edge seahelm already computes: an agent leaving
/// `.running` is a stage of work reaching a resting point. Several agents
/// finishing together coalesce into one round rather than one round each.
///
/// Only repos that already have an integration checkout are touched. Running
/// `/integrate` once is what opts a repo in — nothing here creates a directory
/// on its own, so turning this on cannot surprise anyone with new state on
/// disk.
///
/// This is only safe to run unattended because of what `IntegrationRunner`
/// does: every merge happens in the object database, and the checkout is moved
/// by a single `reset --hard` onto an already-merged commit. There is no
/// partial state to wake up to. The one destructive moment — discarding local
/// edits in the checkout — is never taken automatically; those rounds report a
/// hold instead.
final class IntegrationCoordinator {
    /// Several agents finishing within a turn of each other are one round.
    static let defaultCoalesceWindow: TimeInterval = 2.0

    /// Injectable so tests do not have to spend the real window on every case.
    let coalesceWindow: TimeInterval

    private let isEnabled: () -> Bool
    private let repoRoot: (String) -> String?
    private let worktrees: (String) -> [WorktreeInfo]
    private let integrationPath: (String) -> String?
    private let isCheckoutBusy: (String) -> Bool
    /// Whether a worktree has an agent mid-turn. Such a worktree contributes its
    /// HEAD rather than a live snapshot — see `IntegrationRunner.run`.
    private let isWorktreeBusy: (String) -> Bool
    private let onReport: (IntegrationRunReport, String) -> Void
    private let runRound: (String, String, [WorktreeInfo]) throws -> IntegrationRunReport

    private var pending: [String: DispatchWorkItem] = [:]
    private var inFlight: Set<String> = []

    init(
        coalesceWindow: TimeInterval = IntegrationCoordinator.defaultCoalesceWindow,
        isEnabled: @escaping () -> Bool,
        repoRoot: @escaping (String) -> String?,
        worktrees: @escaping (String) -> [WorktreeInfo],
        integrationPath: @escaping (String) -> String?,
        isCheckoutBusy: @escaping (String) -> Bool,
        isWorktreeBusy: @escaping (String) -> Bool = { _ in false },
        onReport: @escaping (IntegrationRunReport, String) -> Void,
        runRound: ((String, String, [WorktreeInfo]) throws -> IntegrationRunReport)? = nil
    ) {
        self.coalesceWindow = coalesceWindow
        self.isEnabled = isEnabled
        self.repoRoot = repoRoot
        self.worktrees = worktrees
        self.integrationPath = integrationPath
        self.isCheckoutBusy = isCheckoutBusy
        self.isWorktreeBusy = isWorktreeBusy
        self.onReport = onReport
        self.runRound = runRound ?? { repo, path, trees in
            try IntegrationRunner.run(repoPath: repo, integrationPath: path,
                                      worktrees: trees, isBusy: isWorktreeBusy)
        }
    }

    /// An agent status outcome. Only the edge out of `.running` schedules work.
    func handle(_ outcome: IngestOutcome) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard outcome.statusChanged,
              outcome.oldStatus == .running,
              outcome.newStatus != .running else { return }
        schedule(worktreePath: outcome.info.worktreePath)
    }

    /// Exposed for the same edge arriving as a plain transition.
    func handle(_ transition: StatusTransition) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard transition.oldStatus == .running, transition.newStatus != .running else { return }
        schedule(worktreePath: transition.worktreePath)
    }

    private func schedule(worktreePath: String) {
        guard isEnabled(),
              !worktreePath.isEmpty,
              let repo = repoRoot(worktreePath),
              let path = integrationPath(repo),
              FileManager.default.fileExists(atPath: path) else { return }

        // Replace any round already waiting for this repo: the newer edge
        // supersedes it, and the coalesce window restarts so a burst of agents
        // finishing produces one round after the burst, not one per agent.
        pending[repo]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pending[repo] = nil
            self?.run(repo: repo, integrationPath: path)
        }
        pending[repo] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + coalesceWindow, execute: work)
    }

    private func run(repo: String, integrationPath path: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        // One round per repo at a time. A round that lands while another is
        // running would race on the same checkout, and its result would be
        // stale anyway — the edge that triggered it will come round again.
        guard !inFlight.contains(repo) else { return }
        // Someone is using the checkout: publishing would pull files out from
        // under them. Skip rather than build a result that can only be held.
        guard !isCheckoutBusy(path) else { return }

        inFlight.insert(repo)
        let trees = worktrees(repo)
        let round = runRound
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let report = try? round(repo, path, trees)
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight.remove(repo)
                guard let report else { return }
                self.onReport(report, repo)
            }
        }
    }
}
