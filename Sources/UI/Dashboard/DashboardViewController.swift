import AppKit
import QuartzCore

// MARK: - DashboardDelegate

protocol DashboardDelegate: AnyObject {
    func dashboardDidSelectProject(_ project: String, thread: String)
    func dashboardDidRequestEnterProject(_ project: String)
    func dashboardDidReorderCards(order: [String])
    func dashboardDidRequestDelete(_ terminalID: String)
    func dashboardDidRequestCloseRepo(_ project: String)
    func dashboardDidRequestAddProject()
    func dashboardDidChangeSelection(_ dashboard: DashboardViewController)
    func dashboardDidRequestBrowseFiles(worktreePath: String)
    func dashboardDidRequestShowChanges(worktreePath: String)
}

// MARK: - SailorDisplayInfo

struct SailorDisplayInfo {
    let id: String          // terminal ID (from Station.id)
    let name: String        // display name like "Agent-Alpha"
    let project: String     // repo display name
    let thread: String      // branch name
    let paneStatuses: [SailorStatus]     // per-pane statuses
    let mostRecentMessage: String       // message from most recently updated pane
    let lastUserPrompt: String          // most recent user prompt text
    let mostRecentPaneIndex: Int
    let totalDuration: String   // "HH:MM:SS" format
    let roundDuration: String   // "HH:MM:SS" format
    let station: Station
    let worktreePath: String    // needed to lazily create the terminal
    let paneCount: Int          // number of split panes (1 = no badge)
    let paneStations: [Station]  // all pane stations in leaf order
    let isMainWorktree: Bool    // true = base repo, false = git worktree
    let tasks: [TaskItem]              // webhook-tracked task items
    let activityEvents: [ActivityEvent]

    /// Convenience: primary status string for display (first pane's status)
    var status: String {
        (paneStatuses.first ?? .unknown).rawValue.lowercased()
    }

    /// Convenience: backward-compatible lastMessage
    var lastMessage: String {
        mostRecentMessage
    }
}

// MARK: - DashboardViewController

class DashboardViewController: NSViewController, SailorCardDelegate {
    enum LayoutMetrics {
        static let focusPanelCornerRadius: CGFloat = 10
        static let containerHorizontalInset: CGFloat = 0
        static let containerBottomInset: CGFloat = 0
        static let leftRightSidebarTrailingInset: CGFloat = 8
        static let leftColumnWidth: CGFloat = 300
        static let columnSpacing: CGFloat = 8

        static let leftRightFocusMaskedCorners: CACornerMask = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
    }

    private struct FocusLayoutRefs {
        let focusPanel: FocusPanelView
        let scrollView: NSScrollView
        let stack: NSStackView
        var miniCards: [StackedMiniCardContainerView]
    }

    weak var dashboardDelegate: DashboardDelegate?

    /// Set by MainWindowController. Called when the user drills into a terminal so the
    /// keyboard mode can switch to .insert.
    var onEnterTerminal: (() -> Void)?
    /// Set by MainWindowController. Called when the user requests the new-worktree creator.
    var onRequestNewWorktree: (() -> Void)?

    /// Set by TabCoordinator during setup
    weak var stationManager: StationManager?

    /// Set by MainWindowController — forwards split events to TerminalCoordinator
    weak var splitContainerDelegate: SplitContainerDelegate?

    var selectedSailorId: String = ""
    let focusController = DashboardFocusController()
    private var isInDState: Bool { focusController.mode != .idle }

    private var leftColumnWidthExpanded: NSLayoutConstraint?
    private var leftColumnWidthCollapsed: NSLayoutConstraint?
    private var isLeftColumnCollapsed = false
    /// Which of the panes the left column currently shows.
    private var currentLeftPane: LeftPane = .file

    /// Worktree paths idle > 8h — collapsed under the expander in the popover list.
    var idleWorktreePaths: Set<String> = []
    private var worktreeIdleExpanded = false

    var selectedSailorIndex: Int {
        agents.firstIndex(where: { $0.id == selectedSailorId }) ?? 0
    }

    /// Cached SplitContainerView per worktree path
    private var splitContainers: [String: SplitContainerView] = [:]

    /// Currently visible split container in the focus panel
    private(set) var activeSplitContainer: SplitContainerView?

    // Data
    private(set) var agents: [SailorDisplayInfo] = []

    private let layoutTopInset: CGFloat = 8

    // Left-Right layout
    private let leftRightContainer = NSView()
    private let leftRightFocusPanel = FocusPanelView()
    private let leftRightSidebarScroll = NonFirstResponderScrollView()
    private let leftRightSidebarStack = FlippedStackView()
    private var leftRightMiniCards: [StackedMiniCardContainerView] = []
    // The inline worktree creator is no longer shown (the cockpit `/new` command
    // replaces it); the object is kept only so the existing setup/report wiring
    // in MainWindowController still compiles.
    private let inlineCreateView = InlineWorktreeCreateView()
    private var inlineCreateHeightConstraint: NSLayoutConstraint?

    // Left column container — hosts the worktree list, inline create, and the
    // bridge/file/change side panel (one pane visible at a time).
    private let leftColumnContainer = NSView()
    private(set) lazy var sidePanelVC: WorktreeSidePanelViewController = {
        let vc = WorktreeSidePanelViewController(worktreePath: nil, initialTab: .files)
        vc.delegate = self
        return vc
    }()

    // Center overlay
    private var centerOverlay: CenterOverlayView?

    // Helm cockpit (WP-2) — bottom-center radar orb + floating command center,
    // layered on top of everything. Fed the live queue/feed by MainWindowController.
    private(set) lazy var helmCockpit = HelmCockpitController()

    // Empty state
    private let emptyStateView = NSView()

    // MARK: - First responder

    override var acceptsFirstResponder: Bool { isInDState }

    // MARK: - View lifecycle

    override func loadView() {
        let root = DashboardRootView()
        root.wantsLayer = true
        root.setAccessibilityIdentifier("dashboard.view")
        self.view = root

        setupEmptyState()
        setupLeftRightLayout()

        // Show the 3-column layout immediately; hide empty state
        leftRightContainer.isHidden = false

        // The Helm cockpit is installed by MainWindowController into the window
        // content view (so the orb can sit over the status bar), not here.
    }

    /// Layer the Helm cockpit on top of `host`, spanning from `top` down to the
    /// host bottom. MainWindowController passes the window content view + the
    /// content-container top, so the cockpit covers the dashboard AND the status
    /// bar — letting the radar orb bottom-align with the status bar.
    /// Its passthrough container forwards clicks everywhere except the orb/panel.
    func installCockpit(in host: NSView, top: NSLayoutYAxisAnchor) {
        addChild(helmCockpit)
        helmCockpit.view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(helmCockpit.view)
        NSLayoutConstraint.activate([
            helmCockpit.view.topAnchor.constraint(equalTo: top),
            helmCockpit.view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            helmCockpit.view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            helmCockpit.view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
    }

    // MARK: - Public API

    func updateSailors(_ newSailors: [SailorDisplayInfo]) {
        let oldIds = Set(agents.map { $0.id })
        let newIds = Set(newSailors.map { $0.id })
        let structureChanged = oldIds != newIds

        #if DEBUG
        if structureChanged, !oldIds.isEmpty {
            let added = newIds.subtracting(oldIds)
            let removed = oldIds.subtracting(newIds)
            NSLog("DashboardVC.updateSailors: structureChanged — added=%@ removed=%@", "\(added)", "\(removed)")
        }
        #endif

        agents = newSailors

        if isInDState {
            focusController.refreshCards(agents.map { $0.id })
            applyKeyboardFocusVisuals()
        }

        // Show empty state when no agents
        if agents.isEmpty {
            emptyStateView.isHidden = false
            leftRightContainer.isHidden = true
            sidePanelVC.setWorktree(nil)
            return
        } else {
            emptyStateView.isHidden = true
            leftRightContainer.isHidden = false
        }

        // Validate selectedSailorId
        if !agents.contains(where: { $0.id == selectedSailorId }) {
            selectedSailorId = agents.first?.id ?? ""
        }

        if structureChanged {
            rebuildFocusLayout()
        } else {
            updateFocusLayoutInPlace(agents, miniCards: focusLayoutRefs.miniCards, focusPanel: focusLayoutRefs.focusPanel)
        }
        syncSidePanelToSelection()
    }

    private func syncSidePanelToSelection() {
        let path = agents.first(where: { $0.id == selectedSailorId })?.worktreePath
        sidePanelVC.setWorktree(path)
    }

    private func updateFocusLayoutInPlace(_ sorted: [SailorDisplayInfo], miniCards: [StackedMiniCardContainerView], focusPanel: FocusPanelView) {
        // Count mismatch means structure changed — handled by structureChanged check in updateSailors
        guard sorted.count == miniCards.count else { return }

        // Re-embed split container if it was detached (e.g. after tab switch),
        // but only when the dashboard is actually visible.
        // Skip if a terminal already has focus — avoids stealing focus during
        // periodic updates (branch refresh, status polling).
        if activeSplitContainer == nil, view.window != nil,
           !(view.window?.firstResponder is GhosttyNSView) {
            embedSplitContainerForSelectedSailor()
        }
        for (index, agent) in sorted.enumerated() {
            miniCards[index].configure(paneCount: agent.paneCount)
            miniCards[index].layoutChildren()
            WorktreeTitleCache.shared.title(worktreePath: agent.worktreePath, lastUserPrompt: agent.lastUserPrompt, branch: agent.thread) { _ in }
            miniCards[index].miniCardView.configure(
                id: agent.id,
                project: agent.project,
                thread: agent.thread,
                status: agent.status,
                lastMessage: agent.lastMessage,
                lastUserPrompt: WorktreeTitleCache.shared.cachedTitle(worktreePath: agent.worktreePath) ?? agent.lastUserPrompt,
                totalDuration: agent.totalDuration,
                roundDuration: agent.roundDuration,
                paneStatuses: agent.paneStatuses,
                isMainWorktree: agent.isMainWorktree,
                tasks: agent.tasks,
                activityEvents: agent.activityEvents,
                agentType: WorktreeSailorTypeStore.shared.agentType(forWorktree: agent.worktreePath)
                    ?? ShipLog.shared.sailor(forWorktree: agent.worktreePath)?.agentType ?? .unknown
            )
            miniCards[index].isSelected = (agent.id == selectedSailorId)
        }
    }

    func detachTerminals() {
        activeSplitContainer?.removeFromSuperview()
        activeSplitContainer = nil
        activeSplitWorktreePath = nil
    }

    func selectSailor(byWorktreePath path: String) {
        guard let agent = agents.first(where: { $0.worktreePath == path }) else { return }
        selectedSailorId = agent.id
        detachTerminals()
        embedSplitContainerForSelectedSailor()
        updateMiniCardSelection()
        syncSidePanelToSelection()
    }

    var isLeftColumnCollapsedState: Bool { isLeftColumnCollapsed }

    @discardableResult
    func toggleLeftColumnCollapse() -> Bool {
        isLeftColumnCollapsed.toggle()
        leftColumnWidthExpanded?.isActive = !isLeftColumnCollapsed
        leftColumnWidthCollapsed?.isActive = isLeftColumnCollapsed
        animateColumnLayout {
            self.leftColumnContainer.animator().alphaValue = self.isLeftColumnCollapsed ? 0 : 1
        }
        return isLeftColumnCollapsed
    }

    /// Switch the left column between its four panes. Driven by the title-bar
    /// pane-switch icons. Expands the column first if it was collapsed.
    func selectLeftPane(_ pane: LeftPane) {
        currentLeftPane = pane

        switch pane {
        case .bridge:   sidePanelVC.selectTab(.files)  // legacy enum value — bridge tab removed
        case .file:     sidePanelVC.selectTab(.files)
        case .change:   sidePanelVC.selectTab(.changes)
        }

        guard isLeftColumnCollapsed else { return }
        isLeftColumnCollapsed = false
        leftColumnWidthExpanded?.isActive = true
        leftColumnWidthCollapsed?.isActive = false
        animateColumnLayout {
            self.leftColumnContainer.animator().alphaValue = 1
        }
    }

    // MARK: - Worktree popover

    private lazy var worktreePopover: NSPopover = {
        let pop = NSPopover()
        pop.behavior = .transient
        let vc = NSViewController()
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 520))
        host.addSubview(leftRightSidebarScroll)
        NSLayoutConstraint.activate([
            host.widthAnchor.constraint(equalToConstant: 320),
            host.heightAnchor.constraint(equalToConstant: 520),
            leftRightSidebarScroll.topAnchor.constraint(equalTo: host.topAnchor, constant: 8),
            leftRightSidebarScroll.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 8),
            leftRightSidebarScroll.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -8),
            leftRightSidebarScroll.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -8),
        ])
        vc.view = host
        pop.contentViewController = vc
        return pop
    }()

    /// Toggle the worktree list popover anchored to the title-bar worktree icon.
    func toggleWorktreePopover(from sourceView: NSView) {
        if worktreePopover.isShown {
            worktreePopover.close()
        } else {
            populateWorktreeCards()
            worktreePopover.show(relativeTo: sourceView.bounds, of: sourceView, preferredEdge: .maxY)
        }
    }

    func closeWorktreePopover() {
        if worktreePopover.isShown { worktreePopover.close() }
    }

    /// Fleet status line was removed with the left bottom bar; kept as a no-op so
    /// the existing caller compiles. (Could move into the status bar later.)
    func updateFleetSummary(repos: Int, worktrees: Int, hidden: Int) {}

    private func animateColumnLayout(_ extra: @escaping () -> Void) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.allowsImplicitAnimation = true
            extra()
            self.view.layoutSubtreeIfNeeded()
        }
    }

    // MARK: - Inline worktree creation

    func setupInlineCreate(repoPaths: [String],
                           repoPathsProvider: @escaping () -> [String],
                           onAddRepo: @escaping () -> Void,
                           onSubmitCommand: @escaping (String) -> Void,
                           onCreate: @escaping (String, String, SailorType, Bool) -> Void) {
        inlineCreateView.configure(repoPaths: repoPaths)
        inlineCreateView.repoPathsProvider = repoPathsProvider
        inlineCreateView.onAddRepo = onAddRepo
        inlineCreateView.onSubmitCommand = onSubmitCommand
        inlineCreateView.onCreate = onCreate
    }

    func focusInlineCreate() {
        // New-worktree creation moved to the Helm cockpit: open it with `/new `
        // prefilled so the user types the task and submits.
        helmCockpit.openWithCommand("/new ")
    }

    /// Called when the inline create form ends (submit or cancel) so the owner
    /// can exit `.createForm` and restore the nav ring.
    var onInlineCreateFormEnd: (() -> Void)? {
        didSet { inlineCreateView.onFormEnd = onInlineCreateFormEnd }
    }

    func inlineCreateReportSuccess() { inlineCreateView.reportCreateSuccess() }
    func inlineCreateReportFailure(_ message: String) { inlineCreateView.reportCreateFailure(message) }

    // MARK: - Sorting

    private func sortedAgents() -> [SailorDisplayInfo] {
        agents.sorted { a, b in
            statusOrder(a.status) < statusOrder(b.status)
        }
    }

    private func statusOrder(_ status: String) -> Int {
        switch status.lowercased() {
        case "waiting": return 0
        case "running": return 1
        default: return 2
        }
    }

    // MARK: - Layout

    private var focusLayoutRefs: FocusLayoutRefs {
        FocusLayoutRefs(focusPanel: leftRightFocusPanel, scrollView: leftRightSidebarScroll, stack: leftRightSidebarStack, miniCards: leftRightMiniCards)
    }

    private func rebuildFocusLayout() {
        if let selected = agents.first(where: { $0.id == selectedSailorId }) ?? agents.first {
            selectedSailorId = selected.id
            // Only embed when the dashboard is visible to avoid stealing
            // surfaces from the active repo tab's split container.
            if view.window != nil {
                embedSplitContainerForSelectedSailor()
            }
        }
        populateWorktreeCards()
    }

    /// Build the worktree mini-card list (popover content). Idle worktrees
    /// (in `idleWorktreePaths`) collapse below a "N hidden" expander row.
    private func populateWorktreeCards() {
        let refs = focusLayoutRefs
        refs.miniCards.forEach { $0.removeFromSuperview() }
        refs.stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        guard !agents.isEmpty else { leftRightMiniCards = []; return }

        let fixedWidth = refs.scrollView.bounds.width > 0 ? refs.scrollView.bounds.width : 304

        // One card per agent, kept parallel to `agents` for in-place updates.
        let cards = agents.map { makeMiniCard(for: $0, width: fixedWidth) }
        leftRightMiniCards = cards

        let activeCards = zip(agents, cards).filter { !idleWorktreePaths.contains($0.0.worktreePath) }.map(\.1)
        let idleCards = zip(agents, cards).filter { idleWorktreePaths.contains($0.0.worktreePath) }.map(\.1)

        activeCards.forEach { refs.stack.addArrangedSubview($0) }
        if !idleCards.isEmpty {
            refs.stack.addArrangedSubview(makeIdleExpanderRow(hiddenCount: idleCards.count, width: fixedWidth))
            if worktreeIdleExpanded {
                idleCards.forEach { refs.stack.addArrangedSubview($0) }
            }
        }
    }

    private func makeMiniCard(for agent: SailorDisplayInfo, width: CGFloat) -> StackedMiniCardContainerView {
        let container = StackedMiniCardContainerView()
        container.delegate = self
        container.reorderDelegate = self
        container.configure(paneCount: agent.paneCount)
        WorktreeTitleCache.shared.title(worktreePath: agent.worktreePath, lastUserPrompt: agent.lastUserPrompt, branch: agent.thread) { _ in }
        container.miniCardView.configure(
            id: agent.id, project: agent.project, thread: agent.thread,
            status: agent.status, lastMessage: agent.lastMessage,
            lastUserPrompt: WorktreeTitleCache.shared.cachedTitle(worktreePath: agent.worktreePath) ?? agent.lastUserPrompt,
            totalDuration: agent.totalDuration, roundDuration: agent.roundDuration,
            paneStatuses: agent.paneStatuses,
            isMainWorktree: agent.isMainWorktree,
            tasks: agent.tasks,
            activityEvents: agent.activityEvents,
            agentType: WorktreeSailorTypeStore.shared.agentType(forWorktree: agent.worktreePath)
                ?? ShipLog.shared.sailor(forWorktree: agent.worktreePath)?.agentType ?? .unknown
        )
        container.isSelected = (agent.id == selectedSailorId)
        container.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: width),
            container.heightAnchor.constraint(equalToConstant: 84),
        ])
        return container
    }

    private func makeIdleExpanderRow(hiddenCount: Int, width: CGFloat) -> NSView {
        let title = worktreeIdleExpanded
            ? "▾ Hide \(hiddenCount) idle"
            : "▸ \(hiddenCount) idle worktree\(hiddenCount == 1 ? "" : "s")"
        let btn = NSButton(title: title, target: self, action: #selector(toggleWorktreeIdleExpanded))
        btn.isBordered = false
        btn.bezelStyle = .recessed
        btn.contentTintColor = Theme.textSecondary
        btn.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        btn.alignment = .left
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.setAccessibilityIdentifier("worktree.idleExpander")
        NSLayoutConstraint.activate([
            btn.widthAnchor.constraint(equalToConstant: width),
            btn.heightAnchor.constraint(equalToConstant: 26),
        ])
        return btn
    }

    @objc private func toggleWorktreeIdleExpanded() {
        worktreeIdleExpanded.toggle()
        populateWorktreeCards()
    }

    // MARK: - Setup: Empty State

    private func setupEmptyState() {
        emptyStateView.translatesAutoresizingMaskIntoConstraints = false
        emptyStateView.isHidden = true
        view.addSubview(emptyStateView)

        // Folder icon button
        let button = NSButton()
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.title = ""
        if let folderImage = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: "Open Folder") {
            let config = NSImage.SymbolConfiguration(pointSize: 48, weight: .light)
            button.image = folderImage.withSymbolConfiguration(config)
        }
        button.contentTintColor = .secondaryLabelColor
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(emptyStateAddProjectClicked)
        button.setAccessibilityIdentifier("dashboard.emptyState.addButton")
        emptyStateView.addSubview(button)

        // Subtitle label
        let label = NSTextField(labelWithString: "Add a workspace to get started")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 14)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        emptyStateView.addSubview(label)

        NSLayoutConstraint.activate([
            emptyStateView.topAnchor.constraint(equalTo: view.topAnchor),
            emptyStateView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emptyStateView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyStateView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            button.centerXAnchor.constraint(equalTo: emptyStateView.centerXAnchor),
            button.centerYAnchor.constraint(equalTo: emptyStateView.centerYAnchor, constant: -16),

            label.topAnchor.constraint(equalTo: button.bottomAnchor, constant: 12),
            label.centerXAnchor.constraint(equalTo: emptyStateView.centerXAnchor),
        ])
    }

    @objc private func emptyStateAddProjectClicked() {
        dashboardDelegate?.dashboardDidRequestAddProject()
    }

    // MARK: - Setup: Left-Right

    private func setupLeftRightLayout() {
        leftRightContainer.translatesAutoresizingMaskIntoConstraints = false
        leftRightContainer.wantsLayer = true
        leftRightContainer.isHidden = true
        leftRightContainer.setAccessibilityIdentifier("dashboard.layout.left-right")
        leftRightContainer.setAccessibilityElement(true)
        view.addSubview(leftRightContainer)

        // --- Left column container: hosts worktree list + inline create + side panel ---
        leftColumnContainer.translatesAutoresizingMaskIntoConstraints = false
        leftColumnContainer.wantsLayer = true
        leftColumnContainer.layer?.cornerRadius = LayoutMetrics.focusPanelCornerRadius
        leftColumnContainer.layer?.masksToBounds = true
        leftColumnContainer.setAccessibilityIdentifier("dashboard.leftColumn")
        leftRightContainer.addSubview(leftColumnContainer)

        // Worktree list (now hosted in a title-bar popover, not the left column).
        leftRightSidebarScroll.translatesAutoresizingMaskIntoConstraints = false
        leftRightSidebarScroll.hasVerticalScroller = true
        leftRightSidebarScroll.scrollerStyle = .overlay
        leftRightSidebarScroll.drawsBackground = false
        leftRightSidebarScroll.borderType = .noBorder

        leftRightSidebarStack.orientation = .vertical
        leftRightSidebarStack.spacing = 8
        leftRightSidebarStack.alignment = .leading
        leftRightSidebarStack.translatesAutoresizingMaskIntoConstraints = false
        leftRightSidebarScroll.documentView = leftRightSidebarStack

        // The First Mate bottom bar (fleet status + task input) was removed — the
        // command line now lives in the Helm cockpit (`/new` creates worktrees).

        // File/change side panel — fills the column, hidden until selected.
        addChild(sidePanelVC)
        sidePanelVC.view.translatesAutoresizingMaskIntoConstraints = false
        leftColumnContainer.addSubview(sidePanelVC.view)

        // --- Center column: focus panel ---
        leftRightFocusPanel.translatesAutoresizingMaskIntoConstraints = false
        leftRightFocusPanel.setCornerMask(
            [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner],
            radius: 0
        )
        leftRightContainer.addSubview(leftRightFocusPanel)

        let spacing = LayoutMetrics.columnSpacing
        let edge: CGFloat = 8

        // Fixed width for the left column; centre fills the rest. The column
        // starts collapsed (hidden) — the user reveals it with Cmd+B / the
        // title-bar pane icons.
        leftColumnWidthExpanded = leftColumnContainer.widthAnchor.constraint(equalToConstant: LayoutMetrics.leftColumnWidth)
        leftColumnWidthCollapsed = leftColumnContainer.widthAnchor.constraint(equalToConstant: 0)
        leftColumnWidthCollapsed?.isActive = true
        isLeftColumnCollapsed = true
        leftColumnContainer.alphaValue = 0

        NSLayoutConstraint.activate([
            leftRightContainer.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: layoutTopInset),
            leftRightContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: LayoutMetrics.containerHorizontalInset),
            leftRightContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -LayoutMetrics.containerHorizontalInset),
            leftRightContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -LayoutMetrics.containerBottomInset),

            // Left column container — flush to the window's left edge, so when it
            // collapses (width 0) the centre terminal sits flush left too (no strip).
            leftColumnContainer.topAnchor.constraint(equalTo: leftRightContainer.topAnchor),
            leftColumnContainer.leadingAnchor.constraint(equalTo: leftRightContainer.leadingAnchor),
            leftColumnContainer.bottomAnchor.constraint(equalTo: leftRightContainer.bottomAnchor),

            // Side panel fills the whole column now that the bottom bar is gone.
            sidePanelVC.view.topAnchor.constraint(equalTo: leftColumnContainer.topAnchor),
            sidePanelVC.view.leadingAnchor.constraint(equalTo: leftColumnContainer.leadingAnchor),
            sidePanelVC.view.trailingAnchor.constraint(equalTo: leftColumnContainer.trailingAnchor),
            sidePanelVC.view.bottomAnchor.constraint(equalTo: leftColumnContainer.bottomAnchor),

            // Centre terminal panel: flush to left/right/bottom — no gap, no card.
            leftRightFocusPanel.topAnchor.constraint(equalTo: leftRightContainer.topAnchor),
            leftRightFocusPanel.leadingAnchor.constraint(equalTo: leftColumnContainer.trailingAnchor),
            leftRightFocusPanel.bottomAnchor.constraint(equalTo: leftRightContainer.bottomAnchor),
            leftRightFocusPanel.trailingAnchor.constraint(equalTo: leftRightContainer.trailingAnchor),
        ])

        // Pre-select the Files pane WITHOUT expanding the column (it stays
        // collapsed by default; selectLeftPane would force-expand it).
        currentLeftPane = .file
        sidePanelVC.selectTab(.files)
    }

    private func setInlineCreateHeight(_ height: CGFloat, animated: Bool) {
        guard let constraint = inlineCreateHeightConstraint else { return }
        guard abs(constraint.constant - height) > 0.5 else { return }

        let layout = {
            constraint.constant = height
            self.view.layoutSubtreeIfNeeded()
        }

        guard animated, view.window != nil else {
            layout()
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            layout()
        }
    }

    // MARK: - Split container embedding

    private var activeSplitWorktreePath: String?

    /// Embed the selected agent's split container into the focus panel.
    /// `focusTerminal: false` is used for live nav preview — it keeps the dashboard
    /// VC as first responder so arrow keys keep driving the nav ring.
    func embedSplitContainerForSelectedSailor(focusTerminal: Bool = true) {
        let container = focusLayoutRefs.focusPanel.terminalContainer

        guard let agent = agents.first(where: { $0.id == selectedSailorId }) ?? agents.first else { return }
        let worktreePath = agent.worktreePath

        // Skip re-embed if the same split container is already active for this worktree
        if let active = activeSplitContainer,
           active.superview === container,
           activeSplitWorktreePath == worktreePath {
            return
        }

        // Hold reference to previous view for crossfade
        let previousSplitView = activeSplitContainer
        activeSplitContainer = nil
        activeSplitWorktreePath = nil

        // Get or create SplitContainerView
        let splitView: SplitContainerView
        if let cached = splitContainers[worktreePath] {
            splitView = cached
        } else {
            splitView = SplitContainerView(frame: container.bounds)
            splitView.delegate = splitContainerDelegate
            splitContainers[worktreePath] = splitView
        }

        // Populate surface views from StationRegistry
        guard let tree = stationManager?.tree(forPath: worktreePath) else { return }
        var surfaceViews: [String: NSView] = [:]
        for leaf in tree.allLeaves {
            if let station = StationRegistry.shared.station(forId: leaf.stationId) {
                // Ensure station is created
                if station.surface == nil {
                    let stationId = leaf.stationId
                    _ = station.create(in: container, workingDirectory: worktreePath, sessionName: station.sessionName) { [weak splitView] in
                        // Async backend (tmux): register the view once creation finishes
                        guard let splitView, let termView = station.view else { return }
                        splitView.surfaceViews[stationId] = termView
                        splitView.layoutTree()
                    }
                }
                if let termView = station.view {
                    surfaceViews[leaf.stationId] = termView
                }
            }
        }
        splitView.surfaceViews = surfaceViews

        // Embed
        splitView.frame = container.bounds
        splitView.autoresizingMask = [.width, .height]
        container.addSubview(splitView)
        splitView.tree = tree
        activeSplitContainer = splitView
        activeSplitWorktreePath = worktreePath

        previousSplitView?.removeFromSuperview()
        previousSplitView?.alphaValue = 1
        syncSidePanelToSelection()

        // Focus the active leaf — defer to let the view hierarchy settle.
        // Skipped during nav preview so the dashboard VC keeps first responder.
        guard focusTerminal else { return }

        // A terminal is becoming the active surface outside the nav ring (e.g. initial
        // launch embed): the controller must be in .insert so Cmd+Esc can switch back
        // to NORMAL. In-nav commits leave this to exitDashboardNavigation().
        if !isInDState {
            windowKeyboardMode?.enterInsert()
        }

        let leafToFocus = tree.allLeaves.first(where: { $0.id == tree.focusedId }) ?? tree.allLeaves.first
        if let leaf = leafToFocus,
           let station = StationRegistry.shared.station(forId: leaf.stationId),
           let termView = station.view {
            // Immediate attempt (works when hierarchy is stable)
            termView.window?.makeFirstResponder(termView)
            // Deferred attempt (catches cases where the hierarchy hasn't settled yet)
            DispatchQueue.main.async {
                if !(termView.window?.firstResponder is GhosttyNSView) {
                    termView.window?.makeFirstResponder(termView)
                }
            }
        }
    }

    func invalidateSplitContainer(forPath path: String) {
        let container = splitContainers[path]
        container?.removeFromSuperview()
        if activeSplitContainer === container {
            activeSplitContainer = nil
            activeSplitWorktreePath = nil
        }
        splitContainers.removeValue(forKey: path)
    }

    // MARK: - Dashboard Navigation (D-state)

    func enterDashboardNavigation() {
        guard !isInDState else { return }

        // Nav ring active ⇔ keyboardMode .normal. Idempotent; also clears any stale substate.
        windowKeyboardMode?.enterNormal()

        let snapshot = DashboardFocusController.Snapshot(
            firstResponder: view.window?.firstResponder,
            focusedWorktreePath: agents.first(where: { $0.id == selectedSailorId })?.worktreePath
        )
        focusController.captureSnapshot(snapshot)

        let cardIds = agents.map { $0.id }
        let initial = snapshot.focusedWorktreePath
            .flatMap { path in agents.first(where: { $0.worktreePath == path })?.id }
            ?? (selectedSailorId.isEmpty ? nil : selectedSailorId)
        focusController.enterFocusLayout(cardIds: cardIds, initialId: initial)

        view.window?.makeFirstResponder(self)
        applyKeyboardFocusVisuals()
        applyDimOverlayIfNeeded()
    }

    func exitDashboardNavigation(restoreSnapshot: Bool) {
        guard isInDState else { return }

        // Ring is going away: clear any pending delete (guarded no-op otherwise), then
        // assert insert since focus lands on a terminal. Do NOT clear .createForm here.
        windowKeyboardMode?.cancelDelete()
        windowKeyboardMode?.enterInsert()

        let snapshot = focusController.snapshot
        tearDownNavVisuals()

        // A cancelling exit (Esc) undoes any live preview by restoring the pre-nav
        // selection. A committing exit (Return) keeps whatever is currently previewed.
        if restoreSnapshot,
           let path = snapshot?.focusedWorktreePath,
           let original = agents.first(where: { $0.worktreePath == path }),
           original.id != selectedSailorId {
            selectSailor(byWorktreePath: path)
        }

        if restoreSnapshot, let snap = snapshot, let responder = snap.firstResponder,
           (responder as? NSView)?.window != nil {
            view.window?.makeFirstResponder(responder)
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self, let container = self.activeSplitContainer, let tree = container.tree else { return }
                let focusedId = tree.focusedId
                if let leaf = tree.allLeaves.first(where: { $0.id == focusedId }),
                   let termView = container.surfaceViews[leaf.stationId] {
                    self.view.window?.makeFirstResponder(termView)
                }
            }
        }
    }

    /// Leave the nav focus ring WITHOUT touching `windowKeyboardMode`: opens the inline
    /// create form. `beginCreateForm()` has already set `.normal` + `.createForm`; we only
    /// drop the D-state focus ring so a stray key in the form can't be read as a nav chord
    /// (e.g. `d` starting a delete). On form end, `enterDashboardNavigation()` re-enters.
    func exitNavForCreateForm() {
        guard isInDState else { return }
        tearDownNavVisuals()
    }

    /// Visual/state teardown shared by `exitDashboardNavigation` and `exitNavForCreateForm`.
    /// Drops the focus ring, dim overlays, and exits the focus controller. Deliberately does
    /// NOT touch `windowKeyboardMode` or restore the first responder — callers own those decisions.
    private func tearDownNavVisuals() {
        focusController.exit()
        clearKeyboardFocusVisuals()
        clearDimOverlay()
    }

    // MARK: - D-state visual helpers

    private func applyKeyboardFocusVisuals() {
        clearKeyboardFocusVisuals()
        let refs = focusLayoutRefs
        switch focusController.focusedTarget {
        case .none: return
        case .bigPanel:
            refs.focusPanel.isKeyboardFocused = true
        case .card(let agentId):
            refs.miniCards.first(where: { $0.agentId == agentId })?.miniCardView.isKeyboardFocused = true
        }
    }

    private func clearKeyboardFocusVisuals() {
        let refs = focusLayoutRefs
        refs.focusPanel.isKeyboardFocused = false
        refs.miniCards.forEach { $0.miniCardView.isKeyboardFocused = false }
    }

    private func applyDimOverlayIfNeeded() {
        let refs = focusLayoutRefs
        refs.focusPanel.showDimOverlay(opacity: 0.05)
        refs.miniCards.forEach { $0.miniCardView.showDimOverlay(opacity: 0.05) }
    }

    private func clearDimOverlay() {
        let refs = focusLayoutRefs
        refs.focusPanel.hideDimOverlay()
        refs.miniCards.forEach { $0.miniCardView.hideDimOverlay() }
    }

    // MARK: - D-state key handling

    override func keyDown(with event: NSEvent) {
        guard isInDState else { super.keyDown(with: event); return }
        let mode = windowKeyboardMode
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // deletePending: d/y confirm, esc/other cancel
        if case .deletePending(let agentId) = mode?.substate {
            if event.keyCode == 53 { mode?.cancelDelete(); applyKeyboardFocusVisuals(); return }
            if let ch = event.charactersIgnoringModifiers, ch == "d" || ch == "y" {
                if mode?.confirmDelete() == agentId { performDelete(agentId: agentId) }
                return
            }
            mode?.cancelDelete(); applyKeyboardFocusVisuals(); return
        }

        // Helm cockpit keys (NORMAL mode). space toggles the cockpit, ? the help
        // overlay; Esc closes the topmost cockpit surface before falling back to
        // the legacy "exit nav" behavior.
        if event.keyCode == 53 {  // Esc
            if helmCockpit.closeTopmost() { return }
        }
        if flags.isDisjoint(with: [.command, .control, .option]) {
            if event.keyCode == 49 {  // space
                helmCockpit.toggleCockpit(); return
            }
            if event.characters == "?" {
                helmCockpit.toggleHelp(); return
            }
        }

        // Escape with no pending → exit nav (legacy behavior)
        if event.keyCode == 53 && flags.isEmpty {
            exitDashboardNavigation(restoreSnapshot: true); return
        }

        // Build chord: printable char with no command/control/option, else keyCode.
        let chord: KeyChord
        if flags.isDisjoint(with: [.command, .control, .option]),
           let ch = event.charactersIgnoringModifiers, ch.count == 1,
           ch.rangeOfCharacter(from: .alphanumerics) != nil {
            chord = KeyChord(char: ch)
        } else {
            chord = KeyChord(keyCode: event.keyCode)
        }

        guard let action = Keymap.action(mode: .normal, chord: chord) else {
            super.keyDown(with: event); return
        }
        dispatch(action)
    }

    private var windowKeyboardMode: KeyboardModeController? {
        (view.window?.windowController as? MainWindowController)?.keyboardMode
    }

    /// The agent currently focused by the nav ring, if a card is focused.
    private var focusedSailor: SailorDisplayInfo? {
        guard case .card(let agentId) = focusController.focusedTarget else { return nil }
        return agents.first(where: { $0.id == agentId })
    }

    private func dispatch(_ action: KeyboardAction) {
        switch action {
        case .moveFocus(let dir):
            focusController.move(dir, columns: 1)
            applyKeyboardFocusVisuals(); scrollFocusedIntoView()
            previewFocusedCard()
        case .jumpToCard(let idx):
            focusController.jump(toIndex: idx)
            applyKeyboardFocusVisuals(); scrollFocusedIntoView()
            previewFocusedCard()
        case .enterTerminal:
            onEnterTerminal?()
            handleReturnInDState()
        case .deleteFocused:
            guard let agent = focusedSailor else { return }
            guard !agent.isMainWorktree else {
                windowKeyboardMode?.flashHint("main worktree 不可删除")
                return
            }
            windowKeyboardMode?.beginDelete(agentId: agent.id)
        case .showChanges:
            guard let agent = focusedSailor else { return }
            dashboardDelegate?.dashboardDidRequestShowChanges(worktreePath: agent.worktreePath)
        case .browseFiles:
            guard let agent = focusedSailor else { return }
            dashboardDelegate?.dashboardDidRequestBrowseFiles(worktreePath: agent.worktreePath)
        case .newWorktree:
            // Leave the D-state focus ring before opening the form so no stale card
            // visuals remain and a stray key in the form isn't read as a nav chord.
            // keyboardMode stays .normal + .createForm (set by beginCreateForm()).
            exitNavForCreateForm()
            onRequestNewWorktree?()
        }
    }

    private func performDelete(agentId: String) {
        dashboardDelegate?.dashboardDidRequestDelete(agentId)
        focusController.removeCurrentCard()
        applyKeyboardFocusVisuals()
    }

    private func handleReturnInDState() {
        switch focusController.focusedTarget {
        case .none:
            exitDashboardNavigation(restoreSnapshot: true)
        case .bigPanel:
            exitDashboardNavigation(restoreSnapshot: false)
        case .card(let agentId):
            guard let agent = agents.first(where: { $0.id == agentId }) else {
                exitDashboardNavigation(restoreSnapshot: true); return
            }
            selectSailor(byWorktreePath: agent.worktreePath)
            exitDashboardNavigation(restoreSnapshot: false)
        }
    }

    private func scrollFocusedIntoView() {
        guard case .card(let agentId) = focusController.focusedTarget else { return }
        let refs = focusLayoutRefs
        if let card = refs.miniCards.first(where: { $0.agentId == agentId }) {
            card.scrollToVisible(card.bounds)
        }
    }

    /// In focus layouts, live-preview the focused mini card in the main panel as the
    /// nav ring moves — the left panel "follows" the selection. The terminal is NOT
    /// focused (the dashboard VC keeps first responder) so arrows keep navigating;
    /// Return then commits via `handleReturnInDState`.
    private func previewFocusedCard() {
        guard case .card(let agentId) = focusController.focusedTarget else { return }
        guard let agent = agents.first(where: { $0.id == agentId }), agent.id != selectedSailorId else { return }

        selectedSailorId = agent.id
        detachTerminals()
        embedSplitContainerForSelectedSailor(focusTerminal: false)
        updateMiniCardSelection()
        // Re-assert nav visuals: embedding mutated the panel's subviews.
        applyKeyboardFocusVisuals()
        applyDimOverlayIfNeeded()
    }

    // MARK: - SailorCardDelegate

    func agentCardClicked(agentId: String) {
        // Mouse click exits D-state — mouse takes over from keyboard.
        if isInDState {
            exitDashboardNavigation(restoreSnapshot: false)
        }
        // Close any open file/diff overlay so the terminal is shown.
        dismissCenterOverlay()
        // Click selects agent and embeds its split container
        detachTerminals()
        selectedSailorId = agentId
        embedSplitContainerForSelectedSailor()
        updateMiniCardSelection()
        syncSidePanelToSelection()
        dashboardDelegate?.dashboardDidChangeSelection(self)
        // Selecting from the worktree popover dismisses it.
        closeWorktreePopover()
    }

    func agentCardDoubleClicked(agentId: String) {
        guard let agent = agents.first(where: { $0.id == agentId }) else { return }
        dashboardDelegate?.dashboardDidSelectProject(agent.project, thread: agent.thread)
    }

    func agentCardDidRequestDelete(agentId: String) {
        dashboardDelegate?.dashboardDidRequestDelete(agentId)
    }

    func agentCardDidRequestCloseRepo(agentId: String) {
        guard let agent = agents.first(where: { $0.id == agentId }) else { return }
        dashboardDelegate?.dashboardDidRequestCloseRepo(agent.project)
    }

    func agentCardDidRequestBrowseFiles(agentId: String) {
        guard let agent = agents.first(where: { $0.id == agentId }) else { return }
        dashboardDelegate?.dashboardDidRequestBrowseFiles(worktreePath: agent.worktreePath)
    }

    func agentCardDidRequestShowChanges(agentId: String) {
        guard let agent = agents.first(where: { $0.id == agentId }) else { return }
        dashboardDelegate?.dashboardDidRequestShowChanges(worktreePath: agent.worktreePath)
    }

    private func updateMiniCardSelection() {
        let refs = focusLayoutRefs
        for card in refs.miniCards {
            card.isSelected = (card.agentId == selectedSailorId)
        }
    }
}

// MARK: - Dashboard Root View (resolves bg color via updateLayer)

private class DashboardRootView: NSView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = resolvedCGColor(SemanticColors.bg)
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

extension DashboardViewController: MiniCardReorderDelegate {
    func miniCardReorderBegan(_ card: StackedMiniCardContainerView) {
        // No-op — visual lift handled by the card itself
    }

    func miniCardReorderEnded(_ card: StackedMiniCardContainerView) {
        let refs = focusLayoutRefs
        // Read the new order from the stack's arrangedSubviews
        let newOrder = refs.stack.arrangedSubviews.compactMap { ($0 as? StackedMiniCardContainerView)?.agentId }
        guard newOrder.count == agents.count else { return }

        // Rebuild agents in the new order
        var reordered: [SailorDisplayInfo] = []
        for id in newOrder {
            if let agent = agents.first(where: { $0.id == id }) {
                reordered.append(agent)
            }
        }
        agents = reordered

        // Sync the stored miniCards array to match the new stack order
        leftRightMiniCards = refs.stack.arrangedSubviews.compactMap { $0 as? StackedMiniCardContainerView }

        // Persist — pass worktree paths directly to avoid ID→ShipLog lookup failures
        dashboardDelegate?.dashboardDidReorderCards(order: agents.map { $0.worktreePath })
    }

    // MARK: - Center Overlay

    /// Shows a full-cover overlay over the center terminal panel.
    /// Any existing overlay is removed first.
    @discardableResult
    func showCenterOverlay(
        _ content: NSView,
        title: String,
        onSave: (() -> Void)? = nil,
        onPreview: (() -> Void)? = nil
    ) -> CenterOverlayView {
        dismissCenterOverlay()

        let overlay = CenterOverlayView(
            title: title, content: content, onSave: onSave, onPreview: onPreview
        ) { [weak self] in
            self?.dismissCenterOverlay()
        }
        overlay.translatesAutoresizingMaskIntoConstraints = false
        leftRightFocusPanel.addSubview(overlay)

        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: leftRightFocusPanel.topAnchor),
            overlay.leadingAnchor.constraint(equalTo: leftRightFocusPanel.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: leftRightFocusPanel.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: leftRightFocusPanel.bottomAnchor),
        ])

        centerOverlay = overlay
        overlay.window?.makeFirstResponder(overlay)
        return overlay
    }

    /// Removes the center overlay and restores first responder to the active terminal pane.
    func dismissCenterOverlay() {
        guard let overlay = centerOverlay else { return }
        overlay.removeFromSuperview()
        centerOverlay = nil

        DispatchQueue.main.async { [weak self] in
            guard let self, let container = self.activeSplitContainer, let tree = container.tree else { return }
            let focusedId = tree.focusedId
            if let leaf = tree.allLeaves.first(where: { $0.id == focusedId }),
               let termView = container.surfaceViews[leaf.stationId] {
                self.view.window?.makeFirstResponder(termView)
            }
        }
    }
}

extension DashboardViewController: StationDelegate {
    func stationDidRecover(_ station: Station) {
        // Only re-embed when the dashboard is visible
        guard view.window != nil else { return }
        // Find the agent whose station recovered
        guard let agent = agents.first(where: { $0.station === station }) else { return }
        // Re-embed the split container for the active agent
        if agent.id == selectedSailorId {
            invalidateSplitContainer(forPath: agent.worktreePath)
            embedSplitContainerForSelectedSailor()
        }
    }

}

// MARK: - WorktreeSidePanelDelegate

extension DashboardViewController: WorktreeSidePanelDelegate {
    func sidePanel(_ vc: WorktreeSidePanelViewController, didSelectFile path: String) {
        let title = URL(fileURLWithPath: path).lastPathComponent

        // Editable, syntax-highlighted editor for UTF-8 text; fall back to the
        // read-only placeholder for binary / oversized files.
        guard let editor = CodeEditorView(path: path) else {
            showCenterOverlay(FileContentView(path: path), title: title)
            return
        }

        weak var overlayRef: CenterOverlayView?
        let overlay = showCenterOverlay(
            editor,
            title: title,
            onSave: { [weak editor] in editor?.save() },
            onPreview: editor.isPreviewable ? { [weak editor] in
                guard let editor else { return }
                overlayRef?.setPreviewing(editor.togglePreview())
            } : nil
        )
        overlayRef = overlay
        editor.onDirtyChange = { [weak overlay] dirty in
            overlay?.setDirty(dirty)
        }
    }

    func sidePanel(_ vc: WorktreeSidePanelViewController, didSelectChange path: String) {
        let worktreePath = agents.first(where: { $0.id == selectedSailorId })?.worktreePath ?? ""
        let title = "Changes: \(URL(fileURLWithPath: path).lastPathComponent)"
        showCenterOverlay(DiffReviewView(worktreePath: worktreePath), title: title)
    }
}

private final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
}

private final class NonFirstResponderStackView: NSStackView {
    override var acceptsFirstResponder: Bool { false }
}

/// NSScrollView that never steals keyboard focus from the terminal.
private final class NonFirstResponderScrollView: NSScrollView {
    override var acceptsFirstResponder: Bool { false }
}
