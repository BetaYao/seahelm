import Foundation
import Aptabase

/// Thin Aptabase wrapper. Only anonymous product signals — no paths, repo
/// names, messages, or handle content.
enum Analytics {
    private static let appKey = "A-US-1402974604"
    private static let firstWorktreeKey = "seahelm.analytics.firstWorktreeSent"

    static func initialize() {
        Aptabase.shared.initialize(appKey: appKey)
    }

    /// Launch pulse. `worktreeCount` is how many worktrees config already knows
    /// about (layouts / start stamps) before live discovery finishes.
    static func trackAppStarted(worktreeCount: Int) {
        Aptabase.shared.trackEvent("app_started", with: [
            "worktree_count": worktreeCount
        ])
        trackWorktreeCount(worktreeCount)
        // Upgrading users who already have worktrees shouldn't fire
        // `first_worktree` the next time they create one.
        if worktreeCount > 0 {
            UserDefaults.standard.set(true, forKey: firstWorktreeKey)
        }
    }

    static func trackOnboardingCompleted() {
        Aptabase.shared.trackEvent("onboarding_completed")
    }

    /// Called when Seahelm itself creates a worktree (not mere git discovery).
    static func trackWorktreeCreated(totalCount: Int) {
        if !UserDefaults.standard.bool(forKey: firstWorktreeKey) {
            UserDefaults.standard.set(true, forKey: firstWorktreeKey)
            Aptabase.shared.trackEvent("first_worktree", with: [
                "worktree_count": totalCount
            ])
        }
        trackWorktreeCount(totalCount)
    }

    static func trackWorktreeCount(_ count: Int) {
        Aptabase.shared.trackEvent("worktree_count", with: [
            "count": count
        ])
    }

    /// Worktrees persisted in config — available before discovery completes.
    static func knownWorktreeCount(from config: Config) -> Int {
        let paths = Set(config.splitLayouts.keys).union(config.worktreeStartedAt.keys)
        return paths.count
    }
}
