import AppKit

enum SidePanelTab: Int {
    case firstMate = 0
    case files = 1
    case changes = 2
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
    private var fileSearchField: NSTextField?
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
        // Clear — same glass as First Mate / Dashboard overview.
        root.backgroundToken = .clear
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
        // chrome header icons. tabBar stays for updateTabBarHighlight().
        tabBar.isHidden = true

        contentView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(contentView)

        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: root.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        view = root
        rebuildContent()
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
    private func makePaneHeader(title: String, subtitle: String = "") -> NSView {
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
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 13),
            row.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 15),
            row.trailingAnchor.constraint(lessThanOrEqualTo: wrap.trailingAnchor, constant: -15),

            hairline.topAnchor.constraint(equalTo: row.bottomAnchor, constant: 11),
            hairline.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 1),
            hairline.bottomAnchor.constraint(equalTo: wrap.bottomAnchor),
        ])
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
            showFilesTab(path)
        case .changes:
            guard let path = worktreePath else {
                let header = makePaneHeader(title: "Changes")
                contentView.addSubview(header)
                NSLayoutConstraint.activate([
                    header.topAnchor.constraint(equalTo: contentView.topAnchor),
                    header.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                    header.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                ])
                showPlaceholder("No worktree selected", identifier: "sidePanel.emptyPlaceholder", below: header)
                return
            }
            showChangesTab(path)
        }
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

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: contentView.topAnchor),
            header.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

            searchRow.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
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

        // Restore the folder expansion remembered for this worktree.
        controller.restoreExpansion(expandedByWorktree[path] ?? [])
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

        contentView.subviews.forEach { $0.removeFromSuperview() }

        let header = makePaneHeader(
            title: "Changes",
            subtitle: changedFiles.isEmpty ? "clean" : "\(changedFiles.count) files"
        )
        contentView.addSubview(header)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: contentView.topAnchor),
            header.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])

        if changedFiles.isEmpty {
            showPlaceholder("No changes", identifier: "sidePanel.changesEmpty", below: header)
            return
        }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ChangeColumn"))
        column.title = "Changed Files"

        let tableView = NSTableView()
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 26
        tableView.style = .sourceList
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(changeRowClicked)
        tableView.setAccessibilityIdentifier("sidePanel.changesTable")
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 6),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -6),
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

    private func showPlaceholder(_ message: String, identifier: String, below header: NSView? = nil) {
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
    }
}

// MARK: - File search

extension WorktreeSidePanelViewController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === fileSearchField else { return }
        fileTreeController?.filterText = field.stringValue
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
        let badgeColor: NSColor
        switch entry.status {
        case .added:
            badge = "A"
            badgeColor = NSColor(srgbRed: 0x5f/255, green: 0xb8/255, blue: 0x7a/255, alpha: 1)
        case .modified:
            badge = "M"
            badgeColor = NSColor(srgbRed: 0xe0/255, green: 0xa4/255, blue: 0x58/255, alpha: 1)
        case .deleted:
            badge = "D"
            badgeColor = NSColor(srgbRed: 0xe0/255, green: 0x7a/255, blue: 0x6a/255, alpha: 1)
        case .renamed:
            badge = "R"
            badgeColor = NSColor(srgbRed: 0x5b/255, green: 0x93/255, blue: 0xf0/255, alpha: 1)
        case .unknown:
            badge = "?"
            badgeColor = Self.inkDim
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
            pathLabel.font = AppFont.mono(size: 12)
            pathLabel.textColor = Self.ink
            pathLabel.lineBreakMode = .byTruncatingMiddle
            pathLabel.translatesAutoresizingMaskIntoConstraints = false
            cellView.textField = pathLabel

            cellView.addSubview(badgeLabel)
            cellView.addSubview(pathLabel)

            NSLayoutConstraint.activate([
                badgeLabel.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: 8),
                badgeLabel.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
                badgeLabel.widthAnchor.constraint(equalToConstant: 14),

                pathLabel.leadingAnchor.constraint(equalTo: badgeLabel.trailingAnchor, constant: 8),
                pathLabel.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -8),
                pathLabel.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
            ])
        }

        if let badgeLabel = cellView.viewWithTag(100) as? NSTextField {
            badgeLabel.stringValue = badge
            badgeLabel.textColor = badgeColor
        }
        cellView.textField?.stringValue = entry.path
        cellView.textField?.textColor = Self.ink
        cellView.textField?.font = AppFont.mono(size: 12)
        return cellView
    }
}
