import AppKit

/// Step 1: pick default agent from a card grid, Yolo toggle.
/// Status hooks are installed for every detected agent (plus the chosen
/// default) — the old per-card checkboxes added clutter for a choice
/// virtually nobody changed.
final class OnboardingAgentStepView: NSView {
    private var agents: [OnboardingAgentDetector.AgentInfo] = []
    private var defaultType: SailorType = .claudeCode
    private var showingMore = false

    private let columns = 3

    private let detectedLabel = NSTextField(labelWithString: "")
    private let scroll = NSScrollView()
    private let gridStack = NSStackView()
    private let moreButton = OnboardingLinkButton(title: "", color: OnboardingStyle.accent)
    private let yoloPanel = OnboardingPanel()
    private let yoloButton = NSButton(checkboxWithTitle: "Yolo — dangerously skip permission checks",
                                      target: nil, action: nil)

    var isYoloEnabled: Bool { yoloButton.state == .on }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(config: Config) {
        agents = OnboardingAgentDetector.scan()
        defaultType = SailorType(rawValue: config.defaultAgent)
            ?? OnboardingAgentDetector.preferredDefault(from: agents)
        yoloButton.state = config.agentYolo ? .on : .off
        rebuildCards()
    }

    func selectedDefaultAgent() -> SailorType { defaultType }

    func selectedHookAgentIds() -> [String] {
        var types = Set(agents.filter(\.detected).map(\.type))
        types.insert(defaultType)
        return types.map(\.manifestId).sorted()
    }

    private func setup() {
        detectedLabel.translatesAutoresizingMaskIntoConstraints = false

        gridStack.orientation = .vertical
        gridStack.spacing = 12
        gridStack.alignment = .leading
        gridStack.translatesAutoresizingMaskIntoConstraints = false

        // Flipped document so short content hugs the top, not the bottom.
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(gridStack)
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = doc
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            gridStack.topAnchor.constraint(equalTo: doc.topAnchor),
            gridStack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            gridStack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            gridStack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.widthAnchor),
        ])

        moreButton.target = self
        moreButton.action = #selector(toggleMore)

        OnboardingStyle.systemTitle(yoloButton, size: 13, color: OnboardingStyle.textPrimary)
        yoloButton.translatesAutoresizingMaskIntoConstraints = false
        yoloPanel.addSubview(yoloButton)

        addSubview(detectedLabel)
        addSubview(scroll)
        addSubview(moreButton)
        addSubview(yoloPanel)

        NSLayoutConstraint.activate([
            detectedLabel.topAnchor.constraint(equalTo: topAnchor),
            detectedLabel.leadingAnchor.constraint(equalTo: leadingAnchor),

            scroll.topAnchor.constraint(equalTo: detectedLabel.bottomAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: moreButton.topAnchor, constant: -10),

            moreButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            moreButton.bottomAnchor.constraint(equalTo: yoloPanel.topAnchor, constant: -16),

            yoloPanel.leadingAnchor.constraint(equalTo: leadingAnchor),
            yoloPanel.trailingAnchor.constraint(equalTo: trailingAnchor),
            yoloPanel.bottomAnchor.constraint(equalTo: bottomAnchor),
            yoloPanel.heightAnchor.constraint(equalToConstant: 52),

            yoloButton.leadingAnchor.constraint(equalTo: yoloPanel.leadingAnchor, constant: 16),
            yoloButton.centerYAnchor.constraint(equalTo: yoloPanel.centerYAnchor),
        ])
    }

    private func rebuildCards() {
        gridStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let detected = agents.filter(\.detected)
        let hidden = agents.filter { !$0.detected }

        let header = NSMutableAttributedString()
        header.append(NSAttributedString(string: "● ", attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .bold),
            .foregroundColor: NSColor.systemGreen,
        ]))
        header.append(NSAttributedString(string: "Detected on this Mac", attributes: [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .medium),
            .foregroundColor: OnboardingStyle.textSecondary,
        ]))
        header.append(NSAttributedString(string: "  ·  \(detected.count)", attributes: [
            .font: NSFont.systemFont(ofSize: 12.5),
            .foregroundColor: OnboardingStyle.textFaint,
        ]))
        detectedLabel.attributedStringValue = header

        let visible = showingMore ? agents : detected.isEmpty ? agents : detected
        moreButton.isHidden = hidden.isEmpty
        let moreTitle = showingMore ? "Hide undetected agents" : "Show \(hidden.count) more agents →"
        moreButton.attributedTitle = NSAttributedString(string: moreTitle, attributes: [
            .font: NSFont.systemFont(ofSize: 12.5),
            .foregroundColor: OnboardingStyle.accent,
        ])

        // Lay cards out in fixed-count rows so every card shares one width.
        var index = 0
        while index < visible.count {
            let slice = Array(visible[index..<min(index + columns, visible.count)])
            let row = NSStackView(views: slice.map { makeCard($0) })
            row.orientation = .horizontal
            row.spacing = 12
            row.distribution = .fillEqually
            row.translatesAutoresizingMaskIntoConstraints = false
            gridStack.addArrangedSubview(row)
            row.widthAnchor.constraint(
                equalTo: gridStack.widthAnchor,
                multiplier: CGFloat(slice.count) / CGFloat(columns),
                constant: -CGFloat(columns - slice.count) * 12 / CGFloat(columns)
            ).isActive = true
            index += columns
        }

        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func makeCard(_ info: OnboardingAgentDetector.AgentInfo) -> NSView {
        let card = OnboardingPanel()
        card.showsCheckBadge = true
        card.isSelected = info.type == defaultType
        let type = info.type
        card.onClick = { [weak self] in
            guard let self else { return }
            self.defaultType = type
            self.rebuildCards()
        }

        // Terminal glyph tile — stands in for per-agent icons.
        let iconTile = NSView()
        iconTile.wantsLayer = true
        iconTile.layer?.cornerRadius = 9
        iconTile.layer?.backgroundColor = (info.type == defaultType
            ? OnboardingStyle.accent.withAlphaComponent(0.14)
            : NSColor.black.withAlphaComponent(0.05)).cgColor
        iconTile.translatesAutoresizingMaskIntoConstraints = false
        let glyph = OnboardingStyle.monoLabel("❯_", size: 13, weight: .bold,
                                              color: info.type == defaultType
                                                  ? OnboardingStyle.accent
                                                  : OnboardingStyle.textSecondary)
        iconTile.addSubview(glyph)

        let title = OnboardingStyle.label(info.type.displayName, size: 14, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        let cmd = OnboardingStyle.monoLabel(info.command, size: 11, color: OnboardingStyle.textFaint)
        cmd.lineBreakMode = .byTruncatingTail

        card.addSubview(iconTile)
        card.addSubview(title)
        card.addSubview(cmd)

        NSLayoutConstraint.activate([
            card.heightAnchor.constraint(equalToConstant: 72),

            iconTile.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            iconTile.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            iconTile.widthAnchor.constraint(equalToConstant: 38),
            iconTile.heightAnchor.constraint(equalToConstant: 38),
            glyph.centerXAnchor.constraint(equalTo: iconTile.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: iconTile.centerYAnchor),

            title.leadingAnchor.constraint(equalTo: iconTile.trailingAnchor, constant: 12),
            title.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -30),
            title.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            cmd.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            cmd.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -12),
            cmd.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
        ])
        return card
    }

    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    @objc private func toggleMore() {
        showingMore.toggle()
        rebuildCards()
    }
}
