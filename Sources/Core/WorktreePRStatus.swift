import Foundation

/// What a worktree's branch has on GitHub: its newest pull request, whether
/// that PR's checks pass, and where review stands. Drawn on the fleet row so
/// "CI is red" or "approved, merge it" is visible without opening anything.
struct WorktreePRStatus: Equatable {
    enum State: String { case open, draft, merged, closed }
    /// The head commit's check rollup. Nil when the commit reports no checks.
    enum Checks: String { case passing, failing, pending }
    enum Review: String {
        case approved
        case changesRequested = "changes_requested"
        case reviewRequired = "review_required"
    }

    let number: Int
    let url: String
    let state: State
    let checks: Checks?
    let review: Review?

    /// Checks and review only mean something while the PR can still change.
    var isLive: Bool { state == .open || state == .draft }

    /// One sentence for a tooltip or a screen reader.
    var summary: String {
        var parts = ["PR #\(number)", state == .draft ? "draft" : state.rawValue]
        if isLive, let checks {
            parts.append(["passing": "checks passing", "failing": "checks failing",
                          "pending": "checks running"][checks.rawValue]!)
        }
        if isLive, let review {
            parts.append(["approved": "approved", "changes_requested": "changes requested",
                          "review_required": "review required"][review.rawValue]!)
        }
        return parts.joined(separator: " · ")
    }

    /// Wire shape for remote clients (`fleet.groups` items).
    var dict: [String: Any] {
        var d: [String: Any] = ["number": number, "url": url, "state": state.rawValue]
        if isLive, let checks { d["checks"] = checks.rawValue }
        if isLive, let review { d["review"] = review.rawValue }
        return d
    }
}

/// Reads the answer to `WorktreePRStatus.query`. Pure, so it can be tested
/// against recorded JSON.
extension WorktreePRStatus {
    /// A PR as seahelm-core reports it (`pr.list`, the fleet item's `pr`).
    init?(dict d: [String: Any]) {
        guard let number = d["number"] as? Int, let state = State(rawValue: d["state"] as? String ?? "") else { return nil }
        self.init(number: number, url: d["url"] as? String ?? "", state: state,
                  checks: (d["checks"] as? String).flatMap(Checks.init(rawValue:)),
                  review: (d["review"] as? String).flatMap(Review.init(rawValue:)))
    }
}

/// Each worktree's pull request, as seahelm-core fetches it (`pr.list`,
/// `crates/core/src/pr.rs`: GitHub once a minute per repo). The app asks the
/// core every 15 s and keeps the answer; it calls GitHub for none of this.
final class WorktreePRStore {
    static let shared = WorktreePRStore()
    static let interval: TimeInterval = 15

    /// Main queue, when what is known about any worktree changed.
    var onChange: (() -> Void)?

    private let lock = NSLock()
    private var byWorktree: [String: (branch: String, pr: WorktreePRStatus)] = [:]
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }

    /// The worktree's PR as last heard, when it is still for this branch.
    func status(worktreePath: String, branch: String) -> WorktreePRStatus? {
        lock.withLock {
            guard let e = byWorktree[worktreePath], e.branch == branch else { return nil }
            return e.pr
        }
    }

    private func poll() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self, case .success(let r) = CoreSocketClient.call("pr.list") else { return }
            var next: [String: (branch: String, pr: WorktreePRStatus)] = [:]
            for row in r["prs"] as? [[String: Any]] ?? [] {
                guard let path = row["worktree_path"] as? String,
                      let pr = (row["pr"] as? [String: Any]).flatMap(WorktreePRStatus.init(dict:)) else { continue }
                next[path] = (row["branch"] as? String ?? "", pr)
            }
            let changed: Bool = self.lock.withLock {
                let same = next.count == self.byWorktree.count && next.allSatisfy { k, v in
                    self.byWorktree[k].map { $0.branch == v.branch && $0.pr == v.pr } ?? false
                }
                self.byWorktree = next
                return !same
            }
            if changed { DispatchQueue.main.async { self.onChange?() } }
        }
    }
}
