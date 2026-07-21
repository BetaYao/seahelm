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
    private var items: [Item] = []
    private var selectedId: String?

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

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.stripHeight),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),

            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            doc.heightAnchor.constraint(equalTo: scroll.heightAnchor),
        ])
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

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshBackground()
    }

    private func refreshBackground() {
        layer?.backgroundColor = GhosttyBridge.shared.terminalChromeBackground.cgColor
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
/// keyboard focus away from the terminal.
private final class NonScrollingClipScrollView: NSScrollView {
    override var acceptsFirstResponder: Bool { false }
}
