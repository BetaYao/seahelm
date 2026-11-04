import Foundation

/// Claude's and Codex's rate limits and today's tokens, as seahelm-core
/// reads them (`usage.summary`, `crates/core/src/usage.rs`: Claude from the
/// statusline cache the app's bridge feeds, Codex from `codex app-server` and
/// its session logs). The app asks every 30 s and hands the snapshots on.
final class UsageSummaryStore {
    typealias UpdateHandler = (_ claude: UsageSnapshot, _ codex: UsageSnapshot) -> Void

    var onUpdate: UpdateHandler?
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard case .success(let r) = CoreSocketClient.call("usage.summary") else { return }
            let claude = Self.snapshot(r["claude"], provider: .claude)
            let codex = Self.snapshot(r["codex"], provider: .codex)
            DispatchQueue.main.async { self?.onUpdate?(claude, codex) }
        }
    }

    /// One provider's snapshot as the core sends it; empty and stale when
    /// the core has nothing for it.
    static func snapshot(_ v: Any?, provider: UsageProvider) -> UsageSnapshot {
        let d = v as? [String: Any] ?? [:]
        func window(_ w: Any?) -> UsageRateLimitWindow? {
            guard let w = w as? [String: Any], let used = w["used_percent"] as? Int else { return nil }
            return UsageRateLimitWindow(usedPercent: used,
                                        resetsAt: (w["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) },
                                        label: w["label"] as? String)
        }
        return UsageSnapshot(provider: provider, rateLimit: window(d["rate_limit"]),
                             weeklyRateLimit: window(d["weekly_rate_limit"]),
                             todayTokens: d["today_tokens"] as? Int,
                             updatedAt: (d["updated_at"] as? Double).map { Date(timeIntervalSince1970: $0) },
                             isStale: d["is_stale"] as? Bool ?? true)
    }
}
