import Foundation

/// What seahelm-core tells the app, one case per kind of fact
/// (docs/app-reads-core.md). Pane-bound cases carry the app's pane
/// (`Station.id`) when it shows that pane.
enum CoreEvent {
    /// A pane's state changed (or was replayed on connect).
    case pane(terminalID: String, info: [String: Any], isCompletion: Bool, seq: UInt64)
    /// A notice the core decided the user should get.
    case notice([String: Any], terminalID: String?)
    /// A pane's unseen completion was marked or cleared.
    case unseen(terminalID: String, unseen: Bool)
    /// The whole card queue.
    case cards([[String: Any]])
    /// A card a client raised was answered (`option` nil: dismissed).
    case cardAnswered(card: [String: Any], option: String?)
    /// Where a pane's agent is working now.
    case location(terminalID: String, worktree: String?, location: String, createdByAgent: Bool)
    /// A pane's agent has a resume reference (`AgentSessionRef`).
    case session(paneSessionKey: String, ref: [String: Any])
    /// An agent is working in a worktree nobody tracks yet.
    case worktreeDiscovered(path: String, paneSessionKey: String?)
    /// Every event, as the core sent it, for the app's own subscribers
    /// (`EventHub`, until the gateway takes them from the core itself).
    case raw([String: Any])
    case connected(Bool)
}

/// The app's one connection to seahelm-core: calls (`CoreSocketClient`) and
/// one event stream, followed on a thread of its own. On every (re)connect it
/// subscribes first and then replays the core's panes, cards and session
/// references, so nothing that changed while it was away is missed.
/// Observers run on the main thread.
final class CoreClient {
    static let shared = CoreClient()

    private(set) var connected = false
    /// Resume references, by seahelmd session name (`agent.sessions`, then
    /// `agent.session`). Main thread.
    private(set) var sessions: [String: [String: Any]] = [:]

    private var observers: [(CoreEvent) -> Void] = []
    private var thread: Thread?

    private static let types = [
        "pane.status_changed", "pane.updated", "pane.notice", "pane.unseen_changed", "pane.location",
        "pane.closed", "pane.rehomed", "cards.changed", "card.answered", "agent.session", "worktree.discovered",
    ]

    /// Add an observer. Main thread.
    func observe(_ block: @escaping (CoreEvent) -> Void) {
        observers.append(block)
    }

    func start() {
        guard thread == nil else { return }
        let t = Thread { [weak self] in self?.run() }
        t.name = "seahelm-core-client"
        t.qualityOfService = .userInitiated
        thread = t
        t.start()
    }

    /// The app's pane for one of the core's: by session name, else by the
    /// alias (a `Station.id`).
    static func terminalID(session: String, alias: String) -> String? {
        if !session.isEmpty, let station = StationRegistry.shared.station(forSessionName: session) {
            return station.id
        }
        return Fleet.shared.pane(for: alias) != nil ? alias : nil
    }

    // MARK: - The stream

    private func run() {
        var pause: TimeInterval = 1
        while true {
            if let fd = CoreSocketClient.open(timeout: 60) {
                follow(fd)
                close(fd)
                pause = 1
            }
            emitConnected(false)
            Thread.sleep(forTimeInterval: pause)
            pause = min(pause * 2, 10)
        }
    }

    /// One connection: subscribe, replay, then every event until it drops.
    /// The core pings every 15 s, so a minute of silence is a dead core.
    private func follow(_ fd: Int32) {
        let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "events.subscribe",
                                      "params": ["types": Self.types]]
        guard var data = try? JSONSerialization.data(withJSONObject: request) else { return }
        data.append(0x0A)
        guard data.withUnsafeBytes({ write(fd, $0.baseAddress, $0.count) }) == data.count else { return }
        emitConnected(true)
        replay()
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(fd, &buffer, buffer.count)
            guard n > 0 else { return }
            pending.append(contentsOf: buffer[0..<n])
            while let nl = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<nl]
                pending.removeSubrange(pending.startIndex...nl)
                guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      obj["method"] as? String == "event",
                      let ev = obj["params"] as? [String: Any] else { continue }
                DispatchQueue.main.async { [weak self] in self?.dispatch(ev) }
            }
        }
    }

    private func replay() {
        let sessions = CoreSocketClient.call("agent.sessions")
        let panes = CoreSocketClient.call("pane.list", ["detail": true])
        let cards = CoreSocketClient.call("cards.list")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if case .success(let r) = sessions {
                self.sessions = r["agent_sessions"] as? [String: [String: Any]] ?? [:]
            }
            if case .success(let r) = panes {
                for row in r["panes"] as? [[String: Any]] ?? [] {
                    guard let info = row["info"] as? [String: Any],
                          let id = Self.terminalID(session: row["pane_session_key"] as? String ?? "",
                                                   alias: row["pane_id"] as? String ?? "") else { continue }
                    self.emit(.pane(terminalID: id, info: info, isCompletion: false, seq: 0))
                }
            }
            if case .success(let r) = cards {
                self.emit(.cards(r["cards"] as? [[String: Any]] ?? []))
            }
        }
    }

    /// One event from the core, typed. Main thread.
    private func dispatch(_ ev: [String: Any]) {
        emit(.raw(ev))
        let key = ev["pane_session_key"] as? String ?? ""
        let id = Self.terminalID(session: key, alias: ev["pane_id"] as? String ?? "")
        switch ev["type"] as? String {
        case "pane.status_changed", "pane.updated":
            guard let id, let info = ev["info"] as? [String: Any] else { return }
            emit(.pane(terminalID: id, info: info, isCompletion: ev["is_completion"] as? Bool ?? false,
                       seq: (ev["seq"] as? NSNumber)?.uint64Value ?? 0))
        case "pane.notice":
            emit(.notice(ev, terminalID: id))
        case "pane.unseen_changed":
            guard let id else { return }
            emit(.unseen(terminalID: id, unseen: ev["unseen"] as? Bool ?? false))
        case "pane.location":
            guard let id else { return }
            emit(.location(terminalID: id, worktree: ev["worktree"] as? String,
                           location: ev["location"] as? String ?? "",
                           createdByAgent: ev["created_by_agent"] as? Bool ?? false))
        case "cards.changed":
            emit(.cards(ev["cards"] as? [[String: Any]] ?? []))
        case "card.answered":
            emit(.cardAnswered(card: ev["card"] as? [String: Any] ?? [:], option: ev["option"] as? String))
        case "agent.session":
            guard let ref = ev["ref"] as? [String: Any], !key.isEmpty else { return }
            sessions[key] = ref
            emit(.session(paneSessionKey: key, ref: ref))
        case "worktree.discovered":
            guard let path = ev["worktree_path"] as? String else { return }
            emit(.worktreeDiscovered(path: path, paneSessionKey: ev["pane_session_key"] as? String))
        default:
            break
        }
    }

    private func emit(_ event: CoreEvent) {
        if case .pane(let id, let info, let completion, let seq) = event {
            Fleet.shared.apply(terminalID: id, info: info, isCompletion: completion, seq: seq)
        }
        for o in observers { o(event) }
    }

    private func emitConnected(_ up: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.connected != up else { return }
            self.connected = up
            NSLog("[CoreClient] core \(up ? "connected" : "unavailable")")
            self.emit(.connected(up))
        }
    }
}
