import AppKit

/// Right-column chrome header. Expanded: title only. Collapsed: lights + icons + title + expand.
final class TerminalHeaderView: NSView {
    weak var delegate: ChromeHeaderDelegate? {
        didSet { iconCluster.delegate = delegate }
    }

    /// Empty host for repositioned `standardWindowButton`s (used when collapsed).
    let trafficLightSlot = NSView()

    private let titleLabel = NSTextField(labelWithString: "")
    private let iconCluster = ChromeIconClusterView()
    private let expandButton = ChromeIconButton()
    private let collapsedLeadingStack = NSStackView()

    private var isCollapsed = false
    private var collapsedConstraints: [NSLayoutConstraint] = []
    private var expandedConstraints: [NSLayoutConstraint] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    // MARK: - Title formatting

    /// `"repo · pane"`, omitting empty pieces so a lone side never leaves a dangling separator.
    static func formatTitle(repo: String, pane: String) -> String {
        let r = repo.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = pane.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (r.isEmpty, p.isEmpty) {
        case (true, true): return ""
        case (false, true): return r
        case (true, false): return p
        case (false, false): return "\(r) · \(p)"
        }
    }

    // MARK: - Public API

    func setTitle(repo: String, pane: String) {
        titleLabel.stringValue = Self.formatTitle(repo: repo, pane: pane)
    }

    func setCollapsed(_ collapsed: Bool) {
        guard isCollapsed != collapsed else { return }
        isCollapsed = collapsed
        applyCollapsedState()
    }

    func setActivePane(_ pane: ChromeLeftPane?) {
        iconCluster.setActivePane(pane)
    }

    func setWorktreeContextEnabled(_ enabled: Bool) {
        iconCluster.setWorktreeContextEnabled(enabled)
    }

    // MARK: - Setup

    private func setup() {
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("chrome.terminalHeader")

        trafficLightSlot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(trafficLightSlot)

        iconCluster.delegate = delegate
        iconCluster.translatesAutoresizingMaskIntoConstraints = false

        collapsedLeadingStack.orientation = .horizontal
        collapsedLeadingStack.spacing = 8
        collapsedLeadingStack.alignment = .centerY
        collapsedLeadingStack.translatesAutoresizingMaskIntoConstraints = false
        collapsedLeadingStack.addArrangedSubview(iconCluster)
        addSubview(collapsedLeadingStack)

        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = SemanticColors.text
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.cell?.usesSingleLineMode = true
        titleLabel.setAccessibilityIdentifier("chrome.terminalTitle")
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        configureExpandButton()
        addSubview(expandButton)

        expandedConstraints = [
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ]

        collapsedConstraints = [
            trafficLightSlot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            trafficLightSlot.centerYAnchor.constraint(equalTo: centerYAnchor),
            trafficLightSlot.widthAnchor.constraint(equalToConstant: 70),
            trafficLightSlot.heightAnchor.constraint(equalToConstant: 14),

            collapsedLeadingStack.leadingAnchor.constraint(
                equalTo: trafficLightSlot.trailingAnchor, constant: 8),
            collapsedLeadingStack.centerYAnchor.constraint(equalTo: centerYAnchor),

            titleLabel.leadingAnchor.constraint(
                equalTo: collapsedLeadingStack.trailingAnchor, constant: 10),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: expandButton.leadingAnchor, constant: -8),

            expandButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            expandButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ]

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: ChromeLayoutMetrics.headerHeight),
        ])

        applyCollapsedState()
    }

    private func configureExpandButton() {
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        if let image = NSImage(systemSymbolName: "sidebar.left",
                               accessibilityDescription: "Expand Sidebar") {
            expandButton.image = image.withSymbolConfiguration(config)
        }
        expandButton.bezelStyle = .recessed
        expandButton.isBordered = false
        expandButton.imagePosition = .imageOnly
        expandButton.contentTintColor = NSColor(hex: 0x888888)
        expandButton.target = self
        expandButton.action = #selector(expandClicked)
        expandButton.translatesAutoresizingMaskIntoConstraints = false
        expandButton.setAccessibilityIdentifier("chrome.icon.sidebar")
        expandButton.setAccessibilityLabel("Expand Sidebar")
        expandButton.wantsLayer = true
        expandButton.layer?.cornerRadius = 7
        NSLayoutConstraint.activate([
            expandButton.widthAnchor.constraint(equalToConstant: 26),
            expandButton.heightAnchor.constraint(equalToConstant: 26),
        ])
    }

    private func applyCollapsedState() {
        if isCollapsed {
            NSLayoutConstraint.deactivate(expandedConstraints)
            NSLayoutConstraint.activate(collapsedConstraints)
            trafficLightSlot.isHidden = false
            collapsedLeadingStack.isHidden = false
            expandButton.isHidden = false
            titleLabel.alignment = .left
        } else {
            NSLayoutConstraint.deactivate(collapsedConstraints)
            NSLayoutConstraint.activate(expandedConstraints)
            trafficLightSlot.isHidden = true
            collapsedLeadingStack.isHidden = true
            expandButton.isHidden = true
            titleLabel.alignment = .left
        }
        needsLayout = true
    }

    @objc private func expandClicked() {
        delegate?.chromeDidToggleSidebar()
    }
}
