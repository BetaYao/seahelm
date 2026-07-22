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
    private let brandStack = NSStackView()
    private var trafficLightWidth: NSLayoutConstraint!

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

        configureBrand()
        addSubview(brandStack)

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
            trafficLightWidth,
            trafficLightSlot.heightAnchor.constraint(equalToConstant: 14),

            brandStack.leadingAnchor.constraint(
                equalTo: trafficLightSlot.trailingAnchor, constant: 10),
            brandStack.centerYAnchor.constraint(equalTo: centerYAnchor),

            trailingStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            trailingStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailingStack.leadingAnchor.constraint(
                greaterThanOrEqualTo: brandStack.trailingAnchor, constant: 8),
        ])
    }

    /// Sailboat glyph + wordmark. Sits where the traffic lights leave off, so it fills
    /// the gap that opens up in full screen once the slot collapses to zero.
    private func configureBrand() {
        brandStack.orientation = .horizontal
        brandStack.spacing = 5
        brandStack.alignment = .centerY
        brandStack.translatesAutoresizingMaskIntoConstraints = false

        let mark = NSImageView()
        mark.image = NSImage(named: "AppIcon") ?? NSApp.applicationIconImage
        mark.imageScaling = .scaleProportionallyUpOrDown
        mark.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            mark.widthAnchor.constraint(equalToConstant: 20),
            mark.heightAnchor.constraint(equalToConstant: 20),
        ])
        brandStack.addArrangedSubview(mark)

        let label = NSTextField(labelWithString: "Seahelm")
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = NSColor(hex: 0x888888)
        brandStack.addArrangedSubview(label)

        trafficLightWidth = trafficLightSlot.widthAnchor.constraint(equalToConstant: 70)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncTrafficLightSlot()
        guard let window else { return }
        let center = NotificationCenter.default
        for name in [NSWindow.didEnterFullScreenNotification,
                     NSWindow.didExitFullScreenNotification] {
            center.addObserver(self, selector: #selector(syncTrafficLightSlot),
                               name: name, object: window)
        }
    }

    @objc private func syncTrafficLightSlot() {
        let fullScreen = window?.styleMask.contains(.fullScreen) ?? false
        trafficLightWidth.constant = fullScreen ? 0 : 70
        // Only shown in full screen, where the traffic lights vacate the corner.
        brandStack.isHidden = !fullScreen
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

    override var mouseDownCanMoveWindow: Bool { true }
}
