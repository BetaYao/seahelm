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
    /// Owner-set layout export/apply, run on the main thread.
    var exportLayoutHandler: (() -> [String: Any]?)?
    var applyLayoutHandler: ((LayoutNode) -> Bool)?
    /// (targetStationId, mode) → zoomed-after, or nil if the pane isn't found.
    var zoomHandler: ((String?, String) -> Bool?)?
    /// Close a pane by station id (main thread). Returns whether it was closed.
    var closeHandler: ((String) -> Bool)?
    /// Focus a pane by station id (main thread). Returns whether it was focused.
    var focusHandler: ((String) -> Bool)?

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
            let station = StationRegistry.shared.station(forId: s.id)
            let osc = station?.oscTitle ?? ""
            let title = osc.isEmpty ? (station?.persistedTitle ?? "") : osc
            return PaneSnapshot(
                paneId: s.id,
                worktreePath: s.worktreePath,
                branch: s.branch,
                project: s.project,
                agentType: s.agentType.rawValue,
                status: s.status.rawValue,
                lastMessage: s.lastMessage,
                sessionName: station?.sessionName ?? "",
                title: title
            )
        }
    }

    func readPane(paneId: String, source: String, lines: Int) -> String? {
        guard let station = station(for: paneId) else { return nil }
        // Ghostty reads must go through the surface; readViewportText already
        // takes the ghosttyLock internally.
        guard let text = station.readViewportText() else { return "" }
        guard lines > 0 else { return text }
        let all = text.components(separatedBy: "\n")
        return all.count <= lines ? text : all.suffix(lines).joined(separator: "\n")
    }

    func sendText(paneId: String, text: String, enter: Bool) -> Bool {
        guard let station = station(for: paneId) else { return false }
        runOnMain {
            if !text.isEmpty { station.sendText(text) }
            if enter { station.sendEnterKey() }
        }
        return true
    }

    func sendKeys(paneId: String, keys: [String]) -> Bool {
        guard let station = station(for: paneId) else { return false }
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
        guard let sid = station(for: paneId)?.id else { return nil }
        return ShipLog.shared.sailor(for: sid)?.status.rawValue
    }

    func paneOptions(paneId: String) -> [[String: Any]]? {
        guard let station = station(for: paneId) else { return nil }
        let text = station.readViewportText() ?? ""
        return ChoiceOptionParser.parse(text).map {
            ["index": $0.index, "label": $0.label, "selected": $0.selected]
        }
    }

    func splitPane(paneId: String?, direction: String, focus: Bool) -> String? {
        guard let splitHandler else { return nil }
        // right/left place panes side by side; down/up stack them.
        let axis: SplitAxis = (direction == "down" || direction == "up") ? .vertical : .horizontal
        // Resolve session-name references to the canonical station id the split
        // machinery keys on; nil = split the focused pane.
        let targetStationId = paneId.flatMap { station(for: $0)?.id }
        if paneId != nil && targetStationId == nil { return nil }
        var newId: String?
        runOnMain { newId = splitHandler(targetStationId, axis, focus) }
        return newId
    }

    func closePane(paneId: String) -> Bool {
        guard let sid = station(for: paneId)?.id, let closeHandler else { return false }
        var ok = false
        runOnMain { ok = closeHandler(sid) }
        return ok
    }

    func focusPane(paneId: String) -> Bool {
        guard let sid = station(for: paneId)?.id, let focusHandler else { return false }
        var ok = false
        runOnMain { ok = focusHandler(sid) }
        return ok
    }

    func explainPane(paneId: String) -> [String: Any]? {
        guard let station = station(for: paneId) else { return nil }
        let sailor = ShipLog.shared.sailor(for: station.id)
        let agentType = sailor?.agentType ?? .unknown
        let manifest = ManifestStore.shared.manifest(for: agentType.manifestId)

        let content = station.readViewportText() ?? ""
        let osc = (title: station.oscTitle, progress: station.oscProgress)
        let input = DetectionInput(screen: content.lowercased(), oscTitle: osc.title, oscProgress: osc.progress)

        // Live screen detection (what the scan layer sees right now).
        let scan = StatusDetector().detectDetailed(
            processStatus: station.processStatus, shellInfo: nil, content: content,
            manifest: manifest, osc: osc)
        let hookStatus = sailor?.hookStatus ?? .unknown
        let decided = ShipLog.arbitrateDetailed(scan: scan.state, hook: hookStatus, agentType: agentType)

        var result: [String: Any] = [
            "pane_id": station.id,
            "session_name": station.sessionName ?? "",
            "agent": agentType.rawValue,
            "manifest": manifest?.manifest.id ?? "",
            "manifest_version": manifest?.manifest.version ?? "",
            "authority": decided.authority,
            "status": decided.status.rawValue,
            "decided_by": decided.decidedBy,
            "scan_status": scan.state.rawValue,
            "hook_status": hookStatus.rawValue,
            "process_status": "\(station.processStatus)",
            "osc_title": osc.title,
            "osc_progress": osc.progress,
        ]
        if let match = manifest?.matchDetail(input) {
            result["matched_rule"] = [
                "id": match.rule.id,
                "state": match.rule.state,
                "priority": match.rule.priority,
                "region": match.rule.region,
                "evidence": String(match.regionText.suffix(160)),
            ]
        } else {
            result["matched_rule"] = NSNull()
            result["default_status"] = manifest?.defaultStatus.rawValue ?? ""
        }
        return result
    }

    func zoomPane(paneId: String?, mode: String) -> [String: Any]? {
        guard let h = zoomHandler else { return nil }
        let sid = paneId.flatMap { station(for: $0)?.id }
        if paneId != nil && sid == nil { return nil }  // named but not found
        var zoomed: Bool?
        runOnMain { zoomed = h(sid, mode) }
        guard let z = zoomed else { return nil }
        return ["zoomed": z]
    }

    func exportLayout() -> [String: Any]? {
        guard let h = exportLayoutHandler else { return nil }
        var r: [String: Any]?
        runOnMain { r = h() }
        return r
    }

    func applyLayout(root: [String: Any]) -> Bool {
        guard let node = LayoutNode(dict: root), let h = applyLayoutHandler else { return false }
        var ok = false
        runOnMain { ok = h(node) }
        return ok
    }

    /// Resolve a pane reference that may be a per-instance station id OR the
    /// stable zmx session name agents receive as SEAHELM_PANE_ID.
    private func station(for paneId: String) -> Station? {
        StationRegistry.shared.station(forId: paneId)
            ?? StationRegistry.shared.station(forSessionName: paneId)
    }

    /// Ghostty input must run on the main thread; the control socket serves each
    /// request on its own background thread.
    private func runOnMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.sync(execute: block) }
    }
}
