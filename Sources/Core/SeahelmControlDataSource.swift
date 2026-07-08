import Foundation

/// Bridges the control API to seahelm's live state: ShipLog for pane inventory
/// and StationRegistry for terminal reads.
final class SeahelmControlDataSource: ControlDataSource {

    /// The shared inbound-event sink (same closure the HTTP webhook uses).
    /// Returns an optional block-body string for blocking Stop hooks.
    private let hookSink: (WebhookEvent) -> String?

    /// Set by the owner (TabCoordinator) to perform a split on the main thread.
    /// (targetStationId, axis, focus) → new station id, or nil if unsplittable.
    var splitHandler: ((String?, SplitAxis, Bool) -> String?)?

    init(hookSink: @escaping (WebhookEvent) -> String? = { _ in nil }) {
        self.hookSink = hookSink
    }

    func ingestHook(json: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let event = try? WebhookEvent.parse(from: data) else { return nil }
        return hookSink(event)
    }

    func snapshotPanes() -> [PaneSnapshot] {
        ShipLog.shared.allSailors().map { s in
            PaneSnapshot(
                paneId: s.id,
                worktreePath: s.worktreePath,
                branch: s.branch,
                project: s.project,
                agentType: s.agentType.rawValue,
                status: s.status.rawValue,
                lastMessage: s.lastMessage
            )
        }
    }

    func readPane(paneId: String, source: String, lines: Int) -> String? {
        guard let station = StationRegistry.shared.station(forId: paneId) else { return nil }
        // Ghostty reads must go through the surface; readViewportText already
        // takes the ghosttyLock internally.
        guard let text = station.readViewportText() else { return "" }
        guard lines > 0 else { return text }
        let all = text.components(separatedBy: "\n")
        return all.count <= lines ? text : all.suffix(lines).joined(separator: "\n")
    }

    func sendText(paneId: String, text: String, enter: Bool) -> Bool {
        guard let station = StationRegistry.shared.station(forId: paneId) else { return false }
        runOnMain {
            if !text.isEmpty { station.sendText(text) }
            if enter { station.sendEnterKey() }
        }
        return true
    }

    func sendKeys(paneId: String, keys: [String]) -> Bool {
        guard let station = StationRegistry.shared.station(forId: paneId) else { return false }
        runOnMain {
            for key in keys {
                if ControlKeys.isEnter(key) {
                    station.sendEnterKey()
                } else if let bytes = ControlKeys.bytes(for: key) {
                    station.sendText(bytes)
                }
            }
        }
        return true
    }

    func paneStatus(paneId: String) -> String? {
        ShipLog.shared.sailor(for: paneId)?.status.rawValue
    }

    func splitPane(paneId: String?, direction: String, focus: Bool) -> String? {
        guard let splitHandler else { return nil }
        // right/left place panes side by side; down/up stack them.
        let axis: SplitAxis = (direction == "down" || direction == "up") ? .vertical : .horizontal
        var newId: String?
        runOnMain { newId = splitHandler(paneId, axis, focus) }
        return newId
    }

    /// Ghostty input must run on the main thread; the control socket serves each
    /// request on its own background thread.
    private func runOnMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.sync(execute: block) }
    }
}
