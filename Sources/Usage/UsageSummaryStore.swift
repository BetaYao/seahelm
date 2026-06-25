import Foundation

final class UsageSummaryStore {
    typealias UpdateHandler = ([PrimaryCapsuleFrame]) -> Void
    private static let defaultCacheFallbackMaxAge: TimeInterval = 10 * 60

    private let claudeProvider: ClaudeUsageSummaryProvider
    private let codexProvider: CodexUsageSummaryProvider
    private let refreshInterval: TimeInterval
    private let cacheFallbackMaxAge: TimeInterval
    private let queue = DispatchQueue(label: "usage-summary-store", qos: .utility)
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var isRefreshing = false
    private var cachedClaudeSnapshot: ProviderSnapshotCache?
    private var cachedCodexSnapshot: ProviderSnapshotCache?

    var onUpdate: UpdateHandler?

    convenience init(refreshInterval: TimeInterval = 60) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var calendar = Calendar.current
        calendar.timeZone = TimeZone.current
        self.init(
            claudeProvider: ClaudeUsageSummaryProvider(
                cacheReader: ClaudeStatuslineCacheReader(
                    cacheURL: home.appendingPathComponent("Library/Caches/seahelm/claude-statusline.json"),
                    staleInterval: 6 * 60 * 60
                ),
                transcriptAggregator: ClaudeTranscriptUsageAggregator(
                    rootURL: home.appendingPathComponent(".claude/projects"),
                    calendar: calendar,
                    modificationGraceInterval: 24 * 60 * 60
                )
            ),
            codexProvider: CodexUsageSummaryProvider(
                rateLimitClient: CodexAppServerRateLimitClient(),
                sessionUsageAggregator: CodexSessionUsageAggregator(
                    rootURL: home.appendingPathComponent(".codex/sessions"),
                    calendar: calendar,
                    modificationGraceInterval: 24 * 60 * 60
                )
            ),
            refreshInterval: refreshInterval
        )
    }

    init(
        claudeProvider: ClaudeUsageSummaryProvider,
        codexProvider: CodexUsageSummaryProvider,
        refreshInterval: TimeInterval = 60,
        cacheFallbackMaxAge: TimeInterval = UsageSummaryStore.defaultCacheFallbackMaxAge
    ) {
        self.claudeProvider = claudeProvider
        self.codexProvider = codexProvider
        self.refreshInterval = refreshInterval
        self.cacheFallbackMaxAge = cacheFallbackMaxAge
    }

    deinit {
        stop()
    }

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard timer == nil else { return }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: refreshInterval)
        timer.setEventHandler { [weak self] in
            self?.refresh()
        }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        lock.lock()
        let timer = self.timer
        self.timer = nil
        lock.unlock()

        timer?.setEventHandler {}
        timer?.cancel()
    }

    private func refresh() {
        lock.lock()
        guard !isRefreshing else {
            lock.unlock()
            return
        }
        isRefreshing = true
        lock.unlock()

        let claudeCandidate = claudeProvider.snapshot()
        let codexCandidate = codexProvider.snapshot()

        lock.lock()
        let now = Date()
        let claudeResult = Self.resolveSnapshotForDisplay(
            candidate: claudeCandidate,
            cached: cachedClaudeSnapshot,
            now: now,
            maxCacheAge: cacheFallbackMaxAge
        )
        let codexResult = Self.resolveSnapshotForDisplay(
            candidate: codexCandidate,
            cached: cachedCodexSnapshot,
            now: now,
            maxCacheAge: cacheFallbackMaxAge
        )
        cachedClaudeSnapshot = claudeResult.cache
        cachedCodexSnapshot = codexResult.cache
        isRefreshing = false
        lock.unlock()

        let frames = UsageSummaryFormatter.rotationFrames(claude: claudeResult.snapshot, codex: codexResult.snapshot)
        DispatchQueue.main.async { [weak self] in
            self?.onUpdate?(frames)
        }
    }

    static func resolveSnapshotForDisplay(
        candidate: UsageSnapshot,
        cached: ProviderSnapshotCache?,
        now: Date = Date(),
        maxCacheAge: TimeInterval = defaultCacheFallbackMaxAge
    ) -> (snapshot: UsageSnapshot, cache: ProviderSnapshotCache) {
        var cache = cached ?? ProviderSnapshotCache(provider: candidate.provider)
        cache.ingest(candidate, now: now)
        return (cache.displaySnapshot(now: now, maxCacheAge: maxCacheAge), cache)
    }
}

extension UsageSummaryStore {
    struct ProviderSnapshotCache: Equatable {
        let provider: UsageProvider
        private(set) var rateLimit: UsageRateLimitWindow?
        private(set) var rateLimitUpdatedAt: Date?
        private(set) var weeklyRateLimit: UsageRateLimitWindow?
        private(set) var weeklyRateLimitUpdatedAt: Date?
        private(set) var todayTokens: Int?
        private(set) var todayTokensUpdatedAt: Date?
        private(set) var isStale = true

        mutating func ingest(_ snapshot: UsageSnapshot, now: Date = Date()) {
            let snapshotTime = snapshot.updatedAt ?? now
            if let rateLimit = snapshot.rateLimit {
                self.rateLimit = rateLimit
                self.rateLimitUpdatedAt = snapshotTime
            }
            if let weeklyRateLimit = snapshot.weeklyRateLimit {
                self.weeklyRateLimit = weeklyRateLimit
                self.weeklyRateLimitUpdatedAt = snapshotTime
            }
            if let todayTokens = snapshot.todayTokens {
                self.todayTokens = todayTokens
                self.todayTokensUpdatedAt = snapshotTime
            }
            isStale = snapshot.isStale
        }

        func displaySnapshot(now: Date = Date(), maxCacheAge: TimeInterval) -> UsageSnapshot {
            let displayRateLimit = isFresh(rateLimitUpdatedAt, now: now, maxCacheAge: maxCacheAge) ? rateLimit : nil
            let displayWeeklyRateLimit = isFresh(weeklyRateLimitUpdatedAt, now: now, maxCacheAge: maxCacheAge) ? weeklyRateLimit : nil
            let displayTodayTokens = isFreshForToday(todayTokensUpdatedAt, now: now, maxCacheAge: maxCacheAge) ? todayTokens : nil
            let displayUpdatedAt = [displayRateLimit == nil ? nil : rateLimitUpdatedAt,
                                    displayWeeklyRateLimit == nil ? nil : weeklyRateLimitUpdatedAt,
                                    displayTodayTokens == nil ? nil : todayTokensUpdatedAt]
                .compactMap { $0 }
                .max()
            return UsageSnapshot(
                provider: provider,
                rateLimit: displayRateLimit,
                weeklyRateLimit: displayWeeklyRateLimit,
                todayTokens: displayTodayTokens,
                updatedAt: displayUpdatedAt,
                isStale: isStale || displayUpdatedAt == nil
            )
        }

        private func isFresh(_ date: Date?, now: Date, maxCacheAge: TimeInterval) -> Bool {
            guard let date else { return false }
            return now.timeIntervalSince(date) <= maxCacheAge
        }

        private func isFreshForToday(_ date: Date?, now: Date, maxCacheAge: TimeInterval) -> Bool {
            guard isFresh(date, now: now, maxCacheAge: maxCacheAge),
                  let date else { return false }
            return Calendar.current.isDate(date, inSameDayAs: now)
        }
    }
}
