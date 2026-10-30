import Foundation

/// Bridges the control API to seahelm's live state: AgentRegistry for pane inventory
/// and StationRegistry for terminal reads.
final class SeahelmControlDataSource: ControlDataSource {

    /// The shared inbound-event sink (same closure the HTTP webhook used).
    private let hookSink: (WebhookEvent) -> Void

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
    /// (stationId, worktreePath) -> moved. Re-files a live pane under another
    /// worktree without recreating it.
    var moveHandler: ((String, String) -> Bool)?
    /// (stationId, worktreePath or nil, done) — fork a pane's session into another
    /// worktree; `done` gets the new pane's station id. Called on main.
    var forkHandler: ((String, String?, @escaping (Result<String, PaneForkError>) -> Void) -> Void)?
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
    /// Owner-set, main thread: the projects a worktree can start in.
    var repoPathsHandler: (() -> [String])?
    /// Owner-set, main thread: start a worktree (repo, agent, prompt) and call
    /// back with its path, or nil when it could not be created.
    var createWorktreeHandler: ((String, AgentType, String, @escaping (String?) -> Void) -> Void)?
    /// Decline a pane's pending suggestion (main thread — it is UI state).
    var dismissDecisionHandler: ((String) -> Bool)?

    init(hookSink: @escaping (WebhookEvent) -> Void = { _ in }) {
        self.hookSink = hookSink
    }

    func ingestHook(json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let event = try? WebhookEvent.parse(from: data) else { return }
        hookSink(event)
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
            // The header's own fast path (MainWindowController.handlePaneDidAcquireFocus),
            // not PaneTitleResolver.title: that one reads transcripts and writes
            // back to the station, and this runs off the main thread.
            let persisted = station?.persistedTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let displayTitle = PaneTitleResolver.singleLine(
                PaneTitleResolver.displayOscTitle(osc, worktreePath: s.worktreePath,
                                                  pwd: station?.pwd ?? "") ?? persisted)
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
                displayTitle: displayTitle,
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
            return Station.pressKeys(keys, viaSession: sessionKey)
        }
        runOnMain { station.pressKeysOnSurface(keys) }
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

    func movePane(paneId: String, worktreePath: String) -> Bool {
        guard let sid = station(for: paneId)?.id, let moveHandler else { return false }
        var ok = false
        runOnMain { ok = moveHandler(sid, worktreePath) }
        return ok
    }

    func forkPane(paneId: String, worktreePath: String?) -> Result<[String: Any], PaneForkError> {
        // Waits for the fork's zmx session to come up, so a caller on main would wait on itself.
        guard !Thread.isMainThread, let fork = forkHandler,
              let sid = station(for: paneId)?.id else { return .failure(.unknownPane) }
        let done = DispatchSemaphore(value: 0)
        var outcome: Result<String, PaneForkError> = .failure(.launchFailed)
        DispatchQueue.main.async {
            fork(sid, worktreePath) { outcome = $0; done.signal() }
        }
        guard done.wait(timeout: .now() + 30) == .success else { return .failure(.launchFailed) }
        return outcome.map { newId in
            var result: [String: Any] = ["forked": true, "pane_id": newId]
            if let key = StationRegistry.shared.station(forId: newId)?.paneSessionKey {
                result["pane_session_key"] = key
            }
            return result
        }
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

    /// The integration checkouts, live. Reads the stores rather than the app's
    /// UI state, so it answers the same from any thread the socket serves.
    func integrationStatus(path: String?) -> [String: Any]? {
        let all = IntegrationWorktreeStore.shared.checkoutsByRepo
        var wanted = all
        if let path, !path.isEmpty {
            // An unknown repo answers with an empty list rather than with every
            // other repo's state: "this one has no checkout" is the true answer,
            // and a fleet-wide dump would read as if it did.
            let repo = WorktreeDiscovery.findRepoRoot(from: path).map(WorktreeDiscovery.canonicalPath)
            wanted = all.filter { $0.key == repo }
        }

        let checkouts: [[String: Any]] = wanted.keys.sorted().compactMap { repo in
            guard let checkout = wanted[repo] else { return nil }
            var entry: [String: Any] = ["repo": repo, "checkout": checkout]
            entry["exists"] = FileManager.default.fileExists(atPath: checkout)
            let head = GitProcess.run(
                ["rev-parse", "--verify", "--quiet", "HEAD"],
                in: checkout,
                timeout: IntegrationWorktree.timeout
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let head, !head.isEmpty { entry["head"] = head }
            let published = IntegrationWorktreeStore.shared.lastPublishedCommit(forCheckout: checkout)
            if let published {
                entry["last_published"] = published
                // The state the desktop card calls "commits made here": worth
                // its own field, because it is the one an agent should react to.
                entry["moved_by_hand"] = (head != nil && head != published)
            }
            if let state = IntegrationStatusStore.shared.state(forWorktree: checkout) {
                entry["line"] = state.line
                entry["included"] = state.included
                entry["excluded"] = state.excluded.map { item -> [String: Any] in
                    var row: [String: Any] = ["label": item.label, "paths": item.paths]
                    if let against = item.against { row["against"] = against }
                    return row
                }
                entry["conflicted_paths"] = state.conflictedPaths
                entry["held"] = state.isHeld
                if let paths = state.heldPaths { entry["held_paths"] = paths }
                if let heldHead = state.heldHead { entry["held_head"] = heldHead }
            }
            return entry
        }
        return ["checkouts": checkouts]
    }

    func messageSnapshot(paneId: String?) -> [[String: Any]] {
        MessageStreamHub.shared.snapshot(paneId: paneId).map(\.dict)
    }

    func messageHistory(paneId: String, beforeSeq: UInt64, limit: Int) -> [String: Any] {
        let page = MessageStreamHub.shared.history(paneId: paneId, beforeSeq: beforeSeq, limit: limit)
        return ["messages": page.events.map(\.dict), "has_more": page.hasMore]
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
        let hookIdleFresh = AgentRegistry.shared.hookIdleIsFresh(terminalID: station.id)
        let programStatus = station.programStatus
        let decided = AgentRegistry.arbitrateDetailed(scan: scan.state, hook: hookStatus,
                                                      agentType: agentType, hookIdleFresh: hookIdleFresh,
                                                      program: programStatus.liveRoot?.agentStatus ?? .unknown)

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
            // True when no rule matched and `scan_status` is just the manifest's
            // default — the screen is saying nothing, not saying "idle".
            "scan_defaulted": scan.isDefaulted,
            // Background work (a shell / monitor this session started). A separate
            // axis from status: the agent can be idle at a prompt while it is true.
            "background_busy": scan.backgroundBusy,
            "hook_status": hookStatus.rawValue,
            // True while a Stop is still inside its trailing-edge window, where a
            // hook `.idle` outranks a screen that has not gone quiet yet.
            "hook_idle_fresh": hookIdleFresh,
            "process_status": "\(station.processStatus)",
            "osc_title": osc.title,
            "osc_progress": osc.progress,
            // OSC 7501 records, root first. `program_status_live` is false once the
            // program has handed the terminal back to the shell: its done/error
            // records are kept but no longer decide the status.
            "program_status_live": programStatus.liveRoot != nil,
            "program_status": programStatus.records
                .sorted { ($0.key.isEmpty ? "" : "/" + $0.key) < ($1.key.isEmpty ? "" : "/" + $1.key) }
                .map { id, r -> [String: Any] in
                    var d: [String: Any] = ["id": id, "state": "\(r.state)", "app": r.app]
                    if let kind = r.report.kind { d["kind"] = "\(kind)" }
                    if let progress = r.report.progress { d["progress"] = progress }
                    if !r.report.title.isEmpty { d["title"] = r.report.title }
                    if !r.report.msg.isEmpty { d["msg"] = r.report.msg }
                    return d
                },
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
    /// Offer the command to the pane's shell and wait for it (`ShellRunIntegration`):
    /// check the shell is at its prompt, spool the command, press the widget's
    /// key, see whether the shell took it or found a draft, then wait for the
    /// prompt to come back. Everything goes through the session and the spool,
    /// so a pane that is not on screen works the same.
    func execInPane(paneId: String, command: String, timeout: TimeInterval) -> Result<[String: Any], PaneExecError> {
        guard !Thread.isMainThread else { return .failure(.unavailable) }
        guard let station = station(for: paneId) else { return .failure(.unknownPane) }
        guard station.backend == "zmx", let session = station.paneSessionKey, !session.isEmpty else {
            return .failure(.noSession)
        }
        let fm = FileManager.default
        func spool(_ kind: ShellRunIntegration.Spool) -> URL {
            ShellRunIntegration.spoolFile(kind, session: session)
        }
        func read(_ kind: ShellRunIntegration.Spool) -> String? {
            try? String(contentsOf: spool(kind), encoding: .utf8)
        }
        guard fm.fileExists(atPath: spool(.ready).path) else { return .failure(.noIntegration) }
        guard read(.prompt).flatMap(ShellRunIntegration.parsePrompt) != nil else { return .failure(.notAtPrompt) }
        guard Self.execBusy.claim(session) else { return .failure(.busy) }
        defer { Self.execBusy.release(session) }
        func abandon(_ error: PaneExecError) -> Result<[String: Any], PaneExecError> {
            for kind in [ShellRunIntegration.Spool.command, .claimed, .refused] { try? fm.removeItem(at: spool(kind)) }
            return .failure(error)
        }

        try? fm.removeItem(at: spool(.claimed))
        try? fm.removeItem(at: spool(.refused))
        guard fm.createFile(atPath: spool(.command).path, contents: Data(command.utf8),
                            attributes: [.posixPermissions: 0o600]),
              ZmxChannel(paneSessionKey: session).sendRaw(ShellRunIntegration.triggerSequence) else {
            return abandon(.notTaken)
        }

        // The widget answers within a keystroke; allow for a slow zle.
        var claim: (sequence: Int, promptLines: Int)?
        let answerBy = Date().addingTimeInterval(3)
        while Date() < answerBy {
            if let parsed = read(.claimed).flatMap(ShellRunIntegration.parseClaim) {
                claim = parsed
                try? fm.removeItem(at: spool(.claimed))
                break
            }
            if fm.fileExists(atPath: spool(.refused).path) { return abandon(.unsentInput) }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard let claim else { return abandon(.notTaken) }

        // Done when the prompt comes back past the one the command was taken at.
        let started = Date()
        var status: Int?
        while Date().timeIntervalSince(started) < timeout {
            if let prompt = read(.prompt).flatMap(ShellRunIntegration.parsePrompt), prompt.sequence > claim.sequence {
                status = prompt.status
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard let status else { return .failure(.timedOut(seconds: Int(timeout.rounded()))) }
        let elapsed = Date().timeIntervalSince(started)

        let history = ZmxChannel(paneSessionKey: session).readOutput(lines: Self.execHistoryLines) ?? ""
        let output = PaneExecOutput.extract(history: history, command: command, promptLines: claim.promptLines)
        return .success([
            "pane_id": station.id,
            "exit_code": status,
            "duration_ms": Int(elapsed * 1000),
            "output": output.text,
            "truncated": output.truncated,
        ])
    }

    /// Sessions with an exec in flight: one at a time per shell.
    private static let execBusy = ExecBusySet()

    private final class ExecBusySet {
        private let lock = NSLock()
        private var sessions: Set<String> = []
        func claim(_ session: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return sessions.insert(session).inserted
        }
        func release(_ session: String) {
            lock.lock(); sessions.remove(session); lock.unlock()
        }
    }

    /// Enough scrollback for a test run's output; past this `truncated` says so.
    private static let execHistoryLines = 2000

    func notePresence(callerPaneId: String, targetPaneId: String, note: String?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let caller = self.station(for: callerPaneId),
                  let target = self.station(for: targetPaneId) else { return }
            PanePresence.shared.note(target: target.id, entry: PresenceEntry(
                originStationId: caller.id, actor: Self.presenceActor(caller),
                note: PresenceLedger.cleanNote(note)))
        }
    }

    /// "Claude Code #7": the agent in the calling pane and the pane's handle —
    /// the same `#n` chat commands take. A pane with no agent is just its handle.
    static func presenceActor(_ station: Station) -> String {
        let key = PaneHandleRegistry.key(sessionKey: station.paneSessionKey ?? "", paneId: station.id)
        let handle = "#\(PaneHandleRegistry.shared.handle(for: key))"
        guard let agent = AgentRegistry.shared.pane(for: station.id)?.agentType, agent.isAIAgent else {
            return "Pane \(handle)"
        }
        return "\(agent.displayName) \(handle)"
    }

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

extension SeahelmControlDataSource {
    func worktreeCreateOptions() -> [String: Any]? {
        guard let h = repoPathsHandler, createWorktreeHandler != nil else { return nil }
        var paths: [String] = []
        runOnMain { paths = h() }
        let repos = paths.map { ["name": URL(fileURLWithPath: $0).lastPathComponent, "path": $0] }
            .sorted { ($0["name"] ?? "").localizedCaseInsensitiveCompare($1["name"] ?? "") == .orderedAscending }
        // Installed ones only: offering an agent the Mac cannot run would make
        // a worktree whose pane just says "command not found".
        let installed = OnboardingAgentDetector.scan().filter(\.detected).map(\.type)
        let agents = WorktreeAgentTypeStore.lastChosenFirst(installed,
                                                            lastChosen: WorktreeAgentTypeStore.shared.lastChosen)
            .map { ["id": $0.rawValue, "label": $0.displayName] }
        return ["repos": repos, "agents": agents]
    }

    func createWorktree(repoPath: String, agentType: AgentType, prompt: String)
        -> Result<[String: Any], ControlCreateError> {
        // Blocks until git is done, so a caller on main would wait on itself.
        guard !Thread.isMainThread, let create = createWorktreeHandler,
              let repos = repoPathsHandler else { return .failure(.unavailable) }
        var known: [String] = []
        runOnMain { known = repos() }
        guard known.contains(repoPath) else { return .failure(.unknownRepo) }
        let done = DispatchSemaphore(value: 0)
        var created: String?
        DispatchQueue.main.async {
            create(repoPath, agentType, prompt) { path in created = path; done.signal() }
        }
        // `git worktree add` in a large repo takes seconds, not minutes.
        guard done.wait(timeout: .now() + 90) == .success else { return .failure(.timedOut) }
        guard let path = created else { return .failure(.failed("couldn't create the worktree")) }
        return .success([
            "worktree_path": path,
            "pane_session_key": SessionManager.persistentSessionName(for: path),
        ])
    }

    func dismissDecision(paneId: String) -> Bool {
        guard let h = dismissDecisionHandler else { return false }
        var ok = false
        runOnMain { ok = h(paneId) }
        return ok
    }
}
