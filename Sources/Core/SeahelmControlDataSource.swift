import Foundation

/// Bridges the control API to seahelm's live state: ShipLog for pane inventory
/// and StationRegistry for terminal reads.
final class SeahelmControlDataSource: ControlDataSource {

    /// The shared inbound-event sink (same closure the HTTP webhook uses).
    /// Returns an optional block-body string for blocking Stop hooks.
    private let hookSink: (WebhookEvent) -> String?

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
}
