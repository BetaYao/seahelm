import AppKit

/// First Mate tab — shows red-zone pending orders (top) and green-zone watch entries (below).
/// Keyboard: j/k move selection, 1-9 pick options, n dismiss, x clear watch, → navigate.
final class BridgePanelViewController: NSViewController {

    var queue: PendingOrdersQueue? {
        didSet { rebind() }
    }
    var watchFeed: WatchFeed? {
        didSet { rebindWatch() }
    }
    var onNavigateToWorktree: ((String) -> Void)?
    var onApprove: ((PendingOrder) -> Void)?
    /// Called when the user picks a suggestion chip. The handler is responsible for resolving the order (e.g. via queue.resolve) after acting.
    var onSuggestionTapped: ((PendingOrder, String) -> Void)?

    // MARK: - Static helpers

    /// Kinds that require a two-step [!! Confirm] before executing.
    static let dangerousKinds: Set<FirstMateActionKind> = [.autoCommit, .returnToPort]

    static func buttonTitles(for order: PendingOrder) -> [String] {
        order.action.options ?? ["Approve"]
    }

    /// Card = top pad (6) + title (16) + message block + button block + bottom pad (8).
    /// Buttons are stacked vertically (one full-width button per option) so long option
    /// text never clips in a narrow panel. Message block is omitted when the message is empty.
    static func cardHeight(for order: PendingOrder) -> CGFloat {
        let buttons = buttonTitles(for: order).count
        let messageBlock: CGFloat = order.action.message.isEmpty ? 0 : (2 + 30) // gap + 2 lines
        let buttonBlock = 6 + CGFloat(buttons) * 24 + CGFloat(max(0, buttons - 1)) * 4
        return 6 + 16 + messageBlock + buttonBlock + 8
    }

    // MARK: - Private state

    private var pendingOrders: [PendingOrder] = []
    private var watchItems: [WatchItem] = []

    // MARK: - Views

    private let stackView = NSStackView()

    private let ordersHeader = NSTextField(labelWithString: "Pending Orders · 0")
    private let ordersTableView = NSTableView()
    private let ordersScrollView = NSScrollView()

    private let watchHeader = NSTextField(labelWithString: "Watch")
    private let watchTableView = NSTableView()
    private let watchScrollView = NSScrollView()

    /// Layer-backed views whose CGColors must be re-resolved when the
    /// effective appearance changes (light/dark switch).
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
        ordersTableView.usesAutomaticRowHeights = false
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

        watchScrollView.heightAnchor.constraint(equalTo: ordersScrollView.heightAnchor).isActive = true
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

    private func reload() {
        pendingOrders = queue?.all() ?? []
        ordersHeader.stringValue = "Pending Orders · \(pendingOrders.count)"
        ordersTableView.reloadData()
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
        case "n":
            handleDismiss(in: activeTable)
        case "x":
            handleClearWatch()
        case "1", "2", "3", "4", "5", "6", "7", "8", "9":
            handleDigit(Int(key)! - 1, in: activeTable)
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

    private func handleDigit(_ index: Int, in tableView: NSTableView) {
        guard tableView.tag == 1 else { return }
        let row = tableView.selectedRow
        guard row >= 0, row < pendingOrders.count else { return }
        let order = pendingOrders[row]
        let dangerous = Self.dangerousKinds.contains(order.action.kind)
        if let card = tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? OrderCardView {
            card.selectOption(index, dangerous: dangerous)
        } else {
            applyOption(order, index: index)
        }
    }

    private func applyOption(_ order: PendingOrder, index: Int) {
        if let options = order.action.options {
            guard index < options.count else { return }
            onSuggestionTapped?(order, options[index])
        } else {
            onApprove?(order)
            queue?.resolve(id: order.id)
        }
    }
}

// MARK: - NSTableViewDataSource / Delegate

extension BridgePanelViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        switch tableView.tag {
        case 1: return pendingOrders.count
        default: return watchItems.count
        }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if tableView.tag == 1, row < pendingOrders.count {
            return Self.cardHeight(for: pendingOrders[row])
        }
        return tableView.tag == 1 ? 28 : 22
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView.tag == 1 {
            guard row < pendingOrders.count else { return nil }
            let order = pendingOrders[row]
            let id = NSUserInterfaceItemIdentifier("OrderCard")
            let card = (tableView.makeView(withIdentifier: id, owner: self) as? OrderCardView) ?? OrderCardView()
            card.identifier = id
            card.configure(order: order,
                           onOption: { [weak self] idx in self?.applyOption(order, index: idx) },
                           onDismiss: { [weak self] in self?.queue?.resolve(id: order.id) })
            return card
        } else {
            guard row < watchItems.count else { return nil }
            let item = watchItems[row]
            let id = NSUserInterfaceItemIdentifier("WatchCard")
            let card = (tableView.makeView(withIdentifier: id, owner: self) as? WatchCardView) ?? WatchCardView()
            card.identifier = id
            card.configure(item: item)
            return card
        }
    }
}

// MARK: - OrderCardView

private final class OrderCardView: NSTableCellView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(labelWithString: "")
    private let buttonRow = NSStackView()
    private let dismissButton = NSButton()
    private var trackingArea: NSTrackingArea?

    private var onOption: ((Int) -> Void)?
    private var onDismiss: (() -> Void)?
    private var armedDangerousIndex: Int?
    private var dangerousIndexes: Set<Int> = []

    override init(frame: NSRect) { super.init(frame: frame); setup() }
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        messageLabel.font = NSFont.systemFont(ofSize: 11)
        messageLabel.textColor = Theme.textSecondary
        messageLabel.maximumNumberOfLines = 2
        messageLabel.lineBreakMode = .byTruncatingTail
        messageLabel.translatesAutoresizingMaskIntoConstraints = false

        buttonRow.orientation = .vertical
        buttonRow.alignment = .leading
        buttonRow.spacing = 4
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        dismissButton.title = "✕"
        dismissButton.isBordered = false
        dismissButton.contentTintColor = Theme.textSecondary
        dismissButton.target = self
        dismissButton.action = #selector(tappedDismiss)
        dismissButton.isHidden = true
        dismissButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLabel); addSubview(messageLabel); addSubview(buttonRow); addSubview(dismissButton)
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: dismissButton.leadingAnchor, constant: -4),

            dismissButton.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            dismissButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            dismissButton.widthAnchor.constraint(equalToConstant: 18),
            dismissButton.heightAnchor.constraint(equalToConstant: 18),

            messageLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            messageLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            messageLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),

            buttonRow.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: 6),
            buttonRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            buttonRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            buttonRow.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8),
        ])
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t); trackingArea = t
    }
    override func mouseEntered(with event: NSEvent) { dismissButton.isHidden = false }
    override func mouseExited(with event: NSEvent) { dismissButton.isHidden = true }

    func configure(order: PendingOrder,
                   onOption: @escaping (Int) -> Void,
                   onDismiss: @escaping () -> Void) {
        self.onOption = onOption
        self.onDismiss = onDismiss
        self.armedDangerousIndex = nil
        titleLabel.stringValue = "● \(order.action.project) · \(order.action.branch)"
        titleLabel.textColor = Theme.textPrimary
        messageLabel.stringValue = order.action.message
        messageLabel.isHidden = order.action.message.isEmpty

        buttonRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let titles = BridgePanelViewController.buttonTitles(for: order)
        let dangerous = BridgePanelViewController.dangerousKinds.contains(order.action.kind)
        dangerousIndexes = dangerous ? Set(0..<titles.count) : []
        for (i, title) in titles.enumerated() {
            let b = NSButton(title: "\(i + 1) \(title)", target: self, action: #selector(tappedOption(_:)))
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.tag = i
            b.toolTip = title
            b.alignment = .left
            (b.cell as? NSButtonCell)?.lineBreakMode = .byTruncatingTail
            if dangerous { b.contentTintColor = .systemOrange }
            buttonRow.addArrangedSubview(b)
            // Full-width button so long option text stays on its own row (no horizontal clip).
            b.widthAnchor.constraint(equalTo: buttonRow.widthAnchor).isActive = true
        }
    }

    @discardableResult
    func selectOption(_ index: Int, dangerous: Bool) -> Bool {
        if dangerous && armedDangerousIndex != index {
            armedDangerousIndex = index
            if let b = buttonRow.arrangedSubviews[safe: index] as? NSButton { b.title = "!! Confirm" }
            return false
        }
        onOption?(index)
        return true
    }

    @objc private func tappedOption(_ sender: NSButton) {
        let dangerous = dangerousIndexes.contains(sender.tag)
        selectOption(sender.tag, dangerous: dangerous)
    }
    @objc private func tappedDismiss() { onDismiss?() }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

// MARK: - WatchCardView

private final class WatchCardView: NSTableCellView {
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
