import AppKit

enum SidePanelTab: Int {
    case files = 1
    case issues = 2
}

protocol WorktreeSidePanelDelegate: AnyObject {
    func sidePanel(_ vc: WorktreeSidePanelViewController, didSelectFile path: String)
    func sidePanel(_ vc: WorktreeSidePanelViewController, didSelectIssue issue: GitHubIssue)
}

final class WorktreeSidePanelViewController: NSViewController {
    private var worktreePath: String?
    private var selectedTab: SidePanelTab

    weak var delegate: WorktreeSidePanelDelegate?

    private let tabBar = NSStackView()

    /// Fixed host holding one container per tab. Containers stay mounted across
    /// tab switches (only `isHidden` changes) so each tab keeps its scroll
    /// position, selection and — for Files — its live FSEvents watcher. Rebuilt
    /// only when the worktree changes, since that state belongs to a worktree.
    private let contentHost = NSView()
    private var tabContainers: [SidePanelTab: NSView] = [:]
    private var builtTabs: Set<SidePanelTab> = []

    /// The container the selected tab's builders populate. Named `contentView`
    /// so every builder's constraint block reads against the tab it is building.
    private var contentView: NSView { container(for: selectedTab) }

    private func container(for tab: SidePanelTab) -> NSView {
        if let existing = tabContainers[tab] { return existing }
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.isHidden = tab != selectedTab
        contentHost.addSubview(container)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: contentHost.topAnchor),
            container.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor),
        ])
        tabContainers[tab] = container
        return container
    }

    /// Host-provided view (the cross-project worktree card list) shown for the

    // Files tab
    private var fileTreeController: FileTreeOutlineController?
    private var fileSearchField: NSTextField?
    private var hiddenToggleButton: NSButton?
    private var showHiddenFiles = false
    /// Folder expansion state remembered per worktree, restored on return.
    private var expandedByWorktree: [String: Set<String>] = [:]
    /// Root directory enumeration is filesystem work, so keep it off the main
    /// thread. The generation guard below drops results for a worktree/tab that
    /// is no longer selected.
    private static let filesBuildQueue = DispatchQueue(
        label: "seahelm.sidepanel.files-build",
        qos: .userInitiated
    )
    private var filesBuildGeneration = 0

    // Issues tab
    private var issueListView: IssueListView?
    private var issuesHeader: NSView?
    private var issuesPlaceholder: NSView?
    private var issuesObserver: NSObjectProtocol?
    /// Every worktree on screen with its branch, so the Issues list can say
    /// which issues are already being worked on. Set by the dashboard.
    var worktreeBranches: () -> [(path: String, branch: String)] = { [] }

    var selectedTabForTesting: SidePanelTab { selectedTab }
    var worktreePathForTesting: String? { worktreePath }
    var issueRowsForTesting: [IssueRow] { issueListView?.rows ?? [] }
    /// Tabs whose content is currently mounted (built and still in the hierarchy).
    var mountedTabsForTesting: Set<SidePanelTab> { Set(tabContainers.keys) }
    /// Identity of a tab's container, so a test can prove it was reused not rebuilt.
    func containerForTesting(_ tab: SidePanelTab) -> NSView? { tabContainers[tab] }

    /// Seam for tests, so one can describe an integration checkout without
    /// writing into the user's real config directory.
    private let integrationState: (String) -> IntegrationPanelState?

    init(
        worktreePath: String?,
        initialTab: SidePanelTab = .files,
        integrationState: @escaping (String) -> IntegrationPanelState? = {
            IntegrationStatusStore.shared.state(forWorktree: $0)
        }
    ) {
        self.worktreePath = worktreePath
        self.selectedTab = initialTab
        self.integrationState = integrationState
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        if let issuesObserver { NotificationCenter.default.removeObserver(issuesObserver) }
    }

    override func loadView() {
        let root = ThemedBackgroundView()
        // Clear — same glass as First Mate / Dashboard overview.
        root.backgroundToken = .clear
        root.setAccessibilityIdentifier("sidePanel.view")

        tabBar.orientation = .horizontal
        tabBar.spacing = 2
        tabBar.distribution = .fillEqually
        tabBar.translatesAutoresizingMaskIntoConstraints = false

        // Files + Issues only. Orders and the command line live in the Island.
        let tabs: [(SidePanelTab, String, String)] = [
            (.files, "folder", "Files"),
            (.issues, ChromeIconClusterView.issuesSymbol, "Issues"),
        ]
        for (tab, icon, tooltip) in tabs {
            let btn = NSButton()
            btn.bezelStyle = .recessed
            btn.isBordered = false
            btn.imagePosition = .imageOnly
            btn.image = NSImage(systemSymbolName: icon, accessibilityDescription: tooltip)
            btn.contentTintColor = tab == selectedTab ? Theme.accent : Theme.textSecondary
            btn.target = self
            btn.action = #selector(tabButtonClicked(_:))
            btn.tag = tab.rawValue
            btn.toolTip = tooltip
            btn.translatesAutoresizingMaskIntoConstraints = false
            btn.heightAnchor.constraint(equalToConstant: 24).isActive = true
            tabBar.addArrangedSubview(btn)
        }

        // The internal tab bar is hidden — pane switching is driven by the
        // chrome header icons. tabBar stays for updateTabBarHighlight().
        tabBar.isHidden = true

        contentHost.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(contentHost)

        NSLayoutConstraint.activate([
            contentHost.topAnchor.constraint(equalTo: root.topAnchor),
            contentHost.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentHost.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentHost.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        view = root
        showSelectedTab()
    }

    // MARK: - Shared chrome (matches DashboardOverviewView)

    private static let sea = NSColor(srgbRed: 0x1f/255, green: 0xc8/255, blue: 0xda/255, alpha: 1)
    private static let ink: NSColor = SemanticColors.text
    private static let inkDim: NSColor = SemanticColors.muted
    private static let inkFaint: NSColor = SemanticColors.subtle
    private static let line = NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 150/255, green: 215/255, blue: 225/255, alpha: 0.10)
            : NSColor(srgbRed: 0x1f/255, green: 0x23/255, blue: 0x2b/255, alpha: 0.10)
    }

    /// `◍ Title` + optional subtitle + hairline — same rhythm as First Mate.
    private func makePaneHeader(title: String, subtitle: String = "", subtitleToolTip: String? = nil,
                                trailingView: NSView? = nil) -> NSView {
        let icon = NSTextField(labelWithString: "◍")
        icon.font = AppFont.mono(size: 13)
        icon.textColor = Self.sea

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = AppFont.mono(size: 12.5, weight: .bold)
        titleLabel.textColor = Self.ink

        let subLabel = NSTextField(labelWithString: subtitle)
        subLabel.font = AppFont.mono(size: 11)
        subLabel.textColor = Self.inkFaint
        subLabel.isHidden = subtitle.isEmpty
        subLabel.toolTip = subtitleToolTip
        // The subtitle gives way first in a narrow panel, not the title.
        subLabel.lineBreakMode = .byTruncatingTail
        subLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [icon, titleLabel, subLabel])
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .firstBaseline
        row.translatesAutoresizingMaskIntoConstraints = false

        let hairline = NSView()
        hairline.wantsLayer = true
        hairline.layer?.backgroundColor = hairline.resolvedCGColor(Self.line)
        hairline.translatesAutoresizingMaskIntoConstraints = false

        let wrap = NSView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(row)
        wrap.addSubview(hairline)
        var constraints = [
            row.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 13),
            row.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 15),

            hairline.topAnchor.constraint(equalTo: row.bottomAnchor, constant: 11),
            hairline.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 1),
            hairline.bottomAnchor.constraint(equalTo: wrap.bottomAnchor),
        ]
        if let trailingView {
            trailingView.translatesAutoresizingMaskIntoConstraints = false
            wrap.addSubview(trailingView)
            constraints += [
                row.trailingAnchor.constraint(lessThanOrEqualTo: trailingView.leadingAnchor, constant: -10),
                trailingView.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -12),
                trailingView.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                trailingView.widthAnchor.constraint(equalToConstant: 24),
                trailingView.heightAnchor.constraint(equalToConstant: 24),
            ]
        } else {
            constraints.append(row.trailingAnchor.constraint(lessThanOrEqualTo: wrap.trailingAnchor, constant: -15))
        }
        NSLayoutConstraint.activate(constraints)
        return wrap
    }

    @objc private func tabButtonClicked(_ sender: NSButton) {
        guard let tab = SidePanelTab(rawValue: sender.tag) else { return }
        selectTab(tab)
    }

    private func updateTabBarHighlight() {
        for view in tabBar.arrangedSubviews {
            guard let btn = view as? NSButton, let tab = SidePanelTab(rawValue: btn.tag) else { continue }
            btn.contentTintColor = tab == selectedTab ? Theme.accent : Theme.textSecondary
        }
    }

    func setWorktree(_ path: String?) {
        guard path != worktreePath else { return }
        captureExpansion()
        worktreePath = path
        // Mounted content belongs to the previous worktree — discard all of it.
        discardAllTabs()
        if isViewLoaded { showSelectedTab() }
    }

    /// Tear down every mounted tab. Only a worktree change warrants this; a tab
    /// switch must not, or the state this mounting exists to preserve is lost.
    private func discardAllTabs() {
        filesBuildGeneration &+= 1
        for container in tabContainers.values { container.removeFromSuperview() }
        tabContainers.removeAll()
        builtTabs.removeAll()
        clearTabReferences()
    }

    /// Drop per-tab view references so a stale outlet can never outlive its view.
    private func clearTabReferences() {
        fileTreeController = nil
        fileSearchField = nil
        hiddenToggleButton = nil
        issueListView = nil
        issuesHeader = nil
        issuesPlaceholder = nil
    }

    /// Remember the current worktree's folder expansion before tearing the tree down.
    /// Skip while filtering — search expands many rows that must not pollute the
    /// per-worktree expansion memory (or stall worktree switches scanning them).
    private func captureExpansion() {
        guard let path = worktreePath, let controller = fileTreeController else { return }
        guard !controller.isFiltering else { return }
        expandedByWorktree[path] = controller.currentExpandedPaths()
    }

    // MARK: - Internal selection handlers (called by tree/table, forwarded to delegate)

    func handleFileSelection(_ path: String) {
        delegate?.sidePanel(self, didSelectFile: path)
    }

    func handleIssueSelection(_ issue: GitHubIssue) {
        delegate?.sidePanel(self, didSelectIssue: issue)
    }

    /// Switch the visible tab. Driven by the title-bar pane icons.
    func selectTab(_ tab: SidePanelTab) {
        guard tab != selectedTab else { return }
        captureExpansion()
        if tab != .files {
            // A pending Files build may finish after the user has moved to
            // Issues. It can be restarted if Files is selected again.
            filesBuildGeneration &+= 1
        }
        selectedTab = tab
        if isViewLoaded {
            updateTabBarHighlight()
            showSelectedTab()
        }
    }

    /// Reveal the selected tab, building its content the first time only.
    private func showSelectedTab() {
        _ = container(for: selectedTab)      // ensure it exists before hiding siblings
        if !builtTabs.contains(selectedTab) {
            builtTabs.insert(selectedTab)
            buildSelectedTab()
        } else if selectedTab == .files, fileTreeController == nil, let path = worktreePath {
            // The first build may have been invalidated by a quick tab switch.
            // Keep the lightweight loading state and restart it when Files is
            // selected again.
            showFilesLoadingState()
            scheduleFilesTabBuild(path)
        } else if selectedTab == .issues {
            // Entering the tab is the moment a stale list is worth refetching.
            renderIssuesTab()
        }
        for (tab, view) in tabContainers { view.isHidden = tab != selectedTab }
    }

    private func buildSelectedTab() {
        switch selectedTab {
        case .files:
            guard let path = worktreePath else {
                let header = makePaneHeader(title: "Files")
                contentView.addSubview(header)
                NSLayoutConstraint.activate([
                    header.topAnchor.constraint(equalTo: contentView.topAnchor),
                    header.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                    header.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                ])
                showPlaceholder("No worktree selected", identifier: "sidePanel.emptyPlaceholder", below: header)
                return
            }
            showFilesLoadingState()
            scheduleFilesTabBuild(path)
        case .issues:
            if issuesObserver == nil {
                issuesObserver = NotificationCenter.default.addObserver(
                    forName: GitHubIssueStore.didChange, object: nil, queue: .main
                ) { [weak self] _ in
                    guard let self, self.builtTabs.contains(.issues) else { return }
                    self.renderIssuesTab()
                }
            }
            renderIssuesTab()
        }
    }

    /// Show a cheap interim view while the filesystem is being enumerated. The
    /// worktree switch can therefore return to the event loop immediately
    /// instead of constructing the entire Files tab in the click handler.
    private func showFilesLoadingState() {
        contentView.subviews.forEach { $0.removeFromSuperview() }
        fileTreeController = nil
        fileSearchField = nil
        hiddenToggleButton = nil

        let header = makePaneHeader(title: "Files")
        contentView.addSubview(header)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: contentView.topAnchor),
            header.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
        showPlaceholder("Loading files…", identifier: "sidePanel.filesLoading", below: header)
    }

    private func scheduleFilesTabBuild(_ path: String) {
        filesBuildGeneration &+= 1
        let generation = filesBuildGeneration
        let showHidden = showHiddenFiles
        let expanded = expandedByWorktree[path] ?? []

        Self.filesBuildQueue.async {
            let rootNodes = FileTreeOutlineController.childNodes(
                of: URL(fileURLWithPath: path),
                showHidden: showHidden
            )
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.filesBuildGeneration == generation,
                      self.selectedTab == .files,
                      self.worktreePath == path else { return }
                self.presentFilesTab(
                    path,
                    rootNodes: rootNodes,
                    expandedPaths: expanded
                )
            }
        }
    }

    private func presentFilesTab(
        _ path: String,
        rootNodes: [FileTreeNode],
        expandedPaths: Set<String>
    ) {
        contentView.subviews.forEach { $0.removeFromSuperview() }
        fileTreeController = nil
        fileSearchField = nil
        hiddenToggleButton = nil
        showFilesTab(path, initialRootNodes: rootNodes)

        // Expansion can cause lazy child directory reads and outline layout.
        // Let the newly-mounted tab paint before restoring it.
        guard let controller = fileTreeController else { return }
        DispatchQueue.main.async { [weak self, weak controller] in
            guard let self, let controller,
                  self.fileTreeController === controller,
                  self.selectedTab == .files,
                  self.worktreePath == path else { return }
            controller.restoreExpansion(expandedPaths)
        }
    }


    private func showFilesTab(_ path: String, initialRootNodes: [FileTreeNode]) {
        let controller = FileTreeOutlineController(
            rootPath: path,
            showHidden: showHiddenFiles,
            initialRootNodes: initialRootNodes
        )
        controller.onSelectFile = { [weak self] filePath in
            self?.handleFileSelection(filePath)
        }
        fileTreeController = controller

        let header = makePaneHeader(title: "Files")

        // Search row: separate magnifier + text field (borderless NSSearchField
        // collapses its icon onto the placeholder and breaks hit-testing).
        let searchRow = NSView()
        searchRow.translatesAutoresizingMaskIntoConstraints = false

        let magnifier = NSImageView()
        magnifier.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        magnifier.contentTintColor = Self.inkDim
        magnifier.translatesAutoresizingMaskIntoConstraints = false

        let searchField = NSTextField(string: "")
        searchField.isEditable = true
        searchField.isSelectable = true
        searchField.isBordered = false
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = AppFont.mono(size: 12)
        searchField.textColor = Self.ink
        searchField.placeholderAttributedString = NSAttributedString(
            string: "Search files",
            attributes: [
                .foregroundColor: Self.inkDim,
                .font: AppFont.mono(size: 12),
            ]
        )
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.setAccessibilityIdentifier("sidePanel.fileSearch")
        self.fileSearchField = searchField

        let hiddenToggle = NSButton()
        hiddenToggle.bezelStyle = .recessed
        hiddenToggle.isBordered = false
        hiddenToggle.imagePosition = .imageOnly
        hiddenToggle.image = NSImage(systemSymbolName: showHiddenFiles ? "eye" : "eye.slash",
                                     accessibilityDescription: "Toggle hidden files")
        hiddenToggle.contentTintColor = Self.inkDim
        hiddenToggle.target = self
        hiddenToggle.action = #selector(toggleHiddenFiles(_:))
        hiddenToggle.translatesAutoresizingMaskIntoConstraints = false
        hiddenToggle.toolTip = "Show/Hide hidden files"
        hiddenToggle.setAccessibilityIdentifier("sidePanel.toggleHidden")
        self.hiddenToggleButton = hiddenToggle

        searchRow.addSubview(magnifier)
        searchRow.addSubview(searchField)
        searchRow.addSubview(hiddenToggle)

        let scrollView = NSScrollView()
        scrollView.documentView = controller.outlineView
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(header)
        contentView.addSubview(searchRow)
        contentView.addSubview(scrollView)

        // An integration checkout is several worktrees folded together, so the
        // tree alone does not say whose work it is — or whose was left out.
        let composition = integrationState(path).map(makeIntegrationComposition)
        if let composition {
            contentView.addSubview(composition)
            NSLayoutConstraint.activate([
                composition.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
                composition.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
                composition.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -12),
            ])
        }

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: contentView.topAnchor),
            header.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

            searchRow.topAnchor.constraint(equalTo: (composition ?? header).bottomAnchor, constant: 10),
            searchRow.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            searchRow.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            searchRow.heightAnchor.constraint(equalToConstant: 26),

            magnifier.leadingAnchor.constraint(equalTo: searchRow.leadingAnchor),
            magnifier.centerYAnchor.constraint(equalTo: searchRow.centerYAnchor),
            magnifier.widthAnchor.constraint(equalToConstant: 14),
            magnifier.heightAnchor.constraint(equalToConstant: 14),

            searchField.leadingAnchor.constraint(equalTo: magnifier.trailingAnchor, constant: 6),
            searchField.trailingAnchor.constraint(equalTo: hiddenToggle.leadingAnchor, constant: -6),
            searchField.centerYAnchor.constraint(equalTo: searchRow.centerYAnchor),

            hiddenToggle.trailingAnchor.constraint(equalTo: searchRow.trailingAnchor),
            hiddenToggle.centerYAnchor.constraint(equalTo: searchRow.centerYAnchor),
            hiddenToggle.widthAnchor.constraint(equalToConstant: 22),

            scrollView.topAnchor.constraint(equalTo: searchRow.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 6),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -6),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])

    }

    @objc private func toggleHiddenFiles(_ sender: NSButton) {
        showHiddenFiles.toggle()
        fileTreeController?.showHidden = showHiddenFiles
        sender.image = NSImage(systemSymbolName: showHiddenFiles ? "eye" : "eye.slash",
                               accessibilityDescription: "Toggle hidden files")
    }

    // MARK: - Issues tab

    /// Header + list for the selected worktree's repo, or a line saying why
    /// there is none. Re-run on every store change; the list view is kept so
    /// its filter text and scroll survive a refresh.
    private func renderIssuesTab() {
        let container = container(for: .issues)
        let store = GitHubIssueStore.shared
        let state = worktreePath.flatMap { store.state(forWorktree: $0) }
        let repo = worktreePath.flatMap { store.repo(forWorktree: $0) }

        issuesHeader?.removeFromSuperview()
        issuesPlaceholder?.removeFromSuperview()
        issuesPlaceholder = nil

        let refresh = NSButton()
        refresh.bezelStyle = .recessed
        refresh.isBordered = false
        refresh.imagePosition = .imageOnly
        refresh.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh issues")
        refresh.contentTintColor = Theme.textSecondary
        refresh.target = self
        refresh.action = #selector(refreshIssues)
        refresh.toolTip = "Refresh"
        refresh.setAccessibilityIdentifier("sidePanel.issuesRefresh")

        var subtitle = repo?.fullName ?? ""
        if let snapshot = state?.snapshot {
            subtitle += " · \(snapshot.issues.count) open"
            if snapshot.isAnonymous { subtitle += " · not signed in" }
        }
        let header = makePaneHeader(title: "Issues", subtitle: subtitle,
                                    trailingView: repo == nil ? nil : refresh)
        container.addSubview(header)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: container.topAnchor),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        issuesHeader = header

        guard let path = worktreePath, let snapshot = state?.snapshot else {
            issueListView?.removeFromSuperview()
            issueListView = nil
            let message: String
            switch state {
            case .unavailable(let reason)?: message = reason
            case .needsLogin(let reason)?: message = Self.needsLoginMessage(reason)
            case .loading?: message = "Loading issues…"
            case .loaded?: message = ""
            case nil: message = worktreePath == nil ? "No worktree selected" : "Not a GitHub repo"
            }
            issuesPlaceholder = showPlaceholder(message, identifier: "sidePanel.issuesPlaceholder",
                                                below: header, in: container)
            return
        }

        let list: IssueListView
        if let existing = issueListView {
            list = existing
        } else {
            list = IssueListView()
            list.onSelectIssue = { [weak self] issue in self?.handleIssueSelection(issue) }
            container.addSubview(list)
            NSLayoutConstraint.activate([
                list.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                list.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                list.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
            issueListView = list
        }
        // The header is rebuilt each time (its old top constraint went with
        // it), so pin the list under the new one.
        list.topAnchor.constraint(equalTo: header.bottomAnchor).isActive = true
        let worktrees = worktreeBranches()
        let current = worktrees.first { $0.path == path }?.branch
        let others = worktrees
            .filter { $0.path != path && store.repo(forWorktree: $0.path) == repo }
            .map(\.branch)
        list.show(snapshot, currentBranch: current, otherBranches: others)
    }

    static func needsLoginMessage(_ reason: GitHubIssueListState.LoginReason) -> String {
        let why: String
        switch reason {
        case .privateRepo:
            why = "This repo is private — sign in to GitHub to read its issues."
        case .anonymousLimit:
            why = "GitHub's limit for reading without signing in (60 an hour, "
                + "shared by this network) is used up — sign in to read issues."
        }
        return why + "\n\nRun `gh auth login` in a terminal, or put GITHUB_TOKEN=… "
            + "in this project's .env, then press ↻ above."
    }

    @objc private func refreshIssues() {
        guard let path = worktreePath else { return }
        GitHubIssueStore.shared.refresh(worktreePath: path)
    }

    /// What the last round folded in, and what it could not.
    private func makeIntegrationComposition(_ state: IntegrationPanelState) -> NSView {
        var lines: [(String, NSColor)] = []
        lines.append((
            state.included.isEmpty ? "nothing folded in" : "in: " + state.included.joined(separator: ", "),
            Theme.textSecondary
        ))
        for excluded in state.excluded {
            var head = excluded.label
            if let against = excluded.against, !against.isEmpty {
                head += " vs \(against)"
            }
            let where_ = excluded.paths.isEmpty ? "" : " · " + excluded.paths.joined(separator: ", ")
            lines.append(("excluded: \(head)\(where_)", .systemOrange))
        }
        if !state.conflictedPaths.isEmpty {
            lines.append(("conflict markers: " + state.conflictedPaths.joined(separator: ", "), .systemOrange))
        }
        if state.isHeld {
            // Name what is in the way. "local edits here" was true but not
            // actionable: the checkout is where things get run, so something is
            // nearly always dirty and the question is only ever *what*.
            if let head = state.heldHead {
                lines.append((
                    "not checked out — commits made here (\(head.prefix(9))) · /integrate force drops them",
                    .systemOrange
                ))
            } else {
                let paths = state.heldPaths ?? []
                let shown = paths.prefix(3).joined(separator: ", ")
                let rest = paths.count - min(3, paths.count)
                let detail = paths.isEmpty
                    ? ""
                    : " (" + shown + (rest > 0 ? " +\(rest) more" : "") + ")"
                lines.append((
                    "not checked out — local edits here\(detail) · /integrate force",
                    .systemOrange
                ))
            }
        }

        let stack = NSStackView(views: lines.map { text, color in
            let label = NSTextField(labelWithString: text)
            label.font = AppFont.mono(size: 10.5)
            label.textColor = color
            label.lineBreakMode = .byTruncatingTail
            return label
        })
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setAccessibilityIdentifier("sidePanel.integrationComposition")
        return stack
    }

    /// Composition lines currently rendered, top to bottom.
    var integrationCompositionLinesForTesting: [String] {
        guard let stack = contentView.subviews.first(where: {
            $0.accessibilityIdentifier() == "sidePanel.integrationComposition"
        }) as? NSStackView else { return [] }
        return stack.arrangedSubviews.compactMap { ($0 as? NSTextField)?.stringValue }
    }

    /// `host` defaults to the selected tab's container; the Issues tab
    /// re-renders while hidden, so it passes its own.
    @discardableResult
    private func showPlaceholder(_ message: String, identifier: String, below header: NSView? = nil,
                                 in host: NSView? = nil) -> NSTextField {
        let contentView = host ?? self.contentView
        let label = NSTextField(labelWithString: message)
        label.font = AppFont.mono(size: 12)
        label.textColor = Self.inkDim
        label.alignment = .center
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.setAccessibilityIdentifier(identifier)
        label.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(label)
        if let header {
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
                label.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 40),
                label.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 16),
                label.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -16),
            ])
        } else {
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
                label.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 16),
                label.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -16),
            ])
        }
        return label
    }
}

// MARK: - File search

extension WorktreeSidePanelViewController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === fileSearchField else { return }
        fileTreeController?.filterText = field.stringValue
    }
}
