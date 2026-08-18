import Foundation

/// Bridges the control API to seahelm's live state: AgentRegistry for pane inventory
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
    /// Sleep/wake panes by station id (nil = all but the focused one), on the
    /// main thread. Each returns the ids actually affected.
    var sleepHandler: ((String?) -> [String])?
    var wakeHandler: ((String?) -> [String])?
    /// Owner-set window mirroring, run on the main thread: the live split trees
    /// and the dashboard's grouping for a given mode.
    var liveLayoutsHandler: (() -> [String: [String: Any]])?
    var worktreeGroupsHandler: ((String) -> [[String: Any]])?

    init(hookSink: @escaping (WebhookEvent) -> String? = { _ in nil }) {
        self.hookSink = hookSink
    }

    func ingestHook(json: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let event = try? WebhookEvent.parse(from: data) else { return nil }
        return hookSink(event)
    }

    func snapshotPanes() -> [PaneSnapshot] {
        snapshotPanes(includingMemory: false)
    }

    func snapshotPanes(includingMemory: Bool) -> [PaneSnapshot] {
        // Probe once for the whole list, not once per pane: `zmx list` and the
        // process-table walk are the expensive part, and every pane reads from
        // the same two snapshots.
        let memoryBySessionKey = includingMemory ? sessionMemoryBySessionKey() : [:]

        return AgentRegistry.shared.allPanes().map { s in
            let station = StationRegistry.shared.station(forId: s.id)
            let osc = station?.oscTitle ?? ""
            let title = osc.isEmpty ? (station?.persistedTitle ?? "") : osc
            let sessionKey = station?.paneSessionKey ?? ""
            let memory = memoryBySessionKey[sessionKey]
            return PaneSnapshot(
                paneId: s.id,
                worktreePath: s.worktreePath,
                branch: s.branch,
                project: s.project,
                agentType: s.agentType.rawValue,
                status: s.status.rawValue,
                lastMessage: s.lastMessage,
                paneSessionKey: sessionKey,
                title: title,
                memoryBytes: memory?.totalBytes,
                agentMemoryBytes: memory?.agentBytes,
                processName: memory?.processName
            )
        }
    }

    /// Resident memory per zmx session, keyed by session name (a pane's
    /// `paneSessionKey`). Empty when zmx isn't the backend or the probe fails —
    /// memory is best-effort detail and must never break `pane.list`.
    private func sessionMemoryBySessionKey() -> [String: ProcessProbe.SessionMemory] {
        guard let listOutput = ProcessRunner.output([ZmxLocator.executable(), "list"]) else {
            return [:]
        }
        let sessions = SessionManager.parseZmxSessions(listOutput: listOutput)
            .filter { $0.pid != nil }
        guard !sessions.isEmpty else { return [:] }
        let procs = ProcessProbe.allProcesses()
        guard !procs.isEmpty else { return [:] }
        let manifests = ManifestStore.shared.all.map(\.manifest)

        var result: [String: ProcessProbe.SessionMemory] = [:]
        for session in sessions {
            guard let pid = session.pid else { continue }
            result[session.name] = ProcessProbe.memory(
                rootPid: Int32(pid), in: procs, manifests: manifests
            )
        }
        return result
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
        // A pane whose tab was never opened has a Station but no surface, and
        // the writes below silently no-op. Reporting success for that is worse
        // than failing: callers believe an agent was told something it never
        // heard. Deliver through the persistent session instead.
        guard station.canDeliverInput else {
            guard let key = station.paneSessionKey, !key.isEmpty, !text.isEmpty else { return false }
            return ZmxChannel(paneSessionKey: key).sendPrompt(text)
        }
        runOnMain {
            if !text.isEmpty { station.sendText(text) }
            guard enter else { return }
            // Not in the same burst — see `Station.enterSubmitDelay`. Sending
            // both together leaves the text sitting unsent in the composer.
            if text.isEmpty {
                station.sendEnterKey()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + Station.enterSubmitDelay) {
                    station.sendEnterKey()
                }
            }
        }
        return true
    }

    /// Replays a key list in order. Enter is spaced off whatever preceded it for
    /// the same reason `sendText` is: `["up", "enter"]` submits the wrong thing
    /// if the TUI is still ingesting the arrow when the Return lands.
    func sendKeys(paneId: String, keys: [String]) -> Bool {
        guard let station = station(for: paneId) else { return false }
        // Same as `sendText`: with no surface the writes below do nothing, and
        // claiming otherwise tells the caller a key was pressed that wasn't.
        guard station.canDeliverInput else {
            guard let sessionKey = station.paneSessionKey, !sessionKey.isEmpty else { return false }
            let channel = ZmxChannel(paneSessionKey: sessionKey)
            var delivered = true
            for (index, key) in keys.enumerated() {
                if ControlKeys.isEnter(key) {
                    // The pause before a Return is what stops a TUI reading it
                    // as part of the paste it is still ingesting.
                    if index > 0 { Thread.sleep(forTimeInterval: Station.enterSubmitDelay) }
                    delivered = channel.submit() && delivered
                } else if let bytes = ControlKeys.bytes(for: key) {
                    delivered = channel.sendRaw(bytes) && delivered
                }
            }
            return delivered
        }
        runOnMain {
            var delay: TimeInterval = 0
            for (index, key) in keys.enumerated() {
                let isEnter = ControlKeys.isEnter(key)
                if isEnter, index > 0 { delay += Station.enterSubmitDelay }
                let send = {
                    if isEnter {
                        station.sendEnterKey()
                    } else if let bytes = ControlKeys.bytes(for: key) {
                        station.sendText(bytes)
                    }
                }
                if delay == 0 {
                    send()
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: send)
                }
            }
        }
        return true
    }

    func paneStatus(paneId: String) -> String? {
        guard let sid = station(for: paneId)?.id else { return nil }
        return AgentRegistry.shared.pane(for: sid)?.status.rawValue
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

    func sleepPane(paneId: String?) -> [String]? {
        dispatchPaneLifecycle(paneId: paneId, handler: sleepHandler)
    }

    func wakePane(paneId: String?) -> [String]? {
        dispatchPaneLifecycle(paneId: paneId, handler: wakeHandler)
    }

    /// Shared resolve-then-run for sleep/wake: a named pane must exist (nil ⇒
    /// "not found" for the caller), while nil means "all" and is passed through.
    private func dispatchPaneLifecycle(paneId: String?, handler: ((String?) -> [String])?) -> [String]? {
        guard let handler else { return nil }
        let sid = paneId.flatMap { station(for: $0)?.id }
        if paneId != nil && sid == nil { return nil }
        var affected: [String] = []
        runOnMain { affected = handler(sid) }
        return affected
    }

    func memoryStats() -> [String: Any]? {
        MemoryProbe.stats()
    }

    func explainPane(paneId: String) -> [String: Any]? {
        guard let station = station(for: paneId) else { return nil }
        let pane = AgentRegistry.shared.pane(for: station.id)
        let agentType = pane?.agentType ?? .unknown
        let manifest = ManifestStore.shared.manifest(for: agentType.manifestId)

        let content = station.readViewportText() ?? ""
        let osc = (title: station.oscTitle, progress: station.oscProgress)
        let input = DetectionInput(screen: content.lowercased(), oscTitle: osc.title, oscProgress: osc.progress)

        // Live screen detection (what the scan layer sees right now).
        let scan = StatusDetector().detectDetailed(
            processStatus: station.processStatus, shellInfo: nil, content: content,
            manifest: manifest, osc: osc)
        let hookStatus = pane?.hookStatus ?? .unknown
        let decided = AgentRegistry.arbitrateDetailed(scan: scan.state, hook: hookStatus, agentType: agentType)

        var result: [String: Any] = [
            "pane_id": station.id,
            "pane_session_key": station.paneSessionKey ?? "",
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

// MARK: - Window mirroring

extension SeahelmControlDataSource {
    func liveLayouts() -> [String: [String: Any]]? {
        guard let h = liveLayoutsHandler else { return nil }
        var out: [String: [String: Any]] = [:]
        runOnMain { out = h() }
        return out
    }

    func worktreeGroups(mode: String) -> [[String: Any]]? {
        guard let h = worktreeGroupsHandler else { return nil }
        var out: [[String: Any]] = []
        runOnMain { out = h(mode) }
        return out
    }
}
