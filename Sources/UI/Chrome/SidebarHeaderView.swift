import AppKit

/// Left-column chrome header: traffic-light host + tool icons + sidebar toggle.
final class SidebarHeaderView: NSView {
    weak var delegate: ChromeHeaderDelegate? {
        didSet { iconCluster.delegate = delegate }
    }

    /// Empty host for repositioned `standardWindowButton`s.
    let trafficLightSlot = NSView()

    private let iconCluster = ChromeIconClusterView()
    private let sidebarButton = ChromeIconButton()
    private let trailingStack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    // MARK: - Public API

    func setActivePane(_ pane: ChromeLeftPane?) {
        iconCluster.setActivePane(pane)
    }

    func setWorktreeContextEnabled(_ enabled: Bool) {
        iconCluster.setWorktreeContextEnabled(enabled)
    }

    // MARK: - Setup

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        translatesAutoresizingMaskIntoConstraints = false
        // Identifier for UITests; children (icon buttons) remain the interactive a11y elements.
        setAccessibilityIdentifier("chrome.sidebarHeader")

        trafficLightSlot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(trafficLightSlot)

        trailingStack.orientation = .horizontal
        trailingStack.spacing = 2
        trailingStack.alignment = .centerY
        trailingStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(trailingStack)

        iconCluster.delegate = delegate
        trailingStack.addArrangedSubview(iconCluster)

        configureSidebarButton()
        trailingStack.addArrangedSubview(sidebarButton)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: ChromeLayoutMetrics.headerHeight),

            trafficLightSlot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            trafficLightSlot.centerYAnchor.constraint(equalTo: centerYAnchor),
            trafficLightSlot.widthAnchor.constraint(equalToConstant: 70),
            trafficLightSlot.heightAnchor.constraint(equalToConstant: 14),

            trailingStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            trailingStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailingStack.leadingAnchor.constraint(
                greaterThanOrEqualTo: trafficLightSlot.trailingAnchor, constant: 8),
        ])
    }

    private func configureSidebarButton() {
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        if let image = NSImage(systemSymbolName: "sidebar.left",
                               accessibilityDescription: "Toggle Sidebar") {
            sidebarButton.image = image.withSymbolConfiguration(config)
        }
        sidebarButton.bezelStyle = .recessed
        sidebarButton.isBordered = false
        sidebarButton.imagePosition = .imageOnly
        sidebarButton.contentTintColor = NSColor(hex: 0x888888)
        sidebarButton.target = self
        sidebarButton.action = #selector(sidebarClicked)
        sidebarButton.translatesAutoresizingMaskIntoConstraints = false
        sidebarButton.setAccessibilityIdentifier("chrome.icon.sidebar")
        sidebarButton.setAccessibilityLabel("Toggle Sidebar")
        sidebarButton.wantsLayer = true
        sidebarButton.layer?.cornerRadius = 7
        NSLayoutConstraint.activate([
            sidebarButton.widthAnchor.constraint(equalToConstant: 26),
            sidebarButton.heightAnchor.constraint(equalToConstant: 26),
        ])
    }

    @objc private func sidebarClicked() {
        delegate?.chromeDidToggleSidebar()
    }
}
