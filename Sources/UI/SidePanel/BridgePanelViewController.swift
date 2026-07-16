import AppKit

/// First Mate tab — shows red-zone pending orders (top) and green-zone watch entries (below).
/// Keyboard: j/k move selection, 1-9 pick options, n dismiss, x clear watch, → navigate.
final class BridgePanelViewController: NSViewController {

    var queue: PendingOrdersQueue? {
        didSet {
            oldValue?.removeObserver(queueToken); queueToken = nil
            rebind()
        }
    }
    var watchFeed: WatchFeed? {
        didSet {
            oldValue?.removeObserver(watchToken); watchToken = nil
            rebindWatch()
        }
    }

    private var queueToken: Int?
    private var watchToken: Int?

    deinit {
        queue?.removeObserver(queueToken)
        watchFeed?.removeObserver(watchToken)
    }
    var onNavigateToWorktree: ((String) -> Void)?
    var onApprove: ((PendingOrder) -> Void)?
    /// Fired after each reload with the current pending-order count. Lets a host
    /// (e.g. the Helm cockpit orb badge) reflect the count without taking over the
    /// queue's single `onChange` closure.
    var onOrdersCountChanged: ((Int) -> Void)?
    /// Called when the user picks a suggestion chip. The handler is responsible for resolving the order (e.g. via queue.resolve) after acting.
    var onSuggestionTapped: ((PendingOrder, String) -> Void)?

    // MARK: - Static helpers

    /// Kinds that require a two-step [!! Confirm] before executing.
    static let dangerousKinds: Set<FirstMateActionKind> = [.autoCommit, .returnToPort]

    static func buttonTitles(for order: PendingOrder) -> [String] {
        order.action.options ?? ["Approve"]
    }

    /// Bare-TUI card: top(11) + title row(18) + message(measured) + chip stack + bottom(11).
    /// The question is measured at a deliberately-narrow width so the predicted height is
    /// never short of what the real (wider) layout needs — avoids bottom clipping.
    static func cardHeight(for order: PendingOrder) -> CGFloat {
        let titleRow: CGFloat = 18
        // Options stack vertically, one chip (28) per row with 7 between, so the
        // card grows with the option count. Side-by-side chips shared one row's
        // width and truncated every label down to its bare number badge.
        let count = max(1, buttonTitles(for: order).count)
        let chipRow = CGFloat(count) * 28 + CGFloat(count - 1) * 7 + 2  // 30 for a lone chip, as before
        let msg = order.action.message
        var messageBlock: CGFloat = 0
        if !msg.isEmpty {
            let bounds = (msg as NSString).boundingRect(
                with: CGSize(width: 500, height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: AppFont.mono(size: 12.5)])
            messageBlock = ceil(bounds.height) + 9 // + gap above
        }
        return 11 + titleRow + messageBlock + 11 + chipRow + 11
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

    // Tabbed sections (cockpit shows one at a time; the segmented control lives
    // in the cockpit header).
    enum Section { case orders, watch }
    private var ordersSectionView: NSView?
    private var watchSectionView: NSView?
    /// Fired on reload with (ordersCount, watchCount) for the header tabs.
    var onCountsChanged: ((Int, Int) -> Void)?

    func showSection(_ section: Section) {
        ordersSectionView?.isHidden = (section != .orders)
        watchSectionView?.isHidden = (section != .watch)
    }

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
        ordersTableView.selectionHighlightStyle = .none
        ordersTableView.intercellSpacing = NSSize(width: 0, height: 8)

        ordersScrollView.documentView = ordersTableView
        ordersScrollView.drawsBackground = false
        ordersScrollView.hasVerticalScroller = true
        ordersScrollView.autohidesScrollers = true
        ordersScrollView.translatesAutoresizingMaskIntoConstraints = false

        ordersTableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        let section = makeSectionContainer(header: ordersHeader, scroll: ordersScrollView, minHeight: 80,
                                           showHeader: false)
        addFullWidthArranged(section)
        ordersSectionView = section
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

        let section = makeSectionContainer(header: watchHeader, scroll: watchScrollView, minHeight: 60,
                                           showHeader: false)
        addFullWidthArranged(section)
        watchSectionView = section
        section.isHidden = true  // Orders is the default tab
    }

    private func makeSectionContainer(header: NSTextField, scroll: NSScrollView, minHeight: CGFloat,
                                      showHeader: Bool = true) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scroll)
        var constraints: [NSLayoutConstraint] = [
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: minHeight),
        ]
        if showHeader {
            container.addSubview(header)
            constraints += [
                header.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
                header.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
                header.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
                scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            ]
        } else {
            constraints.append(scroll.topAnchor.constraint(equalTo: container.topAnchor, constant: 6))
        }
        NSLayoutConstraint.activate(constraints)
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
        queueToken = queue?.addObserver { [weak self] in
            DispatchQueue.main.async { self?.reload() }
        }
        if isViewLoaded { reload() }
    }

    private func rebindWatch() {
        watchToken = watchFeed?.addObserver { [weak self] in
            DispatchQueue.main.async { self?.reloadWatch() }
        }
        if isViewLoaded { reloadWatch() }
    }

    private func reload() {
        pendingOrders = queue?.all() ?? []
        ordersHeader.stringValue = "Pending Orders · \(pendingOrders.count)"
        ordersTableView.reloadData()
        onOrdersCountChanged?(pendingOrders.count)
        onCountsChanged?(pendingOrders.count, watchItems.count)
    }

    private func reloadWatch() {
        watchItems = watchFeed?.all() ?? []
        watchHeader.stringValue = watchItems.isEmpty ? "Watch" : "Watch · \(watchItems.count)"
        watchTableView.reloadData()
        onCountsChanged?(pendingOrders.count, watchItems.count)
    }

    // MARK: - Keyboard

    /// `i` pressed while a table is focused — host focuses the command input.
    var onFocusInput: (() -> Void)?
    /// Esc pressed while a table is focused — host closes the cockpit.
    var onEscape: (() -> Void)?

    /// Make the Orders table the keyboard responder (used when the cockpit opens
    /// in navigation mode rather than focusing the command input).
    func focusOrdersTable() {
        view.window?.makeFirstResponder(ordersTableView)
        if ordersTableView.numberOfRows > 0, ordersTableView.selectedRow < 0 {
            ordersTableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    // Esc / Tab arrive as responder-chain actions (NSTableView maps them via
    // interpretKeyEvents rather than bubbling raw keyDown).
    override func cancelOperation(_ sender: Any?) { onEscape?() }
    override func insertTab(_ sender: Any?) { toggleActiveTable() }
    /// Enter on a selected order navigates to its pane (when no option was picked).
    override func insertNewline(_ sender: Any?) { handleNavigate(in: ordersTableView) }

    override func keyDown(with event: NSEvent) {
        guard let key = event.characters else { super.keyDown(with: event); return }

        let activeTable = ordersTableView.window?.firstResponder === ordersTableView
            ? ordersTableView
            : (watchTableView.window?.firstResponder === watchTableView ? watchTableView : ordersTableView)

        switch key {
        case "i":
            onFocusInput?()
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

    /// Tab switches keyboard focus between the Orders and Watch tables.
    /// Tab toggles the visible section (Orders ⇄ Watch) and focuses its table.
    /// The host restyles its header tabs via `onToggleSection`.
    var onToggleSection: ((Section) -> Void)?
    private func toggleActiveTable() {
        let toWatch = !(watchSectionView?.isHidden == false)  // currently showing Orders → go Watch
        let section: Section = toWatch ? .watch : .orders
        showSection(section)
        onToggleSection?(section)
        let target = toWatch ? watchTableView : ordersTableView
        view.window?.makeFirstResponder(target)
        if target.numberOfRows > 0, target.selectedRow < 0 {
            target.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
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

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView, table.tag == 1 else { return }
        // Cards are opaque, so reflect selection by toggling their accent bar.
        for row in 0..<table.numberOfRows {
            if let card = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? OrderCardView {
                card.setSelected(row == table.selectedRow)
            }
        }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if tableView.tag == 1, row < pendingOrders.count {
            return Self.cardHeight(for: pendingOrders[row])
        }
        if tableView.tag == 2, row < watchItems.count {
            return WatchCardView.height(for: watchItems[row])
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
                           onOption: { [weak self] idx in self?.applyOption(order, index: idx) })
            card.onNavigate = { [weak self] in self?.onNavigateToWorktree?(order.action.worktreePath) }
            card.onDismiss = { [weak self] in self?.queue?.resolve(id: order.id) }
            card.setSelected(row == tableView.selectedRow)
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

// MARK: - Bare-TUI palette & helpers (prototype THEME.A)

/// First Mate "Bare-TUI" palette (prototype THEME.A). Internal so the Dashboard
/// overview can reuse the exact same colours/cards 1:1.
enum Bare {
    static let cardBg     = NSColor(srgbRed: 0x0e/255, green: 0x2d/255, blue: 0x37/255, alpha: 1)
    static let panelAlt   = NSColor(srgbRed: 120/255, green: 210/255, blue: 225/255, alpha: 0.045)
    static let line       = NSColor(srgbRed: 150/255, green: 215/255, blue: 225/255, alpha: 0.10)
    static let lineStrong = NSColor(srgbRed: 150/255, green: 215/255, blue: 225/255, alpha: 0.18)
    static let ink        = NSColor(srgbRed: 0xcf/255, green: 0xe0/255, blue: 0xe0/255, alpha: 1)
    static let inkDim     = NSColor(srgbRed: 0x7f/255, green: 0xa0/255, blue: 0xa3/255, alpha: 1)
    static let inkFaint   = NSColor(srgbRed: 0x55/255, green: 0x71/255, blue: 0x70/255, alpha: 1)
    static let accent     = NSColor(srgbRed: 0x1f/255, green: 0xc8/255, blue: 0xda/255, alpha: 1)
    static let orange     = NSColor(srgbRed: 0xff/255, green: 0x8a/255, blue: 0x3d/255, alpha: 1)
    static let cornflower = NSColor(srgbRed: 0x5b/255, green: 0x93/255, blue: 0xf0/255, alpha: 1)
    static let red        = NSColor(srgbRed: 0xe8/255, green: 0x46/255, blue: 0x35/255, alpha: 1)
    static let onAccent   = NSColor(srgbRed: 0x06/255, green: 0x20/255, blue: 0x28/255, alpha: 1)

    /// (glyph, short name, colour) for the agent owning a worktree.
    static func agent(worktreePath: String) -> (glyph: String, name: String, color: NSColor) {
        let type = ShipLog.shared.sailor(forWorktree: worktreePath)?.agentType
        let glyph = type?.tabGlyph ?? "✻"
        let name: String
        switch type {
        case .claudeCode: name = "claude"
        case .codex:      name = "codex"
        case .openCode:   name = "opencode"
        case .gemini:     name = "gemini"
        default:          name = (type?.displayName ?? "agent").lowercased()
        }
        let color: NSColor
        switch type {
        case .claudeCode: color = orange
        case .codex:      color = cornflower
        default:          color = accent
        }
        return (glyph, name, color)
    }
}

// MARK: - OptionChipButton

/// A flat Bare-TUI option chip: `[n] label`. Primary (index 0) is accent-filled.
private final class OptionChipButton: NSView {
    var onPick: (() -> Void)?
    private let badge = NSTextField(labelWithString: "")
    private let labelField = NSTextField(labelWithString: "")
    private let primary: Bool

    init(index: Int, title: String, primary: Bool) {
        self.primary = primary
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4
        translatesAutoresizingMaskIntoConstraints = false

        badge.font = AppFont.mono(size: 9.5, weight: .bold)
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 3
        badge.stringValue = "\(index + 1)"
        badge.translatesAutoresizingMaskIntoConstraints = false

        labelField.font = AppFont.mono(size: 12, weight: .regular)
        labelField.lineBreakMode = .byTruncatingTail
        labelField.stringValue = title
        labelField.translatesAutoresizingMaskIntoConstraints = false

        addSubview(badge); addSubview(labelField)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 15),
            badge.heightAnchor.constraint(equalToConstant: 15),
            labelField.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 7),
            labelField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -11),
            labelField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        applyStyle()
        let click = NSClickGestureRecognizer(target: self, action: #selector(tapped))
        addGestureRecognizer(click)
    }
    required init?(coder: NSCoder) { fatalError() }

    func setTitle(_ t: String) { labelField.stringValue = t }

    /// Keyboard focus ring for Tab-cycling through a card's options.
    func setKeyboardFocused(_ focused: Bool) {
        if focused {
            layer?.borderWidth = 2
            layer?.borderColor = Bare.ink.cgColor
        } else {
            applyStyle()
        }
    }

    private func applyStyle() {
        layer?.borderColor = nil
        if primary {
            layer?.backgroundColor = Bare.accent.cgColor
            layer?.borderWidth = 0
            labelField.textColor = Bare.onAccent
            badge.textColor = Bare.onAccent
            badge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.18).cgColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            layer?.borderWidth = 1
            layer?.borderColor = Bare.lineStrong.cgColor
            labelField.textColor = Bare.ink
            badge.textColor = Bare.ink
            badge.layer?.backgroundColor = NSColor(srgbRed: 120/255, green: 210/255, blue: 225/255, alpha: 0.13).cgColor
        }
    }

    @objc private func tapped() { onPick?() }
}

// MARK: - OrderCardView

/// First Mate order card. Internal so the Dashboard overview can lay the exact
/// same card out horizontally in its ORDERS carousel.
final class OrderCardView: NSTableCellView {
    private let accentBar = NSView()
    private let glyphLabel = NSTextField(labelWithString: "")
    private let agentLabel = NSTextField(labelWithString: "")
    private let taskLabel = NSTextField(labelWithString: "")
    private let urgencyLabel = NSTextField(labelWithString: "")
    private let dismissButton = NSButton()
    private let messageLabel = NSTextField(labelWithString: "")
    private let chipRow = NSStackView()

    private var onOption: ((Int) -> Void)?
    /// Clicking the card body (anywhere but an option chip) navigates to its pane.
    var onNavigate: (() -> Void)?
    /// Ignore the suggestion — remove it without acting on any option.
    var onDismiss: (() -> Void)?
    private var armedDangerousIndex: Int?
    private var dangerousIndexes: Set<Int> = []

    override init(frame: NSRect) { super.init(frame: frame); setup() }
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 0
        layer?.backgroundColor = Bare.panelAlt.cgColor

        let click = NSClickGestureRecognizer(target: self, action: #selector(cardClicked(_:)))
        addGestureRecognizer(click)

        accentBar.wantsLayer = true
        accentBar.layer?.backgroundColor = NSColor.clear.cgColor
        accentBar.translatesAutoresizingMaskIntoConstraints = false

        // Header slots, left→right: repo (colored) · dot · session title.
        glyphLabel.font = AppFont.mono(size: 12, weight: .bold)
        glyphLabel.translatesAutoresizingMaskIntoConstraints = false
        glyphLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        agentLabel.font = AppFont.mono(size: 9, weight: .bold)
        agentLabel.textColor = Bare.inkFaint
        agentLabel.translatesAutoresizingMaskIntoConstraints = false
        agentLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        taskLabel.font = AppFont.mono(size: 11.5, weight: .regular)
        taskLabel.textColor = Bare.ink
        taskLabel.lineBreakMode = .byTruncatingTail
        taskLabel.translatesAutoresizingMaskIntoConstraints = false

        urgencyLabel.font = AppFont.mono(size: 10, weight: .bold)
        urgencyLabel.alignment = .right
        urgencyLabel.translatesAutoresizingMaskIntoConstraints = false

        dismissButton.title = "✕"
        dismissButton.font = AppFont.mono(size: 11, weight: .regular)
        dismissButton.isBordered = false
        dismissButton.contentTintColor = Bare.inkFaint
        dismissButton.setButtonType(.momentaryChange)
        dismissButton.target = self
        dismissButton.action = #selector(tappedDismiss)
        dismissButton.toolTip = "Dismiss this suggestion"
        dismissButton.translatesAutoresizingMaskIntoConstraints = false

        messageLabel.font = AppFont.mono(size: 12.5, weight: .regular)
        messageLabel.textColor = Bare.ink
        messageLabel.maximumNumberOfLines = 0
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.translatesAutoresizingMaskIntoConstraints = false

        // Vertical: an option label is a sentence, and side by side they each got a
        // fraction of the card's width and truncated away to nothing. One per row
        // gives every label the full width to read at.
        chipRow.orientation = .vertical
        chipRow.alignment = .leading
        chipRow.spacing = 7
        chipRow.translatesAutoresizingMaskIntoConstraints = false

        addSubview(accentBar); addSubview(glyphLabel); addSubview(agentLabel)
        addSubview(taskLabel); addSubview(urgencyLabel); addSubview(dismissButton)
        addSubview(messageLabel); addSubview(chipRow)

        NSLayoutConstraint.activate([
            accentBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            accentBar.topAnchor.constraint(equalTo: topAnchor),
            accentBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            accentBar.widthAnchor.constraint(equalToConstant: 2),

            glyphLabel.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            glyphLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            agentLabel.centerYAnchor.constraint(equalTo: glyphLabel.centerYAnchor),
            agentLabel.leadingAnchor.constraint(equalTo: glyphLabel.trailingAnchor, constant: 8),
            taskLabel.centerYAnchor.constraint(equalTo: glyphLabel.centerYAnchor),
            taskLabel.leadingAnchor.constraint(equalTo: agentLabel.trailingAnchor, constant: 8),
            taskLabel.trailingAnchor.constraint(lessThanOrEqualTo: urgencyLabel.leadingAnchor, constant: -8),
            urgencyLabel.centerYAnchor.constraint(equalTo: glyphLabel.centerYAnchor),
            urgencyLabel.trailingAnchor.constraint(equalTo: dismissButton.leadingAnchor, constant: -10),
            dismissButton.centerYAnchor.constraint(equalTo: glyphLabel.centerYAnchor),
            dismissButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            dismissButton.widthAnchor.constraint(equalToConstant: 16),

            messageLabel.topAnchor.constraint(equalTo: glyphLabel.bottomAnchor, constant: 9),
            messageLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            messageLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),

            chipRow.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: 11),
            chipRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            // Pin (not hug) the trailing edge: the stack must span the card so each
            // chip gets the full width to lay its label out in.
            chipRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            chipRow.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -11),
        ])
        taskLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    /// Show a left accent bar when this card is the keyboard-selected row.
    func setSelected(_ selected: Bool) {
        accentBar.layer?.backgroundColor = (selected ? Bare.accent : NSColor.clear).cgColor
        layer?.backgroundColor = (selected ? Bare.cardBg : Bare.panelAlt).cgColor
        if !selected { clearChipFocus() }
    }

    /// Index of the option chip highlighted by keyboard Tab-cycling, if any.
    private(set) var focusedChipIndex: Int?

    /// Tab on a keyboard-selected card: cycle the highlight through its chips.
    func cycleFocusedChip() {
        let chips = chipRow.arrangedSubviews.compactMap { $0 as? OptionChipButton }
        guard !chips.isEmpty else { return }
        let next = ((focusedChipIndex ?? -1) + 1) % chips.count
        focusedChipIndex = next
        for (i, chip) in chips.enumerated() { chip.setKeyboardFocused(i == next) }
    }

    func clearChipFocus() {
        focusedChipIndex = nil
        chipRow.arrangedSubviews.compactMap { $0 as? OptionChipButton }
            .forEach { $0.setKeyboardFocused(false) }
    }

    /// Laid-out option chip frames, in order. For tests asserting on the chip layout.
    var optionChipFrames: [CGRect] {
        chipRow.arrangedSubviews.compactMap { $0 as? OptionChipButton }.map(\.frame)
    }

    func configure(order: PendingOrder, onOption: @escaping (Int) -> Void) {
        self.onOption = onOption
        self.armedDangerousIndex = nil

        // Header: repo (colored tag) · status dot · this pane's session title.
        // No agent-type glyph/name — the repo + session title identify the order.
        let sailor = ShipLog.shared.sailor(forWorktree: order.action.worktreePath)
        glyphLabel.stringValue = order.action.project
        glyphLabel.textColor = MiniCardView.repoColor(for: order.action.project)
        glyphLabel.isHidden = order.action.project.isEmpty

        agentLabel.stringValue = "\u{25CF}"
        agentLabel.textColor = (sailor?.status ?? .unknown).color

        let cachedTitle = WorktreeTitleCache.shared.cachedTitle(worktreePath: order.action.worktreePath)
        let branch = order.action.branch.isEmpty ? order.action.project : order.action.branch
        taskLabel.stringValue = [cachedTitle, sailor?.lastUserPrompt].compactMap { $0 }
            .first(where: { !$0.isEmpty }) ?? branch

        let dangerous = BridgePanelViewController.dangerousKinds.contains(order.action.kind)
        urgencyLabel.stringValue = dangerous ? "HIGH" : "NORMAL"
        urgencyLabel.textColor = dangerous ? Bare.red : Bare.accent

        messageLabel.stringValue = order.action.message
        messageLabel.isHidden = order.action.message.isEmpty

        chipRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let titles = BridgePanelViewController.buttonTitles(for: order)
        dangerousIndexes = dangerous ? Set(0..<titles.count) : []
        for (i, title) in titles.enumerated() {
            let chip = OptionChipButton(index: i, title: title, primary: i == 0)
            chip.onPick = { [weak self] in
                self?.selectOption(i, dangerous: self?.dangerousIndexes.contains(i) ?? false)
            }
            chipRow.addArrangedSubview(chip)
            // Stack alignment alone leaves each chip at its intrinsic width, which
            // is what truncated the labels. Pin every chip to the row's full width.
            chip.widthAnchor.constraint(equalTo: chipRow.widthAnchor).isActive = true
        }
    }

    @discardableResult
    func selectOption(_ index: Int, dangerous: Bool) -> Bool {
        if dangerous && armedDangerousIndex != index {
            armedDangerousIndex = index
            if let chip = chipRow.arrangedSubviews[safe: index] as? OptionChipButton { chip.setTitle("!! Confirm") }
            return false
        }
        onOption?(index)
        return true
    }

    @objc private func cardClicked(_ g: NSClickGestureRecognizer) {
        // Clicks inside the option-chip row are handled by the chips themselves;
        // clicks on the dismiss (✕) button must dismiss, not navigate.
        let pt = g.location(in: self)
        if chipRow.frame.contains(pt) { return }
        if dismissButton.frame.contains(pt) { onDismiss?(); return }
        onNavigate?()
    }

    @objc private func tappedDismiss() { onDismiss?() }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

// MARK: - WatchCardView

private final class WatchCardView: NSTableCellView {
    private let dot = NSView()
    private let agentLabel = NSTextField(labelWithString: "")
    private let taskLabel = NSTextField(labelWithString: "")
    private let msgLabel = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Two-line height: dot/name row + up to 2 message lines.
    static func height(for item: WatchItem) -> CGFloat {
        let bounds = (item.message as NSString).boundingRect(
            with: CGSize(width: 470, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: AppFont.mono(size: 12)])
        let msgH = min(ceil(bounds.height), 36) // cap at ~2 lines
        return 9 + 16 + 3 + msgH + 9
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = Bare.panelAlt.cgColor

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        dot.translatesAutoresizingMaskIntoConstraints = false

        agentLabel.font = AppFont.mono(size: 11.5, weight: .medium)
        agentLabel.textColor = Bare.ink
        agentLabel.translatesAutoresizingMaskIntoConstraints = false

        taskLabel.font = AppFont.mono(size: 11, weight: .regular)
        taskLabel.textColor = Bare.inkFaint
        taskLabel.lineBreakMode = .byTruncatingTail
        taskLabel.translatesAutoresizingMaskIntoConstraints = false

        msgLabel.font = AppFont.mono(size: 12, weight: .regular)
        msgLabel.textColor = Bare.inkDim
        msgLabel.maximumNumberOfLines = 2
        msgLabel.lineBreakMode = .byTruncatingTail
        msgLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(dot); addSubview(agentLabel); addSubview(taskLabel); addSubview(msgLabel)

        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            dot.topAnchor.constraint(equalTo: topAnchor, constant: 13),
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),

            agentLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 11),
            agentLabel.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            taskLabel.leadingAnchor.constraint(equalTo: agentLabel.trailingAnchor, constant: 8),
            taskLabel.centerYAnchor.constraint(equalTo: agentLabel.centerYAnchor),
            taskLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),

            msgLabel.leadingAnchor.constraint(equalTo: agentLabel.leadingAnchor),
            msgLabel.topAnchor.constraint(equalTo: agentLabel.bottomAnchor, constant: 3),
            msgLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        ])
        taskLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    func configure(item: WatchItem) {
        let meta = Bare.agent(worktreePath: item.worktreePath)
        dot.layer?.backgroundColor = (item.kind == .watchError ? Bare.red : meta.color).cgColor
        agentLabel.stringValue = meta.name
        taskLabel.stringValue = item.branch
        msgLabel.stringValue = item.message
    }
}
