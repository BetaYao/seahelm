import Foundation

/// What only git can say about whether a worktree is done with: when it last
/// moved, and what it still has to get into a PR.
struct WorktreeCleanupProbe: Equatable {
    /// HEAD's committer date. A commit is movement even when no agent reported
    /// it — a person committing from a terminal of their own.
    var headCommittedAt: Date?
    /// When the worktree directory was made. A fresh checkout of an old commit
    /// has not been sitting there for as long as that commit is old.
    var createdAt: Date?
    /// Files the Changes tab would list. Nil when that cannot be told: no base
    /// ref to measure committed work against, or a probe that skipped the count
    /// because the worktree moved too recently for it to matter.
    var outstandingFiles: Int?

    /// `limit: 0` still counts every file (`totalCount` is uncapped) but skips
    /// the per-file `stat` that ranking them for display would cost.
    static func resolve(worktreePath: String, now: Date = Date()) -> WorktreeCleanupProbe {
        var probe = WorktreeCleanupProbe()
        // A stale removable mount blocks git as surely as it blocks `stat()`.
        guard !VolumeFence.isFenced(worktreePath) else { return probe }

        probe.createdAt = FileSystemProbe.attributes(worktreePath, timeout: 0.5)?[.creationDate] as? Date
        if let output = GitProcess.run(["log", "-1", "--format=%ct", "HEAD"], in: worktreePath),
           let seconds = TimeInterval(output.trimmingCharacters(in: .whitespacesAndNewlines)) {
            probe.headCommittedAt = Date(timeIntervalSince1970: seconds)
        }

        // The count is the expensive half — `git status`, a merge-tree, maybe a
        // GitHub lookup — and a worktree that moved within the day is not a
        // candidate whatever it holds.
        guard WorktreeCleanupPolicy.isQuiet(since: [probe.headCommittedAt, probe.createdAt], now: now) else {
            return probe
        }
        let changes = GitDiff.branchChangedFiles(worktreePath: worktreePath, limit: 0)
        // Without a base only uncommitted work is visible, and "nothing
        // uncommitted" says nothing about commits that never reached a PR.
        if changes.basis != .workingTree {
            probe.outstandingFiles = changes.totalCount
        }
        return probe
    }
}

/// When the fleet marks a worktree as ready to clean up: nobody has touched it
/// for a day, and it has nothing left to go into a PR.
enum WorktreeCleanupPolicy {
    static let quietInterval: TimeInterval = 24 * 3600

    /// The half the fleet can answer without git — decides whether git is
    /// worth asking at all.
    ///
    /// Main and the integration checkout are never candidates: neither is a
    /// piece of work that ends. A running pane is not quiet whatever its clock
    /// says (a long build prints nothing new), and a waiting one is an agent
    /// with a question nobody has answered — the mark would replace the very
    /// dot that says so.
    static func isQuiet(isMain: Bool, isIntegration: Bool, statuses: [AgentStatus],
                        lastActivity: Date?, now: Date) -> Bool {
        guard !isMain, !isIntegration else { return false }
        guard !statuses.contains(where: { $0 == .running || $0 == .waiting }) else { return false }
        return isQuiet(since: [lastActivity], now: now)
    }

    static func isCandidate(isMain: Bool, isIntegration: Bool, statuses: [AgentStatus],
                            lastActivity: Date?, probe: WorktreeCleanupProbe?, now: Date) -> Bool {
        guard isQuiet(isMain: isMain, isIntegration: isIntegration, statuses: statuses,
                      lastActivity: lastActivity, now: now),
              let probe, probe.outstandingFiles == 0 else { return false }
        return isQuiet(since: [probe.headCommittedAt, probe.createdAt], now: now)
    }

    /// A date nobody knows is no evidence of movement.
    static func isQuiet(since dates: [Date?], now: Date) -> Bool {
        dates.allSatisfy { date in date.map { now.timeIntervalSince($0) >= quietInterval } ?? true }
    }
}

/// Probes, cached per worktree and resolved off the main thread, so building
/// the fleet rows only ever reads a dictionary.
final class WorktreeCleanupStore {
    static let shared = WorktreeCleanupStore()

    /// What a probe answers moves on the scale of days; a merged PR or a
    /// commit landing elsewhere shows up within this.
    static let ttl: TimeInterval = 10 * 60

    /// Main queue, once per refresh that changed what is known about a path.
    var onChange: ((String) -> Void)?

    private struct Entry { let probe: WorktreeCleanupProbe; let at: Date }
    private var entries: [String: Entry] = [:]
    private var inFlight: Set<String> = []
    private let lock = NSLock()
    /// Serial: a fleet of quiet worktrees must not fork a `git status` each at once.
    private let queue = DispatchQueue(label: "seahelm.worktree-cleanup", qos: .utility)
    private let resolve: (String) -> WorktreeCleanupProbe

    init(resolve: @escaping (String) -> WorktreeCleanupProbe = { WorktreeCleanupProbe.resolve(worktreePath: $0) }) {
        self.resolve = resolve
    }

    /// The last probe, without touching disk. Nil if never resolved.
    func probe(worktreePath: String) -> WorktreeCleanupProbe? {
        lock.withLock { entries[worktreePath]?.probe }
    }

    /// Re-probe `worktreePath` in the background unless a fresh answer is
    /// already cached or on its way.
    func refresh(worktreePath: String, now: Date = Date()) {
        let shouldResolve: Bool = lock.withLock {
            if let entry = entries[worktreePath], now.timeIntervalSince(entry.at) < Self.ttl { return false }
            return inFlight.insert(worktreePath).inserted
        }
        guard shouldResolve else { return }
        queue.async { [weak self] in
            guard let self else { return }
            let probe = self.resolve(worktreePath)
            let changed: Bool = self.lock.withLock {
                self.inFlight.remove(worktreePath)
                let old = self.entries[worktreePath]?.probe
                self.entries[worktreePath] = Entry(probe: probe, at: Date())
                return old != probe
            }
            guard changed else { return }
            DispatchQueue.main.async { self.onChange?(worktreePath) }
        }
    }

    func evict(worktreePath: String) {
        lock.withLock { _ = entries.removeValue(forKey: worktreePath) }
    }
}
