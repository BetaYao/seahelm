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
    var aggregator: WorktreeStatusAggregator?
    private let lock = NSLock()

    private let pollInterval: TimeInterval = 2.0
    private let pollQueue = DispatchQueue(label: "com.seahelm.status-poll", qos: .utility)
    private let nonPreferredPollStride: Int = 3
    private var preferredPaths: Set<String> = []
    private var pollCycle: Int = 0

    // Cache: skip detection when viewport text hasn't changed
    private var lastViewportHashes: [String: UInt64] = [:]           // keyed by terminal ID
    // Pre-lowercased agent names for faster matching
    private var lowercasedSailorNames: [(name: String, def: SailorDef)] = []

    init(agentConfig: SailorDetectConfig = .default) {
        self.agentConfig = agentConfig
        rebuildSailorNameCache()
        webhookProvider.onStatusChanged = { [weak self] worktreePath in
            self?.scheduleWebhookRefresh(for: worktreePath)
        }
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

    func updateSurfaces(_ trees: [String: SplitTree]) {
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
        // Add trackers for new stations
        for terminalID in self.surfaces.keys {
            if trackers[terminalID] == nil {
                trackers[terminalID] = DebouncedStatusTracker()
            }
        }
        lock.unlock()

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

    private func scheduleWebhookRefresh(for worktreePath: String) {
        lock.lock()
        let pathSnapshot = worktreePaths
        lock.unlock()
        pollQueue.async { [weak self] in
            self?.refreshWebhookDrivenStatus(for: worktreePath, paths: pathSnapshot)
        }
    }

    private func refreshWebhookDrivenStatus(for worktreePath: String, paths: [String: String]) {
        let terminalIDs = paths.compactMap { terminalID, path in
            path == worktreePath ? terminalID : nil
        }
        guard !terminalIDs.isEmpty else { return }

        let hookStatus = webhookProvider.status(for: worktreePath)
        guard hookStatus != .unknown else { return }

        let lastMessage = webhookProvider.lastMessage(for: worktreePath) ?? ""
        let webhookTasks = webhookProvider.tasks(for: worktreePath)
        let lastUserPrompt = webhookProvider.lastUserPrompt(for: worktreePath) ?? ""

        for terminalID in terminalIDs {
            lock.lock()
            let tracker = trackers[terminalID] ?? {
                let t = DebouncedStatusTracker()
                trackers[terminalID] = t
                return t
            }()
            let oldStatus = tracker.currentStatus
            let statusChanged = tracker.update(status: hookStatus)
            lastMessages[terminalID] = lastMessage
            let roundDur = runningStartTimes[terminalID].map { Date().timeIntervalSince($0) } ?? 0
            if statusChanged {
                if hookStatus == .running && oldStatus != .running {
                    runningStartTimes[terminalID] = Date()
                } else if hookStatus != .running && oldStatus == .running {
                    runningStartTimes[terminalID] = nil
                }
            }
            lock.unlock()

            let existingSailorType = ShipLog.shared.agent(for: terminalID)?.agentType ?? .unknown
            ShipLog.shared.updateDetection(terminalID: terminalID, commandLine: nil, agentType: existingSailorType)
            ShipLog.shared.updateStatus(
                terminalID: terminalID,
                status: hookStatus,
                lastMessage: lastMessage,
                roundDuration: roundDur,
                tasks: webhookTasks,
                lastUserPrompt: lastUserPrompt
            )

            DispatchQueue.main.async { [weak self] in
                self?.aggregator?.agentDidUpdate(
                    terminalID: terminalID,
                    status: hookStatus,
                    lastMessage: lastMessage,
                    lastUserPrompt: lastUserPrompt
                )
            }
        }
    }

    private func pollAll(_ surfaceSnapshot: [String: Station], preferredPaths: Set<String>, pollCycle: Int, paths: [String: String]) {
        for (terminalID, surface) in surfaceSnapshot {
            let worktreePath = paths[terminalID] ?? ""
            guard Self.shouldPollPath(worktreePath, preferredPaths: preferredPaths, pollCycle: pollCycle, nonPreferredStride: self.nonPreferredPollStride) else {
                continue
            }
            let processStatus = surface.processStatus
            // readViewportText() can be slow — do NOT hold the lock here
            let content = surface.readViewportText() ?? ""

            // Skip expensive text analysis if viewport hasn't changed
            let contentHash = content.stableHash

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
            let existingSailorType = ShipLog.shared.agent(for: terminalID)?.agentType ?? .unknown
            let agentDef = findSailorDef(inLowercased: lowerContent, existingSailorType: existingSailorType)

            // ScanDecoder runs detect() + extractActivityEvents() — do NOT hold the lock here
            let scanReport = ScanDecoder(
                detector: detector,
                processStatus: processStatus,
                shellInfo: nil,
                content: content,
                agentDef: agentDef
            ).decode()
            let textStatus = scanReport?.status ?? .unknown
            let hookStatus = webhookProvider.status(for: worktreePath)
            let detected = SailorStatus.highestPriority([textStatus, hookStatus])

            // Prefer structured webhook message over terminal text scan
            let webhookMessage = webhookProvider.lastMessage(for: worktreePath)
            let terminalMessage = agentDef?.extractLastMessage(from: content, maxLen: 80) ?? ""
            let lastMessage = webhookMessage ?? (terminalMessage.isEmpty ? nil : terminalMessage) ?? ""
            let webhookTasks = webhookProvider.tasks(for: worktreePath)
            let lastUserPrompt = webhookProvider.lastUserPrompt(for: worktreePath) ?? ""

            // Feed ShipLog with structured data on every poll
            let detectedSailorType = SailorType.detect(fromLowercased: lowerContent)
            let agentType = detectedSailorType == .unknown ? existingSailorType : detectedSailorType

            lock.lock()
            let oldStatus = tracker.currentStatus
            let statusChanged = tracker.update(status: detected)
            lastMessages[terminalID] = lastMessage
            let roundDur = runningStartTimes[terminalID].map { Date().timeIntervalSince($0) } ?? 0
            // Track round duration: record when entering Running, clear when leaving
            if statusChanged {
                if detected == .running && oldStatus != .running {
                    runningStartTimes[terminalID] = Date()
                } else if detected != .running && oldStatus == .running {
                    runningStartTimes[terminalID] = nil
                }
            }
            lock.unlock()

            ShipLog.shared.updateDetection(terminalID: terminalID, commandLine: nil, agentType: agentType)

            // Route through ingest: pass a report with the merged detected status and
            // supply caller-computed values (lastMessage, roundDuration, tasks) that
            // ScanDecoder intentionally leaves blank.
            // Activity events from the scan report are applied only when no webhook events exist.
            let webhookEvents = ShipLog.shared.agent(for: terminalID)?.activityEvents ?? []
            let reportForIngest: StatusReport
            if webhookEvents.isEmpty, let scan = scanReport {
                reportForIngest = StatusReport(status: detected, lastMessage: "", activityEvents: scan.activityEvents)
            } else {
                reportForIngest = StatusReport(status: detected, lastMessage: "", activityEvents: [])
            }
            ShipLog.shared.ingest(
                terminalID: terminalID,
                report: reportForIngest,
                lastUserPrompt: lastUserPrompt,
                messageOverride: lastMessage,
                roundDuration: roundDur,
                tasks: webhookTasks
            )

            DispatchQueue.main.async { [weak self] in
                self?.aggregator?.agentDidUpdate(
                    terminalID: terminalID,
                    status: detected,
                    lastMessage: lastMessage,
                    lastUserPrompt: lastUserPrompt
                )
            }

        }
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

    deinit {
        stop()
    }
}

private extension String {
    /// Simple stable hash (djb2) for change detection.
    var stableHash: UInt64 {
        var hash: UInt64 = 5381
        for byte in self.utf8 {
            hash = ((hash &<< 5) &+ hash) &+ UInt64(byte)
        }
        return hash
    }
}
