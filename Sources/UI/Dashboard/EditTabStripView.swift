import AppKit

/// A compact horizontal tab strip used by edit-mode's LEFT (terminal panes) and
/// RIGHT (file previews) columns. Purely presentational: it renders `items`,
/// highlights `selectedId`, and reports taps/closes through callbacks. The owner
/// owns all state — the strip never mutates the model itself.
final class EditTabStripView: NSView {
    struct Item: Equatable {
        let id: String
        let title: String
        /// When true a close (×) affordance is shown on the tab.
        let closable: Bool
    }

    static let stripHeight: CGFloat = 30

    var onSelect: ((String) -> Void)?
    var onClose: ((String) -> Void)?

    private let scroll = NonScrollingClipScrollView()
    private let stack = NSStackView()
    private let overflowButton = NSButton()
    private var items: [Item] = []
    private var selectedId: String?
    private var scrollTrailingToEdge: NSLayoutConstraint?
    private var scrollTrailingToOverflow: NSLayoutConstraint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func setup() {
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        refreshBackground()

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.horizontalScrollElasticity = .allowed
        scroll.verticalScrollElasticity = .none
        scroll.scrollerStyle = .overlay
        // Keep trackpad gestures on the predominant axis so a slight vertical
        // component cannot walk the clip origin off the tab row.
        scroll.usesPredominantAxisScrolling = true
        addSubview(scroll)

        stack.orientation = .horizontal
        stack.spacing = 2
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedDocumentView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        scroll.documentView = doc

        configureOverflowButton()
        addSubview(overflowButton)

        let trailingEdge = scroll.trailingAnchor.constraint(equalTo: trailingAnchor)
        let trailingOverflow = scroll.trailingAnchor.constraint(
            equalTo: overflowButton.leadingAnchor, constant: -2)
        scrollTrailingToEdge = trailingEdge
        scrollTrailingToOverflow = trailingOverflow
        trailingOverflow.isActive = false

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.stripHeight),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            trailingEdge,
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),

            overflowButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            overflowButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            overflowButton.heightAnchor.constraint(equalToConstant: 22),
            overflowButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 28),

            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            doc.heightAnchor.constraint(equalTo: scroll.heightAnchor),
        ])
    }

    private func configureOverflowButton() {
        overflowButton.bezelStyle = .recessed
        overflowButton.isBordered = false
        overflowButton.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        overflowButton.target = self
        overflowButton.action = #selector(overflowClicked(_:))
        overflowButton.isHidden = true
        overflowButton.translatesAutoresizingMaskIntoConstraints = false
        overflowButton.setAccessibilityIdentifier("chrome.tabs.overflow")
        overflowButton.setAccessibilityLabel("More panes")
        overflowButton.wantsLayer = true
        overflowButton.layer?.cornerRadius = 5
    }

    /// The strip scrolls horizontally only — its content height always equals the
    /// clip height, so the vertical clip origin must be zero.
    ///
    /// Moving the strip between view hierarchies (the columns ⇄ the chrome header)
    /// makes AppKit re-seat the clip view at a non-zero vertical origin. Nothing
    /// looks wrong from the outside — the strip, its scroll view, the document view
    /// and every tab keep correct frames — but the visible rect slides off the tabs
    /// and the row paints empty. Pin it on every layout pass.
    override func layout() {
        super.layout()
        pinVerticalScroll()
        updateOverflowAffordance()
    }

    /// Sitting in the chrome header puts the strip in window-drag territory: with
    /// the default behaviour AppKit turns a press into a window move and never
    /// delivers `mouseDown`, so hit testing alone is not enough to make tabs click.
    override var mouseDownCanMoveWindow: Bool { false }

    /// Only the tabs themselves are interactive; the leftover space stays
    /// transparent so the chrome header underneath keeps dragging the window.
    ///
    /// The lookup is geometric rather than a `super.hitTest` walk: the tabs sit
    /// under a scroll view whose clip/flipped-document chain does not forward hit
    /// tests here (it answers as the scroll view even for points that are inside
    /// the document), which left every tab click falling through to the header's
    /// window drag. Matching each tab's frame in this view's own space sidesteps
    /// that chain entirely and is exactly as precise.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if !overflowButton.isHidden, overflowButton.frame.contains(local) {
            return overflowButton
        }
        for case let tab as TabButton in stack.arrangedSubviews {
            guard tab.convert(tab.bounds, to: self).contains(local) else { continue }
            guard let tabSuper = tab.superview else { return tab }
            // Let the tab resolve its own close button; it answers as itself otherwise.
            return tab.hitTest(convert(local, to: tabSuper)) ?? tab
        }
        return nil
    }

    /// Called from `layout()` and from `apply()`: the bad origin is left behind by a
    /// transient during the move (the scroll view is briefly a different height, which
    /// widens the clip's allowed range), and a single layout pass can run before the
    /// frame settles. Re-asserting it on every model update bounds the damage to one
    /// status-poll tick even if the layout pass misses.
    private func pinVerticalScroll() {
        let origin = scroll.contentView.bounds.origin
        guard origin.y != 0 else { return }
        scroll.contentView.setBoundsOrigin(NSPoint(x: origin.x, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    var clipOriginYForTesting: CGFloat { scroll.contentView.bounds.origin.y }
    /// First tab's frame in the strip's own coordinates.
    var firstTabFrameForTesting: NSRect {
        guard let tab = stack.arrangedSubviews.first else { return .zero }
        return tab.convert(tab.bounds, to: self)
    }

    /// The property that actually broke: a tab can have a perfect frame and still
    /// be outside the scroll view's visible rect, which paints an empty row.
    var firstTabIsVisibleForTesting: Bool {
        guard let tab = stack.arrangedSubviews.first, let doc = scroll.documentView else { return false }
        return scroll.documentVisibleRect.intersects(tab.convert(tab.bounds, to: doc))
    }

    // MARK: - Model application

    /// Update the strip. Rebuilds the tab views only when the id set changes;
    /// otherwise just refreshes titles + selection in place so the 2s status
    /// poll (which nudges titles) never churns the whole view tree.
    func apply(items newItems: [Item], selectedId: String?) {
        let idsChanged = newItems.map(\.id) != items.map(\.id)
            || newItems.map(\.closable) != items.map(\.closable)
        self.items = newItems
        self.selectedId = selectedId

        pinVerticalScroll()
        if idsChanged {
            rebuild()
        } else {
            for case let tab as TabButton in stack.arrangedSubviews {
                if let item = newItems.first(where: { $0.id == tab.itemId }) {
                    tab.title = item.title
                    tab.isSelectedTab = (item.id == selectedId)
                }
            }
        }
        needsLayout = true
    }

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for item in items {
            let tab = TabButton(itemId: item.id)
            tab.title = item.title
            tab.showsClose = item.closable
            tab.isSelectedTab = (item.id == selectedId)
            tab.onSelect = { [weak self] id in self?.onSelect?(id) }
            tab.onClose = { [weak self] id in self?.onClose?(id) }
            stack.addArrangedSubview(tab)
        }
    }

    /// Called after a wheel remaps / settles so the `+N` chip tracks the clip.
    fileprivate func noteScrollSettled() {
        pinVerticalScroll()
        updateOverflowAffordance()
    }

    /// Tabs that don't fit the visible clip — shown as `+N` and listed in a menu.
    private func updateOverflowAffordance() {
        let contentW = stack.fittingSize.width
        let show = items.count > 1 && contentW > bounds.width + 0.5
        let wasShowing = !overflowButton.isHidden
        if show != wasShowing {
            overflowButton.isHidden = !show
            scrollTrailingToEdge?.isActive = !show
            scrollTrailingToOverflow?.isActive = show
            // Constraint flip changes the clip; recount on the next pass.
            needsLayout = true
        }
        guard show, let doc = scroll.documentView else {
            if !show { overflowButton.isHidden = true }
            return
        }
        let visible = scroll.documentVisibleRect
        var hidden = 0
        for case let tab as TabButton in stack.arrangedSubviews {
            let frame = tab.convert(tab.bounds, to: doc)
            if !visible.intersects(frame.insetBy(dx: 1, dy: 0)) {
                hidden += 1
            }
        }
        // At least 1 when the chip is up — content overflowed even if every tab
        // still intersects after a partial scroll.
        overflowButton.title = "+\(max(hidden, 1))"
        refreshOverflowAppearance()
    }

    @objc private func overflowClicked(_ sender: NSButton) {
        let menu = NSMenu()
        for item in items {
            let entry = NSMenuItem(title: item.title, action: #selector(overflowPicked(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = item.id
            entry.state = item.id == selectedId ? .on : .off
            menu.addItem(entry)
        }
        let point = NSPoint(x: 0, y: sender.bounds.height + 2)
        menu.popUp(positioning: nil, at: point, in: sender)
    }

    @objc private func overflowPicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        scrollTabIntoView(id)
        onSelect?(id)
    }

    private func scrollTabIntoView(_ id: String) {
        guard let tab = stack.arrangedSubviews.first(where: {
            ($0 as? TabButton)?.itemId == id
        }) else { return }
        tab.scrollToVisible(tab.bounds)
        pinVerticalScroll()
        updateOverflowAffordance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshBackground()
        refreshOverflowAppearance()
    }

    private func refreshBackground() {
        layer?.backgroundColor = GhosttyBridge.shared.terminalChromeBackground.cgColor
    }

    private func refreshOverflowAppearance() {
        let fg = GhosttyBridge.shared.terminalChromeForeground
        overflowButton.contentTintColor = fg
        overflowButton.layer?.backgroundColor = fg.withAlphaComponent(0.16).cgColor
    }
}

// MARK: - Tab button

private final class TabButton: NSView {
    let itemId: String
    var onSelect: ((String) -> Void)?
    var onClose: ((String) -> Void)?

    var title: String = "" { didSet { label.stringValue = title } }
    var showsClose: Bool = false { didSet { closeButton.isHidden = !showsClose } }
    var isSelectedTab: Bool = false { didSet { refreshAppearance() } }

    private let label = NSTextField(labelWithString: "")
    private let closeButton = NSButton()

    init(itemId: String) {
        self.itemId = itemId
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        translatesAutoresizingMaskIntoConstraints = false

        label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.cell?.usesSingleLineMode = true
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        let cfg = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")?
            .withSymbolConfiguration(cfg)
        closeButton.bezelStyle = .recessed
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.isHidden = true
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 22),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 5),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 12),
            widthAnchor.constraint(lessThanOrEqualToConstant: 200),
        ])
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        refreshAppearance()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// See `EditTabStripView.mouseDownCanMoveWindow` — without this the header's
    /// window drag swallows the press before it reaches here.
    override var mouseDownCanMoveWindow: Bool { false }

    /// Answer as the tab for everything except the close button: otherwise the
    /// title label is the hit view, and it neither handles the press nor opts out
    /// of the window drag.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit is NSButton ? hit : self
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?(itemId)
    }

    @objc private func closeClicked() {
        onClose?(itemId)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearance()
    }

    private func refreshAppearance() {
        let fg = GhosttyBridge.shared.terminalChromeForeground
        if isSelectedTab {
            layer?.backgroundColor = fg.withAlphaComponent(0.16).cgColor
            label.textColor = fg
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            label.textColor = fg.withAlphaComponent(0.6)
        }
        closeButton.contentTintColor = fg.withAlphaComponent(0.6)
    }
}

// MARK: - Helpers

private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// Scroll view that lets horizontal wheel/trackpad scroll through but never grabs
/// keyboard focus away from the terminal. Vertical wheel motion is remapped to
/// horizontal so the tab row cannot scroll out of view.
private final class NonScrollingClipScrollView: NSScrollView {
    override var acceptsFirstResponder: Bool { false }

    override func scrollWheel(with event: NSEvent) {
        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY
        if abs(dy) >= abs(dx), let cg = event.cgEvent?.copy() {
            // Axis1 = vertical, Axis2 = horizontal in AppKit's CGEvent fields.
            cg.setDoubleValueField(.scrollWheelEventDeltaAxis1, value: 0)
            cg.setDoubleValueField(
                .scrollWheelEventDeltaAxis2,
                value: Double(dy)
            )
            if event.hasPreciseScrollingDeltas {
                cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: 0)
                cg.setDoubleValueField(
                    .scrollWheelEventPointDeltaAxis2,
                    value: Double(dy)
                )
            }
            if let redirected = NSEvent(cgEvent: cg) {
                super.scrollWheel(with: redirected)
            } else {
                super.scrollWheel(with: event)
            }
        } else {
            super.scrollWheel(with: event)
        }
        let origin = contentView.bounds.origin
        if origin.y != 0 {
            contentView.setBoundsOrigin(NSPoint(x: origin.x, y: 0))
            reflectScrolledClipView(contentView)
        }
        (superview as? EditTabStripView)?.noteScrollSettled()
    }
}
