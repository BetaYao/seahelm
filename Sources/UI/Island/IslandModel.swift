import AppKit
import Observation
import SwiftUI

/// Island palette — keyed to the product's cyan accent (#1FC8DA) so the
/// floating panel reads as part of the app, not a generic black overlay.
enum IslandStyle {
    static let accent = Color(red: 0x1f / 255, green: 0xc8 / 255, blue: 0xda / 255)
    /// Near-black with a cyan cast for the pill/panel surface.
    static let background = Color(red: 0.016, green: 0.055, blue: 0.066)
}

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
    case event // a suggestion forced the island open
}

/// Observable state driving the island's SwiftUI content. All mutation on main.
@Observable
final class IslandModel {
    static let hoverOpenDelay: TimeInterval = 0.35
    static let popDuration: TimeInterval = 1.4

    var state: IslandState = .closed
    var openReason: IslandOpenReason?

    var rows: [IslandAgentRow] = []
    /// Claude/Codex rate-limit readouts, refreshed by `UsageSummaryStore`.
    /// Rendered in full in the opened header; the closed pill rotates through
    /// them one window at a time.
    private(set) var usageReadouts: [UsageReadout] = []
    /// Index into `pillFrames` — advanced by the rotation timer.
    private(set) var pillUsageIndex = 0
    /// Suggestions waiting on the user to pick an option. This is the island's
    /// only attention signal — status notifications go to Notification Center
    /// and are not mirrored here.
    var orders: [PendingOrder] = []

    /// Screen geometry, set by the panel controller.
    var notchWidth: CGFloat = 190
    var notchHeight: CGFloat = 38
    var isNotchedDisplay: Bool = false
    var openedWidth: CGFloat = 540

    /// SwiftUI-measured height of the opened surface (for hit testing).
    var measuredOpenedHeight: CGFloat = 0
    /// Last measured natural height of the opened list area — persisted
    /// across open cycles so reopening renders at the right size immediately
    /// instead of resizing mid-animation when the measurement lands.
    var cachedListHeight: CGFloat = 0

    // Wired by MainWindowController.
    var onNavigate: ((_ worktreePath: String, _ paneIndex: Int?) -> Void)?
    var onOptionTapped: ((_ order: PendingOrder, _ optionText: String) -> Void)?
    /// Jump to the pane that raised a suggestion without resolving the card.
    var onRevealSuggestion: ((_ order: PendingOrder) -> Void)?
    /// Dismiss a suggestion card without acting on it.
    var onDismissOrder: ((_ order: PendingOrder) -> Void)?
    /// Bridge command submit (same handler as the First Mate composer).
    var onSubmitCommand: ((String) -> Void)?
    /// `/ @ #` autocomplete source — same provider as the cockpit composer.
    var commandMenuProvider: ((Character, String) -> [(name: String, desc: String)])?
    /// One-shot: when set, the opened surface prefills the command field with
    /// this text, focuses it, then clears the flag.
    var pendingCommandPrefill: String?
    /// One-shot: focus the command field without changing its text (double-Ctrl).
    var pendingCommandFocus: Bool = false

    private var popRevertWork: DispatchWorkItem?
    private var usageRotationTimer: Timer?

    var isOpened: Bool { state == .opened }

    deinit {
        usageRotationTimer?.invalidate()
    }

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

    // MARK: - Usage readouts

    static let usageRotationInterval: TimeInterval = 6
    /// Width one rotated window ("✦ 5h 11% 4h1m") needs in the pill's wing.
    static let pillUsageWidth: CGFloat = 118

    /// One rotated frame of the closed pill: a single window plus its
    /// provider's icon.
    struct PillUsageFrame: Equatable {
        let logoName: String
        let segment: UsageReadoutSegment
    }

    /// Every known window, flattened across providers — Claude 5h, Claude 7d,
    /// Codex 5h — so the pill rotates one window at a time instead of trying
    /// to fit a whole provider into a wing.
    var pillFrames: [PillUsageFrame] {
        usageReadouts.flatMap { readout in
            readout.segments.map { PillUsageFrame(logoName: readout.logoName, segment: $0) }
        }
    }

    /// The window currently on show. Pending orders own the left wing, so
    /// usage steps aside while one is waiting.
    var pillUsage: PillUsageFrame? {
        guard orders.isEmpty else { return nil }
        let frames = pillFrames
        guard !frames.isEmpty else { return nil }
        return frames[min(pillUsageIndex, frames.count - 1)]
    }

    func setUsageReadouts(_ readouts: [UsageReadout]) {
        guard readouts != usageReadouts else { return }
        usageReadouts = readouts
        if pillUsageIndex >= pillFrames.count { pillUsageIndex = 0 }
        updateUsageRotation()
    }

    private func updateUsageRotation() {
        usageRotationTimer?.invalidate()
        usageRotationTimer = nil
        guard pillFrames.count > 1 else { return }
        let timer = Timer(timeInterval: Self.usageRotationInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            let count = self.pillFrames.count
            guard count > 0 else { return }
            self.pillUsageIndex = (self.pillUsageIndex + 1) % count
        }
        // .common so the rotation keeps ticking while a menu or drag has the
        // main run loop in tracking mode.
        RunLoop.main.add(timer, forMode: .common)
        usageRotationTimer = timer
    }

    /// Extra width each wing takes on while a usage window is showing. Applied
    /// to both wings so the centre spacer stays locked to the hardware notch.
    var wingUsageWidth: CGFloat { pillUsage == nil ? 0 : Self.pillUsageWidth }

    /// Width of the closed pill. On a notched display it is locked to the
    /// physical notch plus symmetric wings so it merges with the hardware
    /// notch; on external displays it is a fixed simulated-notch width.
    var closedWidth: CGFloat {
        let popBonus: CGFloat = state == .popping ? 18 : 0
        let base = isNotchedDisplay ? notchWidth + 88 : min(360, notchWidth + 170)
        return base + wingUsageWidth * 2 + popBonus
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
}
