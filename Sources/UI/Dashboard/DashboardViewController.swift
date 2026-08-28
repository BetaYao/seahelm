import AppKit
import QuartzCore

// MARK: - DashboardDelegate

protocol DashboardDelegate: AnyObject {
    func dashboardDidSelectProject(_ project: String, thread: String)
    func dashboardDidRequestEnterProject(_ project: String)
    func dashboardDidReorderCards(order: [String])
    func dashboardDidRequestDelete(_ terminalID: String)
    func dashboardDidRequestDeleteWithBranch(_ terminalID: String)
    func dashboardDidRequestCloseRepo(_ project: String)
    func dashboardDidRequestAddProject()
    func dashboardDidChangeSelection(_ dashboard: DashboardViewController)
    func dashboardDidRequestBrowseFiles(worktreePath: String)
    func dashboardDidRequestShowChanges(worktreePath: String)
}

// MARK: - PaneDisplayInfo

/// One split pane, for the fully-expanded "Group by Pane" fleet rows.
struct PaneDisplayInfo {
    let stationId: String   // Station.id — the leaf's surface
    let title: String       // per-pane title (PaneTitleResolver)
    let status: AgentStatus
    let isFocused: Bool      // the worktree's last-focused pane
}

// MARK: - WorktreeRowInfo

struct WorktreeRowInfo {
    let name: String        // display name like "Agent-Alpha"
    let project: String     // repo display name
    let thread: String      // branch name
    let paneStatuses: [AgentStatus]     // per-pane statuses, in leaf order
    /// Worktree-level status from the aggregator (most recently changed pane).
    let rolledUpStatus: AgentStatus
    let mostRecentMessage: String       // message from most recently updated pane
    let lastUserPrompt: String          // most recent user prompt text
    let mostRecentPaneIndex: Int
    let totalDuration: String   // "HH:MM:SS" format
    let roundDuration: String   // "HH:MM:SS" format
    let station: Station
    let worktreePath: String    // needed to lazily create the terminal

    /// Row identity. Deliberately the worktree path and nothing else.
    ///
    /// This used to be a pane's `Station.id` — whichever of the worktree's panes
    /// happened to be registered first. Closing that pane changed the row's
    /// identity, `selectedWorktreeId` stopped matching any row, and the "validate
    /// the selection" fallback then landed on the *first row of the whole fleet*:
    /// close a split pane in one worktree and the terminal jumped to another one.
    /// A worktree outlives every pane inside it, so its path is the only identity
    /// that can't die underneath the selection.
    var id: String { worktreePath }
    let paneCount: Int          // number of split panes (1 = no badge)
    let paneStations: [Station]  // all pane stations in leaf order
    let isMainWorktree: Bool    // true = base repo, false = git worktree
    let tasks: [TaskItem]              // webhook-tracked task items
    let activityEvents: [ActivityEvent]
    let lastActivityAge: String        // "3m"/"2h" since last real activity ("" if unknown)
    let lastActivityAt: Date?
    let gitStats: WorktreeGitStats?    // diff size + ahead/behind (nil until first resolve)
    /// Focused (last-selected) pane title for First Mate fleet rows.
    let currentPaneTitle: String
    /// Running / activity age for that focused pane (compact: `12s` / `3m`).
    let currentPaneRunTime: String
    /// Per-pane rows for the expanded "Group by Pane" mode (leaf order).
    var panes: [PaneDisplayInfo] = []

    /// Rolled-up status for display/grouping. Computed once by the aggregator —
    /// the pane that changed status most recently — and carried here rather than
    /// re-derived, so the dashboard row and the tab badge cannot disagree about
    /// what the same worktree is doing.
    var status: String {
        rolledUpStatus.rawValue.lowercased()
    }

    /// Convenience: backward-compatible lastMessage
    var lastMessage: String {
        mostRecentMessage
    }
}

// MARK: - DashboardViewController

class DashboardViewController: NSViewController {
    enum LayoutMetrics {
        static let leftColumnWidth: CGFloat = 300
    }

    weak var dashboardDelegate: DashboardDelegate?

    /// Set by MainWindowController. Called when the user drills into a terminal so the
    /// keyboard mode can switch to .insert.
    var onEnterTerminal: (() -> Void)?
    /// Set by MainWindowController. Opens the island's command bar with a prefill
    /// (`""` just focuses it) — the single command surface since the fleet
    /// column's composer was removed.
    var onRequestCommandBar: ((String) -> Void)?
    /// Set by MainWindowController. Called when the user requests the new-worktree creator.
    var onRequestNewWorktree: (() -> Void)?
    /// The "+" on a project group header was clicked. Args: the project title and
    /// the rect + view to anchor the create popover to.
    var onAddWorktreeToProject: ((String, NSRect, NSView) -> Void)?
    /// Fold this project's worktrees into its integration checkout. Equivalent
    /// to typing `/integrate` with that repo selected.
    var onIntegrateProject: ((String) -> Void)?
    /// The fleet header "+" was clicked: open the folder picker to add a repo.
    var onRequestAddRepo: (() -> Void)?

    /// Hold/resume the fleet row rebuild while an anchored form is open.
    func setFleetRenderPaused(_ paused: Bool) {
        overviewView.isRenderPaused = paused
    }

    /// Set by TabCoordinator during setup
    weak var stationManager: StationManager?

    /// Set by MainWindowController — forwards split events to TerminalCoordinator
    weak var splitContainerDelegate: SplitContainerDelegate?

    /// The selected fleet row's id — i.e. the selected worktree's path.
    ///
    /// Named for the worktree, not the pane, on purpose: it survives every pane
    /// inside that worktree being split, slept, or closed. See `WorktreeRowInfo.id`.
    var selectedWorktreeId: String = ""

    /// Deprecated layout alias for chrome collapse (SSOT is `ChromeLayoutState`):
    /// - `.split` == sidebar expanded (`!chrome.isCollapsed`)
    /// - `.terminal` == sidebar collapsed (`chrome.isCollapsed`)
    enum ViewMode: Equatable { case split, terminal }
    private(set) var viewMode: ViewMode = .split
    /// Fired after view-mode mirrors chrome collapse (keyboard NORMAL/INSERT).
    /// Ask MainWindow to toggle chrome sidebar collapse (⌘B / legacy shims).
    var onRequestToggleChromeCollapse: (() -> Void)?
    /// Ask MainWindow to set chrome collapse (ViewMode / enter-terminal paths).
    var onRequestSetChromeCollapsed: ((Bool) -> Void)?
    /// Ask MainWindow to run `ChromeLayoutState.selectPane` (re-click collapses).
    var onRequestSelectChromePane: ((ChromeLeftPane) -> Void)?
    /// File / changelog overlay title for the chrome terminal header (`nil` = restore pane title).
    var onCenterOverlayTitleChange: ((String?) -> Void)?

    /// Fires when the edit-mode toggle's availability or on-state changes, so the
    /// chrome header can enable/dim/light its icon. `(available, isOn)`.
    var onEditModeStateChange: ((Bool, Bool) -> Void)?
    /// Last worktree the user actually committed into (split/terminal). Backs the
    /// mode-1 ⇄ mode-2 back-key toggle.
    private(set) var lastCommittedWorktreePath: String?
    /// Fires whenever the lit chrome header tool should change (mode or side switch).
    /// `nil` means no pane lit (sidebar collapsed).
    var onActiveToolChanged: ((ChromeLeftPane?) -> Void)?

    let focusController = DashboardFocusController()
    private var isInDState: Bool { focusController.mode != .idle }

    private var leftColumnWidthExpanded: NSLayoutConstraint?
    private var leftColumnWidthCollapsed: NSLayoutConstraint?
    private var isLeftColumnCollapsed = false
    /// Which of the panes the left column currently shows.
    private var currentLeftPane: LeftPane = .file

    /// Worktree paths idle > 8h — collapsed under the expander in the popover list.
    var idleWorktreePaths: Set<String> = []

    var selectedPaneIndex: Int {
        agents.firstIndex(where: { $0.id == selectedWorktreeId }) ?? 0
    }

    /// Cached SplitContainerView per worktree path
    private var splitContainers: [String: SplitContainerView] = [:]

    /// Currently visible split container in the focus panel
    private(set) var activeSplitContainer: SplitContainerView?

    // Data
    private(set) var agents: [WorktreeRowInfo] = []

    // Left-Right layout
    private let leftRightContainer = NSView()
    private let leftRightFocusPanel = FocusPanelView()
    // The inline worktree creator is no longer shown (the cockpit `/new` command
    // replaces it); the object is kept only so the existing setup/report wiring
    // in MainWindowController still compiles.
    private let inlineCreateView = InlineWorktreeCreateView()

    // Left column content host — overview + side panel swap (no outer width/collapse;
    // WindowChromeController owns column chrome). Exposed for MainWindow embedding.
    let navigatorHostView = NSView()
    /// Terminal / focus-panel host for the chrome terminal slot.
    let terminalHostView = NSView()
    private var leftColumnContainer: NSView { navigatorHostView }
    private(set) lazy var sidePanelVC: WorktreeSidePanelViewController = {
        let vc = WorktreeSidePanelViewController(worktreePath: nil, initialTab: .files)
        vc.delegate = self
        // First Mate titles follow the worktree's current pane, same as the
        // terminal chrome header.
        vc.currentPaneTitleProvider = { [weak self] path in
            self?.currentPaneTitle(forWorktree: path)
        }
        return vc
    }()

    /// Title of the worktree's current pane — the same `focusedId` the terminal
    /// chrome header follows, so First Mate and the header never disagree.
    private func currentPaneTitle(forWorktree path: String) -> String? {
        guard let tree = stationManager?.tree(forPath: path),
              let stationId = PaneTitleResolver.focusedStationId(in: tree),
              let pane = AgentRegistry.shared.panes(forWorktree: path)
                .first(where: { $0.id == stationId })
        else { return nil }
        return PaneTitleResolver.title(for: pane)
    }

    // Center overlay
    private var centerOverlay: CenterOverlayView?

    // MARK: - Edit-mode (split file-preview layout)

    /// Per-worktree preview-set + edit-mode model (decoupled from display mode).
    let previewSets = PreviewSetController()
    /// The two-column edit container, created lazily and reused across worktrees.
    private var editLayoutContainer: EditLayoutContainerView?

    /// Edit mode's tab strips are owned by the window chrome header (one row of
    /// chrome instead of two). The dashboard drives their contents and selection
    /// but does not own the views.
    var editStripsProvider: (() -> (terminal: EditTabStripView, preview: EditTabStripView)?)?
    var onEditModeStripsActive: ((_ active: Bool, _ ratio: CGFloat) -> Void)?
    var onEditStripRatioChange: ((CGFloat) -> Void)?

    /// True once the chrome's strips have had their callbacks wired to this VC.
    private var editStripCallbacksWired = false

    /// The chrome-owned strips, with their callbacks wired on first use.
    private func chromeEditStrips() -> (terminal: EditTabStripView, preview: EditTabStripView)? {
        guard let strips = editStripsProvider?() else { return nil }
        if !editStripCallbacksWired {
            editStripCallbacksWired = true
            strips.terminal.onSelect = { [weak self] id in self?.selectTerminalTab(id) }
            strips.preview.onSelect = { [weak self] id in self?.selectPreviewTab(id) }
            strips.preview.onClose = { [weak self] id in self?.closePreviewTab(id) }
        }
        return strips
    }
    /// Built preview content views keyed by file path (preserves editor state
    /// across tab switches). Torn down on explicit tab close / worktree deletion.
    private var previewContentCache: [String: NSView] = [:]

    /// Where the terminal `SplitContainerView` should live right now — the edit
    /// container's terminal host when edit mode is attached, else the focus panel.
    private var currentTerminalContainer: NSView {
        if let edit = editLayoutContainer, edit.superview != nil { return edit.terminalHost }
        return leftRightFocusPanel.terminalContainer
    }

    private var currentWorktreePath: String? {
        (agents.first(where: { $0.id == selectedWorktreeId }) ?? agents.first)?.worktreePath
    }

    /// True when the selected worktree is showing the split edit layout.
    var isEditModeActive: Bool {
        guard let wt = currentWorktreePath else { return false }
        return previewSets.isEditMode(for: wt) && editLayoutContainer?.superview != nil
    }

    // `?` keyboard cheat-sheet overlay (the floating First Mate cockpit was
    // removed; the command composer lives in the overview now).
    private var helpOverlay: KeyboardHelpOverlay?

    // Fleet overview (spread First Mate). Full-bleed in .overview mode; can also
    // open as a 392pt left side panel over the terminal in .worktree mode.
    private lazy var overviewView: DashboardOverviewView = {
        let view = DashboardOverviewView()
        view.currentPaneTitleProvider = { [weak self] path in
            self?.currentPaneTitle(forWorktree: path)
        }
        return view
    }()
    private var firstMateSideOpen = false
    /// Which content the left side column currently shows (.none = collapsed).
    private enum SidePane { case none, firstMate, files, changes }
    private var currentSide: SidePane = .none
    /// The row the user has explicitly clicked in the overview. Empty until the
    /// first click, so nothing is pre-selected (no stale default highlight).
    private var overviewSelectedId: String = ""
    /// Vertical nav ring over the overview (worktree rows → orders row → command
    /// input). Lives here (not in the view) because visuals need `agents`.
    private var overviewFocus = OverviewFocusModel(worktreeCount: 0)
    /// Worktree awaiting a debounced terminal preview, and its timer. Walking the
    /// list must not re-parent Metal surfaces on every keystroke — see
    /// `schedulePreview(path:)`.
    private var pendingPreviewPath: String?
    private var previewDebounceWork: DispatchWorkItem?
    /// How long ↑↓ must settle before the terminal actually swaps. Long enough to
    /// coalesce a fast key-repeat burst, short enough to feel live.
    private static let previewDebounce: TimeInterval = 0.12

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

        setupLeftRightLayout()
        setupEmptyState()

        // Content hosts are live once chrome mounts them; empty state starts hidden.
        leftRightContainer.isHidden = false

        // Fleet overview (spread First Mate). Full-bleed in .overview mode; in a
        // worktree it docks into the left column (same region as files/changes,
        // pushing the terminal right — not a floating overlay).
        overviewView.onSelectWorktree = { [weak self] path in
            self?.handleWorktreeRowClick(path: path)
        }
        // Pane row (expanded "Group by Pane"): enter the worktree, then focus
        // the specific pane once its split container is embedded.
        overviewView.onSelectPane = { [weak self] path, stationId in
            self?.handlePaneRowClick(path: path, stationId: stationId)
        }
        // Row context menu → the delegate's confirm-and-tear-down path.
        overviewView.onDeleteWorktree = { [weak self] path in
            guard let self, let agent = self.agents.first(where: { $0.worktreePath == path }) else { return }
            self.dashboardDelegate?.dashboardDidRequestDelete(agent.id)
        }
        overviewView.onDeleteWorktreeWithBranch = { [weak self] path in
            guard let self, let agent = self.agents.first(where: { $0.worktreePath == path }) else { return }
            self.dashboardDelegate?.dashboardDidRequestDeleteWithBranch(agent.id)
        }
        // The bottom shortcut strip is a teaser for the full `?` cheat-sheet.
        overviewView.onShowAllShortcuts = { [weak self] in
            self?.toggleHelp()
        }
        overviewView.onGroupingChanged = { [weak self] in
            guard let self else { return }
            overviewSelectedId = overviewView.selectedId
            syncOverviewFocusCounts()
        }
        // "+" on a project group header: the anchored create form, scoped to that
        // project. The window owns the create itself (it holds the repo map and the
        // worktree-create path), so forward the click with its anchor view.
        overviewView.onIntegrate = { [weak self] project in
            self?.onIntegrateProject?(project)
        }
        overviewView.onAddWorktree = { [weak self] project, rect, anchor in
            self?.onAddWorktreeToProject?(project, rect, anchor)
        }
        // Header "+": the folder picker that adds a whole repo.
        overviewView.onAddRepo = { [weak self] in
            self?.onRequestAddRepo?()
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
    func updatePanes(_ newPanes: [WorktreeRowInfo], changedWorktreePath: String? = nil) {
        let oldIds = Set(agents.map { $0.id })
        let newIds = Set(newPanes.map { $0.id })
        let structureChanged = oldIds != newIds

        #if DEBUG
        if structureChanged, !oldIds.isEmpty {
            let added = newIds.subtracting(oldIds)
            let removed = oldIds.subtracting(newIds)
            NSLog("DashboardVC.updatePanes: structureChanged — added=%@ removed=%@", "\(added)", "\(removed)")
        }
        #endif

        agents = newPanes

        // Refresh the overview whenever the First Mate side column is on screen.
        // Without this check, an open First Mate sidebar showed the fleet frozen
        // at the state it had when opened.
        if firstMateSideOpen {
            overviewView.selectedId = overviewSelectedId
            overviewView.update(agents)
            syncOverviewFocusCounts()
        }

        if isInDState {
            focusController.refreshCards(cruiseOrder.map(\.id))
            applyKeyboardFocusVisuals()
        }

        // Show empty state when no agents
        if agents.isEmpty || DebugFlags.forceEmptyState {
            refreshEmptyStateGuide()
            emptyStateView.isHidden = false
            terminalHostView.addSubview(emptyStateView) // keep above focus panel
            leftRightContainer.isHidden = true
            leftRightFocusPanel.isHidden = true
            sidePanelVC.setWorktree(nil)
            return
        } else {
            emptyStateView.isHidden = true
            leftRightFocusPanel.isHidden = false
            leftRightContainer.isHidden = false
        }

        // Validate the selection. Now that a row is keyed by its worktree path,
        // this only fires when the selected worktree itself is gone (deleted, or
        // its last pane closed) — not when a pane inside it comes and goes, which
        // is what used to bounce the selection onto an unrelated worktree.
        if !agents.contains(where: { $0.id == selectedWorktreeId }) {
            selectedWorktreeId = agents.first?.id ?? ""
        }

        if structureChanged {
            rebuildFocusLayout()
        } else {
            reembedSplitContainerIfDetached()
        }
        syncSidePanelToSelection()
        // Keep edit-mode terminal tab titles current (strip diffs internally).
        refreshEditModeTabsIfActive()
    }

    private func syncSidePanelToSelection() {
        let path = agents.first(where: { $0.id == selectedWorktreeId })?.worktreePath
        sidePanelVC.setWorktree(path)
    }

    /// Re-embed the split container if it was detached (e.g. after a tab switch),
    /// but only when the dashboard is visible and no terminal already holds focus
    /// (avoids stealing focus during periodic status/branch refreshes).
    private func reembedSplitContainerIfDetached() {
        if activeSplitContainer == nil, view.window != nil,
           !(view.window?.firstResponder is GhosttyNSView) {
            embedSplitContainerForSelectedPane()
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
    func commitWorktreeSelection(path: String, focusTerminal: Bool = false) {
        lastCommittedWorktreePath = path
        guard agents.contains(where: { $0.worktreePath == path }) else { return }
        selectPane(byWorktreePath: path, focusTerminal: focusTerminal)
        overviewSelectedId = selectedWorktreeId
        // Push the highlight onto the overview so a programmatic commit (e.g. launch
        // restore, chat steering) moves the selected row just like a click does.
        if !overviewView.isHidden {
            overviewView.selectedId = overviewSelectedId
            overviewView.update(agents)
        }
    }

    func selectPane(byWorktreePath path: String, focusTerminal: Bool = true) {
        guard let agent = agents.first(where: { $0.worktreePath == path }) else { return }
        let changed = agent.id != selectedWorktreeId
        if changed {
            dismissCenterOverlay()
        }
        selectedWorktreeId = agent.id
        detachTerminals()
        embedSplitContainerForSelectedPane(focusTerminal: focusTerminal)
        syncSidePanelToSelection()
        if changed { notifySelectionChanged() }
    }

    // MARK: - View mode (alias of chrome collapse)

    /// Request a chrome collapse change. Layout width is owned by chrome — this
    /// only asks MainWindow to update `ChromeLayoutState`.
    func setViewMode(_ mode: ViewMode) {
        guard mode != viewMode else { return }
        onRequestSetChromeCollapsed?(mode == .terminal)
    }

    /// Mirror chrome collapse into the deprecated `ViewMode` alias and apply
    /// content-only side effects (no local column width constraints).
    /// `animated` says a chrome collapse animation is in flight. Re-embedding a
    /// split container reparents Ghostty surfaces — hundreds of milliseconds of
    /// synchronous main-thread work — and landing that mid-slide froze the main
    /// thread for the animation's whole duration, so ⌘B only ever showed its end
    /// state. Hold it until the slide is done.
    func adoptChromeCollapse(_ collapsed: Bool, activePane: ChromeLeftPane?, animated: Bool = false) {
        isLeftColumnCollapsed = collapsed
        let mode: ViewMode = collapsed ? .terminal : .split
        viewMode = mode
        let settleDelay = animated ? ChromeLayoutMetrics.collapseAnimationDuration : 0

        if collapsed {
            if firstMateSideOpen { flushPendingPreview() }
            lastCommittedWorktreePath = agents.first(where: { $0.id == selectedWorktreeId })?.worktreePath
                ?? lastCommittedWorktreePath
            DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay) { [weak self] in
                guard let self, self.viewMode == .terminal else { return }
                self.embedSplitContainerForSelectedPane(focusTerminal: true)
            }
        } else {
            switch activePane {
            case .files:
                openFilesColumn(.files)
                currentSide = .files
            case .changes:
                openFilesColumn(.changes)
                currentSide = .changes
            case .firstMate, .none:
                openFirstMateColumn()
                currentSide = .firstMate
            }
            lastCommittedWorktreePath = agents.first(where: { $0.id == selectedWorktreeId })?.worktreePath
                ?? lastCommittedWorktreePath
            // Same reasoning as the collapse branch — the first embed after a
            // cold start is the most expensive one there is.
            DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay) { [weak self] in
                guard let self, self.viewMode == .split else { return }
                if self.activeSplitContainer == nil {
                    self.embedSplitContainerForSelectedPane(focusTerminal: false)
                }
                self.view.window?.makeFirstResponder(self)
            }
        }
        notifyActiveTool()
    }

    /// Compute + publish the single lit chrome header tool from the current state.
    private func notifyActiveTool() {
        let pane: ChromeLeftPane?
        if isLeftColumnCollapsed {
            pane = nil
        } else {
            switch currentSide {
            case .firstMate: pane = .firstMate
            case .files:     pane = .files
            case .changes:   pane = .changes
            case .none:      pane = nil
            }
        }
        onActiveToolChanged?(pane)
    }

    /// Dock the overview into the left column (worktree First Mate) so expanding
    /// it pushes the terminal right — consistent with files/changes.
    private func mountOverviewInColumn() {
        overviewView.removeFromSuperview()
        overviewView.translatesAutoresizingMaskIntoConstraints = false
        overviewView.layer?.backgroundColor = NSColor.clear.cgColor
        leftColumnContainer.addSubview(overviewView)
        NSLayoutConstraint.activate([
            overviewView.topAnchor.constraint(equalTo: leftColumnContainer.topAnchor),
            overviewView.leadingAnchor.constraint(equalTo: leftColumnContainer.leadingAnchor),
            overviewView.trailingAnchor.constraint(equalTo: leftColumnContainer.trailingAnchor),
            overviewView.bottomAnchor.constraint(equalTo: leftColumnContainer.bottomAnchor),
        ])
    }

    /// First Mate icon → chrome `selectPane(.firstMate)` (re-click collapses).
    func toggleFirstMateSide() { onRequestSelectChromePane?(.firstMate) }

    /// Cmd+B: forward to chrome collapse SSOT (restores last pane on expand).
    func toggleSidebarDefaultDashboard() {
        onRequestToggleChromeCollapse?()
    }

    private func openFirstMateColumn() {
        firstMateSideOpen = true
        sidePanelVC.view.isHidden = true          // First Mate replaces file/change content
        mountOverviewInColumn()
        overviewView.isHidden = false
        overviewView.selectedId = overviewSelectedId
        overviewView.update(agents)
    }

    private func openFilesColumn(_ tab: SidePanelTab) {
        closeFirstMateSide()                      // undock First Mate if it was showing
        sidePanelVC.selectTab(tab)
        sidePanelVC.view.isHidden = false
    }

    /// Undock First Mate: restore the file/change side panel in the column.
    private func closeFirstMateSide() {
        guard firstMateSideOpen else { return }
        firstMateSideOpen = false
        overviewView.isHidden = true
        overviewView.removeFromSuperview()
        sidePanelVC.view.isHidden = false
    }

    /// Open the fleet overview as the left column (⌘E / title-bar dashboard icon).
    func enterOverview() { onRequestSetChromeCollapsed?(false) }

    /// Force the initial expanded First Mate state at launch when chrome has not
    /// already restored a pane. Does not override a collapsed sidebar or a
    /// restored files/changes selection.
    func activateInitialSplit() {
        if viewMode == .split, currentSide == .none || currentSide == .firstMate {
            openFirstMateColumn()
            currentSide = .firstMate
        }
        if activeSplitContainer == nil, !agents.isEmpty {
            embedSplitContainerForSelectedPane(focusTerminal: false)
        }
        notifyActiveTool()
    }

    /// Persist the current First Mate / terminal selection via the dashboard delegate.
    private func notifySelectionChanged() {
        dashboardDelegate?.dashboardDidChangeSelection(self)
    }

    /// Open the island's command bar with `prefill`. The fleet column no longer
    /// carries a composer, so every command entry point funnels here.
    func startNewCommand(prefill: String = "/new ") {
        onRequestCommandBar?(prefill)
    }

    /// Drill into a specific worktree without changing the chrome sidebar state.
    /// Clicking a row is what sets the overview's selection highlight.
    /// `⌃⇥` / `⌃⇧⇥`: switch to `path` and slide the fleet-list highlight onto it.
    ///
    /// This used to go through `selectTab(forWorktree:)` → `selectPane`, which
    /// swaps the terminal content but never touches the overview's selection — so
    /// the content changed while the fleet list (and the First Mate panel showing
    /// it) stayed highlighted on the previous worktree. Everything the highlight
    /// needs is here: the row id, the focus ring's index, and the animation.
    func cycleToWorktree(path: String) {
        selectPane(byWorktreePath: path)
        overviewSelectedId = selectedWorktreeId
        if let index = overviewView.orderedRows.firstIndex(where: { $0.path == path }) {
            _ = overviewFocus.jumpToWorktree(index)
        }
        guard !overviewView.isHidden else {
            overviewView.selectedId = overviewSelectedId
            return
        }
        if !overviewView.moveSelection(to: overviewSelectedId, animated: true) {
            overviewView.selectedId = overviewSelectedId
            overviewView.update(agents)
        }
    }

    func enterWorktree(byWorktreePath path: String) {
        selectPane(byWorktreePath: path)
        overviewSelectedId = selectedWorktreeId
        // If the overview is on screen (fleet full-screen, or docked as the First
        // Mate side panel), move its selection highlight to the clicked row.
        if !overviewView.isHidden {
            overviewView.selectedId = overviewSelectedId
            overviewView.update(agents)
        }
    }

    var isLeftColumnCollapsedState: Bool { isLeftColumnCollapsed }

    @discardableResult
    func toggleLeftColumnCollapse() -> Bool {
        onRequestToggleChromeCollapse?()
        return isLeftColumnCollapsed
    }

    /// Switch the left column's active pane via chrome `selectPane`.
    func selectLeftPane(_ pane: LeftPane) {
        currentLeftPane = pane
        onRequestSelectChromePane?(pane == .change ? .changes : .files)
    }

    /// Expand via chrome SSOT if currently collapsed.
    func expandLeftColumnIfCollapsed() {
        guard isLeftColumnCollapsed else { return }
        onRequestSetChromeCollapsed?(false)
    }

    /// Fleet status line was removed with the left bottom bar; kept as a no-op so
    /// the existing caller compiles. (Could move into the status bar later.)
    func updateFleetSummary(repos: Int, worktrees: Int, hidden: Int) {}

    // MARK: - Inline worktree creation

    func setupInlineCreate(repoPaths: [String],
                           repoPathsProvider: @escaping () -> [String],
                           onAddRepo: @escaping () -> Void,
                           onSubmitCommand: @escaping (String) -> Void,
                           onCreate: @escaping (String, String, AgentType, Bool) -> Void) {
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

    // MARK: - Layout

    private func rebuildFocusLayout() {
        if let selected = agents.first(where: { $0.id == selectedWorktreeId }) ?? agents.first {
            selectedWorktreeId = selected.id
            // Only embed when the dashboard is visible to avoid stealing
            // surfaces from the active repo tab's split container.
            if view.window != nil {
                embedSplitContainerForSelectedPane()
            }
        }
    }

    // MARK: - Setup: Empty State

    private func setupEmptyState() {
        emptyStateView.translatesAutoresizingMaskIntoConstraints = false
        emptyStateView.isHidden = true
        // Hosted in the terminal slot so it remains visible after chrome reparents hosts.
        terminalHostView.addSubview(emptyStateView)

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
        let label = NSTextField(labelWithString: "Add a project to get started")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 14)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        emptyStateView.addSubview(label)

        emptyStateGuideRows = [
            EmptyStateGuideRow(marker: "1.", command: "Add a project", detail: "pick a folder above"),
            EmptyStateGuideRow(marker: "2.", command: "/new <task>", detail: "start a project"),
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
            emptyStateView.topAnchor.constraint(equalTo: terminalHostView.topAnchor),
            emptyStateView.leadingAnchor.constraint(equalTo: terminalHostView.leadingAnchor),
            emptyStateView.trailingAnchor.constraint(equalTo: terminalHostView.trailingAnchor),
            emptyStateView.bottomAnchor.constraint(equalTo: terminalHostView.bottomAnchor),

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
        // Content hosts are slotted into WindowChromeController by MainWindow —
        // they are not laid out as a side-by-side pair inside dashboard.view.
        // leftRightContainer remains a visibility flag for empty-state toggles.
        leftRightContainer.translatesAutoresizingMaskIntoConstraints = false
        leftRightContainer.wantsLayer = true
        leftRightContainer.isHidden = true
        leftRightContainer.setAccessibilityIdentifier("dashboard.layout.left-right")
        leftRightContainer.setAccessibilityElement(true)

        // --- Navigator host: overview + side panel content swap (no width chrome) ---
        navigatorHostView.translatesAutoresizingMaskIntoConstraints = false
        navigatorHostView.wantsLayer = true
        navigatorHostView.layer?.cornerRadius = 0
        navigatorHostView.layer?.masksToBounds = true
        // Transparent so chrome sidebar vibrancy shows through.
        navigatorHostView.layer?.backgroundColor = NSColor.clear.cgColor
        navigatorHostView.setAccessibilityIdentifier("dashboard.leftColumn")

        // Worktree list (handed to the sidebar's Worktrees tab as worktreesTabView).


        addChild(sidePanelVC)
        sidePanelVC.view.translatesAutoresizingMaskIntoConstraints = false
        navigatorHostView.addSubview(sidePanelVC.view)

        // --- Terminal host: focus panel fills the chrome terminal slot ---
        terminalHostView.translatesAutoresizingMaskIntoConstraints = false
        terminalHostView.wantsLayer = true
        terminalHostView.layer?.backgroundColor = NSColor.clear.cgColor
        terminalHostView.setAccessibilityIdentifier("dashboard.terminalHost")

        leftRightFocusPanel.translatesAutoresizingMaskIntoConstraints = false
        leftRightFocusPanel.setCornerMask(
            [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner],
            radius: 0
        )
        terminalHostView.addSubview(leftRightFocusPanel)

        // Width/collapse constraints are retired as window chrome — chrome owns
        // sidebar width. Keep inactive stubs so existing toggle helpers compile
        // until Task 5b rewires collapse to ChromeLayoutState.
        leftColumnWidthExpanded = navigatorHostView.widthAnchor.constraint(equalToConstant: LayoutMetrics.leftColumnWidth)
        leftColumnWidthCollapsed = navigatorHostView.widthAnchor.constraint(equalToConstant: 0)
        leftColumnWidthExpanded?.isActive = false
        leftColumnWidthCollapsed?.isActive = false
        isLeftColumnCollapsed = false
        navigatorHostView.alphaValue = 1

        NSLayoutConstraint.activate([
            sidePanelVC.view.topAnchor.constraint(equalTo: navigatorHostView.topAnchor),
            sidePanelVC.view.leadingAnchor.constraint(equalTo: navigatorHostView.leadingAnchor),
            sidePanelVC.view.trailingAnchor.constraint(equalTo: navigatorHostView.trailingAnchor),
            sidePanelVC.view.bottomAnchor.constraint(equalTo: navigatorHostView.bottomAnchor),

            leftRightFocusPanel.topAnchor.constraint(equalTo: terminalHostView.topAnchor),
            leftRightFocusPanel.leadingAnchor.constraint(equalTo: terminalHostView.leadingAnchor),
            leftRightFocusPanel.bottomAnchor.constraint(equalTo: terminalHostView.bottomAnchor),
            leftRightFocusPanel.trailingAnchor.constraint(equalTo: terminalHostView.trailingAnchor),
        ])

        currentLeftPane = .file
        sidePanelVC.selectTab(.files)
    }

    // MARK: - Split container embedding

    private var activeSplitWorktreePath: String?

    /// Embed the selected agent's split container into the focus panel.
    /// `focusTerminal: false` is used for live nav preview — it keeps the dashboard
    /// VC as first responder so arrow keys keep driving the nav ring.
    func embedSplitContainerForSelectedPane(focusTerminal: Bool = true) {
        guard let agent = agents.first(where: { $0.id == selectedWorktreeId }) ?? agents.first else { return }
        let worktreePath = agent.worktreePath

        // Attach/detach the edit container for THIS worktree's mode before we pick
        // the embed target — currentTerminalContainer depends on it.
        prepareEditContainer(forWorktree: worktreePath)
        let container = currentTerminalContainer

        // Skip re-embed if the same split container is already active for this
        // worktree — but still hand it the keyboard when asked (e.g. committing
        // into mode 3 after a split-mode live preview already embedded it).
        if let active = activeSplitContainer,
           active.superview === container,
           activeSplitWorktreePath == worktreePath {
            finalizeEditLayout(focusTerminal: focusTerminal)
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
                // Asleep panes keep surface nil on purpose — recreating here while
                // leaving isAsleep set made Wake a no-op. The placeholder's Wake
                // button is the only way back.
                if Station.shouldCreateSurfaceOnEmbed(
                    hasSurface: station.surface != nil, isAsleep: station.isAsleep
                ) {
                    let stationId = leaf.stationId
                    _ = station.create(in: container, workingDirectory: worktreePath, paneSessionKey: station.paneSessionKey) { [weak splitView] in
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

        // Embed with a short crossfade — a hard cut swaps the whole terminal
        // surface in one frame and reads as a flash.
        splitView.frame = container.bounds
        splitView.autoresizingMask = [.width, .height]
        splitView.alphaValue = previousSplitView == nil ? 1 : 0
        container.addSubview(splitView)
        splitView.tree = tree
        activeSplitContainer = splitView
        activeSplitWorktreePath = worktreePath

        if let previousSplitView {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.15
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                splitView.animator().alphaValue = 1
            }, completionHandler: {
                // Only detach if a later switch hasn't already re-embedded it.
                if previousSplitView !== self.activeSplitContainer {
                    previousSplitView.removeFromSuperview()
                }
                previousSplitView.alphaValue = 1
            })
        }
        syncSidePanelToSelection()

        finalizeEditLayout(focusTerminal: focusTerminal, tree: tree)
    }

    /// Shared tail for `embedSplitContainerForSelectedPane`: applies zoom + tab
    /// strips in edit mode (or restores the spatial split in focus mode), then
    /// takes keyboard focus when asked. Never re-enters embed (no recursion).
    private func finalizeEditLayout(focusTerminal: Bool, tree: SplitTree? = nil) {
        let editMode = editLayoutContainer?.superview != nil
        if editMode {
            applyZoomToFocusedLeaf()
            refreshEditModeTabs()
            updatePreviewContent()
        } else if let container = activeSplitContainer, container.zoomedLeafId != nil {
            // Leaving edit mode: drop the zoom so the spatial split is restored.
            container.zoomedLeafId = nil
            container.layoutTree()
        }
        notifyEditModeState()

        // Focus the active leaf — defer to let the view hierarchy settle.
        // Skipped during nav preview so the dashboard VC keeps first responder.
        guard focusTerminal else { return }

        if editMode {
            focusZoomedLeaf()
        } else {
            focusActiveTerminalLeaf(tree: tree)
        }
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

        // Drop this worktree's preview set + any cached preview content views.
        for file in previewSets.files(for: path) {
            previewContentCache[file]?.removeFromSuperview()
            previewContentCache.removeValue(forKey: file)
        }
        previewSets.forget(worktree: path)
    }

    // MARK: - Dashboard Navigation (D-state)

    func enterDashboardNavigation() {
        guard !isInDState else { return }

        // Entering the ring drops any substate left over from a previous visit.
        windowKeyboardSubstate?.reset()

        let snapshot = DashboardFocusController.Snapshot(
            firstResponder: view.window?.firstResponder,
            focusedWorktreePath: agents.first(where: { $0.id == selectedWorktreeId })?.worktreePath
        )
        focusController.captureSnapshot(snapshot)

        let cardIds = cruiseOrder.map(\.id)
        let initial = snapshot.focusedWorktreePath
            .flatMap { path in agents.first(where: { $0.worktreePath == path })?.id }
            ?? (selectedWorktreeId.isEmpty ? nil : selectedWorktreeId)
        focusController.enterFocusLayout(cardIds: cardIds, initialId: initial)

        view.window?.makeFirstResponder(self)
        applyKeyboardFocusVisuals()
        applyDimOverlayIfNeeded()
    }

    func exitDashboardNavigation(restoreSnapshot: Bool) {
        guard isInDState else { return }

        let snapshot = focusController.snapshot
        tearDownNavVisuals()

        // A cancelling exit (Esc) undoes any live preview by restoring the pre-nav
        // selection. A committing exit (Return) keeps whatever is currently previewed.
        if restoreSnapshot,
           let path = snapshot?.focusedWorktreePath,
           let original = agents.first(where: { $0.worktreePath == path }),
           original.id != selectedWorktreeId {
            selectPane(byWorktreePath: path)
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

    /// Leave the nav focus ring WITHOUT touching `windowKeyboardSubstate`: opens the inline
    /// create form. `beginCreateForm()` has already set `.normal` + `.createForm`; we only
    /// drop the D-state focus ring so a stray key in the form can't be read as a nav chord
    /// (e.g. `d` starting a delete). On form end, `enterDashboardNavigation()` re-enters.
    func exitNavForCreateForm() {
        guard isInDState else { return }
        tearDownNavVisuals()
    }

    /// Visual/state teardown shared by `exitDashboardNavigation` and `exitNavForCreateForm`.
    /// Drops the focus ring, dim overlays, and exits the focus controller. Deliberately does
    /// NOT touch `windowKeyboardSubstate` or restore the first responder — callers own those decisions.
    private func tearDownNavVisuals() {
        focusController.exit()
        clearKeyboardFocusVisuals()
        clearDimOverlay()
    }

    // MARK: - D-state visual helpers

    private func applyKeyboardFocusVisuals() {
        clearKeyboardFocusVisuals()
        switch focusController.focusedTarget {
        case .none: return
        case .bigPanel:
            leftRightFocusPanel.isKeyboardFocused = true
        case .card:
            break
        }
    }

    private func clearKeyboardFocusVisuals() {
        leftRightFocusPanel.isKeyboardFocused = false
    }

    private func applyDimOverlayIfNeeded() {
        leftRightFocusPanel.showDimOverlay(opacity: 0.05)
    }

    private func clearDimOverlay() {
        leftRightFocusPanel.hideDimOverlay()
    }

    // MARK: - D-state key handling

    /// The dashboard answers only three bare keys now: `?` for the cheat-sheet,
    /// Esc to close an overlay / leave the focus ring, and the `/ @ #` command
    /// prefixes (in `handleNavKey`). Worktree movement is `⌃⇥` / `⌃⇧⇥` at the window
    /// level — the old `hjkl` / `{}` / `1–9` / `i d c f m n` ring is gone, so
    /// everything else falls through to the responder chain.
    override func keyDown(with event: NSEvent) {
        if viewMode != .terminal, !isInDState {
            handleNavKey(event); return
        }
        guard isInDState else { super.keyDown(with: event); return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if event.keyCode == 53 {  // Esc closes overlays first, then exits nav
            if closeTopmostOverlay() { return }
            if flags.isEmpty { exitDashboardNavigation(restoreSnapshot: true); return }
        }
        if flags.isDisjoint(with: [.command, .control, .option]), event.characters == "?" {
            toggleHelp(); return
        }
        super.keyDown(with: event)
    }

    private var windowKeyboardSubstate: KeyboardSubstateController? {
        (view.window?.windowController as? MainWindowController)?.keyboardSubstate
    }

    /// The D-state card ring, in fleet-list display order.
    ///
    /// The ring used to be `agents.map(\.id)` — discovery order — while the list on
    /// screen is grouped and sorted by `WorktreeGroupingMode`. Under any grouping but
    /// the default that made `hjkl` and `1–9` walk an order the eye can't see. The
    /// rendered order is the only one that matches, so it is the ring; the raw
    /// agent order survives only as a fallback for before the overview first
    /// rendered (launching straight into terminal mode).
    var cruiseOrder: [(id: String, path: String)] {
        overviewView.orderedRows.isEmpty
            ? agents.map { (id: $0.id, path: $0.worktreePath) }
            : overviewView.orderedRows
    }

    /// Worktree paths in display order, for the window-level `⌃⇥` worktree cycle.
    var cruiseOrderPaths: [String] { cruiseOrder.map(\.path) }

    // MARK: - Overview (fleet) keyboard handling

    /// Keyboard handling while the overview drives the keyboard (modes 1 & 2).
    ///
    /// The vertical nav ring that used to live here (↑↓ / `jk` walking rows,
    /// `⏎`/`→` committing forward, `{}` group jumps, `1–9`) is gone: worktrees move
    /// with the window-level `⌃⇥` / `⌃⇧⇥` cycle, and rows are still clickable.
    /// What stays is what isn't worktree movement — Tab's region cycle, `?`, and the
    /// island's command prefixes.
    private func handleNavKey(_ event: NSEvent) {
        if event.keyCode == 53 {  // Esc closes overlays (help, …)
            if closeTopmostOverlay() { return }
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.isDisjoint(with: [.command, .control, .option]) else { super.keyDown(with: event); return }
        if event.keyCode == 48 { handleNavTab(); return }                // Tab
        switch event.charactersIgnoringModifiers {
        case "?": toggleHelp()
        case let ch? where ch == "/" || ch == "@" || ch == "#": onRequestCommandBar?(ch)
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
            guard let row = overviewView.orderedRows[safeIndex: i] else { break }
            let selectionChanged = row.id != overviewSelectedId
            overviewSelectedId = row.id
            overviewView.selectedId = row.id
            overviewView.update(agents)
            // Persist the highlighted row immediately so a quit during the
            // preview debounce still restores this worktree, not the previous one.
            if selectionChanged || selectedWorktreeId != row.id {
                selectedWorktreeId = row.id
                notifySelectionChanged()
            }
            if viewMode == .split { schedulePreview(path: row.path) }
        }
    }

    private func handleNavTab() {
        // Tab advances the outer region cycle (panes → sidebar → titlebar/chrome
        // header → helm).
        let forward = !(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false)
        (view.window?.windowController as? MainWindowController)?
            .cycleKeyboardRegion(forward: forward)
    }

    /// Click on a fleet row:
    /// - different row: switch worktrees and hand the keyboard to the active pane
    /// - already-selected row: reclaim terminal keyboard focus (sidebar stays open)
    /// Test seam for the row-click path (the click itself arrives via a closure).
    func handleWorktreeRowClickForTesting(path: String) { handleWorktreeRowClick(path: path) }

    /// What the fleet list — and the First Mate panel that renders it — is
    /// currently highlighting, which is not always the selected pane.
    var overviewSelectedIdForTesting: String { overviewView.selectedId }
    var hasCenterOverlayForTesting: Bool { centerOverlay != nil }

    /// Pane row click in "Group by Pane": drill into the worktree, then focus
    /// the clicked pane's leaf. The split container may still be settling, so the
    /// focus attempt is deferred (mirrors `focusActiveTerminalLeaf`).
    private func handlePaneRowClick(path: String, stationId: String) {
        enterWorktree(byWorktreePath: path)
        guard let container = activeSplitContainer, let tree = container.tree,
              let leaf = tree.allLeaves.first(where: { $0.stationId == stationId }) else { return }
        tree.focusedId = leaf.id
        container.layoutTree()
        DispatchQueue.main.async { [weak self] in
            self?.focusActiveTerminalLeaf(tree: tree)
        }
    }

    private func handleWorktreeRowClick(path: String) {
        // A click commits immediately — cancel any queued live-preview so it
        // can't race the embed and leave focus on the previous worktree.
        previewDebounceWork?.cancel()
        previewDebounceWork = nil
        pendingPreviewPath = nil

        guard let i = overviewView.orderedRows.firstIndex(where: { $0.path == path }) else {
            // Not a fleet row (orders card path, stale list) — drill in as before.
            enterWorktree(byWorktreePath: path)
            return
        }
        let row = overviewView.orderedRows[i]
        // Land the ring on the clicked row so a following ⌃⇥ continues from here
        // rather than from wherever the selection was last.
        _ = overviewFocus.jumpToWorktree(i)

        // Mouse click must focus the terminal. The old split-mode path used
        // preview-without-focus so ↑↓ keyboard live-nav could keep the dashboard
        // as first responder — that ring is gone, and leaving `tree.focusedId`
        // lit while Ghostty is not first responder made panes look focused but
        // reject typing until a second click.
        if row.id == overviewSelectedId, activeSplitWorktreePath == path {
            focusActiveTerminalLeaf()
            return
        }
        enterWorktree(byWorktreePath: path)
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

    /// Flush a queued First Mate preview so quit/save sees the terminal that
    /// matches the highlighted row.
    func flushPendingPreviewForPersistence() {
        flushPendingPreview()
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

    /// Live-follow in mode 2: swap the right-hand terminal to `path` without
    /// stealing keyboard focus from the nav ring. Selection identity is already
    /// updated (and persisted) by `applyOverviewEffect`; this only embeds.
    private func previewWorktree(path: String) {
        guard let agent = agents.first(where: { $0.worktreePath == path }) else { return }
        selectedWorktreeId = agent.id
        guard activeSplitWorktreePath != path else { return }
        detachTerminals()
        embedSplitContainerForSelectedPane(focusTerminal: false)
        syncSidePanelToSelection()
    }

    /// Re-clamp the focus ring after the fleet list rebuilt.
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
            worktreeAnchor: anchor
        )
        // Refresh highlights only — a data refresh must not re-trigger terminal
        // embeds or focus moves.
        switch effect {
        case .previewWorktree(let i):
            if let row = overviewView.orderedRows[safeIndex: i], row.id != overviewSelectedId {
                overviewSelectedId = row.id
                overviewView.selectedId = row.id
            }
        default:
            break
        }
    }

}

// MARK: - Dashboard Root View (resolves bg color via updateLayer)

private class DashboardRootView: NSView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        // Chrome owns the glass sidebar + opaque terminal. Keep the dashboard
        // root fully clear so vibrancy isn't covered by a solid panel fill.
        layer?.backgroundColor = NSColor.clear.cgColor
    }
}

extension DashboardViewController {


    // MARK: - Center Overlay

    /// Shows a full-cover overlay over the center terminal panel.
    /// Title is shown in the chrome `TerminalHeaderView` (not a second overlay header).
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
            content: content, onSave: onSave, onPreview: onPreview
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
        onCenterOverlayTitleChange?(title)
        overlay.window?.makeFirstResponder(overlay)
        return overlay
    }

    /// Removes the center overlay and restores first responder to the active terminal pane.
    func dismissCenterOverlay() {
        guard let overlay = centerOverlay else { return }
        centerOverlay = nil
        onCenterOverlayTitleChange?(nil)
        // Pull out of the hierarchy immediately so the click feels instant;
        // CodeEdit/SwiftUI teardown is deferred to the next turn.
        overlay.removeFromSuperview()

        DispatchQueue.main.async { [weak self, overlay] in
            _ = overlay // release after this runloop turn
            guard let self, let container = self.activeSplitContainer, let tree = container.tree else { return }
            let focusedId = tree.focusedId
            if let leaf = tree.allLeaves.first(where: { $0.id == focusedId }),
               let termView = container.surfaceViews[leaf.stationId] {
                self.view.window?.makeFirstResponder(termView)
            }
        }
    }
}


// MARK: - Edit mode (split file-preview layout)

extension DashboardViewController {

    /// Toggle the selected worktree between focus and edit layout. No-op if the
    /// preview set is empty (nothing to show in the right column).
    func toggleEditMode() {
        guard let wt = currentWorktreePath, !previewSets.isEmpty(wt) else { return }
        let goingEdit = !previewSets.isEditMode(for: wt)
        previewSets.setEditMode(goingEdit, for: wt)
        // Re-embed retargets the split into the right container (prepare attaches/
        // detaches the edit shell). Don't steal terminal focus when entering edit.
        embedSplitContainerForSelectedPane(focusTerminal: !goingEdit)
        if goingEdit {
            if let active = previewSets.activeFile(for: wt) { selectPreviewTab(active) }
        } else {
            // Carry the active file across: focus mode shows it fullscreen.
            dismissCenterOverlay()
            if let active = previewSets.activeFile(for: wt) { presentFileOverlay(path: active) }
        }
        notifyEditModeState()
    }

    private func notifyEditModeState() {
        guard let wt = currentWorktreePath else {
            onEditModeStateChange?(false, false)
            return
        }
        onEditModeStateChange?(!previewSets.isEmpty(wt), previewSets.isEditMode(for: wt))
    }

    // MARK: Container attach / detach

    /// Attach or detach the two-column edit shell for `wt`'s current mode. Runs
    /// before the embed target is chosen; never re-enters embed.
    private func prepareEditContainer(forWorktree wt: String) {
        let container = leftRightFocusPanel.terminalContainer
        if previewSets.isEditMode(for: wt) {
            dismissCenterOverlay()
            let edit = editLayoutContainer ?? makeEditContainer()
            edit.updateRatio(previewSets.splitRatio(for: wt))
            if edit.superview !== container {
                edit.frame = container.bounds
                edit.autoresizingMask = [.width, .height]
                container.addSubview(edit)
            }
            onEditModeStripsActive?(true, edit.currentRatio)
        } else if let edit = editLayoutContainer {
            onEditModeStripsActive?(false, edit.currentRatio)
            edit.removeFromSuperview()
            editLayoutContainer = nil
        }
    }

    private func makeEditContainer() -> EditLayoutContainerView {
        let ratio = currentWorktreePath.map { previewSets.splitRatio(for: $0) } ?? 0.5
        let edit = EditLayoutContainerView(ratio: ratio)
        edit.onRatioChange = { [weak self] r in
            guard let self else { return }
            self.onEditStripRatioChange?(r)
            guard let wt = self.currentWorktreePath else { return }
            self.previewSets.setSplitRatio(r, for: wt)
        }
        editLayoutContainer = edit
        return edit
    }

    // MARK: Terminal tabs (LEFT column)

    private func applyZoomToFocusedLeaf() {
        guard let split = activeSplitContainer, let tree = split.tree else { return }
        let id = split.zoomedLeafId ?? tree.focusedId
        guard tree.allLeaves.contains(where: { $0.id == id }) else {
            // Focused leaf gone (pane closed): fall back to the first leaf.
            if let first = tree.allLeaves.first {
                tree.focusedId = first.id
                split.setZoom(leafId: first.id, on: true)
            }
            return
        }
        tree.focusedId = id
        split.setZoom(leafId: id, on: true)
    }

    private func selectTerminalTab(_ leafId: String) {
        guard let split = activeSplitContainer, let tree = split.tree,
              tree.allLeaves.contains(where: { $0.id == leafId }) else { return }
        tree.focusedId = leafId
        split.setZoom(leafId: leafId, on: true)
        refreshEditModeTabs()
        focusZoomedLeaf()
    }

    func editModeCycleTerminalTab(forward: Bool) {
        guard let split = activeSplitContainer, let tree = split.tree else { return }
        let leaves = tree.allLeaves
        guard !leaves.isEmpty else { return }
        let current = split.zoomedLeafId ?? tree.focusedId
        let idx = leaves.firstIndex(where: { $0.id == current }) ?? 0
        let next = leaves[(idx + (forward ? 1 : leaves.count - 1)) % leaves.count]
        selectTerminalTab(next.id)
    }

    private func focusZoomedLeaf() {
        guard let split = activeSplitContainer, let tree = split.tree else { return }
        let id = split.zoomedLeafId ?? tree.focusedId
        guard let leaf = tree.allLeaves.first(where: { $0.id == id }),
              let view = split.surfaceViews[leaf.stationId] else { return }
        view.window?.makeFirstResponder(view)
        DispatchQueue.main.async {
            if !(view.window?.firstResponder is GhosttyNSView) {
                view.window?.makeFirstResponder(view)
            }
        }
    }

    // MARK: Preview tabs (RIGHT column)

    private func selectPreviewTab(_ path: String) {
        guard let wt = currentWorktreePath else { return }
        previewSets.setActive(path, for: wt)
        updatePreviewContent()
        refreshEditModeTabs()
    }

    func editModeCyclePreviewTab(forward: Bool) {
        guard let wt = currentWorktreePath else { return }
        let files = previewSets.files(for: wt)
        guard !files.isEmpty else { return }
        let current = previewSets.activeFile(for: wt)
        let idx = current.flatMap { files.firstIndex(of: $0) } ?? 0
        let next = files[(idx + (forward ? 1 : files.count - 1)) % files.count]
        selectPreviewTab(next)
    }

    private func closePreviewTab(_ path: String) {
        guard let wt = currentWorktreePath else { return }
        let doomed = previewContentCache.removeValue(forKey: path)
        doomed?.removeFromSuperview()
        // Defer CodeEdit teardown so the tab close isn't blocked on deinit.
        if let doomed {
            DispatchQueue.main.async { _ = doomed }
        }
        _ = previewSets.remove(path, from: wt)

        if previewSets.isEmpty(wt) {
            // Degrade to focus mode when the last preview closes.
            previewSets.setEditMode(false, for: wt)
            embedSplitContainerForSelectedPane(focusTerminal: true)
        } else {
            updatePreviewContent()
            refreshEditModeTabs()
        }
        notifyEditModeState()
    }

    /// Show the active preview file's content view in the right host, building +
    /// caching it on first use so tab switches preserve editor state.
    private func updatePreviewContent() {
        guard let edit = editLayoutContainer, let wt = currentWorktreePath else { return }
        let host = edit.previewHost
        guard let active = previewSets.activeFile(for: wt) else {
            host.subviews.forEach { $0.isHidden = true }
            return
        }
        let content: NSView
        if let cached = previewContentCache[active] {
            content = cached
        } else {
            content = makePreviewContent(path: active)
            previewContentCache[active] = content
            content.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(content)
            NSLayoutConstraint.activate([
                content.topAnchor.constraint(equalTo: host.topAnchor),
                content.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                content.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            ])
        }
        if content.superview !== host {
            content.removeFromSuperview()
            content.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(content)
            NSLayoutConstraint.activate([
                content.topAnchor.constraint(equalTo: host.topAnchor),
                content.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                content.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            ])
        }
        for sub in host.subviews { sub.isHidden = (sub !== content) }
    }

    /// Build the content view for a preview tab, wrapped in the same
    /// `CenterOverlayView` chrome the focus-mode overlay uses (Close / Save /
    /// Preview toolbar + Cmd+S + Esc) so the two modes are identical. The
    /// toolbar's Close closes this tab.
    ///
    /// Text files show a spinner first while bytes are read off-main, then the
    /// cache entry is swapped for the real editor so the click stays responsive.
    private func makePreviewContent(path: String) -> NSView {
        let onClose: () -> Void = { [weak self] in self?.closePreviewTab(path) }
        if let media = MediaPreviewView.make(path: path) {
            return CenterOverlayView(content: media, onClose: onClose)
        }

        let loading = CenterOverlayView(content: EditorLoadingView(), onClose: onClose)
        // Register before the async hop so a fast disk read can't miss the
        // identity check (updatePreviewContent also assigns this same ref).
        previewContentCache[path] = loading
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let text = FileContentView.readContent(at: path)
            DispatchQueue.main.async {
                guard let self else { return }
                // Tab closed or superseded while we were reading — drop the result.
                guard self.previewContentCache[path] === loading else { return }
                let replacement = self.buildPreviewOverlayView(
                    path: path, text: text, onClose: onClose
                )
                self.previewContentCache[path] = replacement
                loading.removeFromSuperview()
                DispatchQueue.main.async { _ = loading }
                if let wt = self.currentWorktreePath,
                   self.previewSets.activeFile(for: wt) == path {
                    self.updatePreviewContent()
                }
            }
        }
        return loading
    }

    /// Shared builder: already-resolved text → editor/fallback wrapped in
    /// `CenterOverlayView`, with Save/Preview wiring for editable text.
    private func buildPreviewOverlayView(
        path: String,
        text: String?,
        onClose: @escaping () -> Void
    ) -> NSView {
        if let text {
            let editor = CodeEditorView(fileURL: URL(fileURLWithPath: path), text: text)
            return wrapEditorInOverlay(editor, onClose: onClose)
        }
        let fallback = MediaPreviewView.fallback(path: path) ?? FileContentView(path: path)
        return CenterOverlayView(content: fallback, onClose: onClose)
    }

    /// Wire Save / Preview / dirty chrome around a loaded `CodeEditorView`.
    private func wrapEditorInOverlay(
        _ editor: CodeEditorView,
        onClose: @escaping () -> Void
    ) -> CenterOverlayView {
        weak var overlayRef: CenterOverlayView?
        let overlay = CenterOverlayView(
            content: editor,
            onSave: { [weak editor] in editor?.save() },
            onPreview: editor.isPreviewable ? { [weak editor] in
                guard let editor else { return }
                overlayRef?.setPreviewing(editor.togglePreview())
            } : nil,
            onClose: onClose
        )
        overlayRef = overlay
        editor.onDirtyChange = { [weak overlay] dirty in
            overlay?.setDirty(dirty)
        }
        return overlay
    }

    // MARK: Tab strip refresh

    private func refreshEditModeTabs() {
        guard editLayoutContainer != nil, let wt = currentWorktreePath else { return }

        let tree = activeSplitContainer?.tree
        let leaves = tree?.allLeaves ?? []
        let selectedLeaf = activeSplitContainer?.zoomedLeafId ?? tree?.focusedId
        let termItems = leaves.map { leaf in
            EditTabStripView.Item(
                id: leaf.id,
                title: terminalTabTitle(leaf: leaf, worktree: wt),
                closable: false
            )
        }
        chromeEditStrips()?.terminal.apply(items: termItems, selectedId: selectedLeaf)

        let files = previewSets.files(for: wt)
        let previewItems = files.map { path in
            EditTabStripView.Item(
                id: path,
                title: URL(fileURLWithPath: path).lastPathComponent,
                closable: true
            )
        }
        chromeEditStrips()?.preview.apply(items: previewItems, selectedId: previewSets.activeFile(for: wt))
    }

    private func terminalTabTitle(leaf: SplitNode.LeafInfo, worktree: String) -> String {
        if let pane = AgentRegistry.shared.panes(forWorktree: worktree)
            .first(where: { $0.id == leaf.stationId }) {
            return PaneTitleResolver.title(for: pane)
        }
        return leaf.paneSessionKey
    }

    /// Called by the status/title refresh path so edit-mode terminal tabs track
    /// pane titles without churning the view tree (the strip diffs internally).
    func refreshEditModeTabsIfActive() {
        guard isEditModeActive else { return }
        refreshEditModeTabs()
    }
}

// MARK: - WorktreeSidePanelDelegate

extension DashboardViewController: WorktreeSidePanelDelegate {
    func sidePanel(_ vc: WorktreeSidePanelViewController, didSelectFile path: String) {
        openFile(path: path)
    }

    /// Open a file through the same viewer path as selecting it in the Files tab:
    /// a right-column tab in edit mode, otherwise the fullscreen center overlay.
    /// Used by the terminal pane's "Preview" context-menu action.
    func openFile(path: String) {
        // Record the file into the (mode-decoupled) preview set. In edit mode it
        // becomes a right-column tab; otherwise it opens as the fullscreen overlay.
        guard let wt = currentWorktreePath else {
            presentFileOverlay(path: path)
            return
        }
        previewSets.add(path, to: wt)

        if previewSets.isEditMode(for: wt) {
            embedSplitContainerForSelectedPane(focusTerminal: false)
            selectPreviewTab(path)
        } else {
            presentFileOverlay(path: path)
        }
        notifyEditModeState()
    }

    /// Present a file as the fullscreen center overlay (focus-mode viewer).
    func presentFileOverlay(path: String) {
        // Full path, not just the basename: the fullscreen viewer fills the
        // window with no other cue about which of several same-named files
        // (Contents.json, index.ts, mod.rs…) is on screen.
        let title = (path as NSString).abbreviatingWithTildeInPath

        // Images and audio/video get a native viewer. Everything else — including
        // markdown and unregistered extensions — goes to the editor first.
        if let media = MediaPreviewView.make(path: path) {
            showCenterOverlay(media, title: title)
            return
        }

        // Show a spinner immediately; file I/O + CodeEdit construction follow
        // once bytes are ready so the file-tree click isn't blocked on disk.
        let loadingOverlay = showCenterOverlay(EditorLoadingView(), title: title)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let text = FileContentView.readContent(at: path)
            DispatchQueue.main.async {
                guard let self else { return }
                // User closed or opened another file while we were reading.
                guard self.centerOverlay === loadingOverlay else { return }

                if let text {
                    let editor = CodeEditorView(
                        fileURL: URL(fileURLWithPath: path), text: text
                    )
                    weak var overlayRef: CenterOverlayView?
                    let overlay = self.showCenterOverlay(
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
                } else {
                    // Binary / oversized: QuickLook, then the read-only placeholder.
                    let fallback = MediaPreviewView.fallback(path: path)
                        ?? FileContentView(path: path)
                    self.showCenterOverlay(fallback, title: title)
                }
            }
        }
    }

    func sidePanel(_ vc: WorktreeSidePanelViewController, didSelectChange path: String) {
        let worktreePath = agents.first(where: { $0.id == selectedWorktreeId })?.worktreePath ?? ""
        let fileName = URL(fileURLWithPath: path).lastPathComponent
        let title = fileName.isEmpty ? "Changes" : fileName
        showCenterOverlay(
            DiffReviewView(worktreePath: worktreePath, selectedPath: path),
            title: title
        )
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

/// Full-width fleet overview: every worktree as a row grouped by the chosen mode,
/// with a shortcut cheat-strip along the bottom. This is the landing surface (the
/// "spread First Mate"); clicking a row drills into that worktree. Commands and
/// pending orders live in the island, not here.
extension Array {
    subscript(safeIndex index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// A fleet row that paints a pointer-hover tint.
///
/// Hover is owned by the list, not by the row's own tracking area. AppKit pairs
/// `mouseEntered` / `mouseExited` off pointer *movement*: scrolling the fleet
/// under a stationary cursor delivers an enter for every row that slides beneath
/// the pointer and no matching exit, so each one it passed stayed tinted and the
/// list read as a dozen rows selected at once. Routing both edges through the
/// list keeps at most one row lit no matter which events AppKit drops.
private protocol FleetHoverRow: NSView {
    func setHovered(_ hovered: Bool)
}

final class DashboardOverviewView: NSView {

    /// Resolves a worktree's current-pane title for order cards.
    var currentPaneTitleProvider: ((String) -> String?)?
    var onSelectWorktree: ((String) -> Void)?
    /// A pane row was clicked in the expanded "Group by Pane" mode. Args:
    /// the pane's worktree path and its Station id.
    var onSelectPane: ((String, String) -> Void)?
    var onDeleteWorktree: ((String) -> Void)?
    var onDeleteWorktreeWithBranch: ((String) -> Void)?
    var onGroupingChanged: (() -> Void)?
    /// The "+" on a project group header was clicked. Args: the project title,
    /// the button's rect in this view's coordinates, and this view (the popover's
    /// anchor — see `addWorktreeClicked`).
    var onAddWorktree: ((String, NSRect, NSView) -> Void)?
    var onIntegrate: ((String) -> Void)?
    /// The header "+" was clicked: add a repo via the folder picker.
    var onAddRepo: (() -> Void)?
    /// The bottom shortcut strip was clicked — show the full `?` cheat-sheet.
    var onShowAllShortcuts: (() -> Void)?

    // Palette — accent hues stay fixed; text/line/panel adapt to light/dark so
    // the navigator stays readable on the glass sidebar in both appearances.
    private static let line = NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 150/255, green: 215/255, blue: 225/255, alpha: 0.10)
            : NSColor(srgbRed: 0x1f/255, green: 0x23/255, blue: 0x2b/255, alpha: 0.10)
    }
    // Dynamic: the raw #1fc8da cyan is unreadable as label ink on the light
    // panel (ORDERS header, `/` trigger glyph).
    private static let sea: NSColor = SemanticColors.accent
    fileprivate static let ink: NSColor = SemanticColors.text
    fileprivate static let inkDim: NSColor = SemanticColors.muted
    fileprivate static let inkFaint: NSColor = SemanticColors.subtle
    fileprivate static let red        = NSColor(srgbRed: 0xe0/255, green: 0x7a/255, blue: 0x6a/255, alpha: 1)
    fileprivate static let emerald    = NSColor(srgbRed: 0x5f/255, green: 0xb8/255, blue: 0x7a/255, alpha: 1)

    private let headerTitle = NSTextField(labelWithString: "First mate")
    private let headerSub = NSTextField(labelWithString: "")
    private let groupingButton = NSButton()
    private let addRepoButton = NSButton()
    private let groupingMenu = NSMenu()
    private let headerLine = NSView()
    private let scroll = NonFirstResponderScrollView()
    private let stack = FlippedStackView()

    // Bottom shortcut cheat-strip (replaced the composer).
    private let hintBar = ShortcutHintBar()

    private let groupingPreference: WorktreeGroupingPreference
    private let now: () -> Date
    private var groupingMode: WorktreeGroupingMode
    private var latestPanes: [WorktreeRowInfo] = []
    private var rowViewsByID: [String: RowView] = [:]
    private var renderedGroupTitles: [String] = []
    /// Project title per "add worktree" button, indexed by the button's tag —
    /// rebuilt with the rows on every render.
    private var addWorktreeProjects: [String] = []
    /// Tag → project for the integrate buttons, rebuilt on every full render
    /// exactly like `addWorktreeProjects`.
    private var integrateProjects: [String] = []
    private static let addWorktreeButtonIdentifier = NSUserInterfaceItemIdentifier("seahelm.addWorktree")
    private static let integrateButtonIdentifier = NSUserInterfaceItemIdentifier("seahelm.integrate")
    private var revealedRowID: String?
    /// The one row currently painting the hover tint, if any.
    private weak var hoveredRow: FleetHoverRow?
    private var paneRowViewsByStationID: [String: PaneRowView] = [:]
    private var lastStructureSignature: String?
    private var fullRenderCount = 0
    #if DEBUG
    private var incrementalUpdateCount = 0
    private var fullRenderTotalDurationMs: Double = 0
    private var incrementalTotalDurationMs: Double = 0
    private var lastTelemetryLogAt = Date.distantPast
    #endif

    override init(frame frameRect: NSRect) {
        let preference = WorktreeGroupingPreference(defaults: .standard)
        groupingPreference = preference
        now = Date.init
        groupingMode = preference.load()
        super.init(frame: frameRect)
        setup()
    }
    required init?(coder: NSCoder) {
        let preference = WorktreeGroupingPreference(defaults: .standard)
        groupingPreference = preference
        now = Date.init
        groupingMode = preference.load()
        super.init(coder: coder)
        setup()
    }

    init(frame frameRect: NSRect, defaults: UserDefaults, now: @escaping () -> Date) {
        let preference = WorktreeGroupingPreference(defaults: defaults)
        groupingPreference = preference
        self.now = now
        groupingMode = preference.load()
        super.init(frame: frameRect)
        setup()
    }


    private func setup() {
        wantsLayer = true
        // Clear so WindowChromeController's sidebar vibrancy shows through.
        layer?.backgroundColor = NSColor.clear.cgColor

        // --- Header: ◍ First mate   N worktrees · M running  (border-bottom) ---
        let headerIcon = NSTextField(labelWithString: "◍")
        headerIcon.font = AppFont.mono(size: 13)
        headerIcon.textColor = Self.sea
        headerTitle.stringValue = "First mate"
        headerTitle.font = AppFont.mono(size: 12.5, weight: .bold)
        headerTitle.textColor = Self.ink
        headerSub.font = AppFont.mono(size: 11)
        headerSub.textColor = Self.inkFaint
        configureGroupingMenu()
        configureAddRepoButton()
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let headerRow = NSStackView(views: [headerIcon, headerTitle, headerSub, spacer,
                                            addRepoButton, groupingButton])
        headerRow.orientation = .horizontal
        headerRow.spacing = 10
        headerRow.alignment = .centerY
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerRow)
        headerLine.wantsLayer = true
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
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(fleetDidScroll),
                                               name: NSView.boundsDidChangeNotification,
                                               object: scroll.contentView)
        addSubview(scroll)

        // --- Bottom shortcut strip ---
        hintBar.onShowAllShortcuts = { [weak self] in self?.onShowAllShortcuts?() }
        addSubview(hintBar)

        NSLayoutConstraint.activate([
            headerRow.topAnchor.constraint(equalTo: topAnchor, constant: 13),
            headerRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 15),
            headerRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -15),

            headerLine.topAnchor.constraint(equalTo: headerRow.bottomAnchor, constant: 11),
            headerLine.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerLine.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerLine.heightAnchor.constraint(equalToConstant: 1),

            scroll.topAnchor.constraint(equalTo: headerLine.bottomAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: hintBar.topAnchor),

            hintBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            hintBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            hintBar.bottomAnchor.constraint(equalTo: bottomAnchor),

            stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
    }

    /// Header: add a whole repo via the folder picker.
    ///
    /// Deliberately *not* a bare "+" — the per-project group headers already use
    /// that for "add one worktree inside this project", and two identical glyphs on
    /// one screen made the two scopes indistinguishable. `folder.badge.plus` says
    /// "pick a folder", which is literally what this opens, and matches the
    /// empty-state add-project button.
    private func configureAddRepoButton() {
        addRepoButton.isBordered = false
        if let image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium)) {
            addRepoButton.image = image
            addRepoButton.title = ""
            addRepoButton.imagePosition = .imageOnly
        } else {
            addRepoButton.title = "+"
            addRepoButton.font = AppFont.mono(size: 13)
        }
        addRepoButton.contentTintColor = Self.inkDim
        addRepoButton.refusesFirstResponder = true
        addRepoButton.toolTip = "Add project"
        addRepoButton.setAccessibilityLabel("Add project")
        addRepoButton.setAccessibilityIdentifier("dashboard.addRepoButton")
        addRepoButton.target = self
        addRepoButton.action = #selector(addRepoClicked)
    }

    @objc private func addRepoClicked() { onAddRepo?() }

    private func configureGroupingMenu() {
        groupingButton.isBordered = false
        let groupingImage = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: nil)
        groupingButton.image = groupingImage?.withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        groupingButton.contentTintColor = Self.inkDim
        if groupingButton.image == nil {
            groupingButton.title = "☷"
            groupingButton.font = AppFont.mono(size: 13)
        } else {
            groupingButton.title = ""
            groupingButton.imagePosition = .imageOnly
        }
        groupingButton.refusesFirstResponder = true
        groupingButton.target = self
        groupingButton.action = #selector(showGroupingMenu(_:))

        let entries: [(WorktreeGroupingMode, String)] = [
            (.repository, "Group by Project"),
            (.status, "Group by Status"),
            (.activityTime, "Group by Time"),
            (.pane, "Expand All Panes"),
        ]
        for (mode, title) in entries {
            let item = NSMenuItem(title: title, action: #selector(selectGroupingMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            groupingMenu.addItem(item)
        }
        refreshGroupingMenuPresentation()
    }

    @objc private func showGroupingMenu(_ sender: NSButton) {
        groupingMenu.popUp(positioning: nil,
                           at: NSPoint(x: 0, y: sender.bounds.maxY + 4),
                           in: sender)
    }

    @objc private func selectGroupingMode(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let mode = WorktreeGroupingMode(rawValue: rawValue) else { return }
        applyGroupingMode(mode)
    }

    private func applyGroupingMode(_ mode: WorktreeGroupingMode) {
        groupingMode = mode
        groupingPreference.save(mode)
        refreshGroupingMenuPresentation()
        render(latestPanes, revealSelection: true)
        onGroupingChanged?()
    }

    private func refreshGroupingMenuPresentation() {
        for item in groupingMenu.items {
            item.state = (item.representedObject as? String) == groupingMode.rawValue ? .on : .off
        }
        let description: String
        switch groupingMode {
        case .repository: description = "Group worktrees by project"
        case .status: description = "Group worktrees by status"
        case .activityTime: description = "Group worktrees by time"
        case .pane: description = "Expand worktrees into panes"
        }
        groupingButton.toolTip = description
        groupingButton.setAccessibilityLabel(description)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshChromeColors()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: - Hover

    @objc private func fleetDidScroll() { refreshHoverForPointer() }

    /// A row reported a tracking-area edge. Enters win outright; an exit only
    /// counts for the row the list still believes is lit, so a stale exit
    /// arriving after the pointer already moved on can't blank the new row.
    private func rowHoverChanged(_ row: FleetHoverRow, entered: Bool) {
        if entered {
            setHoveredRow(row)
        } else if hoveredRow === row {
            setHoveredRow(nil)
        }
    }

    private func setHoveredRow(_ row: FleetHoverRow?) {
        guard hoveredRow !== row else { return }
        hoveredRow?.setHovered(false)
        hoveredRow = row
        row?.setHovered(true)
    }

    /// Re-resolve the hovered row from where the pointer actually is.
    ///
    /// Scrolling moves rows under a still cursor, which AppKit reports as a run
    /// of enters with no exits — so the fleet asks the pointer instead of
    /// trusting the events every time the content offset changes.
    private func refreshHoverForPointer() {
        guard let window, window.isKeyWindow else { setHoveredRow(nil); return }
        let point = scroll.contentView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard scroll.contentView.bounds.contains(point) else { setHoveredRow(nil); return }
        var hit = stack.hitTest(point)
        while let view = hit, !(view is FleetHoverRow) { hit = view.superview }
        setHoveredRow(hit as? FleetHoverRow)
    }

    /// Layer `CGColor`s don't auto-track dynamic `NSColor`s — re-resolve on appearance flips.
    private func refreshChromeColors() {
        layer?.backgroundColor = NSColor.clear.cgColor
        headerLine.layer?.backgroundColor = resolvedCGColor(Self.line)
        headerTitle.textColor = Self.ink
        headerSub.textColor = Self.inkFaint
    }

    /// Worktrees in display (grouped) order — the sequence keyboard nav walks.
    private(set) var orderedRows: [(id: String, path: String)] = []
    /// Indices into `orderedRows` where each rendered group starts — the boundaries
    /// `{` / `}` jump between. Pane rows never enter `orderedRows`, so cruising
    /// stays at worktree level in `.pane` mode too.

    /// Holds the row rebuild while an anchored form (the "+" create popover) is
    /// open, so the list doesn't churn under it on every 2s status poll. Data
    /// still lands; it just paints when the form goes away.
    var isRenderPaused = false {
        didSet {
            guard oldValue, !isRenderPaused else { return }
            render(latestPanes, revealSelection: false)
        }
    }

    func update(_ panes: [WorktreeRowInfo]) {
        latestPanes = panes
        guard !isRenderPaused else { return }
        render(panes, revealSelection: false)
    }

    private func render(_ panes: [WorktreeRowInfo], revealSelection: Bool) {
        let running = panes.filter { $0.rolledUpStatus == .running }.count
        // Tight enough to survive the 300pt docked column next to two buttons:
        // total count, then only the running slice.
        headerSub.stringValue = running > 0 ? "\(panes.count) · \(running) running" : "\(panes.count)"

        let panesByPath = Dictionary(panes.map { ($0.worktreePath, $0) }, uniquingKeysWith: { first, _ in first })
        let groupingItems = panes.map {
            $0.groupingItem(
                creationDate: Self.creationDate($0.worktreePath),
                isIntegration: IntegrationWorktreeStore.shared.isIntegrationWorktree($0.worktreePath)
            )
        }
        let groups = WorktreeGrouping.groups(groupingItems, mode: groupingMode, now: now())

        // A mode switch is an explicit navigation action. If its previous
        // identity is stale, land on the first row in the new ordering before
        // constructing rows so the resolved selection is highlighted and can be
        // revealed. Ordinary data refreshes intentionally preserve stale/empty
        // selection without moving the user's focus.
        if revealSelection, !selectedId.isEmpty,
           !groups.contains(where: { group in group.items.contains(where: { $0.id == selectedId }) }) {
            selectedId = groups.first?.items.first?.id ?? ""
        }

        let structureSignature = Self.structureSignature(for: groups, panesByPath: panesByPath, groupingMode: groupingMode)
        if !revealSelection, structureSignature == lastStructureSignature {
            #if DEBUG
            let start = DispatchTime.now().uptimeNanoseconds
            #endif
            applyIncrementalUpdates(groups: groups, panesByPath: panesByPath)
            #if DEBUG
            recordTelemetry(kind: "incremental",
                            elapsedMs: elapsedMilliseconds(since: start),
                            rowCount: orderedRows.count)
            #endif
            return
        }

        #if DEBUG
        let start = DispatchTime.now().uptimeNanoseconds
        #endif
        fullRenderCount += 1
        lastStructureSignature = structureSignature
        setHoveredRow(nil)
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        orderedRows = []
        rowViewsByID = [:]
        paneRowViewsByStationID = [:]
        renderedGroupTitles = []
        addWorktreeProjects = []
        integrateProjects = []
        revealedRowID = nil

        for (groupIndex, group) in groups.enumerated() {
            renderedGroupTitles.append(group.title)
            let header = makeGroupHeader(group: group, topGap: groupIndex == 0 ? 0 : 13)
            stack.addArrangedSubview(header)
            pin(header)
            let rowsBox = NSStackView()
            rowsBox.orientation = .vertical
            rowsBox.spacing = 4
            rowsBox.alignment = .leading
            rowsBox.translatesAutoresizingMaskIntoConstraints = false
            for groupedItem in group.items {
                guard let pane = panesByPath[groupedItem.path] else { continue }
                let row = RowView(pane: pane,
                                  status: groupedItem.status,
                                  selected: groupedItem.id == selectedId,
                                  showsRepository: groupingMode != .repository)
                row.onTap = { [weak self] path in self?.onSelectWorktree?(path) }
                row.onDelete = { [weak self] path in self?.onDeleteWorktree?(path) }
                row.onDeleteWithBranch = { [weak self] path in self?.onDeleteWorktreeWithBranch?(path) }
                row.onHoverChanged = { [weak self] row, entered in
                    self?.rowHoverChanged(row, entered: entered)
                }
                rowsBox.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: rowsBox.widthAnchor).isActive = true
                orderedRows.append((groupedItem.id, groupedItem.path))
                rowViewsByID[groupedItem.id] = row

                // Fully-expanded third level: one clickable row per pane. A
                // single-pane worktree is already represented by its own row, so
                // expanding it would just duplicate — only expand 2+ panes.
                if groupingMode == .pane, pane.panes.count > 1 {
                    // `paneInfo`, not `pane`: the enclosing `pane` is the
                    // worktree row that owns these, and shadowing it here loses
                    // the worktree path the child row needs.
                    for paneInfo in pane.panes {
                        let paneRow = PaneRowView(pane: paneInfo, worktreePath: pane.worktreePath)
                        paneRow.onTap = { [weak self] worktreePath, stationId in
                            self?.onSelectPane?(worktreePath, stationId)
                        }
                        paneRow.onHoverChanged = { [weak self] row, entered in
                            self?.rowHoverChanged(row, entered: entered)
                        }
                        rowsBox.addArrangedSubview(paneRow)
                        paneRow.widthAnchor.constraint(equalTo: rowsBox.widthAnchor).isActive = true
                        paneRowViewsByStationID[paneInfo.stationId] = paneRow
                    }
                }
            }
            stack.addArrangedSubview(rowsBox)
            pin(rowsBox)
        }

        if revealSelection, let selectedRow = rowViewsByID[selectedId] {
            layoutSubtreeIfNeeded()
            selectedRow.scrollToVisible(selectedRow.bounds)
            revealedRowID = selectedId
        }
        #if DEBUG
        recordTelemetry(kind: "full",
                        elapsedMs: elapsedMilliseconds(since: start),
                        rowCount: orderedRows.count)
        #endif
    }

    private static func structureSignature(
        for groups: [WorktreeGroup],
        panesByPath: [String: WorktreeRowInfo],
        groupingMode: WorktreeGroupingMode
    ) -> String {
        groups.map { group in
            let rows = group.items.map { item in
                let paneIDs: [String]
                if groupingMode == .pane, let pane = panesByPath[item.path], pane.panes.count > 1 {
                    paneIDs = pane.panes.map(\.stationId)
                } else {
                    paneIDs = []
                }
                return "\(item.id){\(paneIDs.joined(separator: ","))}"
            }
            return "\(String(describing: group.id))|\(group.title)|\(rows.joined(separator: ";"))"
        }.joined(separator: "||")
    }

    private func applyIncrementalUpdates(
        groups: [WorktreeGroup],
        panesByPath: [String: WorktreeRowInfo]
    ) {
        orderedRows = groups.flatMap { group in group.items.map { ($0.id, $0.path) } }
        renderedGroupTitles = groups.map(\.title)

        for group in groups {
            for item in group.items {
                guard let pane = panesByPath[item.path] else { continue }
                if let row = rowViewsByID[item.id] {
                    row.update(pane: pane, status: item.status, selected: item.id == selectedId)
                }
                if groupingMode == .pane, pane.panes.count > 1 {
                    for paneInfo in pane.panes {
                        paneRowViewsByStationID[paneInfo.stationId]?
                            .update(pane: paneInfo, worktreePath: pane.worktreePath)
                    }
                }
            }
        }
    }

    #if DEBUG
    private func elapsedMilliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000.0
    }

    private func recordTelemetry(kind: String, elapsedMs: Double, rowCount: Int) {
        if kind == "full" {
            fullRenderTotalDurationMs += elapsedMs
        } else {
            incrementalUpdateCount += 1
            incrementalTotalDurationMs += elapsedMs
        }
        let now = Date()
        guard now.timeIntervalSince(lastTelemetryLogAt) >= 30 else { return }
        lastTelemetryLogAt = now
        let fullAvg = fullRenderCount > 0 ? fullRenderTotalDurationMs / Double(fullRenderCount) : 0
        let incrementalAvg = incrementalUpdateCount > 0 ? incrementalTotalDurationMs / Double(incrementalUpdateCount) : 0
        NSLog("[DashboardOverview] rows=%d full_count=%d full_avg_ms=%.2f incremental_count=%d incremental_avg_ms=%.2f last=%@ %.2fms",
              rowCount, fullRenderCount, fullAvg, incrementalUpdateCount, incrementalAvg, kind, elapsedMs)
    }
    #endif

    /// Move the highlight to `id` in place, cross-fading between the two rows and
    /// scrolling the new one into view.
    ///
    /// The `⌃⇥` path deliberately avoids `update(_:)`: a full re-render tears down
    /// every row view and builds new ones, which cannot animate and reads as the
    /// whole list flickering. Returns false when `id` has no row on screen (the
    /// list hasn't rendered, or the target is filtered out) so the caller can fall
    /// back to a plain re-render.
    @discardableResult
    func moveSelection(to id: String, animated: Bool) -> Bool {
        guard let target = rowViewsByID[id] else { return false }
        guard id != selectedId else { return true }
        rowViewsByID[selectedId]?.setSelected(false, animated: animated)
        target.setSelected(true, animated: animated)
        selectedId = id
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = RowView.selectionFadeDuration
                context.allowsImplicitAnimation = true
                target.scrollToVisible(target.bounds)
            }
        } else {
            target.scrollToVisible(target.bounds)
        }
        revealedRowID = id
        return true
    }

    /// Worktree directory creation date, cached — the sort key inside a repo
    /// group. Missing/unreadable paths sort first (distantPast).
    private static var creationDateCache: [String: Date] = [:]
    /// Also used to build grouping items for remote clients (TabCoordinator).
    static func creationDate(_ path: String) -> Date {
        if let cached = creationDateCache[path] { return cached }
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let date = attrs?[.creationDate] as? Date ?? .distantPast
        creationDateCache[path] = date
        return date
    }

    /// Selected worktree id, so the fleet can mark the current row (accent border).
    var selectedId: String = ""

    // Focused AppKit contract exposed to unit tests without leaking mutable UI.
    var groupingModeForTesting: WorktreeGroupingMode { groupingMode }
    var groupingMenuTitlesForTesting: [String] { groupingMenu.items.map(\.title) }
    var groupingMenuKeyEquivalentsForTesting: [String] { groupingMenu.items.map(\.keyEquivalent) }
    var checkedGroupingModesForTesting: [WorktreeGroupingMode] {
        groupingMenu.items.compactMap { item in
            guard item.state == .on, let rawValue = item.representedObject as? String else { return nil }
            return WorktreeGroupingMode(rawValue: rawValue)
        }
    }
    var renderedGroupTitlesForTesting: [String] { renderedGroupTitles }
    var fullRenderCountForTesting: Int { fullRenderCount }
    /// Project titles behind the rendered "add worktree" buttons, in group order.
    var addWorktreeProjectsForTesting: [String] {
        stack.arrangedSubviews
            .compactMap { $0 as? NSStackView }
            .flatMap { $0.arrangedSubviews }
            .compactMap { $0 as? NSButton }
            .filter { $0.identifier == Self.addWorktreeButtonIdentifier }
            .compactMap { addWorktreeProjects[safeIndex: $0.tag] }
    }
    /// Project titles behind the rendered "integrate" buttons, in group order.
    var integrateProjectsForTesting: [String] {
        stack.arrangedSubviews
            .compactMap { $0 as? NSStackView }
            .flatMap { $0.arrangedSubviews }
            .compactMap { $0 as? NSButton }
            .filter { $0.identifier == Self.integrateButtonIdentifier }
            .compactMap { integrateProjects[safeIndex: $0.tag] }
    }
    var renderedSelectedRowIDForTesting: String? { rowViewsByID[selectedId] == nil ? nil : selectedId }
    /// Ids of every row currently painting the hover tint — more than one means
    /// the scroll-leaves-a-trail bug is back.
    var hoveredRowIDsForTesting: [String] {
        rowViewsByID.filter { $0.value.isHoveredForTesting }.keys.sorted()
    }
    func simulateRowHoverForTesting(id: String, entered: Bool) {
        guard let row = rowViewsByID[id] else { return }
        rowHoverChanged(row, entered: entered)
    }
    var revealedRowIDForTesting: String? { revealedRowID }
    func rowRuntimeTextForTesting(id: String) -> String? { rowViewsByID[id]?.runtimeTextForTesting }
    func rowTitleTextForTesting(id: String) -> String? { rowViewsByID[id]?.titleTextForTesting }
    func rowTitleFrameForTesting(id: String) -> NSRect? { rowViewsByID[id]?.titleFrameForTesting }
    var groupingButtonToolTipForTesting: String? { groupingButton.toolTip }
    var groupingButtonAccessibilityLabelForTesting: String? { groupingButton.accessibilityLabel() }
    var groupingButtonRefusesFirstResponderForTesting: Bool { groupingButton.refusesFirstResponder }
    func selectGroupingModeForTesting(_ mode: WorktreeGroupingMode) { applyGroupingMode(mode) }

    private func pin(_ v: NSView) {
        v.translatesAutoresizingMaskIntoConstraints = false
        v.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 15).isActive = true
        v.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -15).isActive = true
    }

    private func makeGroupHeader(group: WorktreeGroup, topGap: CGFloat) -> NSView {
        var views: [NSView] = []
        if let status = group.status {
            if status == .running {
                views.append(SpinnerDotView(color: status.color))
            } else {
                let glyph = NSTextField(labelWithString: status.glyph)
                glyph.font = AppFont.mono(size: 8)
                glyph.textColor = status.color
                views.append(glyph)
            }

            let title = NSTextField(labelWithString: status.groupLabel)
            title.font = AppFont.mono(size: 11)
            title.textColor = status.color
            title.lineBreakMode = .byTruncatingTail
            views.append(title)

            let count = NSTextField(labelWithString: "\(group.items.count)")
            count.font = AppFont.mono(size: 11)
            count.textColor = Self.inkFaint
            views.append(count)
        } else {
            let title = NSTextField(labelWithString: group.title)
            title.font = AppFont.mono(size: 11, weight: .semibold)
            title.textColor = Self.inkDim
            title.lineBreakMode = .byTruncatingTail
            views.append(title)
        }

        // Project groups (Group by Project / Expand All Panes) carry a trailing
        // "+" that opens the helm prefilled with `/worktree @<project>`.
        var addButton: NSButton?
        if case .repository = group.id {
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
            views.append(spacer)
            // Only worth offering once there is more than one worktree to fold
            // together — on a single-worktree project it would integrate a repo
            // with itself.
            if group.items.count > 1 {
                views.append(makeIntegrateButton(project: group.title))
            }
            let button = makeAddWorktreeButton(project: group.title)
            views.append(button)
            addButton = button
        }

        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = 7
        row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: topGap, left: 0, bottom: 7, right: 0)
        if let addButton {
            addButton.setContentHuggingPriority(.required, for: .horizontal)
            addButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        return row
    }

    /// Trailing "integrate" affordance on a project group header. Equivalent to
    /// `/integrate` with that repo selected, and the only place the feature
    /// announces itself — otherwise it is a command you have to already know.
    private func makeIntegrateButton(project: String) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.bezelStyle = .inline
        button.refusesFirstResponder = true
        if let image = NSImage(systemSymbolName: "arrow.trianglehead.merge", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
            ?? NSImage(systemSymbolName: "arrow.triangle.merge", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium)) {
            button.image = image
            button.title = ""
            button.imagePosition = .imageOnly
        } else {
            button.title = "⑃"
            button.font = AppFont.mono(size: 12)
        }
        button.contentTintColor = Self.inkFaint
        let description = "Integrate \(project)"
        button.toolTip = description
        button.setAccessibilityLabel(description)
        button.identifier = Self.integrateButtonIdentifier
        button.target = self
        button.action = #selector(integrateClicked(_:))
        button.tag = integrateProjects.count
        integrateProjects.append(project)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }

    @objc private func integrateClicked(_ sender: NSButton) {
        guard let project = integrateProjects[safeIndex: sender.tag] else { return }
        onIntegrate?(project)
    }

    /// Trailing "add worktree" affordance on a project group header. Equivalent
    /// to typing `/worktree @<project>` in the helm.
    private func makeAddWorktreeButton(project: String) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.bezelStyle = .inline
        button.refusesFirstResponder = true
        if let image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium)) {
            button.image = image
            button.title = ""
            button.imagePosition = .imageOnly
        } else {
            button.title = "+"
            button.font = AppFont.mono(size: 12)
        }
        button.contentTintColor = Self.inkFaint
        let description = "Add worktree to \(project)"
        button.toolTip = description
        button.setAccessibilityLabel(description)
        button.identifier = Self.addWorktreeButtonIdentifier
        button.target = self
        button.action = #selector(addWorktreeClicked(_:))
        button.tag = addWorktreeProjects.count
        addWorktreeProjects.append(project)
        return button
    }

    @objc private func addWorktreeClicked(_ sender: NSButton) {
        guard let project = addWorktreeProjects[safeIndex: sender.tag] else { return }
        // Anchor to this long-lived view, not the button: the fleet re-renders on
        // every status poll, and a popover whose anchor view leaves the hierarchy
        // closes itself — which read as "the form collapses while I type".
        onAddWorktree?(project, sender.convert(sender.bounds, to: self), self)
    }

    // MARK: - Fleet row

    /// Two-line navigator item under a repo group:
    /// ```
    /// ●  current pane title                         time
    ///    branch  git info                           N panes
    /// ```
    /// Title and branch share a text column so their leading edges align.
    private final class RowView: NSView, FleetHoverRow {
        var onTap: ((String) -> Void)?
        /// Pointer entered (`true`) or left (`false`) this row. The list, not the
        /// row, decides what that means — see `FleetHoverRow`.
        var onHoverChanged: ((FleetHoverRow, Bool) -> Void)?
        var onDelete: ((String) -> Void)?
        var onDeleteWithBranch: ((String) -> Void)?
        /// Refreshed by `update` rather than fixed at init: a row is keyed by its
        /// station id, and a worktree transfer (`handleNewBranch`) re-registers the
        /// same stations under a new path. A reused row that kept its original
        /// `path` would open, reveal, and *delete* the worktree it used to be.
        private var path: String
        private var isMainWorktree: Bool
        private var selected: Bool
        private let showsRepository: Bool
        private let staticDot: NSTextField
        private let runningDot: SpinnerDotView
        private let titleLabel: NSTextField
        private let timeLabel: NSTextField
        private let branchLabel: NSTextField
        private let gitLabel: NSTextField
        private let paneCountLabel: NSTextField
        private let repositoryLabel: NSTextField?
        /// Whether the pointer is currently inside, so a selection change can
        /// repaint without losing the hover tint on the row being left behind.
        private var hovered = false

        private static let cornerRadius: CGFloat = 8
        /// One beat, matched to the fleet list's other selection feedback.
        static let selectionFadeDuration: CFTimeInterval = 0.18
        private static let highlightFill = NSColor(name: nil) { appearance in
            appearance.isDark
                ? NSColor.white.withAlphaComponent(0.10)
                : NSColor.black.withAlphaComponent(0.08)
        }
        private static let hoverFill = NSColor(name: nil) { appearance in
            appearance.isDark
                ? NSColor.white.withAlphaComponent(0.05)
                : NSColor.black.withAlphaComponent(0.04)
        }

        private static func label(_ s: String, _ color: NSColor, _ size: CGFloat,
                                  weight: NSFont.Weight = .regular) -> NSTextField {
            let l = NSTextField(labelWithString: s)
            l.font = AppFont.mono(size: size, weight: weight)
            l.textColor = color
            l.lineBreakMode = .byTruncatingTail
            // Every label in this row is one line by design. Without the cap, a
            // title carrying newlines wraps and the row grows to fit it.
            l.maximumNumberOfLines = 1
            return l
        }
        private static func spacer() -> NSView {
            let v = NSView()
            v.translatesAutoresizingMaskIntoConstraints = false
            v.setContentHuggingPriority(.defaultLow, for: .horizontal)
            v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            return v
        }

        init(pane: WorktreeRowInfo, status: AgentStatus, selected: Bool,
             showsRepository: Bool) {
            self.path = pane.worktreePath
            self.isMainWorktree = pane.isMainWorktree
            self.selected = selected
            self.showsRepository = showsRepository
            self.staticDot = Self.label(status.glyph, status.color, 8)
            // The spinner is only ever visible while the row is `.running`, and it
            // now outlives the status it was built under (rows are reused across
            // incremental updates), so pin it to `.running`'s colour rather than
            // whatever status happened to be current at construction time.
            self.runningDot = SpinnerDotView(color: AgentStatus.running.color)
            self.titleLabel = Self.label(pane.currentPaneTitle, DashboardOverviewView.ink, 12)
            self.timeLabel = Self.label(pane.currentPaneRunTime, DashboardOverviewView.inkFaint, 10)
            let branch = pane.thread.isEmpty ? pane.name : pane.thread
            self.branchLabel = Self.label(branch, DashboardOverviewView.inkDim, 11)
            self.gitLabel = NSTextField(labelWithString: "")
            self.paneCountLabel = Self.label(pane.paneCount > 0 ? "\(pane.paneCount) panes" : "—",
                                             DashboardOverviewView.inkFaint, 10)
            if showsRepository {
                let repo = Self.label(pane.project.isEmpty ? "Unknown project" : pane.project,
                                      ProjectColor.color(for: pane.project), 10, weight: .semibold)
                self.repositoryLabel = repo
            } else {
                self.repositoryLabel = nil
            }
            super.init(frame: .zero)
            wantsLayer = true
            layer?.cornerRadius = Self.cornerRadius
            layer?.masksToBounds = true
            setAccessibilityElement(true)
            setAccessibilityIdentifier("chrome.worktreeRow.\(pane.id)")
            setAccessibilityLabel(pane.name)
            applyBackground(hovered: false)
            // Both dots are plain `addSubview` children (not stack-arranged), so
            // the label-backed one has to opt out of autoresizing constraints by
            // hand — `SpinnerDotView` already does it in its own init.
            staticDot.translatesAutoresizingMaskIntoConstraints = false
            staticDot.setContentHuggingPriority(.required, for: .horizontal)
            staticDot.setContentCompressionResistancePriority(.required, for: .horizontal)
            runningDot.setContentHuggingPriority(.required, for: .horizontal)
            runningDot.setContentCompressionResistancePriority(.required, for: .horizontal)
            titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            timeLabel.setContentHuggingPriority(.required, for: .horizontal)

            // Line 1: current pane title                         time
            let line1 = NSStackView()
            line1.orientation = .horizontal
            line1.alignment = .centerY
            line1.spacing = 7
            line1.translatesAutoresizingMaskIntoConstraints = false
            line1.addArrangedSubview(titleLabel)
            line1.addArrangedSubview(Self.spacer())
            line1.addArrangedSubview(timeLabel)

            // Line 2: branch  git info                              N panes
            branchLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            branchLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            gitLabel.attributedStringValue = Self.gitInfoAttributed(pane.gitStats)
            gitLabel.translatesAutoresizingMaskIntoConstraints = false
            gitLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
            gitLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            paneCountLabel.setContentHuggingPriority(.required, for: .horizontal)

            let line2 = NSStackView()
            line2.orientation = .horizontal
            line2.alignment = .firstBaseline
            line2.spacing = 8
            line2.translatesAutoresizingMaskIntoConstraints = false
            if let repository = repositoryLabel {
                repository.setContentHuggingPriority(.defaultHigh, for: .horizontal)
                repository.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                line2.addArrangedSubview(repository)
            }
            line2.addArrangedSubview(branchLabel)
            line2.addArrangedSubview(gitLabel)
            line2.addArrangedSubview(Self.spacer())
            line2.addArrangedSubview(paneCountLabel)

            let textCol = NSStackView(views: [line1, line2])
            textCol.orientation = .vertical
            textCol.spacing = 3
            textCol.alignment = .leading
            textCol.translatesAutoresizingMaskIntoConstraints = false

            addSubview(staticDot)
            addSubview(runningDot)
            addSubview(textCol)
            NSLayoutConstraint.activate([
                textCol.leadingAnchor.constraint(equalTo: staticDot.trailingAnchor, constant: 7),
                textCol.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
                textCol.topAnchor.constraint(equalTo: topAnchor, constant: 8),
                textCol.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

                staticDot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
                staticDot.centerYAnchor.constraint(equalTo: line1.centerYAnchor),
                runningDot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
                runningDot.centerYAnchor.constraint(equalTo: line1.centerYAnchor),

                line1.widthAnchor.constraint(equalTo: textCol.widthAnchor),
                line2.widthAnchor.constraint(equalTo: textCol.widthAnchor),
            ])
            applyContent(pane: pane, status: status)
        }
        required init?(coder: NSCoder) { fatalError() }

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

        func update(pane: WorktreeRowInfo, status: AgentStatus, selected: Bool) {
            path = pane.worktreePath
            isMainWorktree = pane.isMainWorktree
            setSelected(selected, animated: false)
            setAccessibilityLabel(pane.name)
            applyContent(pane: pane, status: status)
        }

        var runtimeTextForTesting: String { timeLabel.stringValue }
        var titleTextForTesting: String { titleLabel.stringValue }
        var titleFrameForTesting: NSRect { titleLabel.frame }

        private func applyContent(pane: WorktreeRowInfo, status: AgentStatus) {
            let nextTitle = pane.currentPaneTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !nextTitle.isEmpty {
                titleLabel.stringValue = nextTitle
            } else if titleLabel.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                titleLabel.stringValue = PaneTitleResolver.shortenPath(pane.worktreePath)
            }

            // Unlike the title, a duration must be allowed to disappear: it falls
            // back to the activity age once the pane stops, and that is "" when
            // unknown. Holding the last value there would leave a dead pane
            // reading "12s" next to an idle dot. Only a *running* row keeps its
            // last known figure, so a live counter never blanks mid-flight.
            let nextRuntime = pane.currentPaneRunTime.trimmingCharacters(in: .whitespacesAndNewlines)
            if !nextRuntime.isEmpty || status != .running {
                timeLabel.stringValue = nextRuntime
            }

            let nextBranch = (pane.thread.isEmpty ? pane.name : pane.thread)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !nextBranch.isEmpty {
                branchLabel.stringValue = nextBranch
            }
            gitLabel.attributedStringValue = Self.gitInfoAttributed(pane.gitStats)
            paneCountLabel.stringValue = pane.paneCount > 0 ? "\(pane.paneCount) panes" : "—"
            if let repositoryLabel, showsRepository {
                let project = pane.project.isEmpty ? "Unknown project" : pane.project
                repositoryLabel.stringValue = project
                repositoryLabel.textColor = ProjectColor.color(for: project)
            }
            staticDot.stringValue = status.glyph
            staticDot.textColor = status.color
            staticDot.isHidden = status == .running
            runningDot.isHidden = status != .running
        }

        override func mouseDown(with event: NSEvent) { onTap?(path) }

        // MARK: - Context menu

        override func menu(for event: NSEvent) -> NSMenu? {
            let menu = NSMenu()
            for (title, action) in [
                ("Open in Editor", #selector(openInEditorAction)),
                ("Reveal in Finder", #selector(revealInFinderAction)),
                ("Copy Path", #selector(copyPathAction)),
            ] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self
                menu.addItem(item)
            }
            menu.addItem(.separator())
            let deleteItem = NSMenuItem(title: "Delete", action: #selector(deleteAction), keyEquivalent: "")
            deleteItem.target = self
            menu.addItem(deleteItem)
            let deleteBranchItem = NSMenuItem(title: "Delete + Branch", action: #selector(deleteWithBranchAction), keyEquivalent: "")
            deleteBranchItem.target = self
            menu.addItem(deleteBranchItem)
            if isMainWorktree {
                deleteItem.isEnabled = false
                deleteBranchItem.isEnabled = false
                deleteItem.toolTip = "Main worktree cannot be deleted."
                deleteBranchItem.toolTip = "Main worktree cannot be deleted."
            }
            return menu
        }

        @objc private func openInEditorAction() {
            if !WorktreeShellActions.openInEditor(path) {
                let alert = NSAlert()
                alert.messageText = "No supported editor found"
                alert.informativeText = "Install VS Code, Cursor, Zed, or Xcode to use Open in Editor."
                alert.runModal()
            }
        }

        @objc private func revealInFinderAction() { WorktreeShellActions.revealInFinder(path) }

        @objc private func copyPathAction() { WorktreeShellActions.copyPath(path) }

        @objc private func deleteAction() { onDelete?(path) }

        @objc private func deleteWithBranchAction() { onDeleteWithBranch?(path) }

        private var tracking: NSTrackingArea?
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
            addTrackingArea(t); tracking = t
        }
        override func mouseEntered(with event: NSEvent) { onHoverChanged?(self, true) }
        override func mouseExited(with event: NSEvent) { onHoverChanged?(self, false) }

        func setHovered(_ hovered: Bool) {
            guard self.hovered != hovered else { return }
            applyBackground(hovered: hovered)
        }

        /// Move the selection highlight on or off this row.
        ///
        /// `⌃⇥` cycles worktrees one row at a time, and repainting instantly made the
        /// highlight teleport — with the fleet list re-rendered underneath it, the
        /// jump read as the list blinking rather than as a move. Cross-fading the
        /// two rows' fills over one short beat is what makes it read as the
        /// highlight travelling to the next / previous worktree.
        func setSelected(_ isSelected: Bool, animated: Bool) {
            guard selected != isSelected else { return }
            selected = isSelected
            guard animated else { applyBackground(hovered: hovered); return }
            let fade = CABasicAnimation(keyPath: "backgroundColor")
            fade.fromValue = layer?.backgroundColor
            fade.duration = Self.selectionFadeDuration
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            applyBackground(hovered: hovered)
            layer?.add(fade, forKey: "selectionFade")
        }

        private func applyBackground(hovered: Bool) {
            self.hovered = hovered
            if selected {
                layer?.backgroundColor = resolvedCGColor(Self.highlightFill)
            } else if hovered {
                layer?.backgroundColor = resolvedCGColor(Self.hoverFill)
            } else {
                layer?.backgroundColor = NSColor.clear.cgColor
            }
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            applyBackground(hovered: hovered)
        }

        var isHoveredForTesting: Bool { hovered }
    }

    // MARK: - Pane row (Group by Pane)

    /// Third-level row under a worktree in the expanded "Group by Pane" mode:
    /// an indented, clickable pane. `● pane title`, dimmed unless focused.
    private final class PaneRowView: NSView, FleetHoverRow {
        var onTap: ((String, String) -> Void)?
        /// See `RowView.onHoverChanged`.
        var onHoverChanged: ((FleetHoverRow, Bool) -> Void)?
        private let stationId: String
        /// Carried on the view, not captured in `onTap`: rows outlive a single
        /// render now, and a transferred worktree keeps its station ids.
        private var worktreePath: String
        private let dotLabel: NSTextField
        private let titleLabel: NSTextField
        private var hovered = false

        private static let cornerRadius: CGFloat = 6
        private static let hoverFill = NSColor(name: nil) { appearance in
            appearance.isDark
                ? NSColor.white.withAlphaComponent(0.05)
                : NSColor.black.withAlphaComponent(0.04)
        }

        init(pane: PaneDisplayInfo, worktreePath: String) {
            self.stationId = pane.stationId
            self.worktreePath = worktreePath
            self.dotLabel = NSTextField(labelWithString: "\u{25CF}")
            self.titleLabel = NSTextField(labelWithString: pane.title)
            super.init(frame: .zero)
            wantsLayer = true
            layer?.cornerRadius = Self.cornerRadius
            layer?.masksToBounds = true
            setAccessibilityElement(true)
            setAccessibilityIdentifier("chrome.paneRow.\(pane.stationId)")
            setAccessibilityLabel(pane.title)

            dotLabel.font = AppFont.mono(size: 7)
            dotLabel.translatesAutoresizingMaskIntoConstraints = false
            dotLabel.setContentHuggingPriority(.required, for: .horizontal)
            dotLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

            titleLabel.font = AppFont.mono(size: 11)
            titleLabel.lineBreakMode = .byTruncatingTail
            titleLabel.translatesAutoresizingMaskIntoConstraints = false
            titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            addSubview(dotLabel)
            addSubview(titleLabel)
            NSLayoutConstraint.activate([
                // Indent under the worktree row's status dot + text column.
                dotLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 27),
                dotLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
                titleLabel.leadingAnchor.constraint(equalTo: dotLabel.trailingAnchor, constant: 7),
                titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
                titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
                titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            ])
            update(pane: pane, worktreePath: worktreePath)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func mouseDown(with event: NSEvent) { onTap?(worktreePath, stationId) }

        func update(pane: PaneDisplayInfo, worktreePath: String) {
            self.worktreePath = worktreePath
            setAccessibilityLabel(pane.title)
            dotLabel.textColor = pane.status.color
            titleLabel.stringValue = pane.title
            titleLabel.textColor = pane.isFocused ? DashboardOverviewView.inkDim : DashboardOverviewView.inkFaint
        }

        private var tracking: NSTrackingArea?
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
            addTrackingArea(t); tracking = t
        }
        override func mouseEntered(with event: NSEvent) { onHoverChanged?(self, true) }
        override func mouseExited(with event: NSEvent) { onHoverChanged?(self, false) }

        func setHovered(_ hovered: Bool) {
            guard self.hovered != hovered else { return }
            self.hovered = hovered
            layer?.backgroundColor = hovered ? resolvedCGColor(Self.hoverFill) : NSColor.clear.cgColor
        }

        var isHoveredForTesting: Bool { hovered }
    }

}
