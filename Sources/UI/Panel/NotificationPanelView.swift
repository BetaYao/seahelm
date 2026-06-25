import AppKit

protocol NotificationPanelDelegate: AnyObject {
    func notificationPanelDidRequestClose()
    func notificationPanelDidSelectItem(_ entry: NotificationEntry)
}

final class NotificationPanelView: NSView {

    weak var delegate: NotificationPanelDelegate?
    private(set) var isOpen: Bool = false

    // MARK: - Data

    private var items: [NotificationEntry] = []

    // MARK: - Subviews

    private let bellIcon: NSTextField = {
        let label = NSTextField(labelWithString: "\u{1F514}")
        label.font = NSFont.systemFont(ofSize: 13)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let headerLabel: NSTextField = {
        let label = NSTextField(labelWithString: "Notifications")
        label.font = NSFont.boldSystemFont(ofSize: 13)
        label.textColor = SemanticColors.text
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let countLabel: NSTextField = {
        let label = NSTextField(labelWithString: "0")
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        label.textColor = SemanticColors.muted
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let closeButton: NSButton = {
        let button = NSButton(title: "\u{00D7}", target: nil, action: nil)
        button.identifier = NSUserInterfaceItemIdentifier("panel.notification.close")
        button.isBordered = false
        button.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        button.contentTintColor = SemanticColors.muted
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor(white: 1, alpha: 0.03).cgColor
        button.layer?.cornerRadius = 4
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    private let headerBorder: NSView = {
        let v = NSView()
        v.wantsLayer = true
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    private let scrollView: NSScrollView = {
        let sv = NSScrollView()
        sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = false
        sv.drawsBackground = false
        sv.automaticallyAdjustsContentInsets = false
        sv.translatesAutoresizingMaskIntoConstraints = false
        return sv
    }()

    private let contentStack: NSStackView = {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    private let leftBorder: NSView = {
        let v = NSView()
        v.wantsLayer = true
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    // MARK: - Public API

    func setOpen(_ open: Bool, animated: Bool = true) {
        guard open != isOpen else { return }
        isOpen = open
        isHidden = false

        if animated {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                self.animator().alphaValue = open ? 1.0 : 0.0
            }, completionHandler: {
                if !open { self.isHidden = true }
            })
        } else {
            alphaValue = open ? 1.0 : 0.0
            isHidden = !open
        }
    }

    func updateNotifications(_ items: [NotificationEntry]) {
        self.items = items
        countLabel.stringValue = "\(items.count)"

        // Remove old items
        for view in contentStack.arrangedSubviews {
            contentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        for (index, item) in items.enumerated() {
            let card = makeItemView(index: index, entry: item)
            contentStack.addArrangedSubview(card)

            NSLayoutConstraint.activate([
                card.leadingAnchor.constraint(equalTo: contentStack.leadingAnchor, constant: 12),
                card.trailingAnchor.constraint(equalTo: contentStack.trailingAnchor, constant: -12),
            ])
        }
    }

    // MARK: - Setup

    private func setup() {
        identifier = NSUserInterfaceItemIdentifier("panel.notification")
        setAccessibilityIdentifier("panel.notification")
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true
        alphaValue = 0

        closeButton.target = self
        closeButton.action = #selector(closeClicked)

        addSubview(leftBorder)
        addSubview(bellIcon)
        addSubview(headerLabel)
        addSubview(countLabel)
        addSubview(closeButton)
        addSubview(headerBorder)
        addSubview(scrollView)

        scrollView.documentView = contentStack

        NSLayoutConstraint.activate([
            // Left border
            leftBorder.leadingAnchor.constraint(equalTo: leadingAnchor),
            leftBorder.topAnchor.constraint(equalTo: topAnchor),
            leftBorder.bottomAnchor.constraint(equalTo: bottomAnchor),
            leftBorder.widthAnchor.constraint(equalToConstant: 1),

            // Bell icon
            bellIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            bellIcon.centerYAnchor.constraint(equalTo: topAnchor, constant: 20),

            // Header
            headerLabel.leadingAnchor.constraint(equalTo: bellIcon.trailingAnchor, constant: 6),
            headerLabel.centerYAnchor.constraint(equalTo: bellIcon.centerYAnchor),

            // Count
            countLabel.leadingAnchor.constraint(equalTo: headerLabel.trailingAnchor, constant: 6),
            countLabel.centerYAnchor.constraint(equalTo: headerLabel.centerYAnchor),

            // Close button
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            closeButton.centerYAnchor.constraint(equalTo: headerLabel.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 24),
            closeButton.heightAnchor.constraint(equalToConstant: 24),

            // Header border
            headerBorder.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerBorder.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerBorder.topAnchor.constraint(equalTo: topAnchor, constant: 40),
            headerBorder.heightAnchor.constraint(equalToConstant: 1),

            // Scroll view
            scrollView.topAnchor.constraint(equalTo: headerBorder.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            // Content stack width
            contentStack.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ])

        applyShadow()
        applyColors()
    }

    private func applyShadow() {
        shadow = NSShadow()
        layer?.shadowColor = NSColor.black.withAlphaComponent(0.3).cgColor
        layer?.shadowOffset = CGSize(width: -8, height: 0)
        layer?.shadowRadius = 24
        layer?.shadowOpacity = 1.0
    }

    private func makeItemView(index: Int, entry: NotificationEntry) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.identifier = NSUserInterfaceItemIdentifier("panel.notification.item.\(index)")
        container.translatesAutoresizingMaskIntoConstraints = false

        container.layer?.backgroundColor = SemanticColors.tileBg.cgColor
        container.layer?.borderWidth = 1
        container.layer?.borderColor = SemanticColors.line.cgColor
        container.layer?.cornerRadius = 6

        let titleLabel = NSTextField(labelWithString: titleText(for: entry))
        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = SemanticColors.text
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let metaLabel = NSTextField(labelWithString: entry.message)
        metaLabel.font = NSFont.systemFont(ofSize: 11)
        metaLabel.textColor = SemanticColors.muted
        metaLabel.lineBreakMode = .byTruncatingTail
        metaLabel.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(titleLabel)
        container.addSubview(metaLabel)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -10),

            metaLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            metaLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            metaLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -10),
            metaLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
        ])

        // Click gesture
        let click = NSClickGestureRecognizer(target: self, action: #selector(itemClicked(_:)))
        container.addGestureRecognizer(click)

        return container
    }

    private func titleText(for entry: NotificationEntry) -> String {
        var suffix = entry.status.rawValue
        if let paneIndex = entry.paneIndex {
            suffix += " [Pane \(paneIndex)]"
        }
        let target = entry.workspaceName.isEmpty ? entry.branch : "\(entry.workspaceName) / \(entry.branch)"
        return "\(target)  \(suffix)"
    }

    // MARK: - Drawing

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 0, cornerHeight: 0, transform: nil)
    }

    private func applyColors() {
        layer?.backgroundColor = SemanticColors.panel.cgColor
        leftBorder.layer?.backgroundColor = SemanticColors.line.cgColor
        headerBorder.layer?.backgroundColor = SemanticColors.line.cgColor

        // Update item backgrounds
        let itemBg = SemanticColors.tileBg.cgColor
        let borderColor = SemanticColors.line.cgColor
        for view in contentStack.arrangedSubviews {
            view.layer?.backgroundColor = itemBg
            view.layer?.borderColor = borderColor
            view.layer?.cornerRadius = 6
        }
    }

    // MARK: - Actions

    @objc private func closeClicked() {
        delegate?.notificationPanelDidRequestClose()
    }

    @objc private func itemClicked(_ gesture: NSClickGestureRecognizer) {
        guard let view = gesture.view,
              let idStr = view.identifier?.rawValue,
              idStr.hasPrefix("panel.notification.item."),
              let index = Int(idStr.replacingOccurrences(of: "panel.notification.item.", with: "")),
              index < items.count else { return }
        delegate?.notificationPanelDidSelectItem(items[index])
    }
}
