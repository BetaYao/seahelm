import AppKit
import Observation

/// One row in the island — a worktree's aggregated agent state.
struct IslandAgentRow: Identifiable, Equatable {
    let id: String // worktreePath
    let project: String
    let branch: String
    let status: SailorStatus
    let message: String
    /// Task description entered at worktree-creation time.
    let title: String
}

enum IslandState: Equatable {
    case closed
    case opened
    case popping // brief attention pop of the closed pill
}

enum IslandOpenReason: Equatable {
    case hover
    case click
    case event // a suggestion/notification forced the island open
}

/// Observable state driving the island's SwiftUI content. All mutation on main.
@Observable
final class IslandModel {
    static let hoverOpenDelay: TimeInterval = 0.35
    static let popDuration: TimeInterval = 1.4

    var state: IslandState = .closed
    var openReason: IslandOpenReason?

    var rows: [IslandAgentRow] = []
    var primaryEntry: NotificationEntry?
    var unreadCount: Int = 0
    var orders: [PendingOrder] = []
    /// Snapshot of the newest unread notifications, refreshed by
    /// MainWindowController.refreshIsland. Stored (not computed in the view)
    /// so opening the island doesn't re-filter the full history per body eval.
    var recentNotifications: [NotificationEntry] = []
    static let maxRecentNotifications = 5

    /// Screen geometry, set by the panel controller.
    var notchWidth: CGFloat = 190
    var notchHeight: CGFloat = 38
    var isNotchedDisplay: Bool = false
    var openedWidth: CGFloat = 540

    /// SwiftUI-measured height of the opened surface (for hit testing).
    var measuredOpenedHeight: CGFloat = 0

    // Wired by MainWindowController.
    var onNavigate: ((_ worktreePath: String, _ paneIndex: Int?) -> Void)?
    var onOptionTapped: ((_ order: PendingOrder, _ optionText: String) -> Void)?
    /// Dismiss a suggestion card without acting on it.
    var onDismissOrder: ((_ order: PendingOrder) -> Void)?
    var onMarkAllRead: (() -> Void)?
    /// Bridge command submit (same handler as the First Mate composer).
    var onSubmitCommand: ((String) -> Void)?
    /// `/ @ #` autocomplete source — same provider as the cockpit composer.
    var commandMenuProvider: ((Character, String) -> [(name: String, desc: String)])?
    /// One-shot: when set, the opened surface prefills the command field with
    /// this text, focuses it, then clears the flag.
    var pendingCommandPrefill: String?

    /// Transient one-line text shown in the closed pill's left wing when a
    /// notification arrives (cleared automatically).
    var transientText: String?

    private var popRevertWork: DispatchWorkItem?
    private var transientClearWork: DispatchWorkItem?

    var isOpened: Bool { state == .opened }

    func open(reason: IslandOpenReason) {
        popRevertWork?.cancel()
        popRevertWork = nil
        openReason = reason
        state = .opened
    }

    func close() {
        popRevertWork?.cancel()
        popRevertWork = nil
        openReason = nil
        state = .closed
    }

    /// Brief scale "pop" of the closed pill to draw attention to a new event.
    func pop() {
        guard state == .closed || state == .popping else { return }
        state = .popping
        popRevertWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state == .popping else { return }
            self.state = .closed
        }
        popRevertWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.popDuration, execute: work)
    }

    /// Show `text` in the pill for a few seconds alongside a pop.
    func flashTransient(_ text: String) {
        transientText = text
        transientClearWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.transientText = nil
        }
        transientClearWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: work)
        pop()
    }

    /// Width of the closed pill. On a notched display it is locked to the
    /// physical notch plus symmetric wings so it merges with the hardware
    /// notch; on external displays it is a fixed simulated-notch width.
    /// A transient label widens both wings symmetrically so the notch stays
    /// centered on the screen.
    var closedWidth: CGFloat {
        let popBonus: CGFloat = state == .popping ? 18 : 0
        let transientBonus: CGFloat = transientText != nil ? 260 : 0
        if isNotchedDisplay {
            return notchWidth + 88 + popBonus + transientBonus
        }
        return min(360, notchWidth + 170) + popBonus + transientBonus
    }

    /// Sessions needing attention first, then the rest — pill tile order.
    var tileRows: [IslandAgentRow] {
        rows.sorted { statusRank($0.status) > statusRank($1.status) }
    }

    private func statusRank(_ s: SailorStatus) -> Int {
        switch s {
        case .error, .exited: return 4
        case .waiting: return 3
        case .running: return 2
        case .idle: return 1
        case .unknown: return 0
        }
    }

    var hasAttention: Bool {
        unreadCount > 0 || !orders.isEmpty
    }
}
