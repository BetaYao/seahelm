import AppKit

/// Terminal-side empty fleet: every AI agent Seahelm can launch, lit when it is
/// on PATH and dimmed when it is not. Any row opens that agent's install page.
final class EmptyFleetAgentsView: NSView {
    private let watermark = HelmWatermarkView()
    private let titleLabel = NSTextField(labelWithString: "Agents")
    private let hintLabel = NSTextField(wrappingLabelWithString:
        "Installed agents are ready to use. Click any agent to open its install page.")
    private let listStack = NSStackView()
    private let contentStack = NSStackView()

    /// Overridable for tests; production opens the system browser.
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }

    private var rows: [AgentRow] = []
    /// Bumped on every PATH rescan so a slow `AgentDetector.scan` cannot paint
    /// over a newer one (or a test-injected list).
    private var scanGeneration = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Supported agents")

        watermark.translatesAutoresizingMaskIntoConstraints = false
        addSubview(watermark)

        titleLabel.font = AppFont.mono(size: 15, weight: .semibold)
        titleLabel.textColor = Theme.textPrimary
        titleLabel.alignment = .center

        hintLabel.font = AppFont.mono(size: 11)
        hintLabel.textColor = Theme.textSecondary
        hintLabel.alignment = .center
        hintLabel.maximumNumberOfLines = 2
        hintLabel.preferredMaxLayoutWidth = 320

        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 4
        listStack.translatesAutoresizingMaskIntoConstraints = false

        contentStack.orientation = .vertical
        contentStack.alignment = .centerX
        contentStack.spacing = 10
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        [titleLabel, hintLabel, listStack].forEach(contentStack.addArrangedSubview)
        contentStack.setCustomSpacing(14, after: hintLabel)
        addSubview(contentStack)

        NSLayoutConstraint.activate([
            watermark.topAnchor.constraint(equalTo: topAnchor),
            watermark.leadingAnchor.constraint(equalTo: leadingAnchor),
            watermark.trailingAnchor.constraint(equalTo: trailingAnchor),
            watermark.bottomAnchor.constraint(equalTo: bottomAnchor),

            contentStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            contentStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            contentStack.widthAnchor.constraint(lessThanOrEqualToConstant: 340),
            contentStack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            contentStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
            listStack.widthAnchor.constraint(equalToConstant: 280),
        ])

        NotificationCenter.default.addObserver(
            self, selector: #selector(paletteDidChange),
            name: .ghosttyColorSchemeDidChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification, object: nil)

        reload()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Rebuild rows from a PATH scan (or an injected list for tests).
    ///
    /// `AgentDetector.scan` starts a login shell to resolve PATH — about a
    /// second, and up to `ProcessRunner.lookupTimeout` when the shell is chatty.
    /// That must never run on the main thread: this view lives for the life of
    /// the dashboard and used to rescan on every `didBecomeActive`, which made
    /// switching back to Seahelm beachball for several seconds even while the
    /// empty state was hidden.
    func reload(agents: [AgentDetector.AgentInfo]? = nil) {
        if let agents {
            scanGeneration += 1
            apply(agents)
            return
        }
        scanGeneration += 1
        let generation = scanGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let infos = AgentDetector.scan()
            DispatchQueue.main.async {
                guard let self, generation == self.scanGeneration else { return }
                self.apply(infos)
            }
        }
    }

    private func apply(_ infos: [AgentDetector.AgentInfo]) {
        listStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        rows.removeAll()

        for info in infos {
            let row = AgentRow(info: info)
            row.onClick = { [weak self] in self?.open(info.type) }
            listStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
            rows.append(row)
        }
        applyPalette()
    }

    private func open(_ type: AgentType) {
        guard let url = type.installURL else { return }
        openURL(url)
    }

    @objc private func appDidBecomeActive() {
        // Still attached (and still observing) while a real fleet is showing;
        // skip the scan entirely unless this empty state is actually on screen.
        guard window != nil, !isHiddenOrHasHiddenAncestor else { return }
        reload()
    }

    @objc private func paletteDidChange() { applyPalette() }

    private func applyPalette() {
        titleLabel.textColor = Theme.textPrimary
        hintLabel.textColor = Theme.textSecondary
        rows.forEach { $0.applyPalette() }
    }

    // MARK: - Row

    private final class AgentRow: NSView {
        var onClick: (() -> Void)?
        private let info: AgentDetector.AgentInfo
        private let glyphLabel = NSTextField(labelWithString: "")
        private let nameLabel = NSTextField(labelWithString: "")
        private let statusLabel = NSTextField(labelWithString: "")
        private var tracking: NSTrackingArea?
        private var hovering = false {
            didSet { applyPalette() }
        }

        init(info: AgentDetector.AgentInfo) {
            self.info = info
            super.init(frame: .zero)
            wantsLayer = true
            layer?.cornerRadius = 6
            setAccessibilityElement(true)
            setAccessibilityRole(.button)
            setAccessibilityIdentifier("dashboard.emptyState.agent.\(info.type.rawValue)")
            let status = info.detected ? "Installed" : "Not installed"
            setAccessibilityLabel("\(info.type.displayName), \(status)")
            toolTip = info.detected
                ? "Open \(info.type.displayName) docs"
                : "Install \(info.type.displayName)"

            glyphLabel.stringValue = info.type.tabGlyph ?? "◆"
            glyphLabel.font = AppFont.mono(size: 13)
            glyphLabel.setContentHuggingPriority(.required, for: .horizontal)

            nameLabel.stringValue = info.type.displayName
            nameLabel.font = AppFont.mono(size: 13, weight: .medium)

            statusLabel.stringValue = status
            statusLabel.font = AppFont.mono(size: 11)
            statusLabel.alignment = .right
            statusLabel.setContentHuggingPriority(.required, for: .horizontal)

            let stack = NSStackView(views: [glyphLabel, nameLabel, statusLabel])
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.spacing = 8
            stack.translatesAutoresizingMaskIntoConstraints = false
            nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
            addSubview(stack)

            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: topAnchor, constant: 7),
                stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
                stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
                stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
                heightAnchor.constraint(greaterThanOrEqualToConstant: 30),
            ])

            applyPalette()
        }

        required init?(coder: NSCoder) { fatalError() }

        func applyPalette() {
            let bright = info.detected
            let primary = Theme.textPrimary
            let muted = Theme.textSecondary
            let alpha: CGFloat = bright ? 1 : 0.42
            glyphLabel.textColor = (bright ? primary : muted).withAlphaComponent(alpha)
            nameLabel.textColor = (bright ? primary : muted).withAlphaComponent(alpha)
            statusLabel.textColor = muted.withAlphaComponent(bright ? 0.85 : 0.4)
            layer?.backgroundColor = hovering
                ? Theme.accent.withAlphaComponent(0.12).cgColor
                : NSColor.clear.cgColor
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
                owner: self, userInfo: nil)
            addTrackingArea(area)
            tracking = area
        }

        override func mouseEntered(with event: NSEvent) { hovering = true }
        override func mouseExited(with event: NSEvent) { hovering = false }
        override func mouseDown(with event: NSEvent) { onClick?() }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }
}
