import Foundation

/// Periodically polls terminal surfaces and detects agent status changes.
/// Uses text pattern matching against visible terminal content.
/// Polling runs on a background queue to avoid blocking the main thread.
class StatusPublisher {

    private let detector = StatusDetector()
    private var trackers: [String: DebouncedStatusTracker] = [:]  // keyed by terminal ID
    private var timer: Timer?
    private var surfaces: [String: Station] = [:]         // keyed by terminal ID
    /// Reverse mapping: terminal ID → worktree path (for delegate callbacks and webhook provider)
    private var worktreePaths: [String: String] = [:]
    private var agentConfig: SailorDetectConfig
    private var lastMessages: [String: String] = [:]              // keyed by terminal ID
    private var runningStartTimes: [String: Date] = [:]           // keyed by terminal ID
    private(set) var webhookProvider = WebhookStatusProvider()
    var aggregator: CabinStatusAggregator?
    private let lock = NSLock()

    private let pollInterval: TimeInterval = 2.0
    private let pollQueue = DispatchQueue(label: "com.seahelm.status-poll", qos: .utility)
    private let nonPreferredPollStride: Int = 3
    /// Backend-capture (zmx history) cadence for surface-less panes, in poll
    /// cycles. Each such capture forks a subprocess, so we sample every Nth cycle
    /// (~6s at a 2s interval) rather than every cycle, and stagger panes by an
    /// id-derived offset so they don't all fork on the same tick.
    private let backendCaptureStride: Int = 3
    private var preferredPaths: Set<String> = []
    private var pollCycle: Int = 0

    // Cache: skip detection when viewport text hasn't changed
    private var lastViewportHashes: [String: UInt64] = [:]           // keyed by terminal ID

    /// Process-tree probe cache (keyed by terminal ID) + the poll cycle it was
    /// last refreshed on. Re-probed every `probeRefreshStride` cycles since the
    /// sysctl walk is comparatively expensive. Command line is refreshed on the
    /// same walk so shell pane titles stay in sync with the foreground job.
    private var probedTypes: [String: SailorType] = [:]
    private var probedCommandLines: [String: String] = [:]
    private var probedAtCycle: [String: Int] = [:]
    private let probeRefreshStride = 5
    // Pre-lowercased agent names for faster matching
    private var lowercasedSailorNames: [(name: String, def: SailorDef)] = []

    init(agentConfig: SailorDetectConfig = .default) {
        self.agentConfig = agentConfig
        rebuildSailorNameCache()
        // webhook status changes are now handled via handleWebhookEvent → ingest
    }

    private func rebuildSailorNameCache() {
        lowercasedSailorNames = agentConfig.agents.map { ($0.name.lowercased(), $0) }
    }

    func start(trees: [String: SplitTree]) {
        let inputWorktreePaths = Array(trees.keys)
        lock.lock()
        self.surfaces = [:]
        self.worktreePaths = [:]
        for (worktreePath, tree) in trees {
            for leaf in tree.allLeaves {
                if let station = StationRegistry.shared.station(forId: leaf.stationId) {
                    self.surfaces[station.id] = station
                    self.worktreePaths[station.id] = worktreePath
                }
            }
        }
        // Create trackers for each station
        for terminalID in self.surfaces.keys {
            if trackers[terminalID] == nil {
                trackers[terminalID] = DebouncedStatusTracker()
            }
        }
        lock.unlock()
        stop()

        for (worktreePath, tree) in trees {
            let leaves = tree.allLeaves
            for (index, leaf) in leaves.enumerated() {
                aggregator?.registerTerminal(leaf.stationId, worktreePath: worktreePath, leafIndex: index)
            }
        }

        webhookProvider.updateWorktrees(inputWorktreePaths)

        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.schedulePoll()
        }
        // Run immediately on start
        schedulePoll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Drop all per-terminal state for a dead pane. Caller must hold `lock`.
    private func removeTerminalStateLocked(_ terminalID: String) {
        trackers.removeValue(forKey: terminalID)
        lastMessages.removeValue(forKey: terminalID)
        runningStartTimes.removeValue(forKey: terminalID)
        lastViewportHashes.removeValue(forKey: terminalID)
        probedTypes.removeValue(forKey: terminalID)
        probedCommandLines.removeValue(forKey: terminalID)
        probedAtCycle.removeValue(forKey: terminalID)
    }

    func updateSurfaces(_ trees: [String: SplitTree]) {
        let inputWorktreePaths = Array(trees.keys)
        lock.lock()
        let oldSurfaceIDs = Set(self.surfaces.keys)
        let oldPaths = self.worktreePaths
        self.surfaces = [:]
        self.worktreePaths = [:]
        for (worktreePath, tree) in trees {
            for leaf in tree.allLeaves {
                if let station = StationRegistry.shared.station(forId: leaf.stationId) {
                    self.surfaces[station.id] = station
                    self.worktreePaths[station.id] = worktreePath
                }
            }
        }
        // Add trackers for new stations
        for terminalID in self.surfaces.keys {
            if trackers[terminalID] == nil {
                trackers[terminalID] = DebouncedStatusTracker()
            }
        }
        // Self-healing: drop per-terminal state for panes that disappeared
        // (pane closed, worktree deleted). Without this, trackers/hashes/probe
        // caches grow for the app's lifetime.
        let goneIDs = oldSurfaceIDs.subtracting(self.surfaces.keys)
        for id in goneIDs { removeTerminalStateLocked(id) }
        lock.unlock()

        // Aggregator is main-queue only; updateSurfaces is called from main.
        for id in goneIDs {
            if let path = oldPaths[id] {
                aggregator?.unregisterTerminal(id, worktreePath: path)
            }
        }

        for (worktreePath, tree) in trees {
            let leaves = tree.allLeaves
            for (index, leaf) in leaves.enumerated() {
                aggregator?.registerTerminal(leaf.stationId, worktreePath: worktreePath, leafIndex: index)
            }
        }

        webhookProvider.updateWorktrees(inputWorktreePaths)
    }

    /// Prefer polling these worktrees every cycle; others are sampled less frequently.
    func setPreferredPaths(_ paths: [String]) {
        preferredPaths = Set(paths)
    }

    /// Force an out-of-band poll (e.g. the user just clicked a pane and the
    /// header title would otherwise wait up to a full cycle to catch up).
    func refreshNow() {
        schedulePoll()
    }

    private func schedulePoll() {
        // Capture surfaces snapshot under lock, then poll on background
        lock.lock()
        let surfaceSnapshot = surfaces
        let pathSnapshot = worktreePaths
        lock.unlock()
        pollCycle &+= 1
        let cycle = pollCycle
        let preferredSnapshot = preferredPaths
        pollQueue.async { [weak self] in
            self?.pollAll(surfaceSnapshot, preferredPaths: preferredSnapshot, pollCycle: cycle, paths: pathSnapshot)
        }
    }

    private func pollAll(_ surfaceSnapshot: [String: Station], preferredPaths: Set<String>, pollCycle: Int, paths: [String: String]) {
        for (terminalID, surface) in surfaceSnapshot {
            let worktreePath = paths[terminalID] ?? ""
            guard Self.shouldPollPath(worktreePath, preferredPaths: preferredPaths, pollCycle: pollCycle, nonPreferredStride: self.nonPreferredPollStride) else {
                continue
            }
            let processStatus = surface.processStatus
            // readViewportText() can be slow — do NOT hold the lock here.
            // If input is actively holding ghosttyLock, skip this pane for the
            // cycle rather than making keystrokes wait behind a viewport read.
            let read = surface.readViewportTextForPoll()
            if read.contended { continue }
            var content = read.text ?? ""

            // No live surface: this is a dashboard overview card that was never
            // opened, so there is nothing to screen-scrape. Fall back to a
            // throttled backend capture (zmx history) so its agent status still
            // advances instead of freezing until a hook fires. The capture spawns
            // a subprocess, so it runs on a stride (not every cycle) and is
            // staggered per pane to avoid a subprocess burst on a single cycle.
            if content.isEmpty && !surface.hasLiveSurface {
                let offset = Int(truncatingIfNeeded: terminalID.stableHash)
                guard Self.shouldBackendCapture(pollCycle: pollCycle, offset: offset,
                                                stride: self.backendCaptureStride) else { continue }
                content = surface.readBackendText() ?? ""
                // Still nothing (no backend session): skip without poisoning the
                // hash cache with an empty frame that would suppress future scans.
                if content.isEmpty { continue }
            }

            // Skip expensive text analysis only when NOTHING observable changed.
            // The OSC title/progress must be in the hash: an agent "thinking" keeps
            // the viewport text static while animating a braille spinner in its
            // title, and that spinner is the running signal (osc_title rule). The
            // spinner changing between two 2s polls busts the hash and re-scans;
            // when truly idle (static title) the hash is stable and we still skip.
            let contentHash = String.stableHash(parts: content, surface.oscTitle, surface.oscProgress)

            lock.lock()
            let lastHash = lastViewportHashes[terminalID]
            lock.unlock()

            if let lastHash, lastHash == contentHash { continue }

            lock.lock()
            lastViewportHashes[terminalID] = contentHash
            let tracker = trackers[terminalID] ?? {
                let t = DebouncedStatusTracker()
                trackers[terminalID] = t
                return t
            }()
            lock.unlock()

            // Lowercase once, reuse for both agent matching and status detection
            let lowerContent = content.lowercased()
            let existingSailorType = ShipLog.shared.sailor(for: terminalID)?.agentType ?? .unknown
            let agentDef = findSailorDef(inLowercased: lowerContent, existingSailorType: existingSailorType)

            // Prefer process-tree identification over screen-text scraping; it is
            // robust to wrappers (node→codex) and to agents that clear their name
            // off screen. Falls back to text detection when the probe is unsure.
            let probe = probedSession(terminalID: terminalID, sessionName: surface.sessionName, pollCycle: pollCycle)
            let probedType = probe.agentType
            let commandLine = probe.commandLine
            let detectedSailorType = probedType != .unknown ? probedType : SailorType.detect(fromLowercased: lowerContent)
            var agentType = detectedSailorType == .unknown ? existingSailorType : detectedSailorType
            // Shell jobs (brew, make, …) are not in AI manifests — classify from argv.
            if let commandLine, !agentType.isAIAgent {
                let fromCmd = SailorType.detect(fromCommand: commandLine)
                if fromCmd != .unknown { agentType = fromCmd }
            }
            let manifest = ManifestStore.shared.manifest(for: agentType.manifestId)
            let webhookTasks = webhookProvider.tasks(for: worktreePath)

            // The ingested event's status is the debounced committedStatus from
            // detectDetailed below — a ScanDecoder.decode() here would run the
            // whole manifest engine (plus another full-screen lowercase) just to
            // produce a status that gets discarded. Only its activity extraction
            // is actually consumed, so run just that.
            let activityEvents = detector.extractActivityEvents(from: content)
            // Agent type only here — commandLine must land via ingest so the
            // displayed-state gate sees nil→cmd and notifies observers.
            ShipLog.shared.updateDetection(terminalID: terminalID, commandLine: nil, agentType: agentType)

            // Rich detection gives us the visible_idle signal for debounce.
            let osc = (title: surface.oscTitle, progress: surface.oscProgress)
            let detection = detector.detectDetailed(
                processStatus: processStatus, shellInfo: nil, content: content,
                manifest: manifest, osc: osc, lowercasedContent: lowerContent)
            let textStatus = detection.state

            lock.lock()
            let oldStatus = tracker.currentStatus
            let statusChanged = tracker.update(status: textStatus, visibleIdle: detection.visibleIdle)
            // The debounced/committed status drives both pipelines, so a held
            // running→idle flip does not leak into ShipLog either.
            let committedStatus = tracker.currentStatus
            let lastMessage = agentDef?.extractLastMessage(from: content, maxLen: 80) ?? ""
            lastMessages[terminalID] = lastMessage
            let roundDur = runningStartTimes[terminalID].map { Date().timeIntervalSince($0) } ?? 0
            if statusChanged {
                if committedStatus == .running && oldStatus != .running {
                    runningStartTimes[terminalID] = Date()
                } else if committedStatus != .running && oldStatus == .running {
                    runningStartTimes[terminalID] = nil
                }
            }
            lock.unlock()

            let normalized = NormalizedEvent(
                terminalID: terminalID, source: .scan,
                kind: .screenObserved(status: committedStatus, message: "", activity: activityEvents,
                                      commandLine: commandLine, agentType: agentType,
                                      roundDuration: roundDur, tasks: webhookTasks))
            ShipLog.shared.ingest(normalized)

            // Agent permission dialogs are rendered by the TUI rather than sent
            // through Codex/Claude hooks. Surface their numbered choices through
            // the same First Mate question-card pipeline used by native tools.
            let choices = ChoiceOptionParser.parse(content)
            if agentType.isAIAgent, !choices.isEmpty {
                let question = NormalizedEvent(
                    terminalID: terminalID, source: .scan,
                    kind: .question(
                        prompt: "\(agentType.displayName) requires approval",
                        options: choices.map(\.label), followups: []))
                ShipLog.shared.ingest(question)
            }
            // The worktree aggregator is now fed from ShipLog outcomes (arbitrated
            // scan+hook+OSC) in TabCoordinator, not directly here — the scan path
            // is viewport-hash-gated and would push a stale idle while an agent is
            // thinking. Registration still happens via aggregator.registerTerminal.
        }
    }

    /// Cached process-tree probe for a pane. Re-probes at most every
    /// `probeRefreshStride` cycles. Runs on the poll background queue.
    private func probedSession(
        terminalID: String,
        sessionName: String?,
        pollCycle: Int
    ) -> (agentType: SailorType, commandLine: String?) {
        guard let sessionName else { return (.unknown, nil) }
        lock.lock()
        let cachedType = probedTypes[terminalID]
        let cachedCmd = probedCommandLines[terminalID]
        let last = probedAtCycle[terminalID]
        lock.unlock()
        // Reuse cache when still fresh. Allow a known command line with unknown
        // agent type (shell jobs) — that is the brew-update title path.
        if let last, pollCycle - last < probeRefreshStride {
            if let cachedType, cachedType != .unknown {
                return (cachedType, cachedCmd)
            }
            if cachedCmd != nil {
                return (cachedType ?? .unknown, cachedCmd)
            }
        }
        let probe = ProcessProbe.probeSession(sessionName: sessionName)
        let type = SailorType.fromManifestId(probe.agentId)
        lock.lock()
        // Never downgrade a known identity to unknown on a transient probe miss.
        if type != .unknown { probedTypes[terminalID] = type }
        // Unlike agent identity, the command line tracks the *current* foreground
        // job: a nil probe means the job ended, so clear the cache — otherwise a
        // finished `brew update` would title the pane until app restart.
        probedCommandLines[terminalID] = probe.commandLine
        probedAtCycle[terminalID] = pollCycle
        let resultType = probedTypes[terminalID] ?? .unknown
        let resultCmd = probedCommandLines[terminalID]
        lock.unlock()
        return (resultType, resultCmd)
    }

    /// Find agent definition using pre-lowercased content and names
    private func findSailorDef(inLowercased lowerContent: String, existingSailorType: SailorType) -> SailorDef? {
        Self.findSailorDef(
            inLowercased: lowerContent,
            existingSailorType: existingSailorType,
            candidates: lowercasedSailorNames
        )
    }

    static func findSailorDef(
        inLowercased lowerContent: String,
        existingSailorType: SailorType,
        candidates: [(name: String, def: SailorDef)]
    ) -> SailorDef? {
        if existingSailorType.isAIAgent {
            let name = existingSailorType.displayName.lowercased()
            if let def = candidates.first(where: { $0.name == name })?.def {
                return def
            }
        }

        for (name, def) in candidates {
            if lowerContent.contains(name) {
                return def
            }
        }
        return nil
    }

    func status(for terminalID: String) -> SailorStatus {
        lock.lock()
        defer { lock.unlock() }
        return trackers[terminalID]?.currentStatus ?? .unknown
    }

    func lastMessage(for terminalID: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        return lastMessages[terminalID] ?? ""
    }

    /// Returns seconds since the current Running round started, or 0 if not running
    func roundDuration(for terminalID: String) -> TimeInterval {
        lock.lock()
        let start = runningStartTimes[terminalID]
        lock.unlock()
        guard let start else { return 0 }
        return Date().timeIntervalSince(start)
    }

    static func shouldPollPath(
        _ path: String,
        preferredPaths: Set<String>,
        pollCycle: Int,
        nonPreferredStride: Int
    ) -> Bool {
        if preferredPaths.isEmpty { return true }
        if preferredPaths.contains(path) { return true }
        let stride = max(1, nonPreferredStride)
        return pollCycle % stride == 0
    }

    /// Whether a surface-less pane should run a backend capture this cycle.
    /// Sampled every `stride` cycles, staggered by a per-pane `offset` so captures
    /// spread across cycles instead of bursting together.
    static func shouldBackendCapture(pollCycle: Int, offset: Int, stride: Int) -> Bool {
        let s = max(1, stride)
        return ((pollCycle &+ offset) % s + s) % s == 0
    }

    deinit {
        stop()
    }
}

private extension String {
    /// Simple stable hash (djb2) for change detection.
    var stableHash: UInt64 {
        var hash: UInt64 = 5381
        Self.accumulate(&hash, self)
        return hash
    }

    /// djb2 over several parts with a separator byte between them — same result
    /// class as hashing the joined string, without materializing the join
    /// (the viewport part alone can be thousands of bytes, every poll).
    static func stableHash(parts: String...) -> UInt64 {
        var hash: UInt64 = 5381
        for (index, part) in parts.enumerated() {
            if index > 0 { hash = ((hash &<< 5) &+ hash) &+ 1 }
            accumulate(&hash, part)
        }
        return hash
    }

    private static func accumulate(_ hash: inout UInt64, _ s: String) {
        for byte in s.utf8 {
            hash = ((hash &<< 5) &+ hash) &+ UInt64(byte)
        }
    }
}
