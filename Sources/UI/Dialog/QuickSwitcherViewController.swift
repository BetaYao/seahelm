import AppKit

protocol QuickSwitcherDelegate: AnyObject {
    func quickSwitcher(_ vc: QuickSwitcherViewController, didSelect worktree: WorktreeInfo)
}

/// Spotlight-style quick switcher for jumping to worktrees by fuzzy search.
class QuickSwitcherViewController: NSViewController, NSSearchFieldDelegate {
    weak var quickSwitcherDelegate: QuickSwitcherDelegate?

    private let searchField = NSTextField()
    private let resultsTableView = NSTableView()
    private let resultsScrollView = NSScrollView()

    private var allWorktrees: [WorktreeInfo] = []
    private var filteredWorktrees: [WorktreeInfo] = []
    private var statuses: [String: AgentStatus] = [:]

    init(worktrees: [WorktreeInfo], statuses: [String: AgentStatus]) {
        self.allWorktrees = worktrees
        self.filteredWorktrees = worktrees
        self.statuses = statuses
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        primeTitles()
    }

    /// Resolve semantic titles off the main thread, then refresh the rows so the
    /// list shows task descriptions / session summaries instead of pinyin branch
    /// names. Worktrees with a fresh cache entry resolve without disk access.
    private func primeTitles() {
        for info in allWorktrees {
            WorktreeTitleCache.shared.title(
                worktreePath: info.path, lastUserPrompt: "", branch: info.branch
            ) { [weak self] _ in
                self?.resultsTableView.reloadData()
            }
        }
    }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 340))
        container.wantsLayer = true
        container.layer?.backgroundColor = SemanticColors.panel.cgColor
        container.layer?.cornerRadius = 12
        container.layer?.borderWidth = 1
        container.layer?.borderColor = SemanticColors.line.cgColor
        container.setAccessibilityIdentifier("dialog.quickSwitcher")
        container.setAccessibilityElement(true)
        container.setAccessibilityRole(.group)
        self.view = container

        // Search bar: subtle rounded container with a magnifier + borderless field.
        let searchBar = NSView()
        searchBar.wantsLayer = true
        searchBar.layer?.cornerRadius = 10
        searchBar.layer?.backgroundColor = SemanticColors.panel2.cgColor
        searchBar.layer?.borderWidth = 1
        searchBar.layer?.borderColor = SemanticColors.lineAlpha45.cgColor
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(searchBar)

        let magnifier = NSImageView()
        magnifier.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        magnifier.contentTintColor = SemanticColors.muted
        magnifier.translatesAutoresizingMaskIntoConstraints = false
        searchBar.addSubview(magnifier)

        searchField.placeholderString = "Search worktrees..."
        searchField.font = NSFont.systemFont(ofSize: 15)
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.lineBreakMode = .byTruncatingTail
        searchField.cell?.usesSingleLineMode = true
        searchField.delegate = self
        searchField.setAccessibilityIdentifier("dialog.quickSwitcher.searchField")
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchBar.addSubview(searchField)

        // Separator under search
        let separator = NSView()
        separator.wantsLayer = true
        separator.layer?.backgroundColor = SemanticColors.lineAlpha45.cgColor
        separator.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(separator)

        // Results table
        resultsScrollView.hasVerticalScroller = true
        resultsScrollView.drawsBackground = false
        resultsScrollView.borderType = .noBorder
        resultsScrollView.scrollerStyle = .overlay
        resultsScrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(resultsScrollView)

        resultsTableView.backgroundColor = .clear
        resultsTableView.headerView = nil
        resultsTableView.rowHeight = 40
        resultsTableView.intercellSpacing = NSSize(width: 0, height: 0)
        resultsTableView.selectionHighlightStyle = .none
        resultsTableView.delegate = self
        resultsTableView.dataSource = self
        resultsTableView.doubleAction = #selector(confirmSelection)
        resultsTableView.target = self

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("worktree"))
        col.resizingMask = .autoresizingMask
        resultsTableView.addTableColumn(col)
        resultsTableView.setAccessibilityIdentifier("dialog.quickSwitcher.resultsList")
        resultsScrollView.documentView = resultsTableView

        // Hint label
        let hintLabel = NSTextField(labelWithString: "↑↓ navigate  ↵ select  ⎋ cancel")
        hintLabel.font = NSFont.systemFont(ofSize: 11)
        hintLabel.textColor = SemanticColors.muted
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hintLabel)

        NSLayoutConstraint.activate([
            searchBar.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            searchBar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            searchBar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            searchBar.heightAnchor.constraint(equalToConstant: 42),

            magnifier.leadingAnchor.constraint(equalTo: searchBar.leadingAnchor, constant: 12),
            magnifier.centerYAnchor.constraint(equalTo: searchBar.centerYAnchor),
            magnifier.widthAnchor.constraint(equalToConstant: 16),
            magnifier.heightAnchor.constraint(equalToConstant: 16),

            searchField.leadingAnchor.constraint(equalTo: magnifier.trailingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: searchBar.trailingAnchor, constant: -10),
            searchField.centerYAnchor.constraint(equalTo: searchBar.centerYAnchor),

            separator.topAnchor.constraint(equalTo: searchBar.bottomAnchor, constant: 12),
            separator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),

            resultsScrollView.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 6),
            resultsScrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            resultsScrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            resultsScrollView.bottomAnchor.constraint(equalTo: hintLabel.topAnchor, constant: -4),

            hintLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            hintLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
        ])
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(searchField)
        if !filteredWorktrees.isEmpty {
            resultsTableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125: // Down arrow
            moveSelection(by: 1)
        case 126: // Up arrow
            moveSelection(by: -1)
        case 36: // Return
            confirmSelection()
        case 53: // Esc
            dismiss(nil)
        default:
            super.keyDown(with: event)
        }
    }

    private func moveSelection(by delta: Int) {
        guard !filteredWorktrees.isEmpty else { return }
        let current = resultsTableView.selectedRow
        let next = max(0, min(filteredWorktrees.count - 1, current + delta))
        resultsTableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        resultsTableView.scrollRowToVisible(next)
    }

    @objc private func confirmSelection() {
        let row = resultsTableView.selectedRow
        guard row >= 0, row < filteredWorktrees.count else { return }
        let selected = filteredWorktrees[row]
        dismiss(nil)
        quickSwitcherDelegate?.quickSwitcher(self, didSelect: selected)
    }

    private func updateFilter() {
        let query = searchField.stringValue
        filteredWorktrees = FuzzyMatch.filter(allWorktrees, query: query) { info in
            info.branch.isEmpty ? info.displayName : info.branch
        }
        resultsTableView.reloadData()
        if !filteredWorktrees.isEmpty {
            resultsTableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }
}

// MARK: - NSTextFieldDelegate

extension QuickSwitcherViewController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        updateFilter()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(moveDown(_:)) {
            moveSelection(by: 1)
            return true
        }
        if commandSelector == #selector(moveUp(_:)) {
            moveSelection(by: -1)
            return true
        }
        if commandSelector == #selector(insertNewline(_:)) {
            confirmSelection()
            return true
        }
        if commandSelector == #selector(cancelOperation(_:)) {
            dismiss(nil)
            return true
        }
        return false
    }
}

// MARK: - NSTableViewDataSource

extension QuickSwitcherViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return filteredWorktrees.count
    }
}

// MARK: - NSTableViewDelegate

extension QuickSwitcherViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        return QuickSwitcherRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let info = filteredWorktrees[row]
        let status = statuses[info.path] ?? .unknown

        let cell = NSView()
        cell.wantsLayer = true

        // Status dot
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.layer?.backgroundColor = status.color.cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(dot)

        // Worktree title — resolved semantic title (Claude session summary →
        // stored task description → prompt), falling back to the branch/dir name
        // until the cache is primed.
        let title = WorktreeTitleCache.shared.cachedTitle(worktreePath: info.path) ?? info.displayName
        let branchLabel = NSTextField(labelWithString: title)
        branchLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        branchLabel.textColor = SemanticColors.text
        branchLabel.lineBreakMode = .byTruncatingTail
        branchLabel.translatesAutoresizingMaskIntoConstraints = false
        branchLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cell.addSubview(branchLabel)

        // Path (secondary)
        let pathLabel = NSTextField(labelWithString: shortenPath(info.path))
        pathLabel.font = NSFont.systemFont(ofSize: 11)
        pathLabel.textColor = SemanticColors.muted
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.alignment = .right
        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        pathLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        pathLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        cell.addSubview(pathLabel)

        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 14),
            dot.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),

            branchLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 10),
            branchLabel.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            branchLabel.trailingAnchor.constraint(lessThanOrEqualTo: pathLabel.leadingAnchor, constant: -12),

            pathLabel.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -14),
            pathLabel.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            pathLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 180),
        ])

        return cell
    }

    private func shortenPath(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent().lastPathComponent
        let name = url.lastPathComponent
        return "\(parent)/\(name)"
    }
}

// MARK: - Custom Row View

private class QuickSwitcherRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        let selectionRect = bounds.insetBy(dx: 6, dy: 1)
        let path = NSBezierPath(roundedRect: selectionRect, xRadius: 6, yRadius: 6)
        SemanticColors.accentAlpha15.setFill()
        path.fill()
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        return .normal  // keep text colors unchanged when selected
    }
}
