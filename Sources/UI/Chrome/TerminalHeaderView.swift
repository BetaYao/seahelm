import AppKit

/// Right-column chrome header. Expanded: centered title. Collapsed: lights + icons + title + expand.
final class TerminalHeaderView: NSView {
    weak var delegate: ChromeHeaderDelegate? {
        didSet { iconCluster.delegate = delegate }
    }

    /// Empty host for repositioned `standardWindowButton`s (used when collapsed).
    let trafficLightSlot = NSView()

    private let titleLabel = NSTextField(labelWithString: "")
    private let iconCluster = ChromeIconClusterView()
    private let expandButton = ChromeIconButton()
    private let editModeButton = ChromeIconButton()
    private let collapsedLeadingStack = NSStackView()

    /// Whether edit mode is currently on (drives the icon's active tint).
    private var editModeOn = false

    private var isCollapsed = false
    private var collapsedConstraints: [NSLayoutConstraint] = []
    private var expandedConstraints: [NSLayoutConstraint] = []
    private var colorSchemeObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    deinit {
        if let colorSchemeObserver {
            NotificationCenter.default.removeObserver(colorSchemeObserver)
        }
    }

    // MARK: - Title formatting

    /// Chrome title is the current pane title only (repo lives in the fleet row).
    static func formatTitle(repo: String, pane: String) -> String {
        let p = pane.trimmingCharacters(in: .whitespacesAndNewlines)
        if !p.isEmpty { return p }
        return repo.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Public API

    func setTitle(repo: String, pane: String) {
        titleLabel.stringValue = Self.formatTitle(repo: repo, pane: pane)
    }

    func setPaneTitle(_ pane: String) {
        titleLabel.stringValue = pane.trimmingCharacters(in: .whitespacesAndNewlines)
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
        // Identifier for UITests; children (icon buttons / title) remain interactive a11y elements.
        setAccessibilityIdentifier("chrome.terminalHeader")
        refreshImmersion()

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
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.cell?.usesSingleLineMode = true
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setAccessibilityIdentifier("chrome.terminalTitle")
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        configureExpandButton()
        addSubview(expandButton)

        configureEditModeButton()
        addSubview(editModeButton)

        colorSchemeObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyColorSchemeDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshImmersion()
        }

        // Edit-mode toggle is always visible (both collapse states); center it
        // vertically once and swap only its trailing anchor per state.
        NSLayoutConstraint.activate([
            editModeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        // Expanded: true horizontal center in the terminal column.
        expandedConstraints = [
            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: editModeButton.leadingAnchor, constant: -8),
            editModeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
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
                lessThanOrEqualTo: editModeButton.leadingAnchor, constant: -8),

            editModeButton.trailingAnchor.constraint(equalTo: expandButton.leadingAnchor, constant: -4),

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
            titleLabel.alignment = .center
        }
        needsLayout = true
    }

    private func configureEditModeButton() {
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        if let image = NSImage(systemSymbolName: "square.split.2x1",
                               accessibilityDescription: "Toggle File Edit Layout") {
            editModeButton.image = image.withSymbolConfiguration(config)
        }
        editModeButton.bezelStyle = .recessed
        editModeButton.isBordered = false
        editModeButton.imagePosition = .imageOnly
        editModeButton.target = self
        editModeButton.action = #selector(editModeClicked)
        editModeButton.translatesAutoresizingMaskIntoConstraints = false
        editModeButton.setAccessibilityIdentifier("chrome.icon.editMode")
        editModeButton.setAccessibilityLabel("Toggle File Edit Layout")
        editModeButton.wantsLayer = true
        editModeButton.layer?.cornerRadius = 7
        editModeButton.isEnabled = false
        NSLayoutConstraint.activate([
            editModeButton.widthAnchor.constraint(equalToConstant: 26),
            editModeButton.heightAnchor.constraint(equalToConstant: 26),
        ])
    }

    /// Enable + light the edit-mode toggle. `available` gates it on there being
    /// at least one open preview (empty set → focus mode only).
    func setEditMode(available: Bool, isOn: Bool) {
        editModeOn = isOn
        editModeButton.isEnabled = available
        refreshImmersion()
    }

    @objc private func expandClicked() {
        delegate?.chromeDidToggleSidebar()
    }

    @objc private func editModeClicked() {
        delegate?.chromeDidToggleEditMode()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshImmersion()
    }

    /// Match Ghostty surface colors so the title strip disappears into the terminal.
    func refreshImmersion() {
        let bridge = GhosttyBridge.shared
        layer?.backgroundColor = bridge.terminalChromeBackground.cgColor
        titleLabel.textColor = bridge.terminalChromeForeground
        expandButton.contentTintColor = bridge.terminalChromeForeground.withAlphaComponent(0.55)
        let editTint = editModeButton.isEnabled
            ? (editModeOn
                ? SemanticColors.accent
                : bridge.terminalChromeForeground.withAlphaComponent(0.55))
            : bridge.terminalChromeForeground.withAlphaComponent(0.2)
        editModeButton.contentTintColor = editTint
        editModeButton.layer?.backgroundColor = editModeOn && editModeButton.isEnabled
            ? SemanticColors.accent.withAlphaComponent(0.15).cgColor
            : NSColor.clear.cgColor
    }
}
