import AppKit

enum SidePanelTab: Int {
    case firstMate = 0
    case files = 1
    case changes = 2
    case worktrees = 3
}

protocol WorktreeSidePanelDelegate: AnyObject {
    func sidePanel(_ vc: WorktreeSidePanelViewController, didSelectFile path: String)
    func sidePanel(_ vc: WorktreeSidePanelViewController, didSelectChange path: String)
}

final class WorktreeSidePanelViewController: NSViewController {
    private var worktreePath: String?
    private var selectedTab: SidePanelTab

    weak var delegate: WorktreeSidePanelDelegate?

    private let tabBar = NSStackView()
    private let contentView = NSView()

    /// Host-provided view (the cross-project worktree card list) shown for the
    /// `.worktrees` tab. Set by the dashboard, which owns the card data.
    var worktreesTabView: NSView?

    // First Mate tab
    private var bridgeVC: BridgePanelViewController?
    var pendingOrdersQueue: PendingOrdersQueue? {
        didSet { bridgeVC?.queue = pendingOrdersQueue }
    }
    var watchFeed: WatchFeed? {
        didSet { bridgeVC?.watchFeed = watchFeed }
    }
    var onSuggestionTapped: ((PendingOrder, String) -> Void)?
    var onBridgeNavigate: ((String) -> Void)?
    var onBridgeApprove: ((PendingOrder) -> Void)?

    // Files tab
    private var fileTreeController: FileTreeOutlineController?
    private var fileSearchField: NSSearchField?
    private var hiddenToggleButton: NSButton?
    private var showHiddenFiles = false
    /// Folder expansion state remembered per worktree, restored on return.
    private var expandedByWorktree: [String: Set<String>] = [:]

    // Changes tab
    private var changesTableView: NSTableView?
    private var changesScrollView: NSScrollView?
    private var changedFiles: [GitChangedFile] = []
    /// Bumped each time the changes tab starts a (background) reload; stale
    /// completions from an earlier reload are discarded.
    private var changesLoadGeneration = 0

    var selectedTabForTesting: SidePanelTab { selectedTab }
    var worktreePathForTesting: String? { worktreePath }

    init(worktreePath: String?, initialTab: SidePanelTab = .firstMate) {
        self.worktreePath = worktreePath
        self.selectedTab = initialTab
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func loadView() {
        let root = ThemedBackgroundView()
        // Match the First Mate side panel (Bare-TUI card background #0e2d37) so the
        // Files/Changes pane and First Mate read as the same docked side panel.
        root.backgroundToken = NSColor(srgbRed: 0x0e/255, green: 0x2d/255, blue: 0x37/255, alpha: 1)
        root.setAccessibilityIdentifier("sidePanel.view")

        tabBar.orientation = .horizontal
        tabBar.spacing = 2
        tabBar.distribution = .fillEqually
        tabBar.translatesAutoresizingMaskIntoConstraints = false

        // First Mate moved to the Helm cockpit; only Files + Changes remain here.
        let tabs: [(SidePanelTab, String, String)] = [
            (.files, "folder", "Files"),
            (.changes, "list.bullet.rectangle", "Changes"),
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
        // title-bar pane-switch icons now. tabBar is left unused but in place
        // so the highlight bookkeeping in updateTabBarHighlight() stays valid.
        tabBar.isHidden = true

        contentView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(contentView)

        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: root.topAnchor, constant: 4),
            contentView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        view = root
        rebuildContent()
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
        if isViewLoaded { rebuildContent() }
    }

    /// Remember the current worktree's folder expansion before tearing the tree down.
    private func captureExpansion() {
        guard let path = worktreePath, let controller = fileTreeController else { return }
        expandedByWorktree[path] = controller.currentExpandedPaths()
    }

    // MARK: - Internal selection handlers (called by tree/table, forwarded to delegate)

    func handleFileSelection(_ path: String) {
        delegate?.sidePanel(self, didSelectFile: path)
    }

    func handleChangeSelection(_ path: String) {
        delegate?.sidePanel(self, didSelectChange: path)
    }

    /// Switch the visible tab. Driven by the title-bar pane icons.
    func selectTab(_ tab: SidePanelTab) {
        guard tab != selectedTab else { return }
        captureExpansion()
        selectedTab = tab
        if isViewLoaded {
            updateTabBarHighlight()
            rebuildContent()
        }
    }

    private func rebuildContent() {
        // Remove any existing child VC
        bridgeVC?.view.removeFromSuperview()
        bridgeVC?.removeFromParent()
        bridgeVC = nil

        contentView.subviews.forEach { $0.removeFromSuperview() }
        fileTreeController = nil
        fileSearchField = nil
        hiddenToggleButton = nil
        changesTableView = nil
        changesScrollView = nil

        switch selectedTab {
        case .firstMate:
            showFirstMateTab()
        case .files:
            guard let path = worktreePath else {
                showPlaceholder("No worktree selected", identifier: "sidePanel.emptyPlaceholder")
                return
            }
            showFilesTab(path)
        case .changes:
            guard let path = worktreePath else {
                showPlaceholder("No worktree selected", identifier: "sidePanel.emptyPlaceholder")
                return
            }
            showChangesTab(path)
        case .worktrees:
            showWorktreesTab()
        }
    }

    private func showWorktreesTab() {
        guard let listView = worktreesTabView else {
            showPlaceholder("No worktrees", identifier: "sidePanel.worktreesPlaceholder")
            return
        }
        listView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(listView)
        NSLayoutConstraint.activate([
            listView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            listView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10),
            listView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
            listView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    private func showFirstMateTab() {
        let vc = BridgePanelViewController()
        vc.queue = pendingOrdersQueue
        vc.watchFeed = watchFeed
        vc.onSuggestionTapped = { [weak self] order, optionText in self?.onSuggestionTapped?(order, optionText) }
        vc.onNavigateToWorktree = { [weak self] path in self?.onBridgeNavigate?(path) }
        vc.onApprove = { [weak self] order in self?.onBridgeApprove?(order) }
        addChild(vc)
        vc.view.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(vc.view)
        NSLayoutConstraint.activate([
            vc.view.topAnchor.constraint(equalTo: contentView.topAnchor),
            vc.view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            vc.view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            vc.view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
        bridgeVC = vc
    }

    private func showFilesTab(_ path: String) {
        let controller = FileTreeOutlineController(rootPath: path)
        controller.showHidden = showHiddenFiles
        controller.onSelectFile = { [weak self] filePath in
            self?.handleFileSelection(filePath)
        }
        fileTreeController = controller

        // Search + hidden-files toggle row.
        let searchField = NSSearchField()
        searchField.placeholderString = "Search files"
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.sendsSearchStringImmediately = false
        searchField.sendsWholeSearchString = false
        searchField.setAccessibilityIdentifier("sidePanel.fileSearch")
        self.fileSearchField = searchField

        let hiddenToggle = NSButton()
        hiddenToggle.bezelStyle = .recessed
        hiddenToggle.isBordered = false
        hiddenToggle.imagePosition = .imageOnly
        hiddenToggle.image = NSImage(systemSymbolName: showHiddenFiles ? "eye" : "eye.slash",
                                     accessibilityDescription: "Toggle hidden files")
        hiddenToggle.contentTintColor = Theme.textSecondary
        hiddenToggle.target = self
        hiddenToggle.action = #selector(toggleHiddenFiles(_:))
        hiddenToggle.translatesAutoresizingMaskIntoConstraints = false
        hiddenToggle.toolTip = "Show/Hide hidden files"
        hiddenToggle.setAccessibilityIdentifier("sidePanel.toggleHidden")
        self.hiddenToggleButton = hiddenToggle

        let scrollView = NSScrollView()
        scrollView.documentView = controller.outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(searchField)
        contentView.addSubview(hiddenToggle)
        contentView.addSubview(scrollView)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            searchField.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 6),

            hiddenToggle.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            hiddenToggle.leadingAnchor.constraint(equalTo: searchField.trailingAnchor, constant: 4),
            hiddenToggle.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -6),
            hiddenToggle.widthAnchor.constraint(equalToConstant: 22),

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])

        // Restore the folder expansion remembered for this worktree.
        controller.restoreExpansion(expandedByWorktree[path] ?? [])
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        fileTreeController?.filterText = sender.stringValue
    }

    @objc private func toggleHiddenFiles(_ sender: NSButton) {
        showHiddenFiles.toggle()
        fileTreeController?.showHidden = showHiddenFiles
        sender.image = NSImage(systemSymbolName: showHiddenFiles ? "eye" : "eye.slash",
                               accessibilityDescription: "Toggle hidden files")
    }

    private func showChangesTab(_ path: String) {
        // `git status` can take hundreds of ms on large repos — run it off the
        // main thread. The generation counter drops stale results if the user
        // switched tab/worktree (or re-entered) before the scan finished.
        changesLoadGeneration += 1
        let generation = changesLoadGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let entries = GitDiff.changedFileEntries(worktreePath: path)
            DispatchQueue.main.async {
                guard let self, self.changesLoadGeneration == generation,
                      self.selectedTab == .changes, self.worktreePath == path else { return }
                self.presentChanges(entries)
            }
        }
    }

    private func presentChanges(_ entries: [GitChangedFile]) {
        changedFiles = entries

        if changedFiles.isEmpty {
            showPlaceholder("No changes", identifier: "sidePanel.changesEmpty")
            return
        }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ChangeColumn"))
        column.title = "Changed Files"

        let tableView = NSTableView()
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 22
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(changeRowClicked)
        tableView.setAccessibilityIdentifier("sidePanel.changesTable")
        tableView.backgroundColor = .clear

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])

        changesTableView = tableView
        changesScrollView = scrollView
    }

    @objc private func changeRowClicked() {
        guard let tableView = changesTableView else { return }
        let row = tableView.clickedRow
        guard row >= 0, row < changedFiles.count else { return }
        handleChangeSelection(changedFiles[row].path)
    }

    private func showPlaceholder(_ message: String, identifier: String) {
        let label = NSTextField(labelWithString: message)
        label.font = NSFont.systemFont(ofSize: 13)
        label.textColor = Theme.textSecondary
        label.alignment = .center
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.setAccessibilityIdentifier(identifier)
        label.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -16),
        ])
    }
}

// MARK: - NSTableViewDataSource / Delegate (Changes tab)

extension WorktreeSidePanelViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        changedFiles.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = changedFiles[row]
        let badge: String
        switch entry.status {
        case .added:    badge = "A"
        case .modified: badge = "M"
        case .deleted:  badge = "D"
        case .renamed:  badge = "R"
        case .unknown:  badge = "?"
        }

        let id = NSUserInterfaceItemIdentifier("ChangeCell")
        let cellView: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView {
            cellView = reused
        } else {
            cellView = NSTableCellView()
            cellView.identifier = id

            let badgeLabel = NSTextField(labelWithString: "")
            badgeLabel.font = AppFont.mono(size: 11, weight: .semibold)
            badgeLabel.translatesAutoresizingMaskIntoConstraints = false
            badgeLabel.tag = 100

            let pathLabel = NSTextField(labelWithString: "")
            pathLabel.font = NSFont.systemFont(ofSize: 12)
            pathLabel.lineBreakMode = .byTruncatingMiddle
            pathLabel.translatesAutoresizingMaskIntoConstraints = false
            cellView.textField = pathLabel

            cellView.addSubview(badgeLabel)
            cellView.addSubview(pathLabel)

            NSLayoutConstraint.activate([
                badgeLabel.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: 6),
                badgeLabel.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
                badgeLabel.widthAnchor.constraint(equalToConstant: 14),

                pathLabel.leadingAnchor.constraint(equalTo: badgeLabel.trailingAnchor, constant: 6),
                pathLabel.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -6),
                pathLabel.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
            ])
        }

        (cellView.viewWithTag(100) as? NSTextField)?.stringValue = badge
        cellView.textField?.stringValue = entry.path
        return cellView
    }
}
