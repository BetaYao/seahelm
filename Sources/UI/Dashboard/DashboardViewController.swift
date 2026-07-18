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
    let lastActivityAge: String        // "3m"/"2h" since last real activity ("" if unknown)
    let gitStats: WorktreeGitStats?    // diff size + ahead/behind (nil until first resolve)

    /// Rolled-up status for display/grouping: the highest-priority pane, so a
    /// worktree whose first pane is idle but a later pane is running still reads
    /// as running (waiting > error > exited > running > idle). Using `.first`
    /// here made a multi-pane worktree show the first pane's state only.
    var status: String {
        SailorStatus.highestPriority(paneStatuses).rawValue.lowercased()
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

    /// The two keyboard-navigation view modes (the full-bleed overview mode was
    /// removed — the fleet overview only exists docked as the left column now):
    /// - `.split` (mode 2): overview docked as the left column + terminal right,
    ///   keyboard focus stays on the overview ring (terminal live-previews)
    /// - `.terminal` (mode 3): left column collapsed, terminal owns the keyboard
    enum ViewMode: Equatable { case split, terminal }
    private(set) var viewMode: ViewMode = .split
    /// Fired after every view-mode switch (MainWindowController syncs the
    /// keyboard NORMAL/INSERT mode and status-bar hints off this).
    var onViewModeChanged: ((ViewMode) -> Void)?
    /// Last worktree the user actually committed into (split/terminal). Backs the
    /// mode-1 ⇄ mode-2 back-key toggle.
    private(set) var lastCommittedWorktreePath: String?
    /// Fires whenever the lit toolbar tool should change (mode or side switch).
    var onActiveToolChanged: ((TitleBarView.ActiveTool) -> Void)?

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

    private let layoutTopInset: CGFloat = 0

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

    // `?` keyboard cheat-sheet overlay (the floating First Mate cockpit was
    // removed; the command composer lives in the overview now).
    private var helpOverlay: KeyboardHelpOverlay?

    // Fleet overview (spread First Mate). Full-bleed in .overview mode; can also
    // open as a 392pt left side panel over the terminal in .worktree mode.
    private let overviewView = DashboardOverviewView()
    private var firstMateSideOpen = false
    /// Which content the left side column currently shows (.none = collapsed).
    private enum SidePane { case none, firstMate, files, changes }
    private var currentSide: SidePane = .none
    /// The row the user has explicitly clicked in the overview. Empty until the
    /// first click, so nothing is pre-selected (no stale default highlight).
    private var overviewSelectedId: String = ""
    /// Vertical nav ring over the overview (worktree rows → orders row → command
    /// input). Lives here (not in the view) because visuals need `agents`.
    private var overviewFocus = OverviewFocusModel(worktreeCount: 0, orderCount: 0)
    /// Worktree awaiting a debounced terminal preview, and its timer. Walking the
    /// list must not re-parent Metal surfaces on every keystroke — see
    /// `schedulePreview(path:)`.
    private var pendingPreviewPath: String?
    private var previewDebounceWork: DispatchWorkItem?
    /// How long ↑↓ must settle before the terminal actually swaps. Long enough to
    /// coalesce a fast key-repeat burst, short enough to feel live.
    private static let previewDebounce: TimeInterval = 0.12
    private static let firstMateColumnWidth: CGFloat = 392
    private static let overviewSideBg = NSColor(srgbRed: 0x0e/255, green: 0x2d/255, blue: 0x37/255, alpha: 1)

    // Empty state
    private let emptyStateView = NSView()
    /// First-run guide under the empty state's folder button. Only step 1 is
    /// actionable without a repo, so the rest render dimmed until one exists.
    private let emptyStateGuide = NSStackView()
    private var emptyStateGuideRows: [EmptyStateGuideRow] = []
    /// Whether any repo is configured. The empty state shows whenever there are
    /// no agents — which is also true after the last worktree goes away — so the
    /// guide asks this to tell a first launch from a merely empty workspace.
    var hasWorkspaces: () -> Bool = { false }

    // MARK: - First responder

    override var acceptsFirstResponder: Bool { isInDState || viewMode != .terminal }

    // MARK: - View lifecycle

    override func loadView() {
        let root = DashboardRootView()
        root.wantsLayer = true
        root.setAccessibilityIdentifier("dashboard.view")
        self.view = root

        setupEmptyState()
        setupLeftRightLayout()
        sidePanelVC.worktreesTabView = leftRightSidebarScroll

        // Show the 3-column layout immediately; hide empty state
        leftRightContainer.isHidden = false

        // Fleet overview (spread First Mate). Full-bleed in .overview mode; in a
        // worktree it docks into the left column (same region as files/changes,
        // pushing the terminal right — not a floating overlay).
        overviewView.onSelectWorktree = { [weak self] path in
            self?.handleWorktreeRowClick(path: path)
        }
        // Nav-ring ↔ command-field hand-off (see OverviewFocusModel).
        overviewView.onCommandArrowUpAtEmpty = { [weak self] in
            guard let self else { return false }
            let effect = self.overviewFocus.moveUp(commandIsEmpty: true)
            guard case .blurCommandThenLand = effect else { return false }
            self.applyOverviewEffect(effect)
            return true
        }
        overviewView.onCommandEscapeAtEmpty = { [weak self] in
            guard let self else { return }
            self.view.window?.makeFirstResponder(self)
            self.applyOverviewEffect(self.overviewFocus.escapeFromCommand())
        }
        overviewView.onCommandFocused = { [weak self] in
            self?.overviewFocus.noteCommandFocused()
        }
        overviewView.onOrdersChanged = { [weak self] in
            self?.syncOverviewFocusCounts()
        }
    }

    // MARK: - `?` keyboard help overlay

    /// Toggle the `?` keyboard cheat-sheet over the dashboard.
    func toggleHelp() {
        if helpOverlay != nil { dismissHelp(); return }
        let overlay = KeyboardHelpOverlay()
        overlay.onDismiss = { [weak self] in self?.dismissHelp() }
        overlay.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: view.topAnchor),
            overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        helpOverlay = overlay
    }

    private func dismissHelp() {
        helpOverlay?.removeFromSuperview()
        helpOverlay = nil
    }

    /// Close the topmost transient overlay (currently only the help sheet).
    /// Returns true if it dismissed something so the caller stops propagating Esc.
    @discardableResult
    private func closeTopmostOverlay() -> Bool {
        if helpOverlay != nil { dismissHelp(); return true }
        return false
    }

    // MARK: - Public API

    /// `changedWorktreePath` narrows the in-place refresh to one card when the
    /// caller knows only that worktree's status changed; nil refreshes all cards.
    func updateSailors(_ newSailors: [SailorDisplayInfo], changedWorktreePath: String? = nil) {
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

        // Refresh the overview whenever the First Mate side column is on screen.
        // Without this check, an open First Mate sidebar showed the fleet frozen
        // at the state it had when opened.
        if firstMateSideOpen {
            overviewView.selectedId = overviewSelectedId
            overviewView.update(agents)
            syncOverviewFocusCounts()
        }

        if isInDState {
            focusController.refreshCards(agents.map { $0.id })
            applyKeyboardFocusVisuals()
        }

        // Show empty state when no agents
        if agents.isEmpty || DebugFlags.forceEmptyState {
            refreshEmptyStateGuide()
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
            updateFocusLayoutInPlace(agents, miniCards: focusLayoutRefs.miniCards, focusPanel: focusLayoutRefs.focusPanel,
                                     changedWorktreePath: changedWorktreePath)
        }
        syncSidePanelToSelection()
    }

    private func syncSidePanelToSelection() {
        let path = agents.first(where: { $0.id == selectedSailorId })?.worktreePath
        sidePanelVC.setWorktree(path)
    }

    private func updateFocusLayoutInPlace(_ sorted: [SailorDisplayInfo], miniCards: [StackedMiniCardContainerView], focusPanel: FocusPanelView,
                                          changedWorktreePath: String? = nil) {
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
            // Selection highlight is cheap and may change for any card; the full
            // reconfigure below is not — skip cards the caller says didn't change.
            miniCards[index].isSelected = (agent.id == selectedSailorId)
            if let changed = changedWorktreePath, agent.worktreePath != changed { continue }
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
                lastActivityAge: agent.lastActivityAge,
                gitStats: agent.gitStats,
                paneStatuses: agent.paneStatuses,
                isMainWorktree: agent.isMainWorktree,
                tasks: agent.tasks,
                activityEvents: agent.activityEvents,
                agentType: WorktreeSailorTypeStore.shared.agentType(forWorktree: agent.worktreePath)
                    ?? ShipLog.shared.sailor(forWorktree: agent.worktreePath)?.agentType ?? .unknown
            )
        }
    }

    func detachTerminals() {
        activeSplitContainer?.removeFromSuperview()
        activeSplitContainer = nil
        activeSplitWorktreePath = nil
    }

    /// Point "current" at `path` from outside the UI — a chat command doing what
    /// committing a selection on the desktop does, so both sides agree on which
    /// worktree bare prose steers.
    ///
    /// The worktree need not be staffed: the cursor still moves, and the caller
    /// tells the user there is no agent to talk to yet.
    func commitWorktreeSelection(path: String) {
        lastCommittedWorktreePath = path
        guard agents.contains(where: { $0.worktreePath == path }) else { return }
        selectSailor(byWorktreePath: path, focusTerminal: false)
        overviewSelectedId = selectedSailorId
    }

    func selectSailor(byWorktreePath path: String, focusTerminal: Bool = true) {
        guard let agent = agents.first(where: { $0.worktreePath == path }) else { return }
        selectedSailorId = agent.id
        detachTerminals()
        embedSplitContainerForSelectedSailor(focusTerminal: focusTerminal)
        updateMiniCardSelection()
        syncSidePanelToSelection()
    }

    // MARK: - View mode (split ⇄ terminal)

    /// Switch between the two keyboard view modes. No-op if unchanged.
    func setViewMode(_ mode: ViewMode) {
        guard mode != viewMode else { return }
        applyViewMode(mode)
    }

    private func applyViewMode(_ mode: ViewMode) {
        viewMode = mode
        switch mode {
        case .split:
            // Overview docks as the left column; the terminal live-previews on the
            // right but keyboard focus stays on the overview ring.
            openFirstMateColumn()
            currentSide = .firstMate
            if activeSplitContainer == nil {
                embedSplitContainerForSelectedSailor(focusTerminal: false)
            }
            lastCommittedWorktreePath = agents.first(where: { $0.id == selectedSailorId })?.worktreePath
                ?? lastCommittedWorktreePath
            DispatchQueue.main.async { [weak self] in
                guard let self, self.viewMode == .split else { return }
                self.view.window?.makeFirstResponder(self)
            }
        case .terminal:
            closeFirstMateSide()
            currentSide = .none
            overviewView.isHidden = true
            if !isLeftColumnCollapsed { _ = toggleLeftColumnCollapse() }
            lastCommittedWorktreePath = agents.first(where: { $0.id == selectedSailorId })?.worktreePath
                ?? lastCommittedWorktreePath
            // Hand the keyboard to the terminal after Ghostty's own deferred focus
            // handling (existing convention).
            DispatchQueue.main.async { [weak self] in
                guard let self, self.viewMode == .terminal else { return }
                self.embedSplitContainerForSelectedSailor(focusTerminal: true)
            }
        }
        notifyActiveTool()
        onViewModeChanged?(mode)
    }

    /// Compute + publish the single lit toolbar tool from the current state.
    private func notifyActiveTool() {
        let tool: TitleBarView.ActiveTool
        if isLeftColumnCollapsed {
            tool = .none
        } else {
            switch currentSide {
            case .firstMate: tool = .firstMate
            case .files:     tool = .files
            case .changes:   tool = .changes
            case .none:      tool = .none
            }
        }
        onActiveToolChanged?(tool)
    }

    /// Dock the overview into the left column (worktree First Mate) so expanding
    /// it pushes the terminal right — consistent with files/changes.
    private func mountOverviewInColumn() {
        overviewView.removeFromSuperview()
        overviewView.translatesAutoresizingMaskIntoConstraints = false
        overviewView.layer?.backgroundColor = Self.overviewSideBg.cgColor
        leftColumnContainer.addSubview(overviewView)
        NSLayoutConstraint.activate([
            overviewView.topAnchor.constraint(equalTo: leftColumnContainer.topAnchor),
            overviewView.leadingAnchor.constraint(equalTo: leftColumnContainer.leadingAnchor),
            overviewView.trailingAnchor.constraint(equalTo: leftColumnContainer.trailingAnchor),
            overviewView.bottomAnchor.constraint(equalTo: leftColumnContainer.bottomAnchor),
        ])
    }

    /// First Mate icon: dock/undock the Dashboard as the left column (pushes the
    /// terminal right, same as files/changes). No-op in the overview.
    /// First Mate icon (title bar) → toggle the First Mate column.
    func toggleFirstMateSide() { toggleSide(.firstMate) }

    /// Cmd+B: toggle the left side column. Opening from a collapsed state defaults
    /// to the dashboard (First Mate overview) pane instead of whatever content was
    /// left mounted; when a pane is showing, Cmd+B collapses the column.
    func toggleSidebarDefaultDashboard() {
        if isLeftColumnCollapsed {
            toggleSide(.firstMate)
        } else {
            collapseCurrentSide()
        }
    }

    /// Each pane icon toggles its own panel: click when inactive → open that pane;
    /// click when already the active pane → collapse the whole side column.
    private func toggleSide(_ side: SidePane) {
        if currentSide == side && !isLeftColumnCollapsed {
            collapseCurrentSide()
            return
        }
        switch side {
        case .firstMate:
            // Opening the First Mate column IS mode 2 — route through the mode
            // machine so keyboard focus and hints follow.
            setViewMode(.split)
            return
        case .files:     openFilesColumn(.files)
        case .changes:   openFilesColumn(.changes)
        case .none:      collapseCurrentSide(); return
        }
        currentSide = side
        notifyActiveTool()
    }

    private func openFirstMateColumn() {
        firstMateSideOpen = true
        sidePanelVC.view.isHidden = true          // First Mate replaces file/change content
        mountOverviewInColumn()
        overviewView.isHidden = false
        overviewView.selectedId = overviewSelectedId
        overviewView.update(agents)
        leftColumnWidthExpanded?.constant = Self.firstMateColumnWidth
        expandLeftColumnIfCollapsed()
    }

    private func openFilesColumn(_ tab: SidePanelTab) {
        closeFirstMateSide()                      // undock First Mate if it was showing
        // Files/changes replace the First Mate column: keyboard-wise that's the
        // terminal mode (the ring lives on the overview only).
        if viewMode == .split {
            viewMode = .terminal
            onViewModeChanged?(.terminal)
        }
        leftColumnWidthExpanded?.constant = LayoutMetrics.leftColumnWidth
        sidePanelVC.selectTab(tab)
        expandLeftColumnIfCollapsed()
    }

    private func collapseCurrentSide() {
        if firstMateSideOpen {
            // Closing the First Mate column leaves mode 2 → full terminal. Cash in
            // a queued preview first, so the terminal we expand is the selected
            // worktree's rather than the one it happened to be showing.
            flushPendingPreview()
            setViewMode(.terminal)
            return
        } else if !isLeftColumnCollapsed {
            _ = toggleLeftColumnCollapse()
        }
        currentSide = .none
        notifyActiveTool()
    }

    /// Undock First Mate: restore the file/change side panel in the column.
    /// `collapse` also collapses the column so the terminal reclaims the space.
    private func closeFirstMateSide(collapse: Bool = false) {
        guard firstMateSideOpen else { return }
        firstMateSideOpen = false
        overviewView.isHidden = true
        overviewView.removeFromSuperview()
        sidePanelVC.view.isHidden = false
        leftColumnWidthExpanded?.constant = LayoutMetrics.leftColumnWidth
        if collapse, !isLeftColumnCollapsed { _ = toggleLeftColumnCollapse() }
    }

    /// Open the fleet overview as the left column (⌘E / title-bar dashboard icon).
    func enterOverview() { setViewMode(.split) }

    /// Force the initial state at launch. `setViewMode` no-ops when the mode is
    /// unchanged, so the very first activation needs an explicit apply.
    func activateInitialSplit() { applyViewMode(.split) }

    /// Open the First Mate column and start a command in its composer.
    func startNewCommand(prefill: String = "/new ") {
        setViewMode(.split)
        DispatchQueue.main.async { [weak self] in
            self?.overviewView.focusCommand(prefill: prefill)
        }
    }

    func configureOverview(pendingOrders: PendingOrdersQueue?,
                           onSubmitCommand: @escaping (String) -> Void,
                           onOrderAction: @escaping (PendingOrder, String) -> Void,
                           commandMenuProvider: @escaping (Character, String) -> [(name: String, desc: String)]) {
        overviewView.pendingOrders = pendingOrders
        overviewView.onSubmitCommand = onSubmitCommand
        overviewView.onOrderAction = onOrderAction
        overviewView.commandMenuProvider = commandMenuProvider
    }

    /// Drill into a specific worktree: select it, then flip to worktree mode.
    /// Clicking a row is what sets the overview's selection highlight.
    func enterWorktree(byWorktreePath path: String) {
        selectSailor(byWorktreePath: path)
        overviewSelectedId = selectedSailorId
        // If the overview is on screen (fleet full-screen, or docked as the First
        // Mate side panel), move its selection highlight to the clicked row.
        if !overviewView.isHidden {
            overviewView.selectedId = overviewSelectedId
            overviewView.update(agents)
        }
        setViewMode(.terminal)
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

    /// Switch the left column's active pane. Driven by the title-bar pane-switch
    /// icons. Expands the column first if it was collapsed.
    func selectLeftPane(_ pane: LeftPane) {
        currentLeftPane = pane
        toggleSide(pane == .change ? .changes : .files)
    }

    /// Expand the left column if it is currently collapsed (no-op otherwise).
    func expandLeftColumnIfCollapsed() {
        guard isLeftColumnCollapsed else { return }
        isLeftColumnCollapsed = false
        leftColumnWidthExpanded?.isActive = true
        leftColumnWidthCollapsed?.isActive = false
        animateColumnLayout {
            self.leftColumnContainer.animator().alphaValue = 1
        }
    }

    /// Open the global Worktrees tab in the left sidebar: refresh the card list,
    /// select the tab, and expand the column if collapsed. Replaces the old
    /// floating worktree popover.
    func openWorktreesTab() {
        populateWorktreeCards()
        sidePanelVC.selectTab(.worktrees)
        expandLeftColumnIfCollapsed()
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
        // New-worktree creation lives in the overview composer: switch to the
        // overview and prefill `/new ` so the user types the task and submits.
        startNewCommand()
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

    /// Build the worktree mini-card list (shown in the sidebar's Worktrees tab).
    /// Idle worktrees (in `idleWorktreePaths`) collapse below a "N hidden" expander row.
    private func populateWorktreeCards() {
        let refs = focusLayoutRefs
        refs.miniCards.forEach { $0.removeFromSuperview() }
        refs.stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        guard !agents.isEmpty else { leftRightMiniCards = []; return }

        // One card per agent, kept parallel to `agents` for in-place updates.
        // Cards are width-pinned to the stack in addToSidebar (after they're added).
        let cards = agents.map { makeMiniCard(for: $0) }
        leftRightMiniCards = cards

        let activeCards = zip(agents, cards).filter { !idleWorktreePaths.contains($0.0.worktreePath) }.map(\.1)
        let idleCards = zip(agents, cards).filter { idleWorktreePaths.contains($0.0.worktreePath) }.map(\.1)

        activeCards.forEach { addToSidebar($0, stack: refs.stack) }
        if !idleCards.isEmpty {
            addToSidebar(makeIdleExpanderRow(hiddenCount: idleCards.count), stack: refs.stack)
            if worktreeIdleExpanded {
                idleCards.forEach { addToSidebar($0, stack: refs.stack) }
            }
        }
    }

    /// Add a row to the sidebar stack and pin its width to the stack. The width
    /// constraint can only be activated once both views share the stack as a
    /// common ancestor, so it must happen after `addArrangedSubview`.
    private func addToSidebar(_ view: NSView, stack: NSStackView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func makeMiniCard(for agent: SailorDisplayInfo) -> StackedMiniCardContainerView {
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
            lastActivityAge: agent.lastActivityAge, gitStats: agent.gitStats,
            paneStatuses: agent.paneStatuses,
            isMainWorktree: agent.isMainWorktree,
            tasks: agent.tasks,
            activityEvents: agent.activityEvents,
            agentType: WorktreeSailorTypeStore.shared.agentType(forWorktree: agent.worktreePath)
                ?? ShipLog.shared.sailor(forWorktree: agent.worktreePath)?.agentType ?? .unknown
        )
        container.isSelected = (agent.id == selectedSailorId)
        container.translatesAutoresizingMaskIntoConstraints = false
        // Width is pinned to the stack once the card is added to it (see
        // pinToSidebarWidth) — activating it here would have no common ancestor.
        container.heightAnchor.constraint(equalToConstant: 84).isActive = true
        return container
    }

    private func makeIdleExpanderRow(hiddenCount: Int) -> NSView {
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
        // Width is pinned once added to the stack (see pinToSidebarWidth).
        btn.heightAnchor.constraint(equalToConstant: 26).isActive = true
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

        emptyStateGuideRows = [
            EmptyStateGuideRow(marker: "1.", command: "Add a repo", detail: "pick a folder above"),
            EmptyStateGuideRow(marker: "2.", command: "/new <task>", detail: "start a worktree"),
            EmptyStateGuideRow(marker: "3.", command: "/order @branch", detail: "give the agent an order"),
            EmptyStateGuideRow(marker: "4.", command: "/remove", detail: "clean up finished work"),
        ]
        emptyStateGuide.translatesAutoresizingMaskIntoConstraints = false
        emptyStateGuide.orientation = .vertical
        emptyStateGuide.alignment = .leading
        emptyStateGuide.spacing = 6
        emptyStateGuide.setViews(emptyStateGuideRows, in: .leading)
        emptyStateView.addSubview(emptyStateGuide)
        refreshEmptyStateGuide()

        NSLayoutConstraint.activate([
            emptyStateView.topAnchor.constraint(equalTo: view.topAnchor),
            emptyStateView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emptyStateView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyStateView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            button.centerXAnchor.constraint(equalTo: emptyStateView.centerXAnchor),
            button.centerYAnchor.constraint(equalTo: emptyStateView.centerYAnchor, constant: -64),

            label.topAnchor.constraint(equalTo: button.bottomAnchor, constant: 12),
            label.centerXAnchor.constraint(equalTo: emptyStateView.centerXAnchor),

            emptyStateGuide.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 28),
            emptyStateGuide.centerXAnchor.constraint(equalTo: emptyStateView.centerXAnchor),
        ])
    }

    /// Point the guide at the step the user can actually take: with no repo only
    /// step 1 is live, and once one exists step 1 is done and the commands are.
    private func refreshEmptyStateGuide() {
        // The forced state is a stand-in for a first launch, so show it as one.
        let hasRepo = DebugFlags.forceEmptyState ? false : hasWorkspaces()
        for (index, row) in emptyStateGuideRows.enumerated() {
            let isAddRepo = index == 0
            row.setActive(hasRepo ? !isAddRepo : isAddRepo)
            row.setCurrent(hasRepo ? index == 1 : isAddRepo)
        }
    }

    @objc private func emptyStateAddProjectClicked() {
        dashboardDelegate?.dashboardDidRequestAddProject()
    }

    /// One line of the first-run guide: `1.  /new <task>   start a worktree`.
    /// Mono throughout so the three columns line up without a grid.
    final class EmptyStateGuideRow: NSView {
        private let markerLabel: NSTextField
        private let commandLabel: NSTextField
        private let detailLabel: NSTextField
        private let arrowLabel = NSTextField(labelWithString: "← you are here")

        init(marker: String, command: String, detail: String) {
            markerLabel = NSTextField(labelWithString: marker)
            commandLabel = NSTextField(labelWithString: command)
            detailLabel = NSTextField(labelWithString: detail)
            super.init(frame: .zero)

            markerLabel.font = AppFont.mono(size: 12)
            commandLabel.font = AppFont.mono(size: 12, weight: .medium)
            detailLabel.font = AppFont.mono(size: 12)
            arrowLabel.font = AppFont.mono(size: 12)

            let stack = NSStackView(views: [markerLabel, commandLabel, detailLabel, arrowLabel])
            stack.orientation = .horizontal
            stack.alignment = .firstBaseline
            stack.spacing = 10
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)

            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: topAnchor),
                stack.bottomAnchor.constraint(equalTo: bottomAnchor),
                stack.leadingAnchor.constraint(equalTo: leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: trailingAnchor),
                // Fixed columns keep every row's detail text aligned.
                commandLabel.widthAnchor.constraint(equalToConstant: 132),
            ])
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        /// Dim the steps whose command cannot work yet.
        func setActive(_ active: Bool) {
            markerLabel.textColor = active ? .secondaryLabelColor : .tertiaryLabelColor
            commandLabel.textColor = active ? .labelColor : .tertiaryLabelColor
            detailLabel.textColor = active ? .secondaryLabelColor : .tertiaryLabelColor
        }

        /// Mark the one step to do next.
        func setCurrent(_ current: Bool) {
            arrowLabel.isHidden = !current
            arrowLabel.textColor = .tertiaryLabelColor
        }
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
        // Square (Bare-TUI) + First Mate card background, so First Mate and the
        // Files/Changes pane share one consistent docked side-panel look.
        leftColumnContainer.layer?.cornerRadius = 0
        leftColumnContainer.layer?.masksToBounds = true
        leftColumnContainer.layer?.backgroundColor = Self.overviewSideBg.cgColor
        leftColumnContainer.setAccessibilityIdentifier("dashboard.leftColumn")
        leftRightContainer.addSubview(leftColumnContainer)

        // Worktree list (handed to the sidebar's Worktrees tab as worktreesTabView).
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
        // Pin the stack to the scroll's visible width so cards fill the column
        // (no horizontal scroll) regardless of when they're populated.
        leftRightSidebarStack.widthAnchor.constraint(
            equalTo: leftRightSidebarScroll.contentView.widthAnchor).isActive = true

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

        // Skip re-embed if the same split container is already active for this
        // worktree — but still hand it the keyboard when asked (e.g. committing
        // into mode 3 after a split-mode live preview already embedded it).
        if let active = activeSplitContainer,
           active.superview === container,
           activeSplitWorktreePath == worktreePath {
            if focusTerminal { focusActiveTerminalLeaf() }
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
                        // Async backend: register the view once creation finishes
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

        focusActiveTerminalLeaf(tree: tree)
    }

    /// Make the active split leaf's Ghostty view first responder (immediate +
    /// deferred attempt, in case the hierarchy hasn't settled yet).
    private func focusActiveTerminalLeaf(tree: SplitTree? = nil) {
        guard let tree = tree ?? activeSplitContainer?.tree else { return }
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
        if viewMode != .terminal, !isInDState {
            handleNavKey(event); return
        }
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

        // NORMAL mode: ? toggles the keyboard help overlay; Esc closes it first
        // before falling back to the legacy "exit nav" behavior.
        if event.keyCode == 53 {  // Esc
            if closeTopmostOverlay() { return }
        }
        if flags.isDisjoint(with: [.command, .control, .option]) {
            if event.characters == "?" {
                toggleHelp(); return
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

    // MARK: - Overview (fleet) keyboard navigation — the vertical nav ring

    /// Keyboard handling while the overview drives the keyboard (modes 1 & 2).
    /// ↑↓ (j/k) walk worktree rows → orders card row → command input; on the
    /// orders row ←→ pick a card and Tab cycles its options; ⏎/→ commit forward
    /// (mode 1 → 2 → 3); ← in mode 2 goes back to mode 1.
    private func handleNavKey(_ event: NSEvent) {
        if event.keyCode == 53 {  // Esc closes overlays (help, …)
            if closeTopmostOverlay() { return }
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.isDisjoint(with: [.command, .control, .option]) else { super.keyDown(with: event); return }
        let ch = event.charactersIgnoringModifiers
        switch event.keyCode {
        case 126: applyOverviewEffect(overviewFocus.moveUp());   return  // ↑
        case 125: applyOverviewEffect(overviewFocus.moveDown()); return  // ↓
        case 123: handleNavLeft();  return                               // ←
        case 124: handleNavRight(); return                               // →
        case 48:  handleNavTab();   return                               // Tab
        case 36:  handleNavReturn(); return                              // ⏎
        default: break
        }
        switch ch {
        case "k": applyOverviewEffect(overviewFocus.moveUp())
        case "j": applyOverviewEffect(overviewFocus.moveDown())
        case "h": handleNavLeft()
        case "l": handleNavRight()
        case "?": toggleHelp()
        case "n": startNewCommand()
        case "/", "@", "#": overviewView.focusCommand(prefill: ch ?? "")
        case let d? where ("1"..."9").contains(d):
            if let n = Int(d), case .previewWorktree = overviewFocus.jumpToWorktree(n - 1) {
                applyOverviewEffect(.previewWorktree(n - 1))
                commitFocusedWorktreeForward()
            }
        default: super.keyDown(with: event)
        }
    }

    /// Execute a focus-ring effect: highlight rows/cards, live-preview the
    /// terminal in mode 2, and hand focus to/from the command field.
    private func applyOverviewEffect(_ effect: OverviewFocusModel.Effect) {
        switch effect {
        case .none:
            break
        case .previewWorktree(let i):
            overviewView.setKeyboardCardSelected(nil)
            guard let row = overviewView.orderedRows[safeIndex: i] else { break }
            overviewSelectedId = row.id
            overviewView.selectedId = row.id
            overviewView.update(agents)
            if viewMode == .split { schedulePreview(path: row.path) }
        case .selectCard(let i):
            overviewView.setKeyboardCardSelected(i)
        case .focusCommand:
            overviewView.setKeyboardCardSelected(nil)
            overviewView.commandInput.focusInput()
        case .blurCommandThenLand(let row):
            view.window?.makeFirstResponder(self)
            switch row {
            case .worktree(let i): applyOverviewEffect(.previewWorktree(i))
            case .orders(let i):   applyOverviewEffect(.selectCard(i))
            case .command:         break
            }
        }
    }

    private func handleNavLeft() {
        if overviewFocus.selectedCardIndex != nil {
            applyOverviewEffect(overviewFocus.moveLeftInOrders())
        }
    }

    private func handleNavRight() {
        if overviewFocus.selectedCardIndex != nil {
            applyOverviewEffect(overviewFocus.moveRightInOrders())
        } else if overviewFocus.selectedWorktreeIndex != nil {
            commitFocusedWorktreeForward()
        }
    }

    private func handleNavTab() {
        guard let card = overviewFocus.selectedCardIndex else { return }
        overviewView.cycleChipOnCard(at: card)
    }

    private func handleNavReturn() {
        if let card = overviewFocus.selectedCardIndex {
            // ⏎ on a card: jump straight into that card's terminal (mode 3).
            if let path = overviewView.orderCardPaths[safeIndex: card] {
                enterWorktree(byWorktreePath: path)
            }
            return
        }
        if overviewFocus.selectedWorktreeIndex != nil {
            commitFocusedWorktreeForward()
        }
    }

    /// Click on a fleet row. Clicking steps the same ladder as ⏎/→, so the mouse
    /// and the nav ring never disagree about which mode a row lands you in:
    /// - mode 1 (dashboard): commit the clicked worktree → mode 2 (split)
    /// - mode 2, clicking the *selected* row: → mode 3 (terminal), sidebar hidden
    /// - mode 2, clicking a *different* row: stay in mode 2 and just switch
    ///   worktrees — identical to walking there with ↑/↓.
    private func handleWorktreeRowClick(path: String) {
        guard let i = overviewView.orderedRows.firstIndex(where: { $0.path == path }) else {
            // Not a fleet row (orders card path, stale list) — drill in as before.
            enterWorktree(byWorktreePath: path)
            return
        }
        let row = overviewView.orderedRows[i]
        // Land the ring on the clicked row so a following ↑/↓ continues from here
        // rather than from wherever the keyboard was last.
        _ = overviewFocus.jumpToWorktree(i)

        switch viewMode {
        case .split:
            if row.id == overviewSelectedId {
                commitFocusedWorktreeForward()
            } else {
                applyOverviewEffect(.previewWorktree(i))
            }
        case .terminal:
            // Overview is hidden here, but a docked side panel can still surface
            // rows — keep the direct drill-in.
            enterWorktree(byWorktreePath: path)
        }
    }

    /// ⏎/→ on a worktree row: mode 1 → mode 2 (selected worktree), mode 2 → mode 3.
    private func commitFocusedWorktreeForward() {
        guard let i = overviewFocus.selectedWorktreeIndex,
              let row = overviewView.orderedRows[safeIndex: i] else { return }
        switch viewMode {
        case .split:
            // The live preview is debounced, so it may still be queued when the
            // user commits straight after an arrow key. Cash it in before handing
            // over the keyboard, or they land in the previous worktree's terminal.
            flushPendingPreview()
            setViewMode(.terminal)
        case .terminal:
            break
        }
    }

    /// Coalesce live-follow previews while the user walks the fleet list.
    ///
    /// `previewWorktree` detaches and re-parents Metal-backed terminal surfaces —
    /// far too heavy to run on every arrow key. Doing it synchronously per
    /// keystroke stalled the main thread and made fast ↑↓ navigation drop keys
    /// ("press it several times before it moves"). The highlight still updates
    /// synchronously; only the terminal swap waits for the user to settle.
    private func schedulePreview(path: String) {
        pendingPreviewPath = path
        previewDebounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let p = self.pendingPreviewPath else { return }
            self.pendingPreviewPath = nil
            self.previewDebounceWork = nil
            self.previewWorktree(path: p)
        }
        previewDebounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.previewDebounce, execute: work)
    }

    /// Apply a pending debounced preview now. Any path that hands the keyboard to
    /// the terminal must call this first — it assumes the embed already happened,
    /// so a still-queued preview would leave the user in the *previous*
    /// worktree's terminal.
    private func flushPendingPreview() {
        previewDebounceWork?.cancel()
        previewDebounceWork = nil
        guard let path = pendingPreviewPath else { return }
        pendingPreviewPath = nil
        previewWorktree(path: path)
    }

    /// Drop a queued preview that is about to be made irrelevant (mode change,
    /// explicit selection) so it cannot fire afterwards and swap the terminal out
    /// from under the new selection.
    private func cancelPendingPreview() {
        previewDebounceWork?.cancel()
        previewDebounceWork = nil
        pendingPreviewPath = nil
    }

    /// Live-follow in mode 2: swap the right-hand terminal to `path` without
    /// stealing keyboard focus from the nav ring.
    private func previewWorktree(path: String) {
        guard let agent = agents.first(where: { $0.worktreePath == path }),
              agent.id != selectedSailorId else { return }
        selectedSailorId = agent.id
        detachTerminals()
        embedSplitContainerForSelectedSailor(focusTerminal: false)
        updateMiniCardSelection()
        syncSidePanelToSelection()
    }

    /// Re-clamp the focus ring after the fleet list or orders queue rebuilt.
    private func syncOverviewFocusCounts() {
        // Follow the selection by identity, not by position. The fleet list is
        // re-sorted by status, so one status flip anywhere reshuffles it and a
        // plain index clamp would drift the highlight onto whichever worktree now
        // sits in that slot — while the embedded terminal stays on the old one.
        // A nil anchor (selected row gone) falls back to the clamp.
        let anchor = overviewSelectedId.isEmpty
            ? nil
            : overviewView.orderedRows.firstIndex(where: { $0.id == overviewSelectedId })
        let effect = overviewFocus.rowsDidChange(
            worktreeCount: overviewView.orderedRows.count,
            orderCount: overviewView.orderCards.count,
            worktreeAnchor: anchor
        )
        // Refresh highlights only — a data refresh must not re-trigger terminal
        // embeds or focus moves.
        switch effect {
        case .selectCard(let i):
            overviewView.setKeyboardCardSelected(i)
        case .previewWorktree(let i):
            if let row = overviewView.orderedRows[safeIndex: i], row.id != overviewSelectedId {
                overviewSelectedId = row.id
                overviewView.selectedId = row.id
            }
        default:
            break
        }
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
                windowKeyboardMode?.flashHint("The main worktree cannot be deleted")
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
        case .toggleFiles:      selectLeftPane(.file)
        case .toggleChanges:    selectLeftPane(.change)
        case .toggleFirstMate:  toggleFirstMateSide()
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

/// NSScrollView that never steals keyboard focus from the terminal.
private final class NonFirstResponderScrollView: NSScrollView {
    override var acceptsFirstResponder: Bool { false }
}

// MARK: - Dashboard overview (spread First Mate fleet page)

/// Full-width fleet overview: every worktree as a row grouped by status, a
/// horizontal ORDERS carousel, and a command composer. This is the landing
/// surface (the "spread First Mate"); clicking a row drills into that worktree.
extension Array {
    subscript(safeIndex index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

final class DashboardOverviewView: NSView {
    var onSelectWorktree: ((String) -> Void)?
    var onSubmitCommand: ((String) -> Void)?
    /// A card's primary/secondary button was tapped. `optionText` is the chosen
    /// option label (or "" for a plain approve).
    var onOrderAction: ((PendingOrder, String) -> Void)?

    // Nav-ring hooks (owned by DashboardViewController, which holds the
    // OverviewFocusModel — the same ring drives both the full-bleed overview and
    // the docked left column since this is one reparented instance).
    /// Orders queue rebuilt its cards — counts may have changed.
    var onOrdersChanged: (() -> Void)?
    /// ↑ in an EMPTY, menu-closed command field: ring reclaims focus upward.
    var onCommandArrowUpAtEmpty: (() -> Bool)?
    /// Esc in an EMPTY, menu-closed command field: ring reclaims focus (first row).
    var onCommandEscapeAtEmpty: (() -> Void)?
    /// The command field became first responder (incl. mouse click).
    var onCommandFocused: (() -> Void)?

    var pendingOrders: PendingOrdersQueue? {
        didSet {
            oldValue?.removeObserver(ordersToken); ordersToken = nil
            ordersToken = pendingOrders?.addObserver { [weak self] in
                DispatchQueue.main.async { self?.refreshOrders() }
            }
            refreshOrders()
        }
    }
    private var ordersToken: Int?

    // Palette — SeaHelm.dc.html THEME A ("Bare TUI"), matched 1:1.
    private static let bg         = NSColor(srgbRed: 0x08/255, green: 0x22/255, blue: 0x2a/255, alpha: 1) // --app-bg
    private static let panelBg    = NSColor(srgbRed: 120/255, green: 210/255, blue: 225/255, alpha: 0.045) // --panel-alt
    private static let line       = NSColor(srgbRed: 150/255, green: 215/255, blue: 225/255, alpha: 0.10)  // --line
    private static let lineStrong = NSColor(srgbRed: 150/255, green: 215/255, blue: 225/255, alpha: 0.18)  // --line-strong
    private static let cardBg     = NSColor(srgbRed: 0x0e/255, green: 0x2d/255, blue: 0x37/255, alpha: 1)  // --card-bg
    private static let cardBorder = NSColor(srgbRed: 150/255, green: 215/255, blue: 225/255, alpha: 0.12)  // --card-border
    private static let sea        = NSColor(srgbRed: 0x1f/255, green: 0xc8/255, blue: 0xda/255, alpha: 1)  // --accent
    private static let onSea      = NSColor(srgbRed: 0x06/255, green: 0x20/255, blue: 0x28/255, alpha: 1)
    private static let ink        = NSColor(srgbRed: 0xcf/255, green: 0xe0/255, blue: 0xe0/255, alpha: 1)  // --ink
    private static let inkDim     = NSColor(srgbRed: 0x7f/255, green: 0xa0/255, blue: 0xa3/255, alpha: 1)  // --ink-dim
    private static let inkFaint   = NSColor(srgbRed: 0x55/255, green: 0x71/255, blue: 0x70/255, alpha: 1)  // --ink-faint
    private static let red        = NSColor(srgbRed: 0xe0/255, green: 0x7a/255, blue: 0x6a/255, alpha: 1)  // --red
    private static let orange     = NSColor(srgbRed: 0xe0/255, green: 0xa4/255, blue: 0x58/255, alpha: 1)  // --orange
    private static let emerald    = NSColor(srgbRed: 0x5f/255, green: 0xb8/255, blue: 0x7a/255, alpha: 1)  // --emerald
    private static let cornflower = NSColor(srgbRed: 0x5b/255, green: 0x93/255, blue: 0xf0/255, alpha: 1)  // --cornflower

    /// Per-status group presentation (glyph, group colour, info-line colour, label).
    private static func groupMeta(_ s: SailorStatus) -> (glyph: String, color: NSColor, info: NSColor, label: String) {
        switch s {
        case .waiting: return ("●", orange, orange, "Needs input")
        case .running: return ("◐", sea, inkDim, "Running")
        case .idle:    return ("○", emerald, inkDim, "Idle")
        case .error:   return ("✕", red, red, "Error")
        case .exited:  return ("◌", inkDim, inkFaint, "Dormant")
        case .unknown: return ("◌", inkDim, inkFaint, "Unknown")
        }
    }

    private let headerTitle = NSTextField(labelWithString: "Dashboard")
    private let headerSub = NSTextField(labelWithString: "")
    private let scroll = NonFirstResponderScrollView()
    private let stack = FlippedStackView()

    // ORDERS zone
    private let ordersZone = NSView()
    private let ordersCountLabel = NSTextField(labelWithString: "")
    private let ordersCarousel = NSStackView()
    private var ordersZoneHeight: NSLayoutConstraint?

    // Composer — the real First Mate command input (identical styling), plus the
    // same `/ @ #` autocomplete menu the cockpit uses.
    let commandInput = CommandInputView()
    var commandMenuProvider: ((Character, String) -> [(name: String, desc: String)])?
    private let menuContainer = NSView()
    private var menuRows: [MenuRowButton] = []
    private var menuItems: [(name: String, desc: String)] = []
    private var menuSel = 0
    private var menuTrigger: Character = "/"
    private var menuToken = ""
    private var menuFullText = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }

    deinit { pendingOrders?.removeObserver(ordersToken) }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = Self.bg.cgColor

        // --- Header: ◍ Dashboard   N worktrees · M running  (border-bottom) ---
        let headerIcon = NSTextField(labelWithString: "◍")
        headerIcon.font = AppFont.mono(size: 13)
        headerIcon.textColor = Self.sea
        headerTitle.stringValue = "Dashboard"
        headerTitle.font = AppFont.mono(size: 12.5, weight: .bold)
        headerTitle.textColor = Self.ink
        headerSub.font = AppFont.mono(size: 11)
        headerSub.textColor = Self.inkFaint
        let headerRow = NSStackView(views: [headerIcon, headerTitle, headerSub])
        headerRow.orientation = .horizontal
        headerRow.spacing = 10
        headerRow.alignment = .firstBaseline
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerRow)
        let headerLine = NSView()
        headerLine.wantsLayer = true
        headerLine.layer?.backgroundColor = Self.line.cgColor
        headerLine.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerLine)

        // --- Fleet scroll ---
        stack.orientation = .vertical
        stack.spacing = 2
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 0, bottom: 12, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = stack
        addSubview(scroll)

        // --- ORDERS zone (hidden until there are orders) ---
        setupOrdersZone()

        // --- Composer ---
        let composer = setupComposer()

        NSLayoutConstraint.activate([
            headerRow.topAnchor.constraint(equalTo: topAnchor, constant: 13),
            headerRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 15),
            headerRow.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -15),

            headerLine.topAnchor.constraint(equalTo: headerRow.bottomAnchor, constant: 11),
            headerLine.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerLine.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerLine.heightAnchor.constraint(equalToConstant: 1),

            scroll.topAnchor.constraint(equalTo: headerLine.bottomAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: ordersZone.topAnchor),

            ordersZone.leadingAnchor.constraint(equalTo: leadingAnchor),
            ordersZone.trailingAnchor.constraint(equalTo: trailingAnchor),
            ordersZone.bottomAnchor.constraint(equalTo: composer.topAnchor),

            composer.leadingAnchor.constraint(equalTo: leadingAnchor),
            composer.trailingAnchor.constraint(equalTo: trailingAnchor),
            composer.bottomAnchor.constraint(equalTo: bottomAnchor),

            stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        ordersZoneHeight = ordersZone.heightAnchor.constraint(equalToConstant: 0)
        ordersZoneHeight?.isActive = true
    }

    private func setupOrdersZone() {
        ordersZone.wantsLayer = true
        ordersZone.layer?.backgroundColor = Self.panelBg.cgColor
        ordersZone.translatesAutoresizingMaskIntoConstraints = false
        addSubview(ordersZone)

        let topLine = NSView()
        topLine.wantsLayer = true
        topLine.layer?.backgroundColor = Self.line.cgColor
        topLine.translatesAutoresizingMaskIntoConstraints = false

        let lbl = NSTextField(labelWithString: "ORDERS")
        lbl.font = AppFont.mono(size: 11, weight: .bold)
        lbl.textColor = Self.sea
        ordersCountLabel.font = AppFont.mono(size: 11)
        ordersCountLabel.textColor = Self.inkFaint
        let hint = NSTextField(labelWithString: "← scroll →")
        hint.font = AppFont.mono(size: 10)
        hint.textColor = Self.inkFaint

        let head = NSStackView(views: [lbl, ordersCountLabel, NSView(), hint])
        head.orientation = .horizontal
        head.spacing = 9
        head.alignment = .centerY
        head.translatesAutoresizingMaskIntoConstraints = false

        ordersCarousel.orientation = .horizontal
        ordersCarousel.spacing = 12
        ordersCarousel.alignment = .top
        ordersCarousel.translatesAutoresizingMaskIntoConstraints = false
        let cscroll = NonFirstResponderScrollView()
        cscroll.hasHorizontalScroller = false
        cscroll.drawsBackground = false
        cscroll.borderType = .noBorder
        cscroll.translatesAutoresizingMaskIntoConstraints = false
        cscroll.documentView = ordersCarousel
        ordersZone.addSubview(topLine)
        ordersZone.addSubview(head)
        ordersZone.addSubview(cscroll)

        NSLayoutConstraint.activate([
            topLine.topAnchor.constraint(equalTo: ordersZone.topAnchor),
            topLine.leadingAnchor.constraint(equalTo: ordersZone.leadingAnchor),
            topLine.trailingAnchor.constraint(equalTo: ordersZone.trailingAnchor),
            topLine.heightAnchor.constraint(equalToConstant: 1),

            head.topAnchor.constraint(equalTo: ordersZone.topAnchor, constant: 12),
            head.leadingAnchor.constraint(equalTo: ordersZone.leadingAnchor, constant: 22),
            head.trailingAnchor.constraint(equalTo: ordersZone.trailingAnchor, constant: -22),

            cscroll.topAnchor.constraint(equalTo: head.bottomAnchor, constant: 10),
            cscroll.leadingAnchor.constraint(equalTo: ordersZone.leadingAnchor, constant: 22),
            cscroll.trailingAnchor.constraint(equalTo: ordersZone.trailingAnchor, constant: -22),
            cscroll.bottomAnchor.constraint(equalTo: ordersZone.bottomAnchor, constant: -14),
            ordersCarousel.heightAnchor.constraint(equalTo: cscroll.contentView.heightAnchor),
        ])
    }

    private func setupComposer() -> NSView {
        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = Self.bg.cgColor
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)

        let topLine = NSView()
        topLine.wantsLayer = true
        topLine.layer?.backgroundColor = Self.line.cgColor
        topLine.translatesAutoresizingMaskIntoConstraints = false

        // Reuse the real First Mate command input verbatim, including its
        // `/ @ #` autocomplete menu behaviour. Square corners for Bare-TUI (THEME A).
        commandInput.boxCornerRadius = 0
        commandInput.translatesAutoresizingMaskIntoConstraints = false
        commandInput.onSubmit = { [weak self] text in
            let t = text.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { return }
            self?.onSubmitCommand?(t)
            self?.commandInput.text = ""
            self?.hideMenu()
        }
        commandInput.onTextChanged = { [weak self] text in self?.refreshMenu(for: text) }
        commandInput.onMenuKey = { [weak self] key in self?.handleMenuKey(key) ?? false }
        // Esc escalation: close the menu → clear the text → release focus to the ring.
        commandInput.onCancel = { [weak self] in
            guard let self else { return }
            if !self.menuContainer.isHidden { self.hideMenu(); return }
            if !self.commandInput.text.isEmpty {
                self.commandInput.text = ""
                self.hideMenu()
                return
            }
            self.onCommandEscapeAtEmpty?()
        }
        commandInput.onArrowUpAtEmpty = { [weak self] in
            guard let self, self.menuContainer.isHidden else { return false }
            return self.onCommandArrowUpAtEmpty?() ?? false
        }
        commandInput.onFocused = { [weak self] in self?.onCommandFocused?() }

        // The autocomplete dropdown, opening upward above the input box (the
        // composer sits at the window bottom). Added to `self` so it can overlay
        // the fleet area above the composer.
        menuContainer.wantsLayer = true
        menuContainer.layer?.backgroundColor = Bare.cardBg.cgColor
        menuContainer.layer?.borderWidth = 1
        menuContainer.layer?.borderColor = Bare.line.cgColor
        menuContainer.layer?.cornerRadius = 7
        menuContainer.translatesAutoresizingMaskIntoConstraints = false
        menuContainer.isHidden = true

        bar.addSubview(topLine)
        bar.addSubview(commandInput)
        addSubview(menuContainer)
        NSLayoutConstraint.activate([
            topLine.topAnchor.constraint(equalTo: bar.topAnchor),
            topLine.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            topLine.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            topLine.heightAnchor.constraint(equalToConstant: 1),

            commandInput.topAnchor.constraint(equalTo: bar.topAnchor),
            commandInput.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 8),
            commandInput.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -8),
            commandInput.bottomAnchor.constraint(equalTo: bar.bottomAnchor),

            menuContainer.leadingAnchor.constraint(equalTo: commandInput.boxLeadingAnchor),
            menuContainer.trailingAnchor.constraint(equalTo: commandInput.boxTrailingAnchor),
            menuContainer.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -6),
        ])
        return bar
    }

    // MARK: - `/ @ #` autocomplete (overview composer)

    /// Trailing `/@#`-token of the input, if any.
    private func trailingToken(_ text: String) -> (trigger: Character, query: String, token: String)? {
        var token = ""
        var idx = text.endIndex
        while idx > text.startIndex {
            let prev = text.index(before: idx)
            let ch = text[prev]
            if ch == " " { break }
            token = String(ch) + token
            idx = prev
        }
        guard let first = token.first, "/@#".contains(first) else { return nil }
        return (first, String(token.dropFirst()).lowercased(), token)
    }

    private func refreshMenu(for text: String) {
        guard let (trigger, query, token) = trailingToken(text),
              let items = commandMenuProvider?(trigger, query), !items.isEmpty else {
            hideMenu(); return
        }
        renderMenu(trigger: trigger, items: items, token: token, fullText: text)
    }

    private func renderMenu(trigger: Character, items: [(name: String, desc: String)],
                            token: String, fullText: String) {
        menuContainer.subviews.forEach { $0.removeFromSuperview() }
        let triggerColor: NSColor
        switch trigger {
        case "@": triggerColor = Bare.cornflower
        case "#": triggerColor = Bare.orange
        default:  triggerColor = Bare.accent
        }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        menuContainer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: menuContainer.topAnchor, constant: 4),
            stack.leadingAnchor.constraint(equalTo: menuContainer.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: menuContainer.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: menuContainer.bottomAnchor, constant: -4),
        ])

        menuRows = []
        menuItems = Array(items.prefix(6))
        menuTrigger = trigger
        menuToken = token
        menuFullText = fullText
        for item in menuItems {
            let row = MenuRowButton(name: item.name, desc: item.desc,
                                    triggerSymbol: String(trigger), triggerColor: triggerColor)
            row.onPick = { [weak self] in
                self?.applyCompletion(name: item.name, trigger: trigger, token: token, fullText: fullText)
            }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            menuRows.append(row)
        }
        menuContainer.isHidden = false
        setMenuSelection(0)
    }

    private func setMenuSelection(_ i: Int) {
        guard !menuRows.isEmpty else { return }
        menuSel = max(0, min(menuRows.count - 1, i))
        for (idx, row) in menuRows.enumerated() { row.setSelected(idx == menuSel) }
    }

    private func acceptMenuSelection() {
        guard menuSel < menuItems.count else { return }
        applyCompletion(name: menuItems[menuSel].name, trigger: menuTrigger,
                        token: menuToken, fullText: menuFullText)
    }

    private func handleMenuKey(_ key: CommandInputView.MenuKey) -> Bool {
        guard !menuContainer.isHidden, !menuRows.isEmpty else { return false }
        switch key {
        case .up:     setMenuSelection(menuSel - 1)
        case .down:   setMenuSelection(menuSel + 1)
        case .accept: acceptMenuSelection()
        }
        return true
    }

    private func applyCompletion(name: String, trigger: Character, token: String, fullText: String) {
        let base = String(fullText.dropLast(token.count))
        hideMenu()
        commandInput.setTextAndFocusEnd(base + String(trigger) + name + " ")
    }

    private func hideMenu() {
        menuContainer.isHidden = true
        menuContainer.subviews.forEach { $0.removeFromSuperview() }
        menuRows = []
        menuItems = []
        menuSel = 0
    }

    private static func primaryStatus(_ s: SailorDisplayInfo) -> SailorStatus {
        let ps = s.paneStatuses
        if ps.contains(.waiting) { return .waiting }
        if ps.contains(.running) { return .running }
        if ps.contains(.error) { return .error }
        if ps.contains(.idle) { return .idle }
        return ps.first ?? .unknown
    }

    /// Focus the command input with a prefilled command (e.g. "/new ").
    func focusCommand(prefill: String) {
        commandInput.setTextAndFocusEnd(prefill)
    }

    /// Worktrees in display (grouped) order — the sequence keyboard nav walks.
    private(set) var orderedRows: [(id: String, path: String)] = []

    func update(_ sailors: [SailorDisplayInfo]) {
        let running = sailors.filter { Self.primaryStatus($0) == .running }.count
        headerSub.stringValue = "\(sailors.count) worktrees · \(running) running"

        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        orderedRows = []

        // Group by repo, in first-seen order (which follows the configured
        // card/workspace order). Within a repo: main worktree first, then the
        // linked worktrees by creation time (oldest first).
        var repoOrder: [String] = []
        var grouped: [String: [SailorDisplayInfo]] = [:]
        for sailor in sailors {
            if grouped[sailor.project] == nil { repoOrder.append(sailor.project) }
            grouped[sailor.project, default: []].append(sailor)
        }
        for (gi, repo) in repoOrder.enumerated() {
            let items = (grouped[repo] ?? []).sorted { a, b in
                if a.isMainWorktree != b.isMainWorktree { return a.isMainWorktree }
                return Self.creationDate(a.worktreePath) < Self.creationDate(b.worktreePath)
            }
            guard !items.isEmpty else { continue }
            let meta: (glyph: String, color: NSColor, info: NSColor, label: String) =
                ("▸", Self.inkDim, Self.inkDim, repo)
            let header = makeGroupHeader(meta: meta, count: items.count, topGap: gi == 0 ? 0 : 13)
            stack.addArrangedSubview(header)
            pin(header)
            let rowsBox = NSStackView()
            rowsBox.orientation = .vertical
            rowsBox.spacing = 4
            rowsBox.alignment = .leading
            rowsBox.translatesAutoresizingMaskIntoConstraints = false
            for item in items {
                let status = Self.primaryStatus(item)
                let row = RowView(sailor: item, status: status,
                                  infoColor: Self.groupMeta(status).info,
                                  selected: item.id == self.selectedId)
                row.onTap = { [weak self] path in self?.onSelectWorktree?(path) }
                rowsBox.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: rowsBox.widthAnchor).isActive = true
                orderedRows.append((item.id, item.worktreePath))
            }
            stack.addArrangedSubview(rowsBox)
            pin(rowsBox)
        }
    }

    /// Worktree directory creation date, cached — the sort key inside a repo
    /// group. Missing/unreadable paths sort first (distantPast).
    private static var creationDateCache: [String: Date] = [:]
    private static func creationDate(_ path: String) -> Date {
        if let cached = creationDateCache[path] { return cached }
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let date = attrs?[.creationDate] as? Date ?? .distantPast
        creationDateCache[path] = date
        return date
    }

    /// Selected worktree id, so the fleet can mark the current row (accent border).
    var selectedId: String = ""

    /// Cards in carousel order + each card's worktree path, for keyboard nav.
    private(set) var orderCards: [OrderCardView] = []
    private(set) var orderCardPaths: [String] = []

    /// Highlight card `index` as the keyboard selection (nil clears all).
    func setKeyboardCardSelected(_ index: Int?) {
        for (i, card) in orderCards.enumerated() {
            card.setSelected(i == index)
        }
        if let index, let card = orderCards[safeIndex: index] {
            card.scrollToVisible(card.bounds)
        }
    }

    /// Tab on the orders row: cycle option-chip focus on the selected card.
    func cycleChipOnCard(at index: Int) {
        orderCards[safeIndex: index]?.cycleFocusedChip()
    }

    private func refreshOrders() {
        let orders = pendingOrders?.all() ?? []
        ordersCarousel.arrangedSubviews.forEach { $0.removeFromSuperview() }
        ordersCountLabel.stringValue = "\(orders.count)"
        orderCards = []
        orderCardPaths = []
        var maxCard: CGFloat = 0
        for order in orders {
            // The real First Mate order card, laid out horizontally.
            let card = OrderCardView()
            card.wantsLayer = true
            card.configure(order: order) { [weak self] idx in
                let opt = order.action.options?.indices.contains(idx) == true ? order.action.options![idx] : ""
                self?.onOrderAction?(order, opt)
            }
            card.onNavigate = { [weak self] in self?.onSelectWorktree?(order.action.worktreePath) }
            card.onDismiss = { [weak self] in self?.pendingOrders?.resolve(id: order.id) }
            let h = BridgePanelViewController.cardHeight(for: order)
            maxCard = max(maxCard, h)
            ordersCarousel.addArrangedSubview(card)
            card.translatesAutoresizingMaskIntoConstraints = false
            card.widthAnchor.constraint(equalToConstant: 340).isActive = true
            card.heightAnchor.constraint(equalToConstant: h).isActive = true
            orderCards.append(card)
            orderCardPaths.append(order.action.worktreePath)
        }
        // Collapse the whole zone when there's nothing pending; otherwise size it
        // to the tallest card + the "ORDERS" header + padding.
        let show = !orders.isEmpty
        ordersZone.isHidden = !show
        ordersZoneHeight?.constant = show ? (maxCard + 12 + 20 + 10 + 14) : 0
        onOrdersChanged?()
    }

    private func pin(_ v: NSView) {
        v.translatesAutoresizingMaskIntoConstraints = false
        v.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 15).isActive = true
        v.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -15).isActive = true
    }

    private func makeGroupHeader(meta: (glyph: String, color: NSColor, info: NSColor, label: String),
                                 count: Int, topGap: CGFloat) -> NSView {
        // glyph(8px, group colour) · label(11px, group colour, +0.5 tracking) · count(11px, ink-faint)
        let glyph = NSTextField(labelWithString: meta.glyph)
        glyph.font = AppFont.mono(size: 8)
        glyph.textColor = meta.color

        let label = NSTextField(labelWithString: meta.label)
        label.font = AppFont.mono(size: 11)
        label.textColor = meta.color

        let count = NSTextField(labelWithString: "\(count)")
        count.font = AppFont.mono(size: 11)
        count.textColor = Self.inkFaint

        let row = NSStackView(views: [glyph, label, count])
        row.orientation = .horizontal
        row.spacing = 7
        row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: topGap, left: 0, bottom: 7, right: 0)
        return row
    }

    // MARK: - Fleet row

    private final class RowView: NSView {
        var onTap: ((String) -> Void)?
        private let path: String
        private let selected: Bool

        private static func label(_ s: String, _ color: NSColor, _ size: CGFloat) -> NSTextField {
            let l = NSTextField(labelWithString: s)
            l.font = AppFont.mono(size: size)
            l.textColor = color
            l.lineBreakMode = .byTruncatingTail
            return l
        }
        /// Time since a date as a compact largest-unit age: 8s / 5m / 8h / 3d.
        /// Nil (no known activity) renders blank.
        private static func compactAge(since date: Date?) -> String {
            guard let date else { return "" }
            let secs = Int(max(0, Date().timeIntervalSince(date)))
            if secs < 60 { return "\(secs)s" }
            let m = secs / 60
            if m < 60 { return "\(m)m" }
            let h = m / 60
            if h < 24 { return "\(h)h" }
            return "\(h / 24)d"
        }
        private static func spacer() -> NSView {
            let v = NSView()
            v.translatesAutoresizingMaskIntoConstraints = false
            v.setContentHuggingPriority(.defaultLow, for: .horizontal)
            v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            return v
        }

        init(sailor: SailorDisplayInfo, status: SailorStatus, infoColor: NSColor, selected: Bool) {
            self.path = sailor.worktreePath
            self.selected = selected
            super.init(frame: .zero)
            wantsLayer = true   // Bare-TUI: radius 0, no rounding
            if selected { layer?.backgroundColor = DashboardOverviewView.panelBg.cgColor }

            let waiting = (status == .waiting)

            // Left border bar: awaiting=red, selected=accent, else transparent.
            let bar = NSView()
            bar.wantsLayer = true
            bar.layer?.backgroundColor = (waiting ? DashboardOverviewView.red
                : (selected ? DashboardOverviewView.sea : NSColor.clear)).cgColor
            bar.translatesAutoresizingMaskIntoConstraints = false

            // Line 1: [repo tag]  ● title                              time
            // The title is the worktree's session summary (shared resolver, same
            // source as the cards), falling back to task subject / latest message.
            let branch = sailor.thread.isEmpty ? sailor.name : sailor.thread
            let cachedTitle = WorktreeTitleCache.shared.cachedTitle(worktreePath: sailor.worktreePath)
            let subject = sailor.tasks.first?.subject
            let msg = sailor.mostRecentMessage == "No active task." ? nil : sailor.mostRecentMessage
            let titleText = [cachedTitle, subject, msg].compactMap { $0 }
                .first(where: { !$0.isEmpty }) ?? branch

            // Per-repo colored tag; the same project always gets the same color.
            let repoTag = Self.repoTag(sailor.project)
            // Status dot colored by the row's arbitrated status.
            let dot = Self.label("\u{25CF}", status.color, 8)
            dot.setContentHuggingPriority(.required, for: .horizontal)
            let title = Self.label(titleText, DashboardOverviewView.ink, 12)
            title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let lastActive = sailor.activityEvents.map(\.timestamp).max()
            let time = Self.label(Self.compactAge(since: lastActive), DashboardOverviewView.inkFaint, 10)
            time.setContentHuggingPriority(.required, for: .horizontal)

            let line1 = NSStackView()
            line1.orientation = .horizontal
            line1.alignment = .centerY
            line1.spacing = 7
            line1.translatesAutoresizingMaskIntoConstraints = false
            if !sailor.project.isEmpty { line1.addArrangedSubview(repoTag) }
            line1.addArrangedSubview(dot)
            line1.addArrangedSubview(title)
            if waiting { line1.addArrangedSubview(Self.pill("NEEDS INPUT", color: DashboardOverviewView.red)) }
            line1.addArrangedSubview(Self.spacer())
            line1.addArrangedSubview(time)

            // Line 2: worktree name   git info                       N panes
            let name = Self.label(branch, DashboardOverviewView.inkDim, 10.5)
            name.setContentCompressionResistancePriority(.required, for: .horizontal)
            let git = NSTextField(labelWithString: "")
            git.attributedStringValue = Self.gitInfoAttributed(sailor.gitStats)
            git.translatesAutoresizingMaskIntoConstraints = false
            git.setContentHuggingPriority(.required, for: .horizontal)
            let panes = Self.label(sailor.paneCount > 0 ? "\(sailor.paneCount) panes" : "—",
                                   DashboardOverviewView.inkFaint, 10)
            panes.setContentHuggingPriority(.required, for: .horizontal)

            let line2 = NSStackView()
            line2.orientation = .horizontal
            line2.alignment = .firstBaseline
            line2.spacing = 9
            line2.translatesAutoresizingMaskIntoConstraints = false
            line2.addArrangedSubview(name)
            line2.addArrangedSubview(git)
            line2.addArrangedSubview(Self.spacer())
            line2.addArrangedSubview(panes)

            let col = NSStackView(views: [line1, line2])
            col.orientation = .vertical
            col.spacing = 3
            col.alignment = .leading
            col.translatesAutoresizingMaskIntoConstraints = false

            addSubview(bar); addSubview(col)
            NSLayoutConstraint.activate([
                bar.leadingAnchor.constraint(equalTo: leadingAnchor),
                bar.topAnchor.constraint(equalTo: topAnchor),
                bar.bottomAnchor.constraint(equalTo: bottomAnchor),
                bar.widthAnchor.constraint(equalToConstant: 2),

                col.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 13),
                col.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -13),
                col.topAnchor.constraint(equalTo: topAnchor, constant: 8),
                col.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

                line1.widthAnchor.constraint(equalTo: col.widthAnchor),
                line2.widthAnchor.constraint(equalTo: col.widthAnchor),
            ])
        }
        required init?(coder: NSCoder) { fatalError() }

        /// Per-repo colored tag: a stable brand color (shared with the cards) as a
        /// subtle fill + border + colored text. Radius 0 to match the bare-TUI look.
        static func repoTag(_ project: String) -> NSView {
            let color = MiniCardView.repoColor(for: project)
            let l = NSTextField(labelWithString: project)
            l.font = AppFont.mono(size: 10)
            l.textColor = color
            l.lineBreakMode = .byTruncatingTail
            l.translatesAutoresizingMaskIntoConstraints = false
            let pad = NSView()
            pad.wantsLayer = true
            pad.layer?.borderWidth = 1
            pad.layer?.borderColor = color.withAlphaComponent(0.55).cgColor
            pad.layer?.backgroundColor = color.withAlphaComponent(0.12).cgColor
            pad.translatesAutoresizingMaskIntoConstraints = false
            pad.setContentHuggingPriority(.required, for: .horizontal)
            pad.setContentCompressionResistancePriority(.required, for: .horizontal)
            pad.addSubview(l)
            NSLayoutConstraint.activate([
                l.topAnchor.constraint(equalTo: pad.topAnchor, constant: 1),
                l.bottomAnchor.constraint(equalTo: pad.bottomAnchor, constant: -1),
                l.leadingAnchor.constraint(equalTo: pad.leadingAnchor, constant: 5),
                l.trailingAnchor.constraint(equalTo: pad.trailingAnchor, constant: -5),
            ])
            return pad
        }

        /// Compact git summary "+adds −dels  ↑ahead↓behind", colored. Empty when
        /// there are no changes and no divergence (or stats not yet resolved).
        static func gitInfoAttributed(_ stats: WorktreeGitStats?) -> NSAttributedString {
            guard let stats, !stats.isEmpty else { return NSAttributedString() }
            let font = AppFont.mono(size: 10)
            let result = NSMutableAttributedString()
            func append(_ s: String, _ color: NSColor) {
                result.append(NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color]))
            }
            if stats.added > 0 { append("+\(stats.added)", DashboardOverviewView.emerald) }
            if stats.removed > 0 {
                if result.length > 0 { append(" ", DashboardOverviewView.inkFaint) }
                append("\u{2212}\(stats.removed)", DashboardOverviewView.red)
            }
            if stats.hasAheadBehind {
                if result.length > 0 { append("  ", DashboardOverviewView.inkFaint) }
                var ab = ""
                if let ahead = stats.ahead, ahead > 0 { ab += "\u{2191}\(ahead)" }
                if let behind = stats.behind, behind > 0 { ab += "\u{2193}\(behind)" }
                append(ab, DashboardOverviewView.inkFaint)
            }
            return result
        }

        /// Bare-TUI pill: coloured text + 1px border, no fill, radius 0.
        static func pill(_ text: String, color: NSColor) -> NSView {
            let l = NSTextField(labelWithString: text)
            l.font = AppFont.mono(size: 9.5)
            l.textColor = color
            l.translatesAutoresizingMaskIntoConstraints = false
            let pad = NSView()
            pad.wantsLayer = true
            pad.layer?.borderWidth = 1
            pad.layer?.borderColor = color.cgColor
            pad.translatesAutoresizingMaskIntoConstraints = false
            pad.addSubview(l)
            NSLayoutConstraint.activate([
                l.topAnchor.constraint(equalTo: pad.topAnchor, constant: 1),
                l.bottomAnchor.constraint(equalTo: pad.bottomAnchor, constant: -1),
                l.leadingAnchor.constraint(equalTo: pad.leadingAnchor, constant: 5),
                l.trailingAnchor.constraint(equalTo: pad.trailingAnchor, constant: -5),
            ])
            return pad
        }

        override func mouseDown(with event: NSEvent) { onTap?(path) }

        private var tracking: NSTrackingArea?
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
            addTrackingArea(t); tracking = t
        }
        override func mouseEntered(with event: NSEvent) {
            layer?.backgroundColor = DashboardOverviewView.panelBg.cgColor
        }
        override func mouseExited(with event: NSEvent) {
            layer?.backgroundColor = selected ? DashboardOverviewView.panelBg.cgColor : NSColor.clear.cgColor
        }
    }

}
