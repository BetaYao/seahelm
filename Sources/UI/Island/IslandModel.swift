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
    let status: AgentStatus
    let message: String
    /// Task description entered at worktree-creation time.
    let title: String
    /// The worktree's colour from the fleet row menu, drawn as the row's left
    /// bar. Status is shown on the right, so the bar is free to carry it.
    var label: SessionLabel? = nil

    /// Running / waiting / error get a chip + activity line; idle stays quiet.
    var needsAttention: Bool {
        switch status {
        case .running, .waiting, .error: return true
        case .idle, .exited, .unknown: return false
        }
    }
}

/// Repo (= project) bucket for the opened island list.
struct IslandProjectGroup: Identifiable, Equatable {
    let id: String // project name
    let project: String
    let rows: [IslandAgentRow]
}

enum IslandState: Equatable {
    case closed
    case opened
    case popping // brief attention pop of the closed pill
}

/// What the opened island shows (docs/superpowers/specs/2026-11-04-first-mate-surfaces-design.md):
/// the cards waiting on the user, or First Mate's conversation. One at a time;
/// the usage bar stays above both.
enum IslandPage: Equatable {
    case suggestions
    case conversation
}

enum IslandOpenReason: Equatable {
    case hover
    case click
    case event // a suggestion forced the island open
}

/// Observable state driving the island's SwiftUI content. All mutation on main.
/// A `/command`'s reply as the island shows it under the composer.
struct IslandCommandReply: Equatable {
    let text: String
    let isError: Bool
}

@Observable
final class IslandModel {
    static let hoverOpenDelay: TimeInterval = 0.35
    static let popDuration: TimeInterval = 1.4

    var state: IslandState = .closed
    var openReason: IslandOpenReason?
    var page: IslandPage = .conversation

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
    var orders: [Card] = [] {
        didSet {
            // The last card dealt with: First Mate's conversation takes over
            // (without taking the keyboard — `pendingCommandFocus` stays put).
            if orders.isEmpty, page == .suggestions { page = .conversation }
        }
    }

    // MARK: First Mate's conversation

    /// First Mate's timeline (the core's, or the app's own while it runs
    /// First Mate), oldest first. Refreshed while the conversation shows.
    var mateMessages: [MessageEvent] = []
    /// "watching", "working"… and its tone, from the coordinator.
    var mateActivity: String = "off"
    var mateTone: FirstMateStateText.Tone = .quiet
    var mateRunning = false
    /// A turn is under way: the conversation offers Stop.
    var mateBusy = false
    /// What is being typed for First Mate; kept across page switches and closes.
    var draft = ""
    /// The last send that did not reach First Mate; the draft is kept for a retry.
    var sendError: String?
    /// What the core answered the last `/command` typed here (`/notes @repo`,
    /// `/status`, `/help` …): the island is the only place it can be read.
    var commandReply: IslandCommandReply?
    /// Say this to First Mate (a `/command` runs as one). False when it did not go.
    var onSendToFirstMate: ((String) -> Bool)?
    /// Stop First Mate's turn (Esc into its session).
    var onInterruptFirstMate: (() -> Void)?
    /// What is wrong that the user has to hear (`IslandWarning`): the core not
    /// answering, or the control channel held by another instance.
    var warning: IslandWarning?

    /// The cards the island draws, newest first. A report only when it has
    /// something to decide; routine rounds stay in the checkout's status.
    static func newestSuggestions(from cards: [Card]) -> [Card] {
        Array(cards.filter { $0.kind != .report || !$0.options.isEmpty }.reversed())
    }

    /// Whether newly-arrived cards are worth opening the island for: one with
    /// nothing to decide is a notice and waits to be found.
    static func shouldOpen(for fresh: [Card]) -> Bool {
        fresh.contains { !$0.options.isEmpty }
    }

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
    var onOptionTapped: ((_ card: Card, _ optionText: String) -> Void)?
    /// Jump to the pane that raised a suggestion without resolving the card.
    var onRevealSuggestion: ((_ card: Card) -> Void)?
    /// Dismiss a suggestion card without acting on it.
    var onDismissOrder: ((_ card: Card) -> Void)?
    /// Bridge command submit (same handler as the First Mate composer).
    var onSubmitCommand: ((String) -> Void)?
    /// `/ @ #` autocomplete source — same provider as the cockpit composer.
    var commandMenuProvider: ((Character, String) -> [(name: String, desc: String)])?
    /// One-shot: when set, the opened surface prefills the command field with
    /// this text, focuses it, then clears the flag.
    var pendingCommandPrefill: String?
    /// One-shot: focus the command field without changing its text (Cmd+P).
    var pendingCommandFocus: Bool = false

    private var popRevertWork: DispatchWorkItem?
    private var usageRotationTimer: Timer?

    var isOpened: Bool { state == .opened }

    deinit {
        usageRotationTimer?.invalidate()
    }

    /// Open on `page`, or by the queue: cards waiting → the cards, else the
    /// conversation.
    func open(reason: IslandOpenReason, page: IslandPage? = nil) {
        popRevertWork?.cancel()
        popRevertWork = nil
        openReason = reason
        self.page = page ?? (orders.isEmpty ? .conversation : .suggestions)
        state = .opened
    }

    /// Esc: from the conversation back to the cards when there are any, else
    /// shut. False when there was nothing to do.
    func escape() -> Bool {
        guard isOpened else { return false }
        if page == .conversation, !orders.isEmpty {
            page = .suggestions
        } else {
            close()
        }
        return true
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

    /// Opened list: group by repo, attention-first within each group.
    /// Projects themselves sort by their hottest status so a flaming seahelm
    /// group floats above a quiet saas-mono block.
    var projectGroups: [IslandProjectGroup] {
        Self.groupedByProject(rows)
    }

    static func groupedByProject(_ rows: [IslandAgentRow]) -> [IslandProjectGroup] {
        var order: [String] = []
        var buckets: [String: [IslandAgentRow]] = [:]
        for row in rows {
            if buckets[row.project] == nil {
                order.append(row.project)
                buckets[row.project] = []
            }
            buckets[row.project, default: []].append(row)
        }
        let groups = order.map { project -> IslandProjectGroup in
            let sorted = (buckets[project] ?? []).sorted {
                if statusRank($0.status) != statusRank($1.status) {
                    return statusRank($0.status) > statusRank($1.status)
                }
                return ($0.branch, $0.id) < ($1.branch, $1.id)
            }
            return IslandProjectGroup(id: project, project: project, rows: sorted)
        }
        return groups.sorted {
            let lhs = $0.rows.map { statusRank($0.status) }.max() ?? 0
            let rhs = $1.rows.map { statusRank($0.status) }.max() ?? 0
            if lhs != rhs { return lhs > rhs }
            return $0.project < $1.project
        }
    }

    static func statusRank(_ s: AgentStatus) -> Int {
        switch s {
        case .error: return 5
        case .waiting: return 4
        case .running: return 3
        case .idle: return 2
        case .exited: return 1
        case .unknown: return 0
        }
    }

    private func statusRank(_ s: AgentStatus) -> Int { Self.statusRank(s) }
}
