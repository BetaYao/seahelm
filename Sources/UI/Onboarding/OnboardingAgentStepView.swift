import AppKit

/// Step 2: pick the default agent, and say plainly what Seahelm installs for it.
///
/// The card grid and the "show more" link live in the same scroller, so the link
/// tracks the bottom of the cards instead of stranding a block of empty space
/// between them. Status hooks are installed for every detected agent plus the
/// chosen default — the per-card checkboxes the old design had were clutter for
/// a choice virtually nobody changed, but the *outcome* is now stated on screen
/// rather than happening invisibly.
final class OnboardingAgentStepView: NSView {
    private var agents: [OnboardingAgentDetector.AgentInfo] = []
    private var defaultType: SailorType = .claudeCode
    private var showingMore = false

    private let columns = 3

    private let scroll = NSScrollView()
    private let document = OnboardingFlippedView()
    private let detectedLabel = NSTextField(labelWithString: "")
    private let gridStack = NSStackView()
    private let moreButton = OnboardingLinkButton(title: "")

    private let hooksNote = NSTextField(wrappingLabelWithString: "")
    private let yoloRow = OnboardingToggleRow(
        title: "Yolo mode",
        subtitle: "Launch agents with permission checks skipped. Fast, and entirely your risk.",
        symbol: "bolt.fill",
        tint: { SemanticColors.danger }
    )

    var isYoloEnabled: Bool { yoloRow.isOn }

    /// SF Symbol per agent — the old grid gave every card the same `❯_` tile,
    /// which made the grid a wall of identical chips.
    private static func symbol(for type: SailorType) -> String {
        switch type {
        case .claudeCode: return "asterisk"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .openCode: return "square.on.square"
        case .gemini: return "sparkles"
        case .cline: return "terminal.fill"
        case .goose: return "bird.fill"
        case .amp: return "waveform"
        case .aider: return "wand.and.stars"
        case .cursor: return "cursorarrow.rays"
        case .kiro: return "cube.fill"
        case .pi: return "function"
        default: return "terminal.fill"
        }
    }

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
        yoloRow.isOn = config.agentYolo
        // Nothing was detected — open on the full list rather than an empty grid.
        showingMore = !agents.contains(where: \.detected)
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
        gridStack.spacing = 10
        gridStack.alignment = .leading
        gridStack.translatesAutoresizingMaskIntoConstraints = false

        moreButton.target = self
        moreButton.action = #selector(toggleMore)

        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(detectedLabel)
        document.addSubview(gridStack)
        document.addSubview(moreButton)
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false

        hooksNote.font = NSFont.systemFont(ofSize: 12)
        hooksNote.textColor = OnboardingStyle.textFaint
        hooksNote.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scroll)
        addSubview(hooksNote)
        addSubview(yoloRow)

        NSLayoutConstraint.activate([
            detectedLabel.topAnchor.constraint(equalTo: document.topAnchor),
            detectedLabel.leadingAnchor.constraint(equalTo: document.leadingAnchor),

            gridStack.topAnchor.constraint(equalTo: detectedLabel.bottomAnchor, constant: 12),
            gridStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            gridStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),

            moreButton.topAnchor.constraint(equalTo: gridStack.bottomAnchor, constant: 12),
            moreButton.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            document.bottomAnchor.constraint(equalTo: moreButton.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.widthAnchor),

            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),

            hooksNote.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 20),
            hooksNote.leadingAnchor.constraint(equalTo: leadingAnchor),
            hooksNote.trailingAnchor.constraint(equalTo: trailingAnchor),

            yoloRow.topAnchor.constraint(equalTo: hooksNote.bottomAnchor, constant: 12),
            yoloRow.leadingAnchor.constraint(equalTo: leadingAnchor),
            yoloRow.trailingAnchor.constraint(equalTo: trailingAnchor),
            // Cap, not a pin: the block sits right under the cards when the grid
            // is short, and the scroller absorbs the overflow when it isn't.
            yoloRow.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])

        let hugContent = scroll.heightAnchor.constraint(equalTo: document.heightAnchor)
        hugContent.priority = .defaultHigh
        hugContent.isActive = true
    }

    private func rebuildCards() {
        gridStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let detected = agents.filter(\.detected)
        let hidden = agents.filter { !$0.detected }

        detectedLabel.attributedStringValue = makeDetectedHeader(count: detected.count)

        moreButton.isHidden = hidden.isEmpty
        moreButton.text = showingMore
            ? "Hide the \(hidden.count) we couldn't find"
            : "Show \(hidden.count) more agents  →"

        let visible = showingMore || detected.isEmpty ? agents : detected

        // Fixed-count rows so every card shares one width.
        var index = 0
        while index < visible.count {
            let slice = Array(visible[index..<min(index + columns, visible.count)])
            let row = NSStackView(views: slice.map { makeCard($0) })
            row.orientation = .horizontal
            row.spacing = 10
            row.distribution = .fillEqually
            row.translatesAutoresizingMaskIntoConstraints = false
            gridStack.addArrangedSubview(row)
            row.widthAnchor.constraint(
                equalTo: gridStack.widthAnchor,
                multiplier: CGFloat(slice.count) / CGFloat(columns),
                constant: -CGFloat(columns - slice.count) * 10 / CGFloat(columns)
            ).isActive = true
            index += columns
        }

        refreshHooksNote()
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func makeDetectedHeader(count: Int) -> NSAttributedString {
        let header = NSMutableAttributedString()
        if count > 0 {
            header.append(NSAttributedString(string: "● ", attributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: .bold),
                .foregroundColor: OnboardingStyle.ok,
            ]))
            header.append(NSAttributedString(
                string: "Found \(count) agent\(count == 1 ? "" : "s") on this Mac",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12.5, weight: .medium),
                    .foregroundColor: OnboardingStyle.textSecondary,
                ]
            ))
        } else {
            header.append(NSAttributedString(string: "○ ", attributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: .bold),
                .foregroundColor: OnboardingStyle.warn,
            ]))
            header.append(NSAttributedString(
                string: "No agent CLIs on your PATH yet — pick one anyway and install it later",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12.5, weight: .medium),
                    .foregroundColor: OnboardingStyle.textSecondary,
                ]
            ))
        }
        return header
    }

    private func refreshHooksNote() {
        let ids = selectedHookAgentIds()
        let list = ids.joined(separator: ", ")
        let text = NSMutableAttributedString(string: "On continue, Seahelm installs its status hooks for ", attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: OnboardingStyle.textFaint,
        ])
        text.append(NSAttributedString(string: list, attributes: [
            .font: AppFont.mono(size: 11.5, weight: .medium),
            .foregroundColor: OnboardingStyle.textSecondary,
        ]))
        text.append(NSAttributedString(
            string: ", plus the seahelm CLI in ~/.local/bin. Existing configs are merged, never overwritten.",
            attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: OnboardingStyle.textFaint,
            ]
        ))
        hooksNote.attributedStringValue = text
    }

    private func makeCard(_ info: OnboardingAgentDetector.AgentInfo) -> NSView {
        let isDefault = info.type == defaultType
        let card = OnboardingPanel()
        card.showsCheckBadge = true
        card.isSelected = isDefault
        let type = info.type
        card.onClick = { [weak self] in
            guard let self else { return }
            self.defaultType = type
            self.rebuildCards()
        }

        let icon = OnboardingIconTile(
            symbol: Self.symbol(for: info.type), side: 34, pointSize: 14,
            tint: { isDefault ? OnboardingStyle.accent : OnboardingStyle.textSecondary }
        )

        let title = OnboardingStyle.label(info.type.displayName, size: 13.5, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        let cmd = OnboardingStyle.monoLabel(
            info.detected ? info.command : "\(info.command) · not installed",
            size: 10.5,
            color: info.detected ? OnboardingStyle.textFaint : OnboardingStyle.warn
        )
        cmd.lineBreakMode = .byTruncatingTail

        card.addSubview(icon)
        card.addSubview(title)
        card.addSubview(cmd)

        NSLayoutConstraint.activate([
            card.heightAnchor.constraint(equalToConstant: 64),

            icon.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: card.centerYAnchor),

            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 11),
            title.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -30),
            title.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            cmd.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            cmd.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -10),
            cmd.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
        ])
        return card
    }

    @objc private func toggleMore() {
        showingMore.toggle()
        rebuildCards()
    }
}
