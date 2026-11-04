import Foundation

/// What every pane is doing, as seahelm-core decided it (docs/app-reads-core.md,
/// step 2). The app no longer decides status: this follows the core's
/// `events.subscribe` on a thread of its own and writes each outcome into
/// `AgentRegistry` (`applyDecided`), whose consumers carry on as before.
///
/// On every (re)connect it subscribes first, then lays the core's whole
/// `pane.list {detail: true}` over the registry, so nothing that changed
/// while it was away is missed. A pane is found by its seahelmd session name
/// (`pane_session_key`): the core's alias for it can be a previous run's
/// `Station.id`.
final class CoreStatusFeed {
    static let shared = CoreStatusFeed()

    /// Whether the event stream is up. Main thread.
    private(set) var connected = false
    var onConnectionChange: ((Bool) -> Void)?
    /// A notice the core decided to give (`pane.notice`), with the app's pane
    /// for it when it has one. Main thread.
    var onNotice: (([String: Any], String?) -> Void)?
    /// The core marked or cleared a pane's unseen completion. Main thread.
    var onUnseen: ((Bool, String) -> Void)?

    private var thread: Thread?
    private static let types = ["pane.status_changed", "pane.updated", "pane.notice", "pane.unseen_changed"]

    func start() {
        guard thread == nil else { return }
        let t = Thread { [weak self] in self?.run() }
        t.name = "seahelm-core-feed"
        t.qualityOfService = .userInitiated
        thread = t
        t.start()
    }

    private func run() {
        var pause: TimeInterval = 1
        while true {
            if let fd = CoreSocketClient.open(timeout: 60) {
                follow(fd)
                close(fd)
                pause = 1
            }
            setConnected(false)
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
        setConnected(true)
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
                deliver(ev)
            }
        }
    }

    /// The core's view of every pane, laid over the registry.
    private func replay() {
        guard case .success(let list) = CoreSocketClient.call("pane.list", ["detail": true]) else { return }
        for row in list["panes"] as? [[String: Any]] ?? [] {
            guard let info = row["info"] as? [String: Any] else { continue }
            let key = row["pane_session_key"] as? String ?? ""
            let alias = row["pane_id"] as? String ?? ""
            DispatchQueue.main.async {
                guard let id = Self.terminalID(session: key, alias: alias) else { return }
                AgentRegistry.shared.applyDecided(terminalID: id, info: info, event: nil,
                                                  statusChanged: false, isCompletion: false)
            }
        }
    }

    private func deliver(_ ev: [String: Any]) {
        let key = ev["pane_session_key"] as? String ?? ""
        let alias = ev["pane_id"] as? String ?? ""
        switch ev["type"] as? String {
        case "pane.notice":
            DispatchQueue.main.async { [weak self] in
                self?.onNotice?(ev, Self.terminalID(session: key, alias: alias))
            }
            return
        case "pane.unseen_changed":
            let unseen = ev["unseen"] as? Bool ?? false
            DispatchQueue.main.async { [weak self] in
                guard let id = Self.terminalID(session: key, alias: alias) else { return }
                self?.onUnseen?(unseen, id)
            }
            return
        default:
            break
        }
        guard let info = ev["info"] as? [String: Any] else { return }
        let changed = ev["type"] as? String == "pane.status_changed"
        let completion = ev["is_completion"] as? Bool ?? false
        let raw = ev["event"] as? [String: Any]
        DispatchQueue.main.async {
            guard let id = Self.terminalID(session: key, alias: alias) else { return }
            let event = raw.flatMap { raw in
                CoreDecode.kind(raw["kind"]).map {
                    NormalizedEvent(terminalID: id, source: CoreDecode.source(raw["source"]), kind: $0)
                }
            }
            AgentRegistry.shared.applyDecided(terminalID: id, info: info, event: event,
                                              statusChanged: changed, isCompletion: completion)
        }
    }

    /// The app's pane for a core pane: by session name, else by the alias.
    static func terminalID(session: String, alias: String) -> String? {
        if !session.isEmpty, let station = StationRegistry.shared.station(forSessionName: session) {
            return station.id
        }
        return AgentRegistry.shared.pane(for: alias) != nil ? alias : nil
    }

    private func setConnected(_ up: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.connected != up else { return }
            self.connected = up
            NSLog("[CoreStatusFeed] core \(up ? "connected" : "unavailable")")
            self.onConnectionChange?(up)
        }
    }
}
