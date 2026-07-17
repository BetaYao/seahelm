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
    var onMarkAllRead: (() -> Void)?

    private var popRevertWork: DispatchWorkItem?

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

    /// Width of the closed pill. On a notched display it is locked to the
    /// physical notch plus symmetric wings so it merges with the hardware
    /// notch; on external displays it is a fixed simulated-notch width.
    var closedWidth: CGFloat {
        let popBonus: CGFloat = state == .popping ? 18 : 0
        if isNotchedDisplay {
            return notchWidth + 88 + popBonus
        }
        return min(360, notchWidth + 170) + popBonus
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
