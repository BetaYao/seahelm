import Foundation

protocol FleetDelegate: AnyObject {
    func paneDidChange(_ pane: PaneInfo)
}

/// One change to a pane as seahelm-core reported it (`pane.status_changed`,
/// `pane.updated`, or a replay on connect).
struct PaneChange {
    let info: PaneInfo
    let oldStatus: AgentStatus
    let newStatus: AgentStatus
    var statusChanged: Bool { oldStatus != newStatus }
    /// The agent finished a turn (the core's `is_completion`).
    let isCompletion: Bool
    /// The core's event sequence; 0 for a replay.
    let seq: UInt64
}

/// The app's copy of what every pane is doing (docs/app-reads-core.md).
///
/// Two kinds of fact meet here and nothing else:
/// - **Layout**, the app's own: which panes exist, the worktree each is filed
///   under, their order (`register`, `unregister`, `rehome`, `reorder`).
/// - **State**, seahelm-core's: status, messages, tasks, activity, unseen
///   (`apply`, from `CoreClient`). Nothing here decides any of it.
///
/// Keyed by `Station.id`; the core keys by seahelmd session name, and
/// `CoreClient` maps one to the other.
final class Fleet {
    static let shared = Fleet()

    weak var delegate: FleetDelegate?
    /// Every change the core reports, on the main thread.
    var onChange: ((PaneChange) -> Void)?

    private let lock = NSLock()
    private var panes: [String: PaneInfo] = [:]
    private var orderedIDs: [String] = []
    /// Worktree path → its panes, in registration order.
    private var worktreeIndex: [String: [String]] = [:]
    private var backendsByPath: [String: String] = [:]

    private init() {}

    // MARK: - Layout

    func register(station: Station, worktreePath: String, branch: String,
                  project: String, startedAt: Date?,
                  paneSessionKey: String? = nil, backend: String = "seahelmd") {
        let id = station.id
        let channel = paneSessionKey.map { PaneInput.shared.attach(terminalID: id, paneSessionKey: $0) }
        lock.lock(); defer { lock.unlock() }
        backendsByPath[worktreePath] = backend
        panes[id] = PaneInfo(id: id, worktreePath: worktreePath, agentType: .unknown, project: project,
                             branch: branch, status: .unknown, lastMessage: "", commandLine: nil,
                             roundDuration: 0, startedAt: startedAt, station: station, channel: channel,
                             taskProgress: TaskProgress())
        if !(worktreeIndex[worktreePath] ?? []).contains(id) { worktreeIndex[worktreePath, default: []].append(id) }
        if !orderedIDs.contains(id) { orderedIDs.append(id) }
    }

    func unregister(terminalID: String) {
        PaneInput.shared.detach(terminalID: terminalID)
        lock.lock(); defer { lock.unlock() }
        guard let info = panes.removeValue(forKey: terminalID) else { return }
        orderedIDs.removeAll { $0 == terminalID }
        unindex(terminalID, from: info.worktreePath)
    }

    /// File a live pane under another worktree, keeping its state.
    @discardableResult
    func rehome(terminalID: String, to worktreePath: String, branch: String, project: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let old = panes[terminalID], old.worktreePath != worktreePath else { return false }
        if backendsByPath[worktreePath] == nil, let backend = backendsByPath[old.worktreePath] {
            backendsByPath[worktreePath] = backend
        }
        unindex(terminalID, from: old.worktreePath)
        worktreeIndex[worktreePath, default: []].append(terminalID)
        panes[terminalID] = old.rehomed(to: worktreePath, branch: branch, project: project)
        return true
    }

    /// Order panes as the fleet's rows are ordered (worktree paths), keeping
    /// registration order within a worktree.
    func reorder(paths: [String]) {
        lock.lock(); defer { lock.unlock() }
        orderedIDs = orderedIDs.enumerated().sorted { a, b in
            let ai = paths.firstIndex(of: panes[a.element]?.worktreePath ?? "") ?? Int.max
            let bi = paths.firstIndex(of: panes[b.element]?.worktreePath ?? "") ?? Int.max
            return ai != bi ? ai < bi : a.offset < b.offset
        }.map(\.element)
    }

    func backend(forWorktree path: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return backendsByPath[path]
    }

    private func unindex(_ id: String, from path: String) {
        worktreeIndex[path]?.removeAll { $0 == id }
        if worktreeIndex[path]?.isEmpty == true {
            worktreeIndex.removeValue(forKey: path)
            backendsByPath.removeValue(forKey: path)
        }
    }

    // MARK: - State, from the core

    /// Lay the core's fields for a pane over it (`CoreDecode.apply`) and tell
    /// the observers. A pane the app does not show is ignored. Main thread.
    func apply(terminalID: String, info: [String: Any], isCompletion: Bool, seq: UInt64) {
        lock.lock()
        guard let current = panes[terminalID] else { lock.unlock(); return }
        var next = current
        CoreDecode.apply(info, to: &next)
        panes[terminalID] = next
        lock.unlock()
        let change = PaneChange(info: next, oldStatus: current.status, newStatus: next.status,
                                isCompletion: isCompletion, seq: seq)
        delegate?.paneDidChange(next)
        onChange?(change)
    }

    // MARK: - Queries

    func pane(for terminalID: String) -> PaneInfo? {
        lock.lock(); defer { lock.unlock() }
        return panes[terminalID]
    }

    func allPanes() -> [PaneInfo] {
        lock.lock(); defer { lock.unlock() }
        return orderedIDs.compactMap { panes[$0] }
    }

    func terminalIDs(forWorktree path: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return worktreeIndex[path] ?? []
    }

    /// The worktree's first pane.
    func pane(forWorktree path: String) -> PaneInfo? {
        lock.lock(); defer { lock.unlock() }
        return worktreeIndex[path]?.first.flatMap { panes[$0] }
    }

    func panes(forWorktree path: String) -> [PaneInfo] {
        lock.lock(); defer { lock.unlock() }
        return (worktreeIndex[path] ?? []).compactMap { panes[$0] }
    }

    func panesForProject(_ project: String) -> [PaneInfo] {
        allPanes().filter { $0.project == project }
    }

    /// Whether any pane in the worktree has an agent mid-turn: one busy pane
    /// is enough to make its files unsafe to touch.
    func hasRunningPane(inWorktree path: String) -> Bool {
        panes(forWorktree: path).contains { $0.status == .running }
    }

    #if DEBUG
    /// Tests: a pane with no Station.
    func registerForTesting(terminalID: String, worktreePath: String, branch: String, project: String) {
        lock.lock(); defer { lock.unlock() }
        panes[terminalID] = PaneInfo(id: terminalID, worktreePath: worktreePath, agentType: .unknown,
                                     project: project, branch: branch, status: .unknown, lastMessage: "",
                                     commandLine: nil, roundDuration: 0, startedAt: nil, station: nil,
                                     channel: nil, taskProgress: TaskProgress())
        worktreeIndex[worktreePath, default: []].append(terminalID)
        if !orderedIDs.contains(terminalID) { orderedIDs.append(terminalID) }
    }

    /// Tests: set a pane's fields as the core would.
    func applyForTesting(terminalID: String, info: [String: Any], isCompletion: Bool = false) {
        apply(terminalID: terminalID, info: info, isCompletion: isCompletion, seq: 0)
    }
    #endif
}
