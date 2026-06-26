import AppKit

/// WP-2 core cockpit. A full-bleed, click-through overlay layered on top of the
/// dashboard. It floats two things at bottom-center:
///   • the radar orb (always visible) — toggles the panel
///   • the command-center panel (hidden until opened) — Orders + Watch, rendered
///     by a reused `BridgePanelViewController` against the live queue/feed.
///
/// Bare-TUI palette is inlined locally (prototype THEME.A). The `/ @ #` command
/// input, floating cards, and help overlay arrive in later work packages; the
/// legacy sidebar "First Mate" tab is removed once its bottom bar is rehomed.
final class HelmCockpitController: NSViewController {

    // Bare-TUI palette (prototype THEME.A)
    private static let cardBg     = NSColor(srgbRed: 0x0e/255, green: 0x2d/255, blue: 0x37/255, alpha: 1)
    private static let cardBorder = NSColor(srgbRed: 0x96/255, green: 0xd7/255, blue: 0xe1/255, alpha: 0.12)
    private static let scrim      = NSColor(srgbRed: 0x03/255, green: 0x10/255, blue: 0x15/255, alpha: 0.6)
    private static let radar      = NSColor(srgbRed: 0x1f/255, green: 0xc8/255, blue: 0xda/255, alpha: 1)
    private static let ink        = NSColor(srgbRed: 0xcf/255, green: 0xe0/255, blue: 0xe0/255, alpha: 1)
    private static let inkFaint   = NSColor(srgbRed: 0x55/255, green: 0x71/255, blue: 0x70/255, alpha: 1)

    // MARK: - Passthrough container

    private final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            let hit = super.hitTest(point)
            // Empty areas of the container fall through to the terminal beneath.
            return hit === self ? nil : hit
        }
    }

    // MARK: - Data passthrough

    private let bridgeVC = BridgePanelViewController()

    var pendingOrdersQueue: PendingOrdersQueue? {
        didSet {
            bridgeVC.queue = pendingOrdersQueue
            oldValue?.removeObserver(queueCardToken); queueCardToken = nil
            seenOrderIds = Set((pendingOrdersQueue?.all() ?? []).map(\.id))  // seed: don't pop on launch
            queueCardToken = pendingOrdersQueue?.addObserver { [weak self] in
                DispatchQueue.main.async { self?.onOrdersChanged() }
            }
        }
    }
    var watchFeed: WatchFeed? {
        didSet {
            bridgeVC.watchFeed = watchFeed
            oldValue?.removeObserver(watchCardToken); watchCardToken = nil
            seenWatchIds = Set((watchFeed?.all() ?? []).map(\.id))
            watchCardToken = watchFeed?.addObserver { [weak self] in
                DispatchQueue.main.async { self?.onWatchChanged() }
            }
        }
    }
    var onSuggestionTapped: ((PendingOrder, String) -> Void)? {
        didSet { bridgeVC.onSuggestionTapped = onSuggestionTapped }
    }
    var onNavigate: ((String) -> Void)? {
        didSet { bridgeVC.onNavigateToWorktree = onNavigate }
    }
    var onApprove: ((PendingOrder) -> Void)? {
        didSet { bridgeVC.onApprove = onApprove }
    }

    /// Submit a raw command line (`/new …`, `@branch …`, free text). Wired to the
    /// existing BridgeCommandParser/Router via MainWindowController.
    var onSubmitCommand: ((String) -> Void)?

    /// Autocomplete data source: given a trigger (`/`, `@`, `#`) and a lowercased
    /// query, returns matching (name, desc) rows.
    var commandMenuProvider: ((Character, String) -> [(name: String, desc: String)])?

    // MARK: - Views

    private let orb = HelmOrbView()
    private let scrimView = NSView()
    private let panel = NSView()
    private let commandInput = CommandInputView()
    private let menuContainer = NSView()
    private var isOpen = false

    // Floating-card state
    private var seenOrderIds: Set<String> = []
    private var seenWatchIds: Set<String> = []
    private var queueCardToken: Int?
    private var watchCardToken: Int?
    private var floatingCard: HelmFloatingCard?
    private var cardDismissTimer: Timer?

    deinit {
        pendingOrdersQueue?.removeObserver(queueCardToken)
        watchFeed?.removeObserver(watchCardToken)
        cardDismissTimer?.invalidate()
    }

    // MARK: - Lifecycle

    override func loadView() {
        let root = PassthroughView()
        root.translatesAutoresizingMaskIntoConstraints = false
        view = root

        setupScrim(in: root)
        setupPanel(in: root)
        setupOrb(in: root)

        bridgeVC.onOrdersCountChanged = { [weak self] count in self?.orb.setBadge(count) }
    }

    private func setupScrim(in root: NSView) {
        scrimView.wantsLayer = true
        scrimView.layer?.backgroundColor = Self.scrim.cgColor
        scrimView.translatesAutoresizingMaskIntoConstraints = false
        scrimView.isHidden = true
        root.addSubview(scrimView)
        NSLayoutConstraint.activate([
            scrimView.topAnchor.constraint(equalTo: root.topAnchor),
            scrimView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrimView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrimView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        let click = NSClickGestureRecognizer(target: self, action: #selector(scrimClicked))
        scrimView.addGestureRecognizer(click)
    }

    private func setupPanel(in root: NSView) {
        panel.wantsLayer = true
        panel.layer?.backgroundColor = Self.cardBg.cgColor
        panel.layer?.borderWidth = 1
        panel.layer?.borderColor = Self.cardBorder.cgColor
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.isHidden = true
        root.addSubview(panel)

        // Header row: ◍ FIRST MATE … ✕
        let glyph = NSTextField(labelWithString: "◍")
        glyph.font = NSFont.systemFont(ofSize: 13)
        glyph.textColor = Self.radar
        glyph.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "FIRST MATE")
        title.font = AppFont.mono(size: 12, weight: .bold)
        title.textColor = Self.ink
        title.translatesAutoresizingMaskIntoConstraints = false

        let close = NSButton(title: "✕", target: self, action: #selector(toggle))
        close.isBordered = false
        close.contentTintColor = Self.inkFaint
        close.translatesAutoresizingMaskIntoConstraints = false

        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(glyph)
        header.addSubview(title)
        header.addSubview(close)
        panel.addSubview(header)

        // Command input sits between the header and the Orders/Watch list.
        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = Self.cardBorder.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(commandInput)
        panel.addSubview(divider)

        addChild(bridgeVC)
        bridgeVC.view.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(bridgeVC.view)

        // Autocomplete dropdown floats over the list (added last → top z-order).
        menuContainer.wantsLayer = true
        menuContainer.layer?.backgroundColor = Self.cardBg.cgColor
        menuContainer.layer?.borderWidth = 1
        menuContainer.layer?.borderColor = Self.cardBorder.cgColor
        menuContainer.translatesAutoresizingMaskIntoConstraints = false
        menuContainer.isHidden = true
        panel.addSubview(menuContainer)

        commandInput.onSubmit = { [weak self] text in
            self?.onSubmitCommand?(text)
            self?.hideMenu()
        }
        commandInput.onTextChanged = { [weak self] text in self?.refreshMenu(for: text) }
        commandInput.onCancel = { [weak self] in
            guard let self else { return }
            // Esc in the input: collapse the menu first; otherwise step back to
            // table navigation (a second Esc there closes the cockpit).
            if !self.menuContainer.isHidden { self.hideMenu() }
            else { self.bridgeVC.focusOrdersTable() }
        }

        // Keyboard navigation hooks (i focuses input, Esc closes the cockpit).
        bridgeVC.onFocusInput = { [weak self] in self?.commandInput.focusInput() }
        bridgeVC.onEscape = { [weak self] in self?.closeTopmost() }

        NSLayoutConstraint.activate([
            // Panel anchored bottom-center, fixed width, capped height.
            panel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            panel.widthAnchor.constraint(equalToConstant: 380),
            panel.bottomAnchor.constraint(equalTo: orb.topAnchor, constant: -12),
            panel.heightAnchor.constraint(lessThanOrEqualTo: root.heightAnchor, multiplier: 0.64),
            panel.heightAnchor.constraint(greaterThanOrEqualToConstant: 260),

            header.topAnchor.constraint(equalTo: panel.topAnchor),
            header.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 38),

            glyph.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 14),
            glyph.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            title.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 9),
            title.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            close.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -10),
            close.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            commandInput.topAnchor.constraint(equalTo: header.bottomAnchor),
            commandInput.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            commandInput.trailingAnchor.constraint(equalTo: panel.trailingAnchor),

            divider.topAnchor.constraint(equalTo: commandInput.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),

            bridgeVC.view.topAnchor.constraint(equalTo: divider.bottomAnchor),
            bridgeVC.view.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            bridgeVC.view.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            bridgeVC.view.bottomAnchor.constraint(equalTo: panel.bottomAnchor),

            menuContainer.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 4),
            menuContainer.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 10),
            menuContainer.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -10),
        ])
    }

    // MARK: - Autocomplete

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
        case "@": triggerColor = NSColor(srgbRed: 0x5b/255, green: 0x93/255, blue: 0xf0/255, alpha: 1)
        case "#": triggerColor = NSColor(srgbRed: 0xff/255, green: 0x8a/255, blue: 0x3d/255, alpha: 1)
        default:  triggerColor = Self.radar
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

        for item in items.prefix(6) {
            let row = MenuRowButton(name: item.name, desc: item.desc,
                                    triggerSymbol: String(trigger), triggerColor: triggerColor)
            row.onPick = { [weak self] in
                self?.applyCompletion(name: item.name, trigger: trigger, token: token, fullText: fullText)
            }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        menuContainer.isHidden = false
    }

    private func applyCompletion(name: String, trigger: Character, token: String, fullText: String) {
        let base = String(fullText.dropLast(token.count))
        commandInput.text = base + String(trigger) + name + " "
        hideMenu()
        commandInput.focusInput()
    }

    private func hideMenu() {
        menuContainer.isHidden = true
        menuContainer.subviews.forEach { $0.removeFromSuperview() }
    }

    private func setupOrb(in root: NSView) {
        orb.onToggle = { [weak self] in self?.toggle() }
        root.addSubview(orb)
        NSLayoutConstraint.activate([
            orb.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            orb.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
        ])
    }

    // MARK: - Keyboard entry points

    private var helpOverlay: KeyboardHelpOverlay?

    /// Toggle the command center (bound to `space` in dashboard NORMAL mode).
    func toggleCockpit() { toggle() }

    /// Open the center on the Watch tab (bound to `w`). For now just opens it.
    func openCockpit() { if !isOpen { toggle() } }

    /// Toggle the `?` keyboard help overlay.
    func toggleHelp() {
        if helpOverlay != nil { dismissHelp(); return }
        let overlay = KeyboardHelpOverlay()
        overlay.onDismiss = { [weak self] in self?.dismissHelp() }
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

    /// Esc handler: close the topmost cockpit surface. Returns true if it closed
    /// something (so the caller stops propagating the Esc).
    @discardableResult
    func closeTopmost() -> Bool {
        if helpOverlay != nil { dismissHelp(); return true }
        if isOpen { toggle(); return true }
        return false
    }

    // MARK: - Open / close

    @objc private func scrimClicked() { if isOpen { toggle() } }

    @objc private func toggle() {
        isOpen.toggle()
        scrimView.isHidden = !isOpen
        panel.isHidden = !isOpen
        if isOpen {
            dismissCard()  // opening the cockpit supersedes any transient card
            // Open in navigation mode: j/k select cards, 1–9 pick options,
            // Tab switches Orders/Watch, i focuses the command input, Esc closes.
            DispatchQueue.main.async { [weak self] in self?.bridgeVC.focusOrdersTable() }
        } else {
            hideMenu()
        }
    }

    // MARK: - Floating cards

    private func onOrdersChanged() {
        let current = pendingOrdersQueue?.all() ?? []
        let currentIds = Set(current.map(\.id))
        let fresh = current.filter { !seenOrderIds.contains($0.id) }
        seenOrderIds = currentIds  // drop resolved ids so a re-add can pop again
        guard !isOpen, let order = fresh.last else { return }
        let dangerous = BridgePanelViewController.dangerousKinds.contains(order.action.kind)
        let tagColor = dangerous
            ? NSColor(srgbRed: 0xe8/255, green: 0x46/255, blue: 0x35/255, alpha: 1)   // red
            : NSColor(srgbRed: 0xff/255, green: 0x8a/255, blue: 0x3d/255, alpha: 1)   // orange
        popCard(from: order.action.project, task: order.action.branch,
                tag: "PENDING ORDER", tagColor: tagColor,
                body: order.action.message.isEmpty ? "需要舰长决策" : order.action.message,
                hint: "点击处理 · 否则收起到大副", duration: 6.5,
                onClick: { [weak self] in self?.openToOrders() })
    }

    private func onWatchChanged() {
        let current = watchFeed?.all() ?? []
        let currentIds = Set(current.map(\.id))
        let fresh = current.filter { !seenWatchIds.contains($0.id) }
        seenWatchIds = currentIds
        guard !isOpen, let item = fresh.first else { return }
        popCard(from: item.branch, task: "",
                tag: "WATCH", tagColor: Self.radar,
                body: item.message, hint: "点击查看 · 否则自动消失", duration: 5.0,
                onClick: { [weak self] in self?.openToWatch() })
    }

    private func popCard(from: String, task: String, tag: String, tagColor: NSColor,
                         body: String, hint: String, duration: TimeInterval,
                         onClick: @escaping () -> Void) {
        dismissCard()
        let card = HelmFloatingCard(from: from, task: task, tag: tag, tagColor: tagColor,
                                    body: body, hint: hint)
        card.onClick = { [weak self] in self?.dismissCard(); onClick() }
        view.addSubview(card)
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.widthAnchor.constraint(equalToConstant: 360),
            card.bottomAnchor.constraint(equalTo: orb.topAnchor, constant: -14),
        ])
        floatingCard = card
        card.startCountdown(duration: duration)
        cardDismissTimer?.invalidate()
        cardDismissTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            self?.dismissCard()
        }
    }

    private func dismissCard() {
        cardDismissTimer?.invalidate(); cardDismissTimer = nil
        floatingCard?.removeFromSuperview()
        floatingCard = nil
    }

    private func openToOrders() {
        if !isOpen { toggle() }
    }
    private func openToWatch() {
        if !isOpen { toggle() }
    }
}

/// A single autocomplete row: `‹trigger› name … desc`, with hover highlight.
private final class MenuRowButton: NSView {
    private static let ink      = NSColor(srgbRed: 0xcf/255, green: 0xe0/255, blue: 0xe0/255, alpha: 1)
    private static let inkFaint = NSColor(srgbRed: 0x55/255, green: 0x71/255, blue: 0x70/255, alpha: 1)
    private static let hoverBg  = NSColor(srgbRed: 0x1f/255, green: 0xc8/255, blue: 0xda/255, alpha: 0.10)

    var onPick: (() -> Void)?
    private var trackingArea: NSTrackingArea?

    init(name: String, desc: String, triggerSymbol: String, triggerColor: NSColor) {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 30).isActive = true

        let sym = NSTextField(labelWithString: triggerSymbol)
        sym.font = AppFont.mono(size: 12, weight: .bold)
        sym.textColor = triggerColor
        sym.translatesAutoresizingMaskIntoConstraints = false

        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = AppFont.mono(size: 12, weight: .regular)
        nameLabel.textColor = Self.ink
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        let descLabel = NSTextField(labelWithString: desc)
        descLabel.font = AppFont.mono(size: 11, weight: .regular)
        descLabel.textColor = Self.inkFaint
        descLabel.alignment = .right
        descLabel.lineBreakMode = .byTruncatingTail
        descLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        descLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(sym); addSubview(nameLabel); addSubview(descLabel)
        NSLayoutConstraint.activate([
            sym.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            sym.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.leadingAnchor.constraint(equalTo: sym.trailingAnchor, constant: 9),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            descLabel.leadingAnchor.constraint(greaterThanOrEqualTo: nameLabel.trailingAnchor, constant: 10),
            descLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            descLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t); trackingArea = t
    }
    override func mouseEntered(with event: NSEvent) { layer?.backgroundColor = Self.hoverBg.cgColor }
    override func mouseExited(with event: NSEvent) { layer?.backgroundColor = NSColor.clear.cgColor }
    // mouseDown (not click recognizer) so the field editor's resignFirstResponder
    // doesn't swallow the first interaction with the menu.
    override func mouseDown(with event: NSEvent) { onPick?() }
}
