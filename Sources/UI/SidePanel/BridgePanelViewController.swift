import AppKit

/// First Mate tab — shows red-zone pending orders (top) and green-zone watch entries (below).
/// Keyboard: j/k move selection, Enter approve/expand, n dismiss, x clear watch, → navigate.
final class BridgePanelViewController: NSViewController {

    var queue: PendingOrdersQueue? {
        didSet { rebind() }
    }
    var watchFeed: WatchFeed? {
        didSet { rebindWatch() }
    }
    var onNavigateToWorktree: ((String) -> Void)?
    var onApprove: ((PendingOrder) -> Void)?
    var suggestionFeed: SuggestionFeed? {
        didSet { rebindSuggestions() }
    }
    var onSuggestionTapped: ((SuggestionItem, String) -> Void)?

    // MARK: - Private state

    private var pendingOrders: [PendingOrder] = []
    private var expandedOrderIds: Set<String> = []
    private var watchItems: [WatchItem] = []
    /// Flattened (item, option) pairs, one per rendered chip row.
    private var suggestionRows: [(item: SuggestionItem, option: String)] = []

    // MARK: - Views

    private let stackView = NSStackView()

    private let ordersHeader = NSTextField(labelWithString: "Pending Orders · 0")
    private let ordersTableView = NSTableView()
    private let ordersScrollView = NSScrollView()

    private let watchHeader = NSTextField(labelWithString: "Watch")
    private let watchTableView = NSTableView()
    private let watchScrollView = NSScrollView()

    private let suggestHeader = NSTextField(labelWithString: "Suggestions")
    private let suggestTableView = NSTableView()
    private let suggestScrollView = NSScrollView()

    /// Layer-backed views whose CGColors must be re-resolved when the
    /// effective appearance changes (light/dark switch). `.cgColor` snapshots
    /// the color at resolve time, so we re-apply via `resolvedCGColor`.
    private var dividers: [NSView] = []

    // MARK: - Lifecycle

    override func loadView() {
        let root = ThemedBackgroundView()
        root.backgroundToken = Theme.background
        root.onAppearanceChange = { [weak self] in
            guard let self else { return }
            for line in self.dividers {
                line.layer?.backgroundColor = line.resolvedCGColor(SemanticColors.line)
            }
        }

        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 0
        stackView.distribution = .fill
        stackView.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: root.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        setupOrdersSection()
        setupWatchSection()
        setupSuggestSection()

        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        reload()
    }

    // MARK: - Setup

    private func setupOrdersSection() {
        ordersHeader.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        ordersHeader.textColor = Theme.textSecondary
        ordersHeader.translatesAutoresizingMaskIntoConstraints = false

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("OrderCol"))
        col.title = ""
        ordersTableView.addTableColumn(col)
        ordersTableView.headerView = nil
        ordersTableView.rowHeight = 28
        ordersTableView.dataSource = self
        ordersTableView.delegate = self
        ordersTableView.tag = 1
        ordersTableView.setAccessibilityIdentifier("bridge.ordersTable")
        ordersTableView.allowsEmptySelection = true
        ordersTableView.backgroundColor = .clear

        ordersScrollView.documentView = ordersTableView
        ordersScrollView.drawsBackground = false
        ordersScrollView.hasVerticalScroller = true
        ordersScrollView.autohidesScrollers = true
        ordersScrollView.translatesAutoresizingMaskIntoConstraints = false

        ordersTableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        let section = makeSectionContainer(header: ordersHeader, scroll: ordersScrollView, minHeight: 80)
        addFullWidthArranged(section)
        addFullWidthArranged(makeDivider())
    }

    /// Add an arranged subview and pin its width to the stack so it fills the
    /// full panel width (vertical NSStackView won't stretch the cross-axis on
    /// its own without an explicit constraint).
    private func addFullWidthArranged(_ subview: NSView) {
        stackView.addArrangedSubview(subview)
        subview.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
    }

    private func setupWatchSection() {
        watchHeader.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        watchHeader.textColor = Theme.textSecondary
        watchHeader.translatesAutoresizingMaskIntoConstraints = false

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("WatchCol"))
        col.title = ""
        watchTableView.addTableColumn(col)
        watchTableView.headerView = nil
        watchTableView.rowHeight = 22
        watchTableView.dataSource = self
        watchTableView.delegate = self
        watchTableView.tag = 2
        watchTableView.setAccessibilityIdentifier("bridge.watchTable")
        watchTableView.allowsEmptySelection = true
        watchTableView.backgroundColor = .clear

        watchScrollView.documentView = watchTableView
        watchScrollView.drawsBackground = false
        watchScrollView.hasVerticalScroller = true
        watchScrollView.autohidesScrollers = true
        watchScrollView.translatesAutoresizingMaskIntoConstraints = false
        watchTableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        let section = makeSectionContainer(header: watchHeader, scroll: watchScrollView, minHeight: 80)
        addFullWidthArranged(section)

        // Even split: pin Watch scroll height equal to Orders scroll height.
        // Both floors are 80 pt so the equal constraint cannot conflict at minimum size.
        watchScrollView.heightAnchor.constraint(equalTo: ordersScrollView.heightAnchor).isActive = true
    }

    private func setupSuggestSection() {
        suggestHeader.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        suggestHeader.textColor = Theme.textSecondary
        suggestHeader.translatesAutoresizingMaskIntoConstraints = false

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("SuggestCol"))
        col.title = ""
        suggestTableView.addTableColumn(col)
        suggestTableView.headerView = nil
        suggestTableView.rowHeight = 26
        suggestTableView.dataSource = self
        suggestTableView.delegate = self
        suggestTableView.tag = 3
        suggestTableView.setAccessibilityIdentifier("bridge.suggestTable")
        suggestTableView.allowsEmptySelection = true
        suggestTableView.backgroundColor = .clear

        suggestScrollView.documentView = suggestTableView
        suggestScrollView.drawsBackground = false
        suggestScrollView.hasVerticalScroller = true
        suggestScrollView.autohidesScrollers = true
        suggestScrollView.translatesAutoresizingMaskIntoConstraints = false
        suggestTableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        addFullWidthArranged(makeDivider())
        let section = makeSectionContainer(header: suggestHeader, scroll: suggestScrollView, minHeight: 60)
        addFullWidthArranged(section)
    }

    private func makeSectionContainer(header: NSTextField, scroll: NSScrollView, minHeight: CGFloat) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(header)
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),

            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: minHeight),
        ])
        return container
    }

    private func makeDivider() -> NSView {
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = line.resolvedCGColor(SemanticColors.line)
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        dividers.append(line)
        return line
    }

    // MARK: - Data

    private func rebind() {
        queue?.onChange = { [weak self] in
            DispatchQueue.main.async { self?.reload() }
        }
        if isViewLoaded { reload() }
    }

    private func rebindWatch() {
        watchFeed?.onChange = { [weak self] in
            DispatchQueue.main.async { self?.reloadWatch() }
        }
        if isViewLoaded { reloadWatch() }
    }

    private func rebindSuggestions() {
        suggestionFeed?.onChange = { [weak self] in
            DispatchQueue.main.async { self?.reloadSuggestions() }
        }
        if isViewLoaded { reloadSuggestions() }
    }

    private func reloadSuggestions() {
        let items = suggestionFeed?.all() ?? []
        suggestionRows = items.flatMap { item in item.options.map { (item, $0) } }
        suggestHeader.stringValue = suggestionRows.isEmpty ? "Suggestions" : "Suggestions · \(suggestionRows.count)"
        suggestTableView.reloadData()
    }

    private func reload() {
        pendingOrders = queue?.all() ?? []
        ordersHeader.stringValue = "Pending Orders · \(pendingOrders.count)"
        ordersTableView.reloadData()
        watchTableView.reloadData()
    }

    private func reloadWatch() {
        watchItems = watchFeed?.all() ?? []
        watchHeader.stringValue = watchItems.isEmpty ? "Watch" : "Watch · \(watchItems.count)"
        watchTableView.reloadData()
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        guard let key = event.characters else { super.keyDown(with: event); return }

        let activeTable = ordersTableView.window?.firstResponder === ordersTableView
            ? ordersTableView
            : (watchTableView.window?.firstResponder === watchTableView ? watchTableView : ordersTableView)

        switch key {
        case "j":
            moveSelection(in: activeTable, by: 1)
        case "k":
            moveSelection(in: activeTable, by: -1)
        case "\r":
            handleEnter(in: activeTable)
        case "n":
            handleDismiss(in: activeTable)
        case "x":
            handleClearWatch()
        default:
            if event.keyCode == 124 { // right arrow
                handleNavigate(in: activeTable)
            } else {
                super.keyDown(with: event)
            }
        }
    }

    private func moveSelection(in tableView: NSTableView, by delta: Int) {
        let count = tableView.numberOfRows
        guard count > 0 else { return }
        let current = tableView.selectedRow
        let next = max(0, min(count - 1, (current == -1 ? (delta > 0 ? 0 : count - 1) : current + delta)))
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    private func handleEnter(in tableView: NSTableView) {
        guard tableView.tag == 1 else { return }
        let row = tableView.selectedRow
        guard row >= 0, row < pendingOrders.count else { return }
        let order = pendingOrders[row]
        let isExpanded = expandedOrderIds.contains(order.id)
        let decision = BridgeConfirmFlow.onEnter(kind: order.action.kind, expanded: isExpanded)
        switch decision {
        case .expand:
            expandedOrderIds.insert(order.id)
            ordersTableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
        case .execute:
            expandedOrderIds.remove(order.id)
            onApprove?(order)
            queue?.resolve(id: order.id)
        }
    }

    private func handleDismiss(in tableView: NSTableView) {
        guard tableView.tag == 1 else { return }
        let row = tableView.selectedRow
        guard row >= 0, row < pendingOrders.count else { return }
        let order = pendingOrders[row]
        queue?.resolve(id: order.id)
    }

    private func handleClearWatch() {
        let row = watchTableView.selectedRow
        guard row >= 0, row < watchItems.count else { return }
        watchFeed?.clear(id: watchItems[row].id)
    }

    private func handleNavigate(in tableView: NSTableView) {
        let row = tableView.selectedRow
        guard tableView.tag == 1, row >= 0, row < pendingOrders.count else { return }
        let order = pendingOrders[row]
        onNavigateToWorktree?(order.action.worktreePath)
    }
}

// MARK: - NSTableViewDataSource / Delegate

extension BridgePanelViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        switch tableView.tag {
        case 1: return pendingOrders.count
        case 3: return suggestionRows.count
        default: return watchItems.count
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView.tag == 3 {
            guard row < suggestionRows.count else { return nil }
            let pair = suggestionRows[row]
            let id = NSUserInterfaceItemIdentifier("SuggestCell")
            let cell: SuggestionCellView
            if let reused = tableView.makeView(withIdentifier: id, owner: self) as? SuggestionCellView {
                cell = reused
            } else {
                cell = SuggestionCellView()
                cell.identifier = id
            }
            cell.configure(branch: pair.item.branch, option: pair.option,
                           onTap: { [weak self] in self?.onSuggestionTapped?(pair.item, pair.option) })
            return cell
        }
        if tableView.tag == 1 {
            guard row < pendingOrders.count else { return nil }
            let order = pendingOrders[row]
            let isExpanded = expandedOrderIds.contains(order.id)
            let id = NSUserInterfaceItemIdentifier("OrderCell")
            let cell: OrderCellView
            if let reused = tableView.makeView(withIdentifier: id, owner: self) as? OrderCellView {
                cell = reused
            } else {
                cell = OrderCellView()
                cell.identifier = id
            }
            cell.configure(order: order, expanded: isExpanded,
                           onApprove: { [weak self] in self?.approveOrder(order) },
                           onDismiss: { [weak self] in self?.queue?.resolve(id: order.id) })
            return cell
        } else {
            guard row < watchItems.count else { return nil }
            let item = watchItems[row]
            let id = NSUserInterfaceItemIdentifier("WatchCell")
            let cell: WatchCellView
            if let reused = tableView.makeView(withIdentifier: id, owner: self) as? WatchCellView {
                cell = reused
            } else {
                cell = WatchCellView()
                cell.identifier = id
            }
            cell.configure(item: item)
            return cell
        }
    }
}

// MARK: - Private helpers

private extension BridgePanelViewController {
    func approveOrder(_ order: PendingOrder) {
        let isExpanded = expandedOrderIds.contains(order.id)
        let decision = BridgeConfirmFlow.onEnter(kind: order.action.kind, expanded: isExpanded)
        switch decision {
        case .expand:
            expandedOrderIds.insert(order.id)
            if let idx = pendingOrders.firstIndex(where: { $0.id == order.id }) {
                ordersTableView.reloadData(forRowIndexes: IndexSet(integer: idx), columnIndexes: IndexSet(integer: 0))
            }
        case .execute:
            expandedOrderIds.remove(order.id)
            onApprove?(order)
            queue?.resolve(id: order.id)
        }
    }
}

// MARK: - OrderCellView

private final class OrderCellView: NSTableCellView {
    private let messageLabel = NSTextField(labelWithString: "")
    private let approveButton = NSButton()
    private let dismissButton = NSButton()

    private var onApprove: (() -> Void)?
    private var onDismiss: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        messageLabel.font = NSFont.systemFont(ofSize: 12)
        messageLabel.lineBreakMode = .byTruncatingTail
        messageLabel.translatesAutoresizingMaskIntoConstraints = false

        approveButton.bezelStyle = .inline
        approveButton.title = "✓"
        approveButton.contentTintColor = .systemGreen
        approveButton.isBordered = false
        approveButton.target = self
        approveButton.action = #selector(tappedApprove)
        approveButton.translatesAutoresizingMaskIntoConstraints = false

        dismissButton.bezelStyle = .inline
        dismissButton.title = "✕"
        dismissButton.contentTintColor = .systemRed
        dismissButton.isBordered = false
        dismissButton.target = self
        dismissButton.action = #selector(tappedDismiss)
        dismissButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(messageLabel)
        addSubview(approveButton)
        addSubview(dismissButton)

        NSLayoutConstraint.activate([
            dismissButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            dismissButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            dismissButton.widthAnchor.constraint(equalToConstant: 20),

            approveButton.trailingAnchor.constraint(equalTo: dismissButton.leadingAnchor, constant: -4),
            approveButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            approveButton.widthAnchor.constraint(equalToConstant: 20),

            messageLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            messageLabel.trailingAnchor.constraint(equalTo: approveButton.leadingAnchor, constant: -4),
            messageLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(order: PendingOrder, expanded: Bool, onApprove: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        self.onApprove = onApprove
        self.onDismiss = onDismiss
        let prefix = expanded ? "⚠ " : ""
        messageLabel.stringValue = prefix + order.action.message
        messageLabel.textColor = expanded ? .systemOrange : Theme.textPrimary
        approveButton.title = expanded ? "!!" : "✓"
    }

    @objc private func tappedApprove() { onApprove?() }
    @objc private func tappedDismiss() { onDismiss?() }
}

// MARK: - WatchCellView

private final class WatchCellView: NSTableCellView {
    private let iconLabel = NSTextField(labelWithString: "")
    private let branchLabel = NSTextField(labelWithString: "")
    private let msgLabel = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        iconLabel.font = NSFont.systemFont(ofSize: 11)
        iconLabel.translatesAutoresizingMaskIntoConstraints = false

        branchLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        branchLabel.lineBreakMode = .byTruncatingTail
        branchLabel.translatesAutoresizingMaskIntoConstraints = false

        msgLabel.font = NSFont.systemFont(ofSize: 11)
        msgLabel.textColor = Theme.textSecondary
        msgLabel.lineBreakMode = .byTruncatingTail
        msgLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconLabel)
        addSubview(branchLabel)
        addSubview(msgLabel)

        NSLayoutConstraint.activate([
            iconLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            iconLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconLabel.widthAnchor.constraint(equalToConstant: 16),

            branchLabel.leadingAnchor.constraint(equalTo: iconLabel.trailingAnchor, constant: 4),
            branchLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            branchLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 100),

            msgLabel.leadingAnchor.constraint(equalTo: branchLabel.trailingAnchor, constant: 6),
            msgLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            msgLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(item: WatchItem) {
        iconLabel.stringValue = item.kind == .watchError ? "⚠" : "⏳"
        iconLabel.textColor = item.kind == .watchError ? .systemRed : .systemYellow
        branchLabel.stringValue = item.branch
        msgLabel.stringValue = item.message
    }
}

// MARK: - SuggestionCellView

private final class SuggestionCellView: NSTableCellView {
    private let branchLabel = NSTextField(labelWithString: "")
    private let button = NSButton()
    private var onTap: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        branchLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        branchLabel.textColor = Theme.textSecondary
        branchLabel.lineBreakMode = .byTruncatingTail
        branchLabel.translatesAutoresizingMaskIntoConstraints = false

        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = NSFont.systemFont(ofSize: 11)
        button.lineBreakMode = .byTruncatingTail
        button.target = self
        button.action = #selector(tapped)
        button.translatesAutoresizingMaskIntoConstraints = false

        addSubview(branchLabel)
        addSubview(button)

        NSLayoutConstraint.activate([
            branchLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            branchLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            branchLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 90),

            button.leadingAnchor.constraint(equalTo: branchLabel.trailingAnchor, constant: 6),
            button.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(branch: String, option: String, onTap: @escaping () -> Void) {
        self.onTap = onTap
        branchLabel.stringValue = branch
        button.title = option
        button.toolTip = option
    }

    @objc private func tapped() { onTap?() }
}
